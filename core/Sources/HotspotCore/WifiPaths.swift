import Foundation

// MARK: - Shared contract paths (see CLAUDE.md "shared contract")
//
// These mirror bin/hotspotd and libexec/auto-hotspot-check.sh. Every value
// here has an env override so tests never touch the real install.

public enum WifiPaths {
    /// Test seam: when non-nil, these values shadow the process environment.
    /// Never set by the app itself; only the portable test target populates
    /// it, so tests can point every path at a temporary directory without
    /// mutating process-global environment variables.
    public static var environmentOverride: [String: String]?

    private static func env(_ key: String) -> String? {
        if let override = environmentOverride, let value = override[key] { return value }
        return ProcessInfo.processInfo.environment[key]
    }

    public static var logPath: String {
        env("AUTO_HOTSPOT_LOG")
            ?? (NSHomeDirectory() + "/Library/Logs/auto-hotspot.log")
    }

    public static var stateDir: String {
        env("AUTO_HOTSPOT_STATE")
            ?? (NSHomeDirectory() + "/.local/state/auto-hotspot")
    }

    public static var configPath: String {
        env("AUTO_HOTSPOT_CONFIG")
            ?? (NSHomeDirectory() + "/.config/auto-hotspot/config")
    }

    public static var agentStatusPath: String { stateDir + "/agent.status" }
    public static var triggerPath: String { stateDir + "/trigger" }
    public static var lockPath: String { stateDir + "/lock" }
    public static var lastJoinAttemptPath: String { stateDir + "/last-join-attempt" }
}
