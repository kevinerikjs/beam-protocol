#if os(macOS)
import Foundation
import IOKit.hid
import Phoros

/// A virtual HID gamepad on the host that replays `ControllerReport`s, so
/// games see a real controller with analog sticks and triggers.
///
/// The device is created on the first connected report and removed when a
/// report arrives with the connected flag clear, when `release()` is called,
/// or when the instance goes away. Games see that as a controller being
/// plugged in and unplugged.
///
/// ```swift
/// let gamepad = VirtualGamepad()
/// gamepad.onEvent = { event in log(event) }
/// // on every `.input` packet:
/// if let report = ControllerReport.parse(from: packet.payload) {
///     gamepad.handle(report, connected: packet.flags & ControllerReport.connectedFlag != 0)
/// }
/// // on disconnect:
/// gamepad.release()
/// ```
///
/// Creation needs the `com.apple.developer.hid.virtual.device` entitlement.
/// Without it `IOHIDUserDeviceCreateWithProperties` returns nil. That is
/// reported once per session as `.creationFailed`, after which reports are
/// dropped silently until the next `release()`, so a missing entitlement
/// never produces sixty log lines a second.
@available(macOS 13, *)
public final class VirtualGamepad: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        /// The virtual device exists. Games can see it.
        case created
        /// The virtual device was removed.
        case released
        /// The system refused to create the device. Almost always the
        /// entitlement is missing from the running binary.
        case creationFailed
        /// One report was not accepted by the HID stack.
        case reportRejected(IOReturn)
    }

    /// Delivered on the gamepad's own queue.
    public var onEvent: ((Event) -> Void)?

    /// Name the system shows for the device.
    public let productName: String
    public let manufacturer: String

    private var device: IOHIDUserDevice?
    private var creationFailed = false
    private let queue = DispatchQueue(label: "phoros.virtual-gamepad", qos: .userInteractive)

    public init(productName: String = "Phoros Controller", manufacturer: String = "Phoros") {
        self.productName = productName
        self.manufacturer = manufacturer
    }

    deinit {
        device = nil
    }

    /// Whether a virtual device currently exists.
    public var isActive: Bool { queue.sync { device != nil } }

    /// Feed one report. `connected == false` removes the device.
    public func handle(_ report: ControllerReport, connected: Bool) {
        queue.async { [self] in
            guard connected else {
                releaseLocked()
                return
            }
            if device == nil { createLocked() }
            guard let device else { return }
            let bytes = GamepadReport.bytes(for: report)
            let result = bytes.withUnsafeBufferPointer { buffer in
                IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), buffer.baseAddress!, buffer.count)
            }
            if result != kIOReturnSuccess { onEvent?(.reportRejected(result)) }
        }
    }

    /// Remove the device, if any, and allow creation to be tried again.
    public func release() {
        queue.async { [self] in releaseLocked() }
    }

    private func createLocked() {
        guard !creationFailed else { return }
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey: Data(GamepadReport.descriptor),
            kIOHIDVendorIDKey: GamepadReport.vendorID,
            kIOHIDProductIDKey: GamepadReport.productID,
            kIOHIDVersionNumberKey: 1,
            kIOHIDProductKey: productName,
            kIOHIDManufacturerKey: manufacturer,
            kIOHIDTransportKey: "Virtual",
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_GamePad,
        ]
        guard let created = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else {
            creationFailed = true
            onEvent?(.creationFailed)
            return
        }
        device = created
        onEvent?(.created)
    }

    private func releaseLocked() {
        creationFailed = false
        guard device != nil else { return }
        device = nil  // dropping the last reference removes the HID device
        onEvent?(.released)
    }
}
#endif
