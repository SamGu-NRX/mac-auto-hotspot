import Foundation

// Redaction and the opt-in evidence bundle.
//
// The default outputs (terminal summary, --json, --markdown) are redacted:
// SSIDs become the token REDACTED and log message text never appears. The
// `bundle` subcommand is the opt-in: it writes the log tail as-is so a
// support thread can see the actual lines. Even there, one residue policy
// applies: unclassifiable log lines (lines that do not match the repo's
// [ts] [level] message shape) are not included — their provenance is
// unknown, so they are listed by line number only, not exported.

public struct BundleResult {
    public var dir: String
    public var files: [String]
    public var redacted: Bool
}

/// Writes the evidence bundle under `destination` and returns the file list.
/// Everything is created with restrictive permissions (0600 files, 0700 dir).
public func writeBundle(
    _ s: InputSummary,
    to destination: String,
    redacted: Bool
) throws -> BundleResult {
    let fm = FileManager.default
    try fm.createDirectory(atPath: destination, withIntermediateDirectories: true, attributes: [
        .posixPermissions: 0o700,
    ])

    // 1. report.json — the full envelope (redacted by default).
    let json = serialize(s)
    let jsonPath = destination + "/report.json"
    try json.write(to: URL(fileURLWithPath: jsonPath))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonPath)

    // 2. log.tail.txt — the same tail window the reader saw, optionally
    //    unredacted. SSID redaction applies to log prose too: the SSID
    //    literally appears in some messages ("joined SSID ...").
    let tailPath = destination + "/log.tail.txt"
    var tailText = "# tail window: \(s.log.bytesRead) bytes of \(s.inputs.logPath)\n"
    tailText += "# truncated_head: \(s.log.truncatedHead)\n"
    for line in s.log.lines {
        let msg = redacted ? redactProse(line.message, secrets: s.knownSecrets) : line.message
        tailText += "[\(line.timestamp)] [\(line.level)] \(msg)\n"
    }
    if !s.log.refusals.isEmpty {
        tailText += "\n# unclassifiable lines (count \(s.log.linesRefused)) — listed, not included:\n"
        for r in s.log.refusals {
            tailText += "# \(r)\n"
        }
    }
    try tailText.data(using: .utf8)?.write(to: URL(fileURLWithPath: tailPath))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tailPath)

    // 3. manifest.txt — what was read, what was bounded, what is absent.
    let manifestPath = destination + "/manifest.txt"
    var m = "auto-hotspot-report bundle\n"
    m += "captured_at: \(s.capturedAt)\n"
    m += "clock: \(s.clockIsFake ? "fake (deterministic replay)" : "live")\n"
    m += "redacted: \(redacted)\n"
    m += "config_path: \(s.inputs.configPath) (\(s.config.fileState))\n"
    m += "log_path: \(s.inputs.logPath) (\(s.log.fileState))\n"
    m += "log_tail_bytes: \(s.log.bytesRead) (cap \(s.log.tailCapBytes))\n"
    m += "rotated_log: \(s.log.rotatedFilePresent ? "present, not read" : "absent")\n"
    m += "state_dir: \(s.inputs.stateDir)\n"
    m += "agent_status: \(s.inputs.agentStatusPath) (\(s.agent.fileState))\n"
    m += "known_limits: no network probing; no packet capture; timestamps are\n"
    m += "read as written (offset-aware); rotated log not included\n"
    try m.data(using: .utf8)?.write(to: URL(fileURLWithPath: manifestPath))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestPath)

    return BundleResult(dir: destination, files: ["report.json", "log.tail.txt", "manifest.txt"], redacted: redacted)
}

/// Redacts SSID-shaped mentions in free prose, in two layers:
///
/// 1. Known-secret pass: every raw SSID the readers saw (config, agent.status)
///    disappears as a whole phrase, case-insensitively — a multi-word SSID
///    like "Secret Garden" cannot leave fragments like "Garden" behind.
/// 2. Keyword pass: an `SSID` keyword still redacts the token that follows,
///    catching an SSID the readers never bound but a log line echoed.
///
/// Applies only where prose is exported (the bundle tail).
func redactProse(_ message: String, secrets: [String] = []) -> String {
    var out = message
    for secret in secrets where !secret.isEmpty {
        out = out.replacingOccurrences(
            of: secret,
            with: "REDACTED",
            options: [.caseInsensitive]
        )
    }
    for kw in ["SSID", "ssid"] {
        out = redactAfterKeyword(out, keyword: kw)
    }
    return out
}

func redactAfterKeyword(_ text: String, keyword: String) -> String {
    var result = ""
    var searchStart = text.startIndex
    while let range = text.range(of: keyword, range: searchStart..<text.endIndex) {
        result += text[searchStart..<range.upperBound]
        var after = range.upperBound
        // Skip a single space or quote/colon after the keyword.
        if after < text.endIndex, [" ", ":", "\"", "'"].contains(text[after]) {
            result.append(text[after])
            after = text.index(after: after)
        }
        // Consume the value up to whitespace or end.
        var valueEnd = after
        while valueEnd < text.endIndex, text[valueEnd] != " ", text[valueEnd] != "\t" {
            valueEnd = text.index(after: valueEnd)
        }
        if valueEnd > after {
            result += "REDACTED"
        }
        searchStart = valueEnd
    }
    result += text[searchStart...]
    return result
}
