import Foundation

// Reader for the state-dir files and the install-path existence checks —
// everything the controller uses beyond config, agent.status and the log:
//
//   last-join-attempt  epoch seconds of the last join attempt (cooldown base)
//   lock/              mkdir-based single-flight lock (checker + app agree)
//   trigger            file the CLI touches to poke the running agent
//   build-fingerprint  SHA-256 over the app sources, written after install
//   ~/Library/LaunchAgents/com.andrewwang.autohotspot.plist        (existence)
//   ~/Applications/AutoHotspot.app/Contents/MacOS/AutoHotspot      (existence)
//
// Faithfulness notes:
// - hotspotd treats a missing OR non-numeric last-join-attempt as 0 — the
//   reader binds missing and malformed states explicitly with effective 0.
// - The lock's staleness window is max(COOLDOWN * 4, 300) seconds, the same
//   formula as libexec/auto-hotspot-check.sh's acquire_lock. A lock older
//   than the window is present_but_stale (the controller would remove it and
//   proceed; this reader never mutates anything). A plain file at the lock
//   path also blocks the controller's mkdir, so it binds as held.
// - build-fingerprint binds only when it is exactly 64 lowercase hex chars
//   (sha256sum's output shape).

public struct StateReading {
    public var lastJoinAttempt: FieldObservation = .missing(effective: .int(0))
    /// absent | held | present_but_stale
    public var lockState = "absent"
    public var lockAgeSeconds: Int?
    public var lockStaleWindowSeconds = 300
    public var trigger: FieldObservation = .missing(effective: .null)
    public var buildFingerprint: FieldObservation = .missing(effective: .null)
    public var installPlistPresent = false
    public var agentExecPresent = false
}

public func readState(
    stateDir: String,
    homeDirectory: String,
    effectiveCooldownSeconds: Int,
    clock: ReportClock
) -> StateReading {
    var reading = StateReading()
    let nowEpoch = clock.epochSeconds

    // last-join-attempt
    let ljaPath = stateDir + "/last-join-attempt"
    if let size = FileRead.fileSize(ljaPath) {
        if size > 64 {
            reading.lastJoinAttempt = .malformed(
                detail: "last-join-attempt exceeds 64 bytes", effective: .int(0))
        } else if let text = FileRead.readString(ljaPath) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isNumeric = !trimmed.isEmpty && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
            if isNumeric, let epoch = Int64(trimmed) {
                reading.lastJoinAttempt = .present(.int(epoch))
            } else if isNumeric {
                reading.lastJoinAttempt = .malformed(
                    detail: "epoch out of range", effective: .int(0))
            } else {
                // hotspotd's `case ''|*[!0-9]*) last=0` — but the state is
                // reported, not swallowed.
                reading.lastJoinAttempt = .malformed(
                    detail: "not an epoch integer", effective: .int(0))
            }
        } else {
            reading.lastJoinAttempt = .malformed(
                detail: "not valid UTF-8", effective: .int(0))
        }
    } else {
        reading.lastJoinAttempt = .missing(effective: .int(0))
    }

    // lock — mkdir-style, so it is a directory (or, abnormally, a file).
    let lockPath = stateDir + "/lock"
    var lockIsDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: lockPath, isDirectory: &lockIsDir) {
        reading.lockState = "held"
        if let mtime = FileRead.modificationDate(lockPath) {
            let age = Int(nowEpoch - Int64(mtime.timeIntervalSince1970))
            reading.lockAgeSeconds = age
            // Same formula as the checker: stale window scales with the
            // effective cooldown, floored at 300s.
            let window = max(effectiveCooldownSeconds * 4, 300)
            reading.lockStaleWindowSeconds = window
            if age > window {
                reading.lockState = "present_but_stale"
            }
        }
    }

    // trigger
    let triggerPath = stateDir + "/trigger"
    if let mtime = FileRead.modificationDate(triggerPath) {
        reading.trigger = .present(.int(Int64(mtime.timeIntervalSince1970)))
    } else {
        reading.trigger = .missing(effective: .null)
    }

    // build-fingerprint
    let fpPath = stateDir + "/build-fingerprint"
    if let size = FileRead.fileSize(fpPath) {
        if size > 128 {
            reading.buildFingerprint = .malformed(
                detail: "build-fingerprint exceeds 128 bytes", effective: .null)
        } else if let text = FileRead.readString(fpPath) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLowerHex = trimmed.count == 64
                && trimmed.allSatisfy { $0.isHexDigit }
                && trimmed == trimmed.lowercased()
            if isLowerHex {
                reading.buildFingerprint = .present(.string(trimmed))
            } else {
                reading.buildFingerprint = .malformed(
                    detail: "expected 64 lowercase hex characters", effective: .null)
            }
        } else {
            reading.buildFingerprint = .malformed(
                detail: "not valid UTF-8", effective: .null)
        }
    } else {
        reading.buildFingerprint = .missing(effective: .null)
    }

    // Install paths — existence only (bin/hotspotd hardcodes these relative
    // to $HOME; see ReportInputs).
    let inputs = ReportInputs(
        configPath: stateDir, logPath: stateDir, stateDir: stateDir,
        homeDirectory: homeDirectory)
    reading.installPlistPresent = FileRead.exists(inputs.launchAgentPlistPath)
    reading.agentExecPresent = FileRead.exists(inputs.agentExecPath)
    return reading
}
