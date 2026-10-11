import Foundation
import XCTest

/// Proof that the portable core cannot call Apple frameworks or actual
/// network commands:
///
/// 1. Structural: this test target compiles and runs on Linux, where
///    AppKit/CoreWLAN/CoreLocation/UserNotifications do not exist. Any
///    import or call into them would fail the build before a test ran.
/// 2. Enforced: the guard below scans every core source file for the
///    forbidden imports and command names, so a macOS-side regression is
///    caught the same day it's introduced — on Linux, in CI-less mode.
final class GuardTests: XCTestCase {
    private var coreSourcesDir: String {
        // Tests/HotspotCoreTests/GuardTests.swift -> package root -> Sources/HotspotCore
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/HotspotCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        return here.appendingPathComponent("Sources/HotspotCore").path
    }

    /// Apple-only frameworks and the concrete network/radio commands the
    /// core must never reference. Foundation is allowed (portable); nothing
    /// else is.
    private let forbiddenTokens: [String] = [
        "import AppKit", "import Cocoa", "import CoreWLAN", "import CoreLocation",
        "import UserNotifications", "import Network", "import CFNetwork", "import Darwin",
        "CWWiFiClient", "CWInterface", "CLLocationManager", "UNUserNotificationCenter",
        "NWPathMonitor", "NSStatusBar", "NSApplication",
        "networksetup", "ipconfig", "/usr/bin/curl", "Process(",
        "Thread.sleep", "URLSession", "Socket", "connect(",
    ]

    func testCoreSourcesDeclareNoAppleFrameworkImportsAndNoNetworkCommands() throws {
        let fm = FileManager.default
        let files = try fm.subpathsOfDirectory(atPath: coreSourcesDir)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThan(files.count, 0, "expected to find core sources at \(coreSourcesDir)")

        var violations: [String] = []
        for file in files {
            let url = URL(fileURLWithPath: coreSourcesDir).appendingPathComponent(file)
            let text = try String(contentsOfFile: url.path, encoding: .utf8)
            for (lineNumber, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comment-only mentions are documentation (e.g. naming what
                // stays on the macOS side), not code. Stripping the comment
                // tail keeps the guard strict on real code.
                let code = trimmed.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                for token in forbiddenTokens where code.contains(token) {
                    violations.append("\(file):\(lineNumber + 1): contains \(token)")
                }
            }
        }
        XCTAssertEqual(violations, [], "core sources must stay dependency-free")
    }

    func testPackageManifestHasNoExternalDependencies() throws {
        let manifestURL = URL(fileURLWithPath: coreSourcesDir)
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOfFile: manifestURL.path, encoding: .utf8)
        XCTAssertFalse(manifest.contains(".package("), "no external package dependencies allowed")
        XCTAssertFalse(manifest.contains("linkedFramework"), "no framework linkage allowed")
        XCTAssertFalse(manifest.contains("linkedLibrary"), "no extra library linkage allowed")
    }
}
