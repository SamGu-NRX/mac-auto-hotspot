// swift-tools-version:5.10
// The support-report package: portable, dependency-free diagnostics for
// auto-hotspot. Nothing here imports CoreWLAN, CoreLocation, or any other
// macOS-only or authorization framework — the package builds and tests on
// Linux, so a macOS-framework import would not even compile. This package
// is read-only by design: it observes the files the controller writes and
// never touches Wi-Fi state, the agent, launchd, or network tools.
import PackageDescription

let package = Package(
    name: "HotspotReport",
    targets: [
        .target(
            name: "HotspotReport",
            path: "Sources/HotspotReport"
        ),
        .executableTarget(
            name: "hotspot-report",
            dependencies: ["HotspotReport"],
            path: "Sources/hotspot-report"
        ),
        .testTarget(
            name: "HotspotReportTests",
            dependencies: ["HotspotReport"],
            path: "Tests/HotspotReportTests"
        ),
    ]
)
