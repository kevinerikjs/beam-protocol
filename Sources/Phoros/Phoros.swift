// Phoros: a real-time media and input protocol for Apple platforms. One
// device sends video and audio, the other sends control back. Screen
// mirroring is one use of it.
//
// The module has four layers, each in its own folder:
//
//   Framing    Every byte on the wire belongs to a packet: a ten-byte header
//              followed by a payload. `PacketHeader`, `Packet`, `FrameDecoder`,
//              `LengthPrefix`.
//
//   Media      What goes inside video, audio and input packets, and which
//              codec a packet is in. `VideoFragmentHeader`, `AudioChunkHeader`,
//              `AudioCodecID`, `VideoCodecID`, `QualityPreset`, `ControllerReport`.
//
//   Handshake  How two devices pair once and authenticate every time after,
//              and how each side learns what the other can do.
//              `PairingMessage`, `PeerCapabilities`, `ControlButton`.
//
//   Control    Typed JSON messages exchanged during a session: quality
//              changes, window selection, media keys, clicks, keystrokes.
//              `ControlMessage`.
//
// This module turns values into bytes and bytes into values and nothing else.
// The package's other products build on it: PhorosSession holds the decisions
// a peer makes during a session, PhorosNetwork moves the bytes over
// Network.framework, and PhorosMedia encodes and decodes exactly what the wire
// carries. Discovering peers, capturing a screen, storing secrets and drawing
// UI belong to the application.
//
// Two ideas run through every type here:
//
//   1. Peers upgrade independently. A phone can run a two-year-old client
//      against a host updated this morning, or the reverse. Every addition is
//      an optional field, every new feature is used only after the other side
//      advertised it, and the absence of an advertisement is never read as
//      "probably fine".
//
//   2. The packet is the authority for media. Codec negotiation during the
//      handshake decides what a host *may* send; the flags byte on each media
//      packet says what it *did* send. Receivers decode from the flags, never
//      from what they remember being negotiated.
//
// docs/wire-format.md has the byte-level reference; docs/compatibility.md has
// the rules and the incidents that produced them.

/// The Phoros wire protocol version this package implements.
///
/// This is the version of the *contract*, not of the Swift package. It only
/// changes for a deliberate, incompatible break, which has not happened yet and
/// should be avoided by adding optional fields and capability flags instead.
public enum Phoros {
    public static let protocolVersion = 1
}
