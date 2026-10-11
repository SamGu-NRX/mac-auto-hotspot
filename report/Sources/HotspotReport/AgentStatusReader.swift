import Foundation

// Reader for the agent's own status file: $STATE_DIR/agent.status — flat JSON
// written atomically by menubar/Wifi.swift's writeAgentStatus (the only code
// in the repo that knows the fields only the TCC-granted app can observe).
//
// Faithfulness notes:
// - bin/hotspotd's agent_status_field ignores the WHOLE file when its mtime
//   is older than AGENT_STATUS_MAX_AGE (600s). The reader mirrors that: when
//   the file is stale, every bound field becomes .stale with the controller's
//   default as effective value. Mtime in the future (clock skew / restore)
//   means a negative age — fresh, as in hotspotd's arithmetic.
// - If the mtime is unreadable the reader falls back to the `updated` epoch
//   the app embeds, and says which signal it used (staleness_source).
// - hotspotd reads fields with lenient sed regexes; this reader is stricter:
//   `watcher_running: 1` is a malformed field here, not false. Strict is the
//   point of a schema binding.

public struct AgentStatusReading {
    /// present | missing | oversized | unparsable
    public var fileState = "missing"
    public var fields: [String: FieldObservation] = [:]
    public var staleAfterSeconds = Defaults.agentStatusStaleAfterSeconds
    public var mtimeAgeSeconds: Int?
    public var updatedAgeSeconds: Int?
    /// "mtime" | "updated_field" | nil (no signal available)
    public var stalenessSource: String?
    public var isStale = false
    /// Keys present in the JSON that the schema does not bind. Counted and
    /// listed, never hidden.
    public var unknownKeys: [String] = []

    public func observation(_ key: String) -> FieldObservation? { fields[key] }
}

/// The five fields the schema binds from agent.status.
public enum AgentStatusKeys {
    public static let watcherRunning = "watcher_running"
    public static let locationAuthorized = "location_authorized"
    public static let ssidCurrent = "ssid_current"
    public static let lastJoinResult = "last_join_result"
    public static let updated = "updated"

    public static let all: [String] = [
        watcherRunning, locationAuthorized, ssidCurrent, lastJoinResult, updated,
    ]
}

public func readAgentStatus(
    at path: String,
    clock: ReportClock,
    staleAfterSeconds: Int = Defaults.agentStatusStaleAfterSeconds,
    sizeCap: Int = 65_536
) -> AgentStatusReading {
    var reading = AgentStatusReading()
    reading.staleAfterSeconds = staleAfterSeconds

    func failAll(_ state: String, detail: String? = nil) {
        reading.fileState = state
        for key in AgentStatusKeys.all {
            if let d = detail {
                reading.fields[key] = .malformed(detail: d, effective: defaultFor(key))
            } else {
                reading.fields[key] = .missing(effective: defaultFor(key))
            }
        }
    }

    guard let size = FileRead.fileSize(path) else {
        failAll("missing")
        return reading
    }
    guard size <= sizeCap else {
        failAll("oversized", detail: "agent.status exceeds \(sizeCap)-byte cap")
        return reading
    }
    guard let text = FileRead.readString(path), !text.isEmpty else {
        failAll("unparsable", detail: "file is not valid UTF-8")
        return reading
    }

    reading.fileState = "present"
    let value: JSONValue
    do {
        value = try JSON.parse(text)
    } catch {
        failAll("unparsable", detail: "invalid JSON: \(describe(error))")
        return reading
    }
    guard case .object(let pairs) = value else {
        failAll("unparsable", detail: "top-level JSON value is not an object")
        return reading
    }

    let known = Set(AgentStatusKeys.all)
    for (k, _) in pairs where !known.contains(k) {
        reading.unknownKeys.append(k)
    }

    // Bind each field with an explicit type check.
    for key in AgentStatusKeys.all {
        guard let v = value[key] else {
            reading.fields[key] = .missing(effective: defaultFor(key))
            continue
        }
        switch key {
        case AgentStatusKeys.watcherRunning, AgentStatusKeys.locationAuthorized:
            if case .bool(let b) = v {
                reading.fields[key] = .present(.bool(b))
            } else {
                reading.fields[key] = .malformed(detail: "expected true/false", effective: defaultFor(key))
            }
        case AgentStatusKeys.ssidCurrent, AgentStatusKeys.lastJoinResult:
            if case .string(let s) = v {
                reading.fields[key] = .present(.string(s))
            } else {
                reading.fields[key] = .malformed(detail: "expected a string", effective: defaultFor(key))
            }
        case AgentStatusKeys.updated:
            switch v {
            case .int(let n):
                reading.fields[key] = .present(.int(n))
                reading.updatedAgeSeconds = Int(clock.epochSeconds - n)
            case .double(let d) where d == d.rounded():
                let n = Int64(d)
                reading.fields[key] = .present(.int(n))
                reading.updatedAgeSeconds = Int(clock.epochSeconds - n)
            default:
                reading.fields[key] = .malformed(detail: "expected an epoch integer", effective: .null)
            }
        default:
            break
        }
    }

    // Staleness, faithful to hotspotd: mtime first, embedded `updated` as
    // the documented fallback when stat gives us nothing.
    let nowEpoch = clock.epochSeconds
    if let mtime = FileRead.modificationDate(path) {
        let age = Int(nowEpoch - Int64(mtime.timeIntervalSince1970))
        reading.mtimeAgeSeconds = age
        reading.stalenessSource = "mtime"
        reading.isStale = age > staleAfterSeconds
    } else if let updatedAge = reading.updatedAgeSeconds {
        reading.stalenessSource = "updated_field"
        reading.isStale = updatedAge > staleAfterSeconds
        reading.mtimeAgeSeconds = updatedAge
    }

    if reading.isStale {
        let age = reading.mtimeAgeSeconds ?? 0
        for key in AgentStatusKeys.all {
            if case .present = reading.fields[key] {
                reading.fields[key] = .stale(ageSeconds: max(age, 0), effective: defaultFor(key))
            }
        }
    }
    return reading
}

func defaultFor(_ key: String) -> JSONValue {
    switch key {
    case AgentStatusKeys.watcherRunning: return Defaults.watcherRunning
    case AgentStatusKeys.locationAuthorized: return Defaults.locationAuthorized
    case AgentStatusKeys.ssidCurrent: return Defaults.ssidCurrent
    case AgentStatusKeys.lastJoinResult: return Defaults.lastJoinResult
    default: return .null
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? JSONError, case .malformed(_, let detail) = e {
        return detail
    }
    return String(describing: error)
}
