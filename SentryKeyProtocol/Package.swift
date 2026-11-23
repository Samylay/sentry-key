// swift-tools-version: 6.0
import PackageDescription

// Shared protocol code for the iPhone app and the Mac agent: SSH wire formats,
// ssh-agent messages, and BLE framing. No third-party dependencies.
let package = Package(
    name: "SentryKeyProtocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SentryKeyProtocol", targets: ["SentryKeyProtocol"]),
    ],
    targets: [
        .target(name: "SentryKeyProtocol"),
        .testTarget(name: "SentryKeyProtocolTests", dependencies: ["SentryKeyProtocol"]),
    ]
)
