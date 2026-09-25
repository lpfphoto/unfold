import Foundation
import IOKit.hid
import QuartzCore

/// Reads the MacBook hinge angle from the "lid angle" HID sensor
/// (Apple vendor 0x05AC, product 0x8104, sensor usage page 0x20 / orientation usage 0x8A).
/// Present on 16" MacBook Pro 2019 and most Apple Silicon MacBooks. Needs no special permissions.
final class LidSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    var isOpen: Bool { device != nil }

    @discardableResult
    func open() -> Bool {
        close()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x0020,
            kIOHIDPrimaryUsageKey: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        manager = m
        guard let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let d = devices.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            close()
            return false
        }
        device = d
        return read() != nil
    }

    /// Hinge angle in degrees (0 = closed), or nil if the sensor could not be read.
    func read() -> Double? {
        guard let d = device else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8) { buffer -> Double? in
            var length = CFIndex(buffer.count)
            guard IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, buffer.baseAddress!, &length) == kIOReturnSuccess,
                  length >= 3 else { return nil }
            return Double(UInt16(buffer[1]) | UInt16(buffer[2]) << 8)
        }
    }

    func close() {
        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
    }
}

/// Polls the sensor on its own thread. The HID call blocks for ~0.6 ms (mostly waiting on the hardware),
/// which would otherwise eat into every animation frame on the main thread; here it can take its time and
/// each frame simply picks up the newest reading.
final class SensorPoller: @unchecked Sendable {
    private let sensor = LidSensor()
    private let sensorLock = NSLock()          // serialises all IOHID calls (poll thread + `readNow`)
    private let stateLock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var angle: Double?
    private var available = false
    private var interval = 1.0 / 12

    /// Opens the sensor, takes a first reading synchronously and starts polling. Returns that reading.
    func start() -> Double? {
        let first = readNow()
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "Unfold.LidSensor"
        thread.qualityOfService = .userInteractive
        thread.start()
        return first
    }

    /// Newest reading (nil until the first success) and whether the sensor currently answers.
    var latest: (angle: Double?, available: Bool) {
        stateLock.withLock { (angle, available) }
    }

    /// 120 Hz while animating, 12 Hz otherwise. Switching to fast polls right away.
    func setFast(_ fast: Bool) {
        let new = fast ? 1.0 / 120 : 1.0 / 12
        let changed = stateLock.withLock { () -> Bool in
            defer { interval = new }
            return interval != new
        }
        if changed && fast { wake.signal() }
    }

    /// A fresh reading right now (e.g. after waking), reopening the device if it stopped answering.
    @discardableResult
    func readNow() -> Double? {
        let (value, open) = sensorLock.withLock { () -> (Double?, Bool) in
            if sensor.isOpen, let v = sensor.read() { return (v, true) }
            let v = sensor.open() ? sensor.read() : nil
            return (v, sensor.isOpen)
        }
        store(value, open: open)
        return value
    }

    private func run() {
        var failures = 0
        while true {
            let started = CACurrentMediaTime()
            let (value, open) = sensorLock.withLock { () -> (Double?, Bool) in
                if let v = sensor.read() { return (v, true) }
                failures += 1
                // Keep retrying cheaply; reopen now and then (the device can vanish across sleep).
                let v = failures % 60 == 0 && sensor.open() ? sensor.read() : nil
                return (v, sensor.isOpen)
            }
            if value != nil { failures = 0 }
            store(value, open: open)
            let wait = stateLock.withLock { interval } - (CACurrentMediaTime() - started)
            if wait > 0 { _ = wake.wait(timeout: .now() + wait) }
        }
    }

    private func store(_ value: Double?, open: Bool) {
        stateLock.withLock {
            if let value { angle = value; available = true } else if !open { available = false }
        }
    }
}
