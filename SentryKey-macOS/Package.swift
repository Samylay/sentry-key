// swift-tools-version: 6.0
import PackageDescription

// The Mac side of SentryKey: the ssh-agent socket and the queue of sign
// requests waiting for the phone. No third-party dependencies.
//
// The menu bar app and the Bluetooth central are not here yet: they need an
// app bundle, and will use the `SentryKeyAgent` library.
let package = Package(
    name: "SentryKeyMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SentryKeyAgent", targets: ["SentryKeyAgent"]),
    ],
    dependencies: [
        .package(path: "../SentryKeyProtocol"),
    ],
    targets: [
        .target(
            name: "SentryKeyAgent",
            dependencies: [.product(name: "SentryKeyProtocol", package: "SentryKeyProtocol")]
        ),
        // A stand-in phone with a software key, for development and tests
        // only. Kept out of `SentryKeyAgent` so the real agent can never
        // link a key that lives on the Mac.
        .target(
            name: "SentryKeyAgentDevSupport",
            dependencies: [
                "SentryKeyAgent",
                .product(name: "SentryKeyProtocol", package: "SentryKeyProtocol"),
            ]
        ),
        .executableTarget(
            name: "sentrykey-agent-dev",
            dependencies: [
                "SentryKeyAgent",
                "SentryKeyAgentDevSupport",
                .product(name: "SentryKeyProtocol", package: "SentryKeyProtocol"),
            ]
        ),
        .testTarget(
            name: "SentryKeyAgentTests",
            dependencies: [
                "SentryKeyAgent",
                "SentryKeyAgentDevSupport",
                .product(name: "SentryKeyProtocol", package: "SentryKeyProtocol"),
            ]
        ),
    ]
)
