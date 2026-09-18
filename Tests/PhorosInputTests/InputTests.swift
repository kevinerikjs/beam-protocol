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
