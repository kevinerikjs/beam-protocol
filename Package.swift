// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BeamProtocol",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BeamProtocol", targets: ["BeamProtocol"])
    ],
    targets: [
        .target(name: "BeamProtocol"),
        .testTarget(name: "BeamProtocolTests", dependencies: ["BeamProtocol"])
    ]
)
