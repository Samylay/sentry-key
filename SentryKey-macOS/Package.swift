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
        // Bluetooth on the Mac: the connection to the phone, pairing, and
        // the QR code drawn in a terminal.
        .target(
            name: "SentryKeyBluetooth",
            dependencies: [
                "SentryKeyAgent",
                .product(name: "SentryKeyProtocol", package: "SentryKeyProtocol"),
            ]
        ),
        // The real agent, as a command-line tool until the menu bar app
        // exists. It links no development target.
        .executableTarget(
            name: "sentrykey-agent",
            dependencies: [
                "SentryKeyAgent",
                "SentryKeyBluetooth",
                .product(name: "SentryKeyProtocol", package: "SentryKeyProtocol"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // macOS refuses Bluetooth to a program that does not say
                // why it wants it. A command-line tool has no bundle to say
                // it in, so the text is embedded in the binary itself.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/sentrykey-agent/Info.plist",
                ]),
            ]
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
                "SentryKeyBluetooth",
                .product(name: "SentryKeyProtocol", package: "SentryKeyProtocol"),
            ]
        ),
    ]
)
