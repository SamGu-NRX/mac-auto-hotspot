import Foundation

// Human renderings, shared by the CLI and tested from the test target.
// Every renderer is a pure function over InputSummary — no I/O.

extension FieldObservation {
    /// One-line terminal rendering.
    public func summaryLine(redact: Bool) -> String {
        switch self {
        case .present(let v):
            if redact { return "present = REDACTED" }
            return "present = \(describeScalar(v, redact: false))"
        case .missing(let eff):
            return "missing (controller default: \(describeScalar(eff, redact: false)))"
        case .stale(let age, let eff):
            return "stale \(age)s (controller default: \(describeScalar(eff, redact: redact)))"
        case .malformed(let detail, let eff):
            return "malformed — \(detail) (controller default: \(describeScalar(eff, redact: redact)))"
        }
    }

    public func markdownState() -> String {
        switch self {
        case .present: return "present"
        case .missing: return "missing"
        case .stale: return "stale"
        case .malformed: return "malformed"
        }
    }

    public func markdownEffective(redact: Bool) -> String {
        switch self {
        case .present where redact: return "REDACTED"
        default: return describeScalar(effectiveValue, redact: redact)
        }
    }
}

public func describeScalar(_ v: JSONValue, redact: Bool) -> String {
    if case .string(let s) = v {
        return redact ? "REDACTED" : "\"\(s)\""
    }
    return JSON.write(v)
}

public func renderTerminal(_ s: InputSummary) -> String {
    var out: [String] = []
    out.append("auto-hotspot report  (\(s.capturedAt)\(s.clockIsFake ? ", fake clock" : ""))")
    out.append("")
    out.append("config      \(s.config.fileState)  accepted=\(s.config.counts.linesAccepted) refused=\(s.config.counts.linesRefused) ignored=\(s.config.counts.linesIgnored)")
    for key in ConfigKeys.all {
        guard let obs = s.config.observation(key) else { continue }
        out.append("  \(key.padding(toLength: 16, withPad: " ", startingAt: 0)) \(obs.summaryLine(redact: isRedactedConfigKey(key)))")
    }
    out.append("")
    out.append("agent.status \(s.agent.fileState)\(s.agent.isStale ? "  (STALE, \(s.agent.mtimeAgeSeconds ?? 0)s old)" : "")")
    for key in AgentStatusKeys.all {
        guard let obs = s.agent.observation(key) else { continue }
        out.append("  \(key.padding(toLength: 20, withPad: " ", startingAt: 0)) \(obs.summaryLine(redact: key == AgentStatusKeys.ssidCurrent))")
    }
    out.append("")
    out.append("log         \(s.log.fileState)  accepted=\(s.log.linesAccepted) refused=\(s.log.linesRefused)\(s.log.truncatedHead ? " (tail window truncated)" : "")")
    if let last = s.log.lastTimestamp {
        out.append("  last accepted line: \(last)")
    }
    out.append("")
    out.append("state dir   \(s.inputs.stateDir)")
    out.append("  last-join-attempt  \(s.state.lastJoinAttempt.summaryLine(redact: false))")
    out.append("  lock               \(s.state.lockState)\(s.state.lockAgeSeconds.map { " (\($0)s old, stale after \(s.state.lockStaleWindowSeconds)s)" } ?? "")")
    out.append("  trigger            \(s.state.trigger.summaryLine(redact: false))")
    out.append("  build-fingerprint  \(s.state.buildFingerprint.summaryLine(redact: false))")
    out.append("  launchd plist      \(s.state.installPlistPresent ? "present" : "absent")")
    out.append("  agent executable   \(s.state.agentExecPresent ? "present" : "absent")")
    out.append("")
    out.append("read-only run; bundle with: hotspot-report bundle --output=<dir>")
    return out.joined(separator: "\n")
}

public func renderMarkdown(_ s: InputSummary) -> String {
    var m = "# auto-hotspot report\n\n"
    m += "captured_at: `\(s.capturedAt)`\(s.clockIsFake ? " (fake clock)" : "")\n\n"
    m += "## Config (`\(s.inputs.configPath)`, \(s.config.fileState))\n\n"
    m += "| key | state | effective |\n|---|---|---|\n"
    for key in ConfigKeys.all {
        guard let obs = s.config.observation(key) else { continue }
        m += "| `\(key)` | \(obs.markdownState()) | `\(obs.markdownEffective(redact: isRedactedConfigKey(key)))` |\n"
    }
    if !s.config.counts.refusals.isEmpty {
        m += "\nRefused lines (\(s.config.counts.linesRefused)):\n"
        for r in s.config.counts.refusals { m += "- \(r)\n" }
    }
    m += "\n## agent.status (`\(s.inputs.agentStatusPath)`, \(s.agent.fileState))\n\n"
    m += "| field | state | effective |\n|---|---|---|\n"
    for key in AgentStatusKeys.all {
        guard let obs = s.agent.observation(key) else { continue }
        m += "| `\(key)` | \(obs.markdownState()) | `\(obs.markdownEffective(redact: key == AgentStatusKeys.ssidCurrent))` |\n"
    }
    m += "\n## Log (`\(s.inputs.logPath)`, \(s.log.fileState))\n\n"
    m += "accepted \(s.log.linesAccepted) / refused \(s.log.linesRefused); tail cap \(s.log.tailCapBytes) bytes\(s.log.truncatedHead ? " (truncated head)" : "")\n"
    if let first = s.log.firstTimestamp, let last = s.log.lastTimestamp {
        m += "window: `\(first)` .. `\(last)`\n"
    }
    if !s.log.refusals.isEmpty {
        m += "\nRefused lines:\n"
        for r in s.log.refusals { m += "- \(r)\n" }
    }
    m += "\n## State (`\(s.inputs.stateDir)`)\n\n"
    m += "- last-join-attempt: \(s.state.lastJoinAttempt.summaryLine(redact: false))\n"
    m += "- lock: \(s.state.lockState)\n"
    m += "- trigger: \(s.state.trigger.summaryLine(redact: false))\n"
    m += "- build-fingerprint: \(s.state.buildFingerprint.summaryLine(redact: false))\n"
    m += "- launchd plist: \(s.state.installPlistPresent ? "present" : "absent"); agent executable: \(s.state.agentExecPresent ? "present" : "absent")\n"
    m += "\n## Limits\n\nRead-only; no network probing; rotated log noted, not read; bundle writes only under `--output`.\n"
    return m
}
