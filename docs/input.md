# Controller forwarding

A game controller paired to the client plays games on the host. The client samples the controller and sends `.input` packets. The host replays them into a virtual gamepad. The operating system, and every game on it, sees a real controller.

The wire side is one packet type and one fourteen-byte payload, `ControllerReport`. [wire-format.md](wire-format.md#controller-reports) describes it. `PhorosInput` carries both ends.

## What the host needs

`VirtualGamepad` creates the device with `IOHIDUserDevice`. That call needs the `com.apple.developer.hid.virtual.device` entitlement. Apple grants it per team on request. Ask from the developer portal: Identifiers, your App ID, Additional Capabilities, HID Virtual Device. After the grant:

1. Enable the capability on the App ID.
2. Add `com.apple.developer.hid.virtual.device` = `true` to the app's entitlements file.
3. Build with a provisioning profile that includes it. A Developer ID app with a restricted entitlement must embed a profile. Xcode does this with `-allowProvisioningUpdates`.

Without the entitlement, `IOHIDUserDeviceCreateWithProperties` returns nil. There is no test path around it. Running as root does not help. The system kills an ad hoc signed binary that claims the entitlement when it starts. `VirtualGamepad` reports `.creationFailed` once per session and drops reports after that.

A host that does not have the entitlement must not set `HostCapabilities.supportsControllerInput`. It still receives `.input` packets from older clients. Recognise the type and return, before any JSON decode. Letting sixty binary packets a second fall into the JSON path fills the log.

## Host

```swift
import Phoros, PhorosSession, PhorosInput

let capabilities = HostCapabilities(deviceName: "Mac", supportsControllerInput: true)
let gamepad = VirtualGamepad(productName: "My App Controller", manufacturer: "My App")
gamepad.onEvent = { event in
    switch event {
    case .created: log("virtual gamepad created")
    case .released: log("virtual gamepad removed")
    case .creationFailed: log("entitlement missing, controller input dropped")
    case .reportRejected(let status): log("HID rejected a report: \(status)")
    }
}

// In the frame handler:
case .packet(let packet) where packet.type == .input:
    guard let report = ControllerReport.parse(from: packet.payload) else { return }
    gamepad.handle(report, connected: packet.flags & ControllerReport.connectedFlag != 0)

// When the session ends:
gamepad.release()
```

The device appears on the first connected report and disappears on a report with the flag clear, on `release()`, or when the instance is dropped. Games see a controller plug in and unplug.

`GamepadReport` holds the HID descriptor and the mapping from `ControllerReport` to the nine report bytes. The descriptor is a generic desktop gamepad: sixteen buttons, a hat switch for the d-pad, X/Y/Z/Rz for the sticks and Rx/Ry for the triggers. Vendor id `0x1209` and product id `0xBEA0` are fixed. Games key their remapping profiles on that pair.

## Client

```swift
import Phoros, PhorosInput

let sampler = ControllerSampler()          // 60 Hz, 1 s keepalive
sampler.onAttachmentChange = { attached in showGamepadBadge(attached) }
sampler.onReport = { report, connected in
    let flags: UInt8 = connected ? ControllerReport.connectedFlag : 0
    send(Packet.encode(.input, flags: flags, payload: report.serialized()))
}

// After auth_success:
if host.supportsControllerInput { sampler.start() }

// On disconnect:
sampler.stop()
```

`ControllerSampler` forwards the first connected controller that has an extended gamepad profile. `ReportThrottle` sends a report when the state changed, and otherwise once per keepalive interval. A quiet controller costs one packet a second. A report lost to a reconnect is repaired within that second. When the controller disconnects, one neutral report with `connected == false` goes out and the host releases its device.

Start the sampler only for a host that advertised `supportsControllerInput`. A host that predates the flag drops the packets. The client would show a controller badge for input that goes nowhere.

The GameController framework stops delivering input when an iOS app leaves the foreground, so forwarding pauses in the background and in Picture in Picture.

## Testing

`GamepadReport` and `ReportThrottle` are pure and covered by `swift test`. `VirtualGamepad` can only be tested with the entitlement in a signed build. Run the host and connect a controller to the client. Check that the system's Game Controllers list, or any game, shows the virtual device with sticks and triggers moving.
