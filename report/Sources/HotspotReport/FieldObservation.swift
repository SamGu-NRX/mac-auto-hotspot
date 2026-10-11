import Foundation

/// The state of every schema-bound field. A report that silently substituted
/// defaults would be exactly the kind of opaque output this tool exists to
/// replace, so each field carries its state explicitly:
///
/// - present:   bound from the source with the expected type.
/// - missing:   the field or its whole source file is absent; `effective` is
///              the documented default the controller itself would use.
/// - stale:     the source is older than the controller's staleness window,
///              so the controller ignores it; `effective` mirrors that.
/// - malformed: the field exists but failed schema validation (wrong type,
///              unparsable line, oversized source); `effective` mirrors the
///              controller's fallback.
public enum FieldObservation {
    case present(JSONValue)
    case missing(effective: JSONValue)
    case stale(ageSeconds: Int, effective: JSONValue)
    case malformed(detail: String, effective: JSONValue)

    public var stateName: String {
        switch self {
        case .present: return "present"
        case .missing: return "missing"
        case .stale: return "stale"
        case .malformed: return "malformed"
        }
    }

    /// The value the report acts on — the bound value, or the mirrored
    /// controller default for every non-present state.
    public var effectiveValue: JSONValue {
        switch self {
        case .present(let v): return v
        case .missing(let e): return e
        case .stale(_, let e): return e
        case .malformed(_, let e): return e
        }
    }

    public var isPresent: Bool {
        if case .present = self { return true }
        return false
    }

    public var isMalformed: Bool {
        if case .malformed = self { return true }
        return false
    }

    /// Ordered JSON rendering for the machine-readable summary.
    public var json: JSONValue {
        switch self {
        case .present(let v):
            return .object([("state", .string("present")), ("value", v)])
        case .missing(let e):
            return .object([("state", .string("missing")), ("effective", e)])
        case .stale(let age, let e):
            return .object([
                ("state", .string("stale")),
                ("age_seconds", .int(Int64(age))),
                ("effective", e),
            ])
        case .malformed(let detail, let e):
            return .object([
                ("state", .string("malformed")),
                ("detail", .string(detail)),
                ("effective", e),
            ])
        }
    }
}

/// Config keys and their defaults, mirroring bin/hotspotd's load_config and
/// libexec/auto-hotspot-check.sh's sourcing block — including the U+2019
/// RIGHT SINGLE QUOTATION MARK in the default SSID (written as a \u{2019}
/// escape here so no editor or shell normalizes it to ASCII ').
public enum ConfigKeys {
    public static let ssid = "SSID"
    public static let checkInterval = "CHECK_INTERVAL"
    public static let enabled = "ENABLED"
    public static let cooldown = "COOLDOWN"
    public static let wifiInterface = "WIFI_INTERFACE"
    public static let hotspotRouter = "HOTSPOT_ROUTER"
    public static let hotspotdBin = "HOTSPOTD_BIN"
    public static let notify = "NOTIFY"

    public static let all: [String] = [
        ssid, checkInterval, enabled, cooldown,
        wifiInterface, hotspotRouter, hotspotdBin, notify,
    ]

    public static func isKnown(_ key: String) -> Bool {
        all.contains(key)
    }
}

public enum Defaults {
    public static let ssid: JSONValue = .string("Andrew\u{2019}s iPhone")
    public static let checkInterval: JSONValue = .int(300)
    public static let enabled: JSONValue = .int(1)
    public static let cooldown: JSONValue = .int(30)
    public static let wifiInterface: JSONValue = .string("en0")
    public static let hotspotRouter: JSONValue = .string("172.20.10.1")
    public static let hotspotdBin: JSONValue = .string("")
    public static let notify: JSONValue = .int(1)

    // agent.status field defaults — mirror hotspotd's agent_status_field
    // fallbacks (false / false / "" / "").
    public static let watcherRunning: JSONValue = .bool(false)
    public static let locationAuthorized: JSONValue = .bool(false)
    public static let ssidCurrent: JSONValue = .string("")
    public static let lastJoinResult: JSONValue = .string("")

    // agent.status staleness: AGENT_STATUS_MAX_AGE in bin/hotspotd.
    public static let agentStatusStaleAfterSeconds = 600
}

/// Known join-result vocabulary written by the app's writeAgentStatus —
/// menubar/Wifi.swift's JoinResult enum plus the two string literals the
/// watcher writes directly ("online", "none"). Values outside this list are
/// kept as-is but reported as unrecognized (the app may know more than the
/// reader does; the report says so instead of guessing).
public enum JoinResults {
    public static let known: [String] = [
        "success", "already_joined", "not_found", "auth_failed",
        "interface_error", "verification_failed", "wifi_off",
        "online", "none",
    ]
}
