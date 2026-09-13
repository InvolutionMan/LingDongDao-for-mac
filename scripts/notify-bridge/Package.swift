// swift-tools-version:5.9
import PackageDescription

/// The bridge that turns WeChat / QQ notifications into Atoll live activities.
///
/// It is a standalone package on purpose: it depends on `AtollExtensionKit`
/// (the public extension API) rather than on Atoll's sources, so the app itself
/// needs no changes and the helper can be built and installed on its own.
let package = Package(
    name: "atoll-notify-bridge",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/Ebullioscopic/AtollExtensionKit", branch: "main"),
    ],
    targets: [
        // The logic lives in a library so the tests can reach it; the
        // executable is only the entry point launchd starts.
        .target(
            name: "NotifyBridgeCore",
            dependencies: [.product(name: "AtollExtensionKit", package: "AtollExtensionKit")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "atoll-notify-bridge", dependencies: ["NotifyBridgeCore"]),
        .testTarget(name: "NotifyBridgeCoreTests", dependencies: ["NotifyBridgeCore"]),
    ]
)
