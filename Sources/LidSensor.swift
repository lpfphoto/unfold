import Foundation
import IOKit.hid
import QuartzCore

/// Reads the MacBook hinge angle from the "lid angle" HID sensor
/// (Apple vendor 0x05AC, product 0x8104, sensor usage page 0x20 / orientation usage 0x8A).
/// Present on 16" MacBook Pro 2019 and most Apple Silicon MacBooks. Needs no special permissions.
///
/// The sensor exposes the angle twice: report 1 in whole degrees (logical 0…360), and report 7 in
/// hundredths of a degree (usage 0x0545, logical 0…36000, unit exponent −2). Both are refreshed by the
/// sensor at only ~10 Hz. Report 7 is used when present, report 1 otherwise.
final class LidSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var fine = false

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
        fine = readFine() != nil
        return read() != nil
    }

    /// Hinge angle in degrees (0 = closed), or nil if the sensor could not be read.
    func read() -> Double? {
        fine ? (readFine() ?? readWhole()) : readWhole()
    }

    private func readFine() -> Double? {
        report(7, minLength: 5) { b in
            let value = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
            return value <= 36000 ? Double(value) / 100 : nil
        }
    }

    private func readWhole() -> Double? {
        report(1, minLength: 3) { b in Double(UInt16(b[1]) | UInt16(b[2]) << 8) }
    }

    private func report(_ id: Int, minLength: Int, _ decode: (UnsafeMutableBufferPointer<UInt8>) -> Double?) -> Double? {
        guard let d = device else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { buffer -> Double? in
            var length = CFIndex(buffer.count)
            guard IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, id, buffer.baseAddress!, &length) == kIOReturnSuccess,
                  length >= minLength else { return nil }
            return decode(buffer)
        }
    }

    func close() {
        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
    }
}

/// One sensor sample, stamped with the moment the sensor produced it (on the host clock).
struct LidSample {
    var time: CFTimeInterval
    var angle: Double
}

/// Polls the sensor on its own thread (the HID call blocks for ~0.6–0.9 ms, mostly waiting on the hardware)
/// and turns its ~10 Hz samples into a continuous angle.
///
/// The sensor samples on a very regular clock (≈100.6 ms). The poller locks onto that clock: a changed
/// value is stamped with the sensor tick that falls inside the window since the previous read, not with
/// the (jittery) moment we happened to notice it. While the value stays the same, the ticks still happen,
/// so they are recorded as repeated samples; otherwise a movement after a pause would be smeared back
/// across the pause. `angle(at:)` then draws a smooth curve exactly through those samples.
final class SensorPoller: @unchecked Sendable {
    private let sensor = LidSensor()
    private let sensorLock = NSLock()          // serialises all IOHID calls (poll thread + `readNow`)
    private let stateLock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var available = false
    private var interval = 1.0 / 12

    private var samples: [LidSample] = []      // oldest first
    private var version = 0                    // bumped whenever `samples` changes
    private var lastValue: Double?
    private var lastReadStart: CFTimeInterval = 0
    private var tick: CFTimeInterval?          // last sensor tick we are locked onto
    private var lastWasRepeat = false          // the newest sample is an inferred repeat, not a reading
    private var period = 0.1006                // sensor sample period, refined while locked
    private static let historyLimit = 32

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
        stateLock.withLock { (samples.last?.angle, available) }
    }

    /// The current sample history (a copy) and its version, which changes whenever a sample is added.
    func snapshot() -> (version: Int, samples: [LidSample]) {
        stateLock.withLock { (version, samples) }
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
    /// Starts a new sample history: whatever was recorded before is from another moment.
    @discardableResult
    func readNow() -> Double? {
        let started = CACurrentMediaTime()
        let (value, open) = sensorLock.withLock { () -> (Double?, Bool) in
            if sensor.isOpen, let v = sensor.read() { return (v, true) }
            let v = sensor.open() ? sensor.read() : nil
            return (v, sensor.isOpen)
        }
        stateLock.withLock {
            if let value {
                samples = [LidSample(time: started, angle: value)]
                version += 1
                lastValue = value
                tick = nil
                lastWasRepeat = false
                available = true
            } else if !open {
                available = false
            }
            lastReadStart = started
        }
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
            stateLock.withLock { record(value, open: open, readStarted: started) }
            let wait = stateLock.withLock { interval } - (CACurrentMediaTime() - started)
            if wait > 0 { _ = wake.wait(timeout: .now() + wait) }
        }
    }

    /// Called with `stateLock` held.
    private func record(_ value: Double?, open: Bool, readStarted now: CFTimeInterval) {
        let windowStart = lastReadStart
        lastReadStart = now
        guard let value else {
            if !open { available = false }
            return
        }
        available = true
        guard let last = lastValue else {
            append(LidSample(time: now, angle: value))
            lastValue = value
            return
        }
        lastValue = value
        if value != last {
            let stamp = stampChange(windowStart: windowStart, windowEnd: now)
            // A repeat inferred for this very tick was premature: the change had happened, just not shown yet.
            if lastWasRepeat, let previous = samples.last, previous.time >= stamp - 0.001 { samples.removeLast() }
            append(LidSample(time: stamp, angle: value))
            lastWasRepeat = false
        } else if let locked = tick {
            // Unchanged, but the sensor kept sampling: record the ticks that are safely past (a change can take
            // several milliseconds to become readable) as repeats.
            var next = locked + period
            while next < now - 0.015 {
                append(LidSample(time: next, angle: value))
                tick = next
                lastWasRepeat = true
                next += period
            }
        }
    }

    /// The sensor tick at which a change observed in (windowStart, windowEnd] happened.
    private func stampChange(windowStart: CFTimeInterval, windowEnd: CFTimeInterval) -> CFTimeInterval {
        let middle = (windowStart + windowEnd) / 2
        let halfWidth = (windowEnd - windowStart) / 2
        if let locked = tick {
            let n = ((middle - locked) / period).rounded()
            let predicted = locked + n * period
            // n = 0 is allowed only onto an inferred repeat, which the change then replaces.
            if n >= (lastWasRepeat ? 0 : 1), abs(predicted - middle) <= halfWidth + 0.004 {
                // The clock predicts a tick inside the window: use it, and nudge the clock towards what we
                // saw when the window is tight enough to say something (fast polling).
                let residual = middle - predicted
                let gain = halfWidth < 0.01 ? 0.25 : 0
                if n >= 1 { period = min(max(period + gain * 0.2 * residual / n, 0.09), 0.11) }
                tick = predicted + gain * residual
                return tick!
            }
        }
        tick = middle                                    // no lock yet, or lost it: start from here
        return middle
    }

    private func append(_ sample: LidSample) {
        version += 1
        samples.append(sample)
        if samples.count > Self.historyLimit { samples.removeFirst(samples.count - Self.historyLimit) }
    }

    /// Cubic Hermite through the samples with centred (Catmull-Rom) tangents: passes exactly through every
    /// sample and has no kinks. (A monotone variant never overshoots, but on real lid movements Catmull-Rom
    /// strays at most ~0.05° past the samples, within the sensor noise, and is ~15 % smoother.)
    static func interpolate(_ s: [LidSample], at t: CFTimeInterval) -> Double? {
        guard let first = s.first, let last = s.last else { return nil }
        if s.count == 1 || t <= first.time { return first.angle }
        if t >= last.time { return last.angle }
        var i = s.count - 2
        while i > 0 && s[i].time > t { i -= 1 }
        let p0 = s[max(i - 1, 0)], p1 = s[i], p2 = s[i + 1], p3 = s[min(i + 2, s.count - 1)]
        let m1 = p2.time > p0.time ? (p2.angle - p0.angle) / (p2.time - p0.time) : 0
        let m2 = p3.time > p1.time ? (p3.angle - p1.angle) / (p3.time - p1.time) : 0
        let h = p2.time - p1.time
        guard h > 0 else { return p2.angle }
        let u = (t - p1.time) / h, u2 = u * u, u3 = u2 * u
        return (2 * u3 - 3 * u2 + 1) * p1.angle + (u3 - 2 * u2 + u) * h * m1
            + (-2 * u3 + 3 * u2) * p2.angle + (u3 - u2) * h * m2
    }
}
