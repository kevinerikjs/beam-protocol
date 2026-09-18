# BeamProtocol

BeamProtocol is a small Swift package for the wire format used by [Beam](https://github.com/kevinerikjs/beam-ios) and [Beacon](https://github.com/kevinerikjs/beacon-macos): a paired Apple-device screen-streaming client and host.

It provides packet framing, media payload headers, pairing messages, control messages, and capability negotiation. It does not open sockets, capture a screen, encode media, store credentials, or draw UI.

## Requirements

- Swift 6.0 or later
- iOS 16+, macOS 14+, or another Apple platform with Foundation and CoreMedia

## Add it to an app

Add the package in Xcode using this URL:

```
https://github.com/kevinerikjs/beam-protocol.git
```

Or declare it in a Swift package:

```swift
dependencies: [
    .package(url: "https://github.com/kevinerikjs/beam-protocol.git", from: "1.0.0")
]
```

Then add `BeamProtocol` to the target dependency and import it where the protocol is used.

```swift
import BeamProtocol

let header = BeamPacketHeader(
    type: .control,
    flags: 0,
    payloadLength: UInt32(payload.count)
)
let message = header.serialized() + payload
```

TCP control messages in Beam are wrapped with a four-byte big-endian length prefix:

```swift
connection.send(content: encodedMessage.lengthPrefixed(), completion: .contentProcessed { _ in })
```

## Wire format

Every packet starts with a ten-byte header:

| Bytes | Field | Encoding |
| --- | --- | --- |
| 0–3 | magic | `0x4245414D` (`BEAM`), big-endian |
| 4 | type | `BeamPacketType` raw value |
| 5 | flags | packet-type-specific flags |
| 6–9 | payload length | unsigned 32-bit, big-endian |

Video payloads add a sixteen-byte fragment header. Audio payloads add a twelve-byte sequence/timestamp header. Presentation timestamps are microseconds.

The package models JSON pairing and control messages with `Codable`. Media codecs are negotiated by name during authentication; the packet flag remains the authority for decoding an individual media packet.

## Compatibility rules

Installed clients and hosts do not update together. A package version therefore cannot prove that two peers can communicate. Keep the wire contract compatible:

- Add optional JSON fields and capability names for new features.
- Send an optional feature only after the peer advertises support.
- Keep packet IDs, field meanings, header sizes, and legacy codec IDs stable.
- Use a new protocol major version only for a deliberate breaking change, and make the host return an actionable upgrade error.

The package follows semantic versioning for its Swift API. A package major release is not automatically a wire-protocol break.

## Testing

Run the package tests:

```bash
swift test
```

The suite checks fixed wire bytes, parser round trips, and legacy codec handling. Before a Beam or Beacon release, also test the supported device combinations on real hardware: current client/current host, current client/previous host, and previous client/current host.

## Scope and security

This package is intentionally transport-agnostic. Applications must authenticate peers before accepting control messages or media, bound message sizes before allocating buffers, and protect any remote transport with TLS.

Pairing secrets, screen contents, audio, analytics, and network transport are outside this package.

## Contributing

Open an issue before proposing a wire-format change. Include the compatibility story, a fixed-byte fixture or message fixture, and tests for both the older and newer peer behavior.

## License

MIT. See [LICENSE](LICENSE).
