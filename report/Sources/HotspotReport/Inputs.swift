import Foundation

/// The set of files a report run observes, bound the same way the controller
/// binds them (CLAUDE.md "shared contract"): the same three env overrides
/// bin/hotspotd honors — AUTO_HOTSPOT_CONFIG, AUTO_HOTSPOT_LOG,
/// AUTO_HOTSPOT_STATE — plus the HOME-derived install paths, which
/// bin/hotspotd hardcodes relative to $HOME.
///
/// Everything here is a path description. Opening any of these files is
/// strictly read-only.
public struct ReportInputs {
    public var configPath: String
    public var logPath: String
    public var stateDir: String
    public var homeDirectory: String

    public init(configPath: String, logPath: String, stateDir: String, homeDirectory: String) {
        self.configPath = configPath
        self.logPath = logPath
        self.stateDir = stateDir
        self.homeDirectory = homeDirectory
    }

    /// Flag overrides (highest), then the AUTO_HOTSPOT_* environment
    /// overrides (the same ones the controller honors), then the $HOME
    /// defaults from the shared contract.
    public static func fromEnvironment(_ env: [String: String]) -> ReportInputs {
        let home = env["HOME"] ?? ""
        return ReportInputs(
            configPath: env["AUTO_HOTSPOT_CONFIG"] ?? (home + "/.config/auto-hotspot/config"),
            logPath: env["AUTO_HOTSPOT_LOG"] ?? (home + "/Library/Logs/auto-hotspot.log"),
            stateDir: env["AUTO_HOTSPOT_STATE"] ?? (home + "/.local/state/auto-hotspot"),
            homeDirectory: home
        )
    }

    // Derived paths — the state-dir files the controller writes, per the
    // shared contract in CLAUDE.md and menubar/Wifi.swift's WifiPaths.

    public var agentStatusPath: String { stateDir + "/agent.status" }
    public var lockPath: String { stateDir + "/lock" }
    public var triggerPath: String { stateDir + "/trigger" }
    public var lastJoinAttemptPath: String { stateDir + "/last-join-attempt" }
    public var buildFingerprintPath: String { stateDir + "/build-fingerprint" }
    public var rotatedLogPath: String { logPath + ".1" }

    // Install paths (existence-only checks; bin/hotspotd hardcodes these
    // relative to $HOME with no env override, so the reader does too).

    public var launchAgentPlistPath: String {
        homeDirectory + "/Library/LaunchAgents/com.andrewwang.autohotspot.plist"
    }

    public var agentExecPath: String {
        homeDirectory + "/Applications/AutoHotspot.app/Contents/MacOS/AutoHotspot"
    }
}

// MARK: - File helpers (read-only)

enum FileRead {
    /// File size in bytes, or nil when the file does not exist or stat fails.
    static func fileSize(_ path: String) -> Int? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        if let n = attrs[.size] as? NSNumber { return Int(n.uint64Value) }
        if let u = attrs[.size] as? UInt64 { return Int(u) }
        if let i = attrs[.size] as? Int { return i }
        return nil
    }

    /// Modification time as a Date, or nil when unavailable.
    static func modificationDate(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        if let d = attrs[.modificationDate] as? Date { return d }
        if let n = attrs[.modificationDate] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        return nil
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Reads a UTF-8 file, refusing anything that is not valid UTF-8.
    static func readString(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads at most the last `capBytes` bytes of a file, split into complete
    /// lines (a partial line at the head of the window is dropped and the
    /// caller is told via the returned flag). Bounded by construction: a
    /// multi-megabyte log can never balloon a report run.
    static func readTailLines(_ path: String, capBytes: Int) -> (lines: [String], truncatedHead: Bool, bytesRead: Int) {
        let size = fileSize(path) ?? 0
        guard size > 0, let handle = FileHandle(forReadingAtPath: path) else {
            return ([], false, 0)
        }
        defer { try? handle.close() }
        var truncatedHead = false
        if size > capBytes {
            truncatedHead = true
            try? handle.seek(toOffset: UInt64(size - capBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.readToEnd() else {
            return ([], truncatedHead, 0)
        }
        var text = String(data: data, encoding: .utf8) ?? ""
        if truncatedHead {
            // Drop the partial line at the window head, if any.
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            } else {
                return ([], truncatedHead, data.count)
            }
        }
        // A trailing "" after a final newline is not a line.
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return (lines, truncatedHead, data.count)
    }
}
