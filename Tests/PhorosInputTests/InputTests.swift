import XCTest
import Phoros
@testable import PhorosInput

final class GamepadReportTests: XCTestCase {
    func testNeutralReport() {
        XCTAssertEqual(GamepadReport.bytes(for: .neutral), [0, 0, 8, 127, 127, 127, 127, 0, 0])
        XCTAssertEqual(GamepadReport.bytes(for: .neutral).count, GamepadReport.size)
    }

    func testButtonBitsFollowTheDescriptorOrder() {
        let all = ControllerReport(buttons: [.a, .b, .x, .y, .leftShoulder, .rightShoulder, .leftThumbstick, .rightThumbstick, .menu, .options, .home])
        let bytes = GamepadReport.bytes(for: all)
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1], 0b0000_0111)
    }

    func testHatSwitch() {
        XCTAssertEqual(GamepadReport.hat(for: []), 8)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadUp]), 0)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadUp, .dpadRight]), 1)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadRight]), 2)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadDown, .dpadRight]), 3)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadDown]), 4)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadDown, .dpadLeft]), 5)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadLeft]), 6)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadUp, .dpadLeft]), 7)
        XCTAssertEqual(GamepadReport.hat(for: [.dpadUp, .dpadDown]), 8, "opposites cancel")
    }

    func testAxesMapFullRangeAndInvertY() {
        XCTAssertEqual(GamepadReport.axisByte(0), 127)
        XCTAssertEqual(GamepadReport.axisByte(32767), 255)
        XCTAssertEqual(GamepadReport.axisByte(-32767), 0)
        XCTAssertEqual(GamepadReport.axisByte(32767, inverted: true), 0, "stick up is HID Y minimum")
        let report = ControllerReport(leftX: 32767, leftY: 32767, rightX: -32767, rightY: -32767, leftTrigger: 200, rightTrigger: 10)
        XCTAssertEqual(Array(GamepadReport.bytes(for: report)[3...]), [255, 0, 0, 255, 200, 10])
    }

    func testDescriptorIsPinned() {
        XCTAssertEqual(GamepadReport.descriptor.count, 86)
        XCTAssertEqual(GamepadReport.descriptor.first, 0x05)
        XCTAssertEqual(GamepadReport.descriptor.last, 0xC0)
        XCTAssertEqual(GamepadReport.vendorID, 0x1209)
        XCTAssertEqual(GamepadReport.productID, 0xBEA0)
    }
}

final class ReportThrottleTests: XCTestCase {
    func testSendsOnChangeAndOnKeepalive() {
        var throttle = ReportThrottle(keepalive: 1.0)
        let t0 = Date()
        XCTAssertTrue(throttle.shouldSend(.neutral, now: t0), "first report always goes")
        XCTAssertFalse(throttle.shouldSend(.neutral, now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(throttle.shouldSend(ControllerReport(buttons: [.a]), now: t0.addingTimeInterval(0.6)), "a change goes at once")
        XCTAssertFalse(throttle.shouldSend(ControllerReport(buttons: [.a]), now: t0.addingTimeInterval(1.5)))
        XCTAssertTrue(throttle.shouldSend(ControllerReport(buttons: [.a]), now: t0.addingTimeInterval(1.6)), "keepalive after a quiet second")
    }

    func testResetForcesTheNextReport() {
        var throttle = ReportThrottle()
        let t0 = Date()
        XCTAssertTrue(throttle.shouldSend(.neutral, now: t0))
        throttle.reset()
        XCTAssertTrue(throttle.shouldSend(.neutral, now: t0))
    }

    func testConversionsFromGameControllerRanges() {
        XCTAssertEqual(ControllerReport.axis(1), 32767)
        XCTAssertEqual(ControllerReport.axis(-1), -32767)
        XCTAssertEqual(ControllerReport.axis(0), 0)
        XCTAssertEqual(ControllerReport.trigger(1), 255)
        XCTAssertEqual(ControllerReport.trigger(0.5), 127)
    }
}

final class FrameMappingTests: XCTestCase {
    let frame = CGSize(width: 1920, height: 1080)

    func testMatchingAspectMapsOneToOne() {
        let content = FrameMapping.contentRect(sourceSize: CGSize(width: 3840, height: 2160), frameSize: frame)
        XCTAssertEqual(content, CGRect(x: 0, y: 0, width: 1, height: 1))
        let point = FrameMapping.sourcePoint(forFramePoint: CGPoint(x: 0.25, y: 0.5), sourceFrame: CGRect(x: 100, y: 200, width: 3840, height: 2160), shownViewport: nil, frameSize: frame)
        XCTAssertEqual(point, CGPoint(x: 100 + 960, y: 200 + 1080))
    }

    func testTallSourceIsPillarboxedAndTapsInTheBarsAreRejected() {
        let source = CGSize(width: 1080, height: 1920)
        let content = FrameMapping.contentRect(sourceSize: source, frameSize: frame)
        XCTAssertEqual(content.height, 1)
        XCTAssertEqual(content.width, 0.31640625, accuracy: 0.0001)
        XCTAssertNil(FrameMapping.sourcePoint(forFramePoint: CGPoint(x: 0.05, y: 0.5), sourceFrame: CGRect(origin: .zero, size: source), shownViewport: nil, frameSize: frame))
        let centre = FrameMapping.sourcePoint(forFramePoint: CGPoint(x: 0.5, y: 0.5), sourceFrame: CGRect(origin: .zero, size: source), shownViewport: nil, frameSize: frame)!
        XCTAssertEqual(centre.x, 540, accuracy: 2)
        XCTAssertEqual(centre.y, 960, accuracy: 2)
    }

    func testViewportLockIsUndone() {
        let sourceFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let lock = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)   // bottom-right quarter, same aspect
        let point = FrameMapping.sourcePoint(forFramePoint: CGPoint(x: 0, y: 0), sourceFrame: sourceFrame, shownViewport: lock, frameSize: frame)!
        XCTAssertEqual(point.x, 960, accuracy: 2)
        XCTAssertEqual(point.y, 540, accuracy: 2)
    }

    func testEmptySizesAreRejected() {
        XCTAssertTrue(FrameMapping.contentRect(sourceSize: .zero, frameSize: frame).isNull)
        XCTAssertNil(FrameMapping.sourcePoint(forFramePoint: .zero, sourceFrame: .zero, shownViewport: nil, frameSize: frame))
    }
}

final class KeyModifiersTests: XCTestCase {
    func testMaskMatchesCarbon() {
        XCTAssertEqual(KeyModifiers.command.rawValue, 0x0100)
        XCTAssertEqual(KeyModifiers.shift.rawValue, 0x0200)
        XCTAssertEqual(KeyModifiers.option.rawValue, 0x0800)
        XCTAssertEqual(KeyModifiers.control.rawValue, 0x1000)
        XCTAssertEqual(KeyModifiers(wireName: "cmd"), .command)
        XCTAssertEqual(KeyModifiers(wireName: "alt"), .option)
        XCTAssertEqual(KeyModifiers(wireName: "ctrl"), .control)
        XCTAssertNil(KeyModifiers(wireName: "hyper"))
    }

    #if os(macOS)
    func testChordLookupAndFlags() {
        XCTAssertEqual(InputReplay.ansiKeyCode(for: "c"), 8)
        XCTAssertEqual(InputReplay.ansiKeyCode(for: "C"), 8)
        XCTAssertNil(InputReplay.ansiKeyCode(for: "é"))
        XCTAssertNil(InputReplay.ansiKeyCode(for: "ab"))
        XCTAssertEqual(InputReplay.eventFlags(for: [.command, .shift]), [.maskCommand, .maskShift])
    }
    #endif
}

final class GamepadProfileTests: XCTestCase {
    func testIdentitiesArePinned() {
        XCTAssertEqual(GamepadProfile.dualShock4.vendorID, 0x054C)
        XCTAssertEqual(GamepadProfile.dualShock4.productID, 0x09CC)
        XCTAssertEqual(GamepadProfile.xboxOne.vendorID, 0x045E)
        XCTAssertEqual(GamepadProfile.xboxOne.productID, 0x02FD)
        XCTAssertEqual(GamepadProfile.generic.inputReport(for: .neutral), GamepadReport.bytes(for: .neutral))
    }

    func testDualShockReport() {
        let neutral = DualShock4Report.bytes(for: .neutral)
        XCTAssertEqual(neutral.count, 64)
        XCTAssertEqual(Array(neutral[0...5]), [0x01, 127, 127, 127, 127, 0x08])
        let pressed = DualShock4Report.bytes(for: ControllerReport(buttons: [.a, .x, .leftShoulder, .home, .dpadUp], leftTrigger: 255))
        XCTAssertEqual(pressed[5], 0b0011_0000 | 0)          // cross + square, hat up
        XCTAssertEqual(pressed[6] & 0x0F, 0b0101)            // L1 + L2
        XCTAssertEqual(pressed[7] & 0x03, 0x01)              // PS
        XCTAssertEqual(pressed[8], 255)
        XCTAssertEqual(DualShock4Report.featureReport(id: 0x02)?.count, 37)
        XCTAssertNil(DualShock4Report.featureReport(id: 0x99))
    }

    func testXboxReport() {
        let neutral = XboxOneReport.bytes(for: .neutral)
        XCTAssertEqual(neutral.count, 17)
        XCTAssertEqual(neutral[0], 0x01)
        XCTAssertEqual(UInt16(neutral[1]) | UInt16(neutral[2]) << 8, 32767, accuracy: 2)
        XCTAssertEqual(neutral[13], 0, "hat released is 0 on Xbox")
        let pressed = XboxOneReport.bytes(for: ControllerReport(buttons: [.a, .y, .menu, .options, .dpadRight], leftX: 32767, rightTrigger: 255))
        XCTAssertEqual(UInt16(pressed[1]) | UInt16(pressed[2]) << 8, 65535)
        XCTAssertEqual(UInt16(pressed[11]) | UInt16(pressed[12]) << 8, 1023)
        XCTAssertEqual(pressed[13], 3)
        XCTAssertEqual(pressed[14], 0b0001_0001)
        XCTAssertEqual(pressed[15], 0b0000_1000)
        XCTAssertEqual(pressed[16], 0x01, "View is the first bit after the button word")
        XCTAssertEqual(XboxOneReport.homeReport(pressed: true), [0x02, 0x01])
        let bothFull = XboxOneReport.bytes(for: ControllerReport(leftX: -32767, leftY: -32767, rightX: 32767, rightY: 32767, leftTrigger: 255, rightTrigger: 255))
        XCTAssertEqual(UInt16(bothFull[9]) | UInt16(bothFull[10]) << 8, 1023, "full trigger must not overflow")
        XCTAssertEqual(UInt16(bothFull[1]) | UInt16(bothFull[2]) << 8, 0)
        XCTAssertEqual(UInt16(bothFull[3]) | UInt16(bothFull[4]) << 8, 65535, "stick down is Y max")
        _ = DualShock4Report.bytes(for: ControllerReport(leftX: .min, leftY: .max, rightX: .min, rightY: .max, leftTrigger: 255, rightTrigger: 255))
    }
}
