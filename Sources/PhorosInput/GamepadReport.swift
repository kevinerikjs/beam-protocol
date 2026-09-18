import Foundation
import Phoros

/// The HID picture of a `ControllerReport`: a generic desktop gamepad with
/// sixteen buttons, a hat switch for the d-pad, four stick axes and two
/// trigger axes. Pure functions, no I/O, so the mapping is testable anywhere.
public enum GamepadReport {
    /// Bytes in one input report. No report ID.
    ///
    /// ```
    /// [0]    buttons 1-8: A, B, X, Y, LB, RB, left thumbstick, right thumbstick
    /// [1]    buttons 9-16: menu, options, home, five unused
    /// [2]    hat switch in the low nibble: 0-7 clockwise from up, 8 = released
    /// [3-6]  X, Y, Z, Rz: left stick X/Y, right stick X/Y, 0-255, centre 128, HID down is positive
    /// [7-8]  Rx, Ry: left and right trigger, 0-255
    /// ```
    public static let size = 9

    /// A vendor id from the pid.codes open-source space and a product id that
    /// is ours. Games key remapping profiles on this pair, so it is fixed.
    public static let vendorID = 0x1209
    public static let productID = 0xBEA0

    /// HID report descriptor for `bytes(for:)`.
    public static let descriptor: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Gamepad)
        0xA1, 0x01,        // Collection (Application)
        //   16 buttons
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (1)
        0x29, 0x10,        //   Usage Maximum (16)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x10,        //   Report Count (16)
        0x81, 0x02,        //   Input (Data, Variable, Absolute)
        //   Hat switch (d-pad)
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x39,        //   Usage (Hat Switch)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x07,        //   Logical Maximum (7)
        0x35, 0x00,        //   Physical Minimum (0)
        0x46, 0x3B, 0x01,  //   Physical Maximum (315)
        0x65, 0x14,        //   Unit (Degrees)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x42,        //   Input (Data, Variable, Absolute, Null State)
        0x75, 0x04,        //   Report Size (4), padding
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x03,        //   Input (Constant)
        //   Sticks: X, Y, Z, Rz
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x30,        //   Usage (X)
        0x09, 0x31,        //   Usage (Y)
        0x09, 0x32,        //   Usage (Z)
        0x09, 0x35,        //   Usage (Rz)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x04,        //   Report Count (4)
        0x81, 0x02,        //   Input (Data, Variable, Absolute)
        //   Triggers: Rx, Ry
        0x09, 0x33,        //   Usage (Rx)
        0x09, 0x34,        //   Usage (Ry)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x02,        //   Report Count (2)
        0x81, 0x02,        //   Input (Data, Variable, Absolute)
        0xC0,              // End Collection
    ]

    /// The nine report bytes for one controller state.
    public static func bytes(for report: ControllerReport) -> [UInt8] {
        let b = report.buttons
        var byte0: UInt8 = 0
        if b.contains(.a) { byte0 |= 1 << 0 }
        if b.contains(.b) { byte0 |= 1 << 1 }
        if b.contains(.x) { byte0 |= 1 << 2 }
        if b.contains(.y) { byte0 |= 1 << 3 }
        if b.contains(.leftShoulder) { byte0 |= 1 << 4 }
        if b.contains(.rightShoulder) { byte0 |= 1 << 5 }
        if b.contains(.leftThumbstick) { byte0 |= 1 << 6 }
        if b.contains(.rightThumbstick) { byte0 |= 1 << 7 }

        var byte1: UInt8 = 0
        if b.contains(.menu) { byte1 |= 1 << 0 }
        if b.contains(.options) { byte1 |= 1 << 1 }
        if b.contains(.home) { byte1 |= 1 << 2 }

        return [
            byte0,
            byte1,
            hat(for: b),
            axisByte(report.leftX),
            axisByte(report.leftY, inverted: true),
            axisByte(report.rightX),
            axisByte(report.rightY, inverted: true),
            report.leftTrigger,
            report.rightTrigger,
        ]
    }

    /// Hat switch value: 0-7 clockwise starting at up, 8 when released or
    /// when opposite directions are pressed together.
    public static func hat(for buttons: ControllerReport.Buttons) -> UInt8 {
        let up = buttons.contains(.dpadUp), down = buttons.contains(.dpadDown)
        let left = buttons.contains(.dpadLeft), right = buttons.contains(.dpadRight)
        switch (up, right, down, left) {
        case (true, false, false, false): return 0
        case (true, true, false, false): return 1
        case (false, true, false, false): return 2
        case (false, true, true, false): return 3
        case (false, false, true, false): return 4
        case (false, false, true, true): return 5
        case (false, false, false, true): return 6
        case (true, false, false, true): return 7
        default: return 8
        }
    }

    /// Maps a wire axis (-32767...32767, up and right positive) to a HID axis
    /// byte (0-255, centre 128). `inverted` is for the Y axes, where HID
    /// counts down as positive.
    public static func axisByte(_ value: Int16, inverted: Bool = false) -> UInt8 {
        let v = inverted ? -Int(value) : Int(value)
        return UInt8(clamping: (v + 32767) >> 8)
    }
}
