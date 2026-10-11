// swift-tools-version:5.9
import PackageDescription

// HotspotCore holds the dependency-free half of the agent: config parsing,
// the agent.status writer, the shared state files (lock, cooldown stamp), the
// log, and the evaluation decision logic (Controller). It must never import
// an Apple-only framework — the same sources compile on Linux, where the
// portable test target runs. The macOS side (menubar/Wifi.swift) binds this
// logic to CoreWLAN/CoreLocation/UNUserNotificationCenter through the
// ControllerEffects protocol.
let package = Package(
    name: "HotspotCore",
    targets: [
        .target(name: "HotspotCore", path: "Sources/HotspotCore"),
        .testTarget(name: "HotspotCoreTests", dependencies: ["HotspotCore"], path: "Tests/HotspotCoreTests"),
    ]
)
