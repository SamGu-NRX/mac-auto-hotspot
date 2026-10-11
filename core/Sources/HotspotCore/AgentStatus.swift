import Foundation

// MARK: - agent.status
//
// Written atomically (temp file + rename) on every engine event so `hotspotd
// status` can merge it in without ever seeing a half-written file.

public struct AgentStatus: Codable {
    public var watcher_running: Bool
    public var location_authorized: Bool
    public var ssid_current: String
    public var last_join_result: String
    public var updated: Int

    public init(watcher_running: Bool, location_authorized: Bool,
                ssid_current: String, last_join_result: String, updated: Int) {
        self.watcher_running = watcher_running
        self.location_authorized = location_authorized
        self.ssid_current = ssid_current
        self.last_join_result = last_join_result
        self.updated = updated
    }
}

public func writeAgentStatusFile(watcherRunning: Bool, locationAuthorized: Bool,
                                 ssidCurrent: String, lastJoinResult: String) {
    let dir = WifiPaths.stateDir
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
        wifiLog("error", "agent.status: could not create state dir: \(error.localizedDescription)")
        return
    }

    let status = AgentStatus(
        watcher_running: watcherRunning,
        location_authorized: locationAuthorized,
        ssid_current: ssidCurrent,
        last_join_result: lastJoinResult,
        updated: Int(Date().timeIntervalSince1970)
    )

    guard let data = try? JSONEncoder().encode(status) else {
        wifiLog("error", "agent.status: encode failed")
        return
    }

    let finalPath = WifiPaths.agentStatusPath
    let tmpPath = finalPath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
    do {
        try data.write(to: URL(fileURLWithPath: tmpPath))
        if fm.fileExists(atPath: finalPath) {
            // replaceItemAt is unreliable in non-Darwin Foundation; fall
            // back to remove + move, which still never exposes a
            // half-written final file.
            do {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: finalPath),
                                          withItemAt: URL(fileURLWithPath: tmpPath))
            } catch {
                try fm.removeItem(atPath: finalPath)
                try fm.moveItem(atPath: tmpPath, toPath: finalPath)
            }
        } else {
            try fm.moveItem(atPath: tmpPath, toPath: finalPath)
        }
    } catch {
        wifiLog("error", "agent.status: atomic write failed: \(error.localizedDescription)")
        try? fm.removeItem(atPath: tmpPath)
    }
}
