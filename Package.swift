// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Phoros",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1)
    ],
    products: [
        // The wire contract. Foundation only.
        .library(name: "Phoros", targets: ["Phoros"]),
        // Session logic on top of the contract: pairing and auth state machines, frame
        // reassembly, audio sequencing, send backlog policy, quality adaptation. No I/O.
        .library(name: "PhorosSession", targets: ["PhorosSession"]),
        // Length-prefixed transport over Network.framework.
        .library(name: "PhorosNetwork", targets: ["PhorosNetwork"]),
        // Codecs shaped for the wire: H.264/HEVC via VideoToolbox, AAC-LC via AudioToolbox,
        // parameter sets, Annex B, sample buffers.
        .library(name: "PhorosMedia", targets: ["PhorosMedia"])
    ],
    targets: [
        .target(name: "Phoros"),
        .target(name: "PhorosSession", dependencies: ["Phoros"]),
        .target(name: "PhorosNetwork", dependencies: ["Phoros"]),
        .target(name: "PhorosMedia", dependencies: ["Phoros"]),
        .testTarget(name: "PhorosTests", dependencies: ["Phoros"]),
        .testTarget(name: "PhorosSessionTests", dependencies: ["PhorosSession"]),
        .testTarget(name: "PhorosMediaTests", dependencies: ["PhorosMedia"])
    ]
)
