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
/// let gamepad = VirtualGamepad(profile: .xboxOne)
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

    /// The controller identity presented to the system. Fixed for the
    /// lifetime of the device; create a new `VirtualGamepad` to change it.
    public let profile: GamepadProfile

    private var device: IOHIDUserDevice?
    private var creationFailed = false
    private var homePressed = false
    private let queue = DispatchQueue(label: "phoros.virtual-gamepad", qos: .userInteractive)

    /// `profile` defaults to `.xboxOne`, which macOS adopts into
    /// `GCController` with its built-in mapping. `.generic` is only visible
    /// to raw HID readers.
    public init(profile: GamepadProfile = .xboxOne) {
        self.profile = profile
    }

    deinit {
        // An activated device must be cancelled, and may only be released
        // after its cancel handler ran. The handler holds the last reference.
        if let device {
            IOHIDUserDeviceCancel(device)
            self.device = nil
        }
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
            post(profile.inputReport(for: report), to: device)
            if profile == .xboxOne, report.buttons.contains(.home) != homePressed {
                homePressed.toggle()
                post(XboxOneReport.homeReport(pressed: homePressed), to: device)
            }
        }
    }

    /// Remove the device, if any, and allow creation to be tried again.
    public func release() {
        queue.async { [self] in releaseLocked() }
    }

    private func post(_ bytes: [UInt8], to device: IOHIDUserDevice) {
        let result = bytes.withUnsafeBufferPointer { buffer in
            IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), buffer.baseAddress!, buffer.count)
        }
        if result != kIOReturnSuccess { onEvent?(.reportRejected(result)) }
    }

    private func createLocked() {
        guard !creationFailed else { return }
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey: Data(profile.descriptor),
            kIOHIDVendorIDKey: profile.vendorID,
            kIOHIDProductIDKey: profile.productID,
            kIOHIDVersionNumberKey: profile.versionNumber,
            kIOHIDProductKey: profile.productName,
            kIOHIDManufacturerKey: profile.manufacturer,
            kIOHIDTransportKey: profile.transport,
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_GamePad,
        ]
        guard let created = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else {
            creationFailed = true
            onEvent?(.creationFailed)
            return
        }
        let profile = self.profile
        IOHIDUserDeviceSetCancelHandler(created) {
            // Keeps `created` alive until IOKit is done with it, then drops it.
            _ = created
        }
        IOHIDUserDeviceRegisterGetReportBlock(created, { type, reportID, report, length in
            guard type == kIOHIDReportTypeFeature, let answer = profile.featureReport(id: UInt8(reportID)) else {
                return kIOReturnUnsupported
            }
            let n = min(answer.count, Int(length.pointee))
            answer.withUnsafeBufferPointer { report.update(from: $0.baseAddress!, count: n) }
            length.pointee = CFIndex(n)
            return kIOReturnSuccess
        })
        IOHIDUserDeviceSetDispatchQueue(created, queue)
        IOHIDUserDeviceActivate(created)
        device = created
        homePressed = false
        onEvent?(.created)
    }

    private func releaseLocked() {
        creationFailed = false
        guard let device else { return }
        IOHIDUserDeviceCancel(device)
        self.device = nil  // dropping the last reference removes the HID device
        onEvent?(.released)
    }
}
#endif
