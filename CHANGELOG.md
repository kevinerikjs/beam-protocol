# Changelog

## 1.0.0

First release. Protocol version 1: the wire contract that Beam 3.0 and Beacon 1.4 speak.

- `Phoros`: packet framing (`PacketHeader`, `Packet`, `LengthPrefix`, `FrameDecoder`), media headers (`VideoFragmentHeader`, `AudioChunkHeader`), codecs (`AudioCodecID`, `VideoCodecID`, `QualityPreset`), `ControllerReport`, handshake (`PairingMessage`, `ControlButton`, `PeerCapabilities`), and `ControlMessage` with type-keyed decoding.
- `PhorosSession`: `PairingHost`, `PairingClient`, `HostAuthenticator`, `ClientCapabilities`, `HostCapabilities`, `SharedSecret`, `FrameAssembler`, `AudioSequenceGuard`, `SendScheduler`, `VideoHold`, `RoundTripProbe`, `HeartbeatMonitor`, `QualityLadder`.
- `PhorosNetwork`: `PhorosConnection`.
- `PhorosMedia`: `VideoEncoder`, `VideoFormat`, `AnnexB`, `PCMChunk`, `AACEncoder`, `AACDecoder`.
- 84 tests. Wire fixtures pin every header's bytes and every message's JSON.
