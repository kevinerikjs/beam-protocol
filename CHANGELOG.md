# Changelog

## 1.3.0

Protocol version stays 1. Additive.

- `PhorosInput`: `GamepadProfile`. `VirtualGamepad` now presents a known controller identity, `.xboxOne` by default or `.dualShock4`, with that controller's descriptor and report layout. macOS's GameController framework adopts the device and every game gets the same mapping. `.generic` remains for raw-HID readers. The Xbox layout was verified through `GCController` on macOS 26: every button and axis lands on its name. The DualShock 4 layout follows the documented USB report and answers the driver's calibration and identity feature reports, but has not been verified on hardware.
- `VirtualGamepad` cancels the activated device before releasing it (IOKit aborted otherwise) and answers feature-report reads.
- 102 tests.

## 1.2.0

Protocol version stays 1. Additive.

- `Phoros`: `KeyModifiers`, the Carbon-valued mask that `MediaKeyCommand.keystrokeModifiers` carries, with `init?(wireName:)` for `ControlButton.modifier` names.
- `PhorosInput`: `InputReplay` (macOS) posts keystrokes, text, media keys and clicks for `ControlMessage.mediaKey`. `FrameMapping` maps frame-normalised taps and rects to the source with letterbox and viewport lock undone.
- README mark.
- 99 tests.

## 1.1.0

Protocol version stays 1. Everything here is additive.

- `Phoros`: `PairingMessage.supportsControllerInput`, sent by hosts that replay `.input` packets. `PeerCapabilities.supportsControllerInput` reads it with the conservative default.
- `PhorosSession`: `HostCapabilities.supportsControllerInput`.
- `PhorosInput`, new product: `ControllerSampler` and `ReportThrottle` for the client, `VirtualGamepad` (macOS 13+, `IOHIDUserDevice`) for the host, `GamepadReport` for the HID descriptor and report bytes, and `ControllerReport.init(GCExtendedGamepad)`.
- 93 tests.

## 1.0.0

First release. Protocol version 1: the wire contract that Beam 3.0 and Beacon 1.4 speak.

- `Phoros`: packet framing (`PacketHeader`, `Packet`, `LengthPrefix`, `FrameDecoder`), media headers (`VideoFragmentHeader`, `AudioChunkHeader`), codecs (`AudioCodecID`, `VideoCodecID`, `QualityPreset`), `ControllerReport`, handshake (`PairingMessage`, `ControlButton`, `PeerCapabilities`), and `ControlMessage` with type-keyed decoding.
- `PhorosSession`: `PairingHost`, `PairingClient`, `HostAuthenticator`, `ClientCapabilities`, `HostCapabilities`, `SharedSecret`, `FrameAssembler`, `AudioSequenceGuard`, `SendScheduler`, `VideoHold`, `RoundTripProbe`, `HeartbeatMonitor`, `QualityLadder`.
- `PhorosNetwork`: `PhorosConnection`.
- `PhorosMedia`: `VideoEncoder`, `VideoFormat`, `AnnexB`, `PCMChunk`, `AACEncoder`, `AACDecoder`.
- 84 tests. Wire fixtures pin every header's bytes and every message's JSON.
