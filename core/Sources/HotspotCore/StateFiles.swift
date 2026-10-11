import Foundation

// MARK: - Shared state files
//
// Lock and last-join-attempt live in the state dir and are shared with
// libexec/auto-hotspot-check.sh, so the app and the degraded-mode script can
// never race each other and cooldown state is honored regardless of which
// one wrote it. Wrapped in a namespace so the app-side SystemEffects adapter
// (menubar/Wifi.swift) can call these without the method/global name
// collision the old flat top-level functions would create.

/// Same mkdir-style lock, same path, same staleness window as
/// libexec/auto-hotspot-check.sh's acquire_lock — so the app and the
/// degraded-mode script can never race each other.
private let lockStaleSeconds: TimeInterval = 300

public enum StateStore {
    public static func acquireLock() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: WifiPaths.lockPath, withIntermediateDirectories: false)
            return true
        } catch {
            // Lock dir likely already exists; fall through to the staleness check.
        }
        if let attrs = try? fm.attributesOfItem(atPath: WifiPaths.lockPath),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > lockStaleSeconds {
            try? fm.removeItem(atPath: WifiPaths.lockPath)
            if (try? fm.createDirectory(atPath: WifiPaths.lockPath, withIntermediateDirectories: false)) != nil {
                return true
            }
        }
        return false
    }

    public static func releaseLock() {
        try? FileManager.default.removeItem(atPath: WifiPaths.lockPath)
    }

    // MARK: last-join-attempt stamp
    //
    // Same file, same format (epoch seconds, plain text) as the shell
    // worker's LAST_JOIN_FILE, so cooldown state is shared regardless of
    // which one wrote it.

    public static func readLastJoinAttempt() -> TimeInterval? {
        guard let s = try? String(contentsOfFile: WifiPaths.lastJoinAttemptPath, encoding: .utf8) else { return nil }
        return TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func writeLastJoinAttempt(at time: TimeInterval) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: WifiPaths.stateDir, withIntermediateDirectories: true)
        try? "\(Int(time))".write(toFile: WifiPaths.lastJoinAttemptPath, atomically: true, encoding: .utf8)
    }

    public static func clearLastJoinAttempt() {
        try? FileManager.default.removeItem(atPath: WifiPaths.lastJoinAttemptPath)
    }
}

// MARK: - Filesystem helpers

public func ensureFileExists(atPath path: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                             withIntermediateDirectories: true)
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }
}
