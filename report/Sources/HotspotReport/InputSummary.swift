import Foundation

// Assembly: run the readers, bind the effective values the controller would
// see, and serialize the whole picture as deterministic JSON (stable key
// order — insertion ordering — suitable for diffing between runs).
//
// Redaction (what leaves the machine in `--json` and `--markdown`):
// - `ssid_current` and the effective `ssid` become the literal REDACTED
//   token. The SSID is the one low-cardinality, user-identifying string in
//   the dataset; on the terminal and in the default JSON it never appears.
// - Other string values keep their content; numeric/boolean keys carry no
//   identifying information.
// - The full log bundle is opt-in (`bundle`) because it can contain prose;
//   see Redaction.swift for the bundle's own policy.

public struct InputSummary {
    public var capturedAt: String
    public var clockIsFake: Bool
    public var inputs: ReportInputs
    public var config: ConfigReading
    public var agent: AgentStatusReading
    public var log: LogReading
    public var state: StateReading
    /// Raw SSID values seen in config and agent.status. Used only by the
    /// bundle's prose redaction: a multi-word SSID must disappear as a whole
    /// phrase, not leave fragments after the `SSID` keyword pass.
    public var knownSecrets: [String]

    public static func collect(inputs: ReportInputs, clock: ReportClock) -> InputSummary {
        let config = readConfig(at: inputs.configPath)
        let agent = readAgentStatus(at: inputs.agentStatusPath, clock: clock)
        let log = readLog(at: inputs.logPath, rotatedPath: inputs.rotatedLogPath)
        let state = readState(
            stateDir: inputs.stateDir,
            homeDirectory: inputs.homeDirectory,
            effectiveCooldownSeconds: config.effectiveCooldown,
            clock: clock
        )
        var secrets: [String] = []
        if case .present(.string(let cfgSSID))? = config.observation(ConfigKeys.ssid),
           !cfgSSID.isEmpty, cfgSSID != "REDACTED" {
            secrets.append(cfgSSID)
        }
        if case .present(.string(let agentSSID))? = agent.observation(AgentStatusKeys.ssidCurrent),
           !agentSSID.isEmpty, agentSSID != "REDACTED", !secrets.contains(agentSSID) {
            secrets.append(agentSSID)
        }
        return InputSummary(
            capturedAt: ISOTimestamp.format(clock.now),
            clockIsFake: clock.isFake,
            inputs: inputs,
            config: config,
            agent: agent,
            log: log,
            state: state,
            knownSecrets: secrets
        )
    }
}

/// The keys whose values never serialize unredacted.
public func isRedactedConfigKey(_ key: String) -> Bool {
    key == ConfigKeys.ssid
}

func caseIsPresent(_ obs: FieldObservation) -> Bool {
    if case .present = obs { return true }
    return false
}

/// One field's explicit state, redacted when required.
func fieldJSON(_ obs: FieldObservation, redact: Bool) -> JSONValue {
    var obj: [(String, JSONValue)] = []
    switch obs {
    case .present(let v):
        obj.append(("state", .string("present")))
        obj.append(("value", redact ? .string("REDACTED") : v))
    case .missing:
        obj.append(("state", .string("missing")))
    case .stale(let age, let eff):
        obj.append(("state", .string("stale")))
        obj.append(("age_seconds", .int(Int64(age))))
        if !redact { obj.append(("observed_value", eff)) }
    case .malformed(let detail, let eff):
        obj.append(("state", .string("malformed")))
        obj.append(("detail", .string(detail)))
        if !redact { obj.append(("observed_value", eff)) }
    }
    // The controller-visible value: for present fields that's the value
    // itself (redacted here); for every other state it's the schema default.
    obj.append(("effective", redact && caseIsPresent(obs) ? .string("REDACTED") : obs.effectiveValue))
    return .object(obj)
}

/// Builds the full JSON document. Key order is fixed by construction, so two
/// runs over identical inputs produce byte-identical output apart from
/// captured_at.
public func buildJSON(_ s: InputSummary) -> JSONValue {
    var doc: [(String, JSONValue)] = []
    doc.append(("schema", .string("auto-hotspot.report/1")))
    doc.append(("captured_at", .string(s.capturedAt)))
    doc.append(("clock", .object([
        ("fake", .bool(s.clockIsFake)),
    ])))

    // Config — every key with its explicit state.
    var cfgFields: [(String, JSONValue)] = []
    for key in ConfigKeys.all {
        guard let obs = s.config.observation(key) else { continue }
        cfgFields.append((key, fieldJSON(obs, redact: isRedactedConfigKey(key))))
    }
    doc.append(("config", .object([
        ("file", .object([
            ("path", .string(s.inputs.configPath)),
            ("state", .string(s.config.fileState)),
        ])),
        ("lines", .object([
            ("accepted", .int(Int64(s.config.counts.linesAccepted))),
            ("refused", .int(Int64(s.config.counts.linesRefused))),
            ("ignored", .int(Int64(s.config.counts.linesIgnored))),
        ])),
        ("refusals", .array(s.config.counts.refusals.map { .string($0) })),
        ("unknown_keys", .array(s.config.counts.unknownKeys.map { .string($0) })),
        ("fields", .object(cfgFields)),
    ])))

    // Agent status.
    var agentFields: [(String, JSONValue)] = []
    for key in AgentStatusKeys.all {
        guard let obs = s.agent.observation(key) else { continue }
        agentFields.append((key, fieldJSON(obs, redact: key == AgentStatusKeys.ssidCurrent)))
    }
    var agentObj: [(String, JSONValue)] = [
        ("file", .object([
            ("path", .string(s.inputs.agentStatusPath)),
            ("state", .string(s.agent.fileState)),
        ])),
        ("fields", .object(agentFields)),
    ]
    if let age = s.agent.mtimeAgeSeconds {
        agentObj.append(("mtime_age_seconds", .int(Int64(age))))
    }
    agentObj.append(("stale_after_seconds", .int(Int64(s.agent.staleAfterSeconds))))
    if let src = s.agent.stalenessSource {
        agentObj.append(("staleness_source", .string(src)))
    }
    agentObj.append(("stale", .bool(s.agent.isStale)))
    if !s.agent.unknownKeys.isEmpty {
        agentObj.append(("unknown_keys", .array(s.agent.unknownKeys.map { .string($0) })))
    }
    doc.append(("agent_status", .object(agentObj)))

    // Log — counts and shape, no message text in the default envelope.
    doc.append(("log", .object([
        ("path", .string(s.inputs.logPath)),
        ("state", .string(s.log.fileState)),
        ("rotated_present", .bool(s.log.rotatedFilePresent)),
        ("tail_cap_bytes", .int(Int64(s.log.tailCapBytes))),
        ("bytes_read", .int(Int64(s.log.bytesRead))),
        ("truncated_head", .bool(s.log.truncatedHead)),
        ("lines_read", .int(Int64(s.log.linesRead))),
        ("lines_accepted", .int(Int64(s.log.linesAccepted))),
        ("lines_refused", .int(Int64(s.log.linesRefused))),
        ("levels", .object(s.log.levels.keys.sorted().map { ($0, JSONValue.int(Int64(s.log.levels[$0] ?? 0))) })),
        ("unknown_levels", .int(Int64(s.log.unknownLevels))),
        ("first_ts", s.log.firstTimestamp.map { .string($0) } ?? .null),
        ("last_ts", s.log.lastTimestamp.map { .string($0) } ?? .null),
        ("refusals", .array(s.log.refusals.map { .string($0) })),
    ])))

    // State dir + install paths.
    doc.append(("state", .object([
        ("dir", .string(s.inputs.stateDir)),
        ("last_join_attempt", fieldJSON(s.state.lastJoinAttempt, redact: false)),
        ("lock", .object([
            ("state", .string(s.state.lockState)),
            ("age_seconds", s.state.lockAgeSeconds.map { JSONValue.int(Int64($0)) } ?? .null),
            ("stale_after_seconds", .int(Int64(s.state.lockStaleWindowSeconds))),
        ])),
        ("trigger", fieldJSON(s.state.trigger, redact: false)),
        ("build_fingerprint", fieldJSON(s.state.buildFingerprint, redact: false)),
        ("install", .object([
            ("launchd_plist_present", .bool(s.state.installPlistPresent)),
            ("agent_exec_present", .bool(s.state.agentExecPresent)),
        ])),
    ])))
    return .object(doc)
}

public func serialize(_ s: InputSummary) -> Data {
    Data(JSON.write(buildJSON(s)).utf8)
}
