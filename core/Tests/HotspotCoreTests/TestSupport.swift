import Foundation
import XCTest
@testable import HotspotCore

/// Temporary-path support. Every test gets its own throwaway "home" with the
/// same layout install.sh would create, and points WifiPaths at it through
/// the environmentOverride seam — no process-global environment mutation, no
/// real user paths touched.
enum TestEnv {
    static func makeHome(_ label: String) -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspotcore-\(label)-\(UUID().uuidString)")
        for sub in [".config/auto-hotspot", ".local/state/auto-hotspot", "Library/Logs"] {
            try! FileManager.default.createDirectory(atPath: root.appendingPathComponent(sub).path,
                                                     withIntermediateDirectories: true)
        }
        return root.path
    }

    static func activate(home: String) {
        WifiPaths.environmentOverride = [
            "AUTO_HOTSPOT_CONFIG": home + "/.config/auto-hotspot/config",
            "AUTO_HOTSPOT_LOG": home + "/Library/Logs/auto-hotspot.log",
            "AUTO_HOTSPOT_STATE": home + "/.local/state/auto-hotspot",
        ]
    }

    static func deactivate() {
        WifiPaths.environmentOverride = nil
    }

    static func writeConfig(_ text: String, home: String) throws {
        try text.write(toFile: home + "/.config/auto-hotspot/config", atomically: true, encoding: .utf8)
    }
}

/// Fake time: tests advance the clock explicitly; nothing here sleeps.
final class Clock {
    var time: Double = 1_700_000_000

    func advance(_ seconds: Double) {
        time += seconds
    }
}

func XCTAssertEqual(_ lhs: [(level: String, message: String)],
                    _ rhs: [(level: String, message: String)],
                    _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let a = lhs.map { "\($0.level)|\($0.message)" }
    let b = rhs.map { "\($0.level)|\($0.message)" }
    XCTAssertEqual(a, b, message, file: file, line: line)
}
