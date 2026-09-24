import Foundation
import IOKit.hid

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
        var buffer = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(buffer.count)
        guard IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, &buffer, &length) == kIOReturnSuccess,
              length >= 3 else { return nil }
        return Double(UInt16(buffer[1]) | UInt16(buffer[2]) << 8)
    }

    func close() {
        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
    }
}
