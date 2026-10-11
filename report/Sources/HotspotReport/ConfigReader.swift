import Foundation

// Reader for the controller's config file — the shell-sourced KEY="VALUE"
// file at $HOME/.config/auto-hotspot/config (bin/hotspotd's CONFIG).
//
// Faithfulness notes (how the controller actually behaves):
// - bin/hotspotd sources the file, so later assignments win; the reader also
//   binds last-assignment-wins for every key.
// - hotspotd's config_set always writes double-quoted values with the four
//   escapes \\ \" \` \$; the reader decodes exactly those, leaving any other
//   backslash pair literal (bash double-quote semantics).
// - Single-quoted values contain no escapes at all (bash semantics).
// - An unquoted value containing shell metacharacters would break or hijack
//   `. "$CONFIG"`, so it is refused, not guessed at.
// - This is a line-by-line binder, not a bash emulator: it does not reproduce
//   bash's abort-on-syntax-error behavior for the rest of the file. A file
//   that would fail to source is reported line by line with exact counts.

public struct ConfigCounts {
    public var linesAccepted = 0
    public var linesRefused = 0
    public var linesIgnored = 0
    /// First N refusals, with line numbers (capped to keep the report small).
    public var refusals: [String] = []
    public var unknownKeys: [String] = []

    mutating func refuse(_ lineNo: Int, _ reason: String) {
        linesRefused += 1
        if refusals.count < 50 {
            refusals.append("line \(lineNo): \(reason)")
        }
    }
}

public struct ConfigReading {
    /// present | missing | oversized
    public var fileState = "missing"
    public var counts = ConfigCounts()
    /// All 8 schema keys, each with an explicit state.
    public var fields: [String: FieldObservation] = [:]

    public func observation(_ key: String) -> FieldObservation? { fields[key] }
    public func effective(_ key: String) -> JSONValue { fields[key]?.effectiveValue ?? .null }

    public var effectiveSSID: String { stringValue(ConfigKeys.ssid) }
    public var effectiveCheckInterval: Int { intValue(ConfigKeys.checkInterval) ?? 300 }
    public var effectiveEnabled: Bool { intValue(ConfigKeys.enabled) == 1 }
    public var effectiveCooldown: Int { intValue(ConfigKeys.cooldown) ?? 30 }
    public var effectiveWifiInterface: String { stringValue(ConfigKeys.wifiInterface) }
    public var effectiveHotspotRouter: String { stringValue(ConfigKeys.hotspotRouter) }
    public var effectiveHotspotdBin: String { stringValue(ConfigKeys.hotspotdBin) }
    public var effectiveNotify: Bool { intValue(ConfigKeys.notify) == 1 }

    func stringValue(_ key: String) -> String {
        if case .string(let s) = effective(key) { return s }
        return ""
    }
    func intValue(_ key: String) -> Int? {
        if case .int(let n) = effective(key) { return Int(n) }
        return nil
    }
}

/// Reads and schema-binds the config file. `sizeCap` bounds the read — a
/// pathologically large file is reported as one oversized source, its fields
/// malformed, instead of being slurped.
public func readConfig(at path: String, sizeCap: Int = 1_048_576) -> ConfigReading {
    var reading = ConfigReading()

    guard let size = FileRead.fileSize(path) else {
        reading.fileState = "missing"
        for key in ConfigKeys.all {
            reading.fields[key] = .missing(effective: defaultValue(key))
        }
        return reading
    }
    guard size <= sizeCap else {
        reading.fileState = "oversized"
        for key in ConfigKeys.all {
            reading.fields[key] = .malformed(
                detail: "config source exceeds \(sizeCap)-byte cap",
                effective: defaultValue(key)
            )
        }
        return reading
    }
    guard let text = FileRead.readString(path) else {
        reading.fileState = "oversized"
        for key in ConfigKeys.all {
            reading.fields[key] = .malformed(
                detail: "config source is not valid UTF-8",
                effective: defaultValue(key)
            )
        }
        return reading
    }
    reading.fileState = "present"

    var boundKeys: Set<String> = []
    let lines = text.components(separatedBy: "\n")
    for (idx, rawLine) in lines.enumerated() {
        let lineNo = idx + 1
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            reading.counts.linesIgnored += 1
            continue
        }
        guard let eq = trimmed.firstIndex(of: "=") else {
            reading.counts.refuse(lineNo, "not KEY=VALUE")
            continue
        }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let rawValue = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)

        guard ConfigKeys.isKnown(key) else {
            reading.counts.refuse(lineNo, "unknown key \(key)")
            reading.counts.unknownKeys.append(key)
            continue
        }

        // Bind. Whatever happens from here, the key resolves to an explicit
        // field state (malformed on failure, per-key last-wins on success).
        let decoded = decodeConfigValue(rawValue)
        switch decoded {
        case .failure(let reason):
            reading.counts.refuse(lineNo, reason)
            reading.fields[key] = .malformed(detail: reason, effective: defaultValue(key))
        case .success(let value):
            if let reason = validateValue(key, value) {
                reading.counts.refuse(lineNo, "\(key): \(reason)")
                reading.fields[key] = .malformed(detail: reason, effective: defaultValue(key))
            } else if isNumericKey(key), let n = Int64(value) {
                // Numeric keys bind as ints — the controller does arithmetic
                // on them, so the report's effective value is a number.
                reading.counts.linesAccepted += 1
                reading.fields[key] = .present(.int(n))
            } else {
                reading.counts.linesAccepted += 1
                reading.fields[key] = .present(.string(value))
            }
        }
        boundKeys.insert(key)
    }

    // Keys never bound from the file bind as missing-with-default.
    for key in ConfigKeys.all where reading.fields[key] == nil {
        reading.fields[key] = .missing(effective: defaultValue(key))
    }
    return reading
}

/// Defaults per key, exactly as the controller's own load blocks define them.
func defaultValue(_ key: String) -> JSONValue {
    switch key {
    case ConfigKeys.ssid: return Defaults.ssid
    case ConfigKeys.checkInterval: return Defaults.checkInterval
    case ConfigKeys.enabled: return Defaults.enabled
    case ConfigKeys.cooldown: return Defaults.cooldown
    case ConfigKeys.wifiInterface: return Defaults.wifiInterface
    case ConfigKeys.hotspotRouter: return Defaults.hotspotRouter
    case ConfigKeys.hotspotdBin: return Defaults.hotspotdBin
    case ConfigKeys.notify: return Defaults.notify
    default: return .null
    }
}

enum ConfigValueDecode {
    case success(String)
    case failure(String)
}

/// Decodes the value side of `KEY=VALUE` with the quoting rules the
/// controller's own writers use (config_set double-quote escaping, the app's
/// unquoteConfigValue tolerance for single quotes, and plain unquoted
/// tokens).
func decodeConfigValue(_ raw: String) -> ConfigValueDecode {
    if raw.isEmpty { return .success("") }

    let first = raw.first!
    if first == "\"" {
        guard raw.count >= 2, raw.hasSuffix("\"") else {
            return .failure("unbalanced double quotes")
        }
        let inner = String(raw.dropFirst().dropLast())
        var out = ""
        var i = inner.startIndex
        while i < inner.endIndex {
            let c = inner[i]
            if c == "\\" {
                let next = inner.index(after: i)
                if next < inner.endIndex {
                    let n = inner[next]
                    switch n {
                    case "\\", "\"", "$", "`":
                        out.append(n)
                        i = inner.index(after: next)
                        continue
                    default:
                        out.append("\\")   // bash: backslash stays literal here
                        i = next
                        continue
                    }
                } else {
                    out.append("\\")
                    break
                }
            }
            out.append(c)
            i = inner.index(after: i)
        }
        return .success(out)
    }

    if first == "'" {
        guard raw.count >= 2, raw.hasSuffix("'") else {
            return .failure("unbalanced single quotes")
        }
        // Bash single quotes: no escape processing at all.
        return .success(String(raw.dropFirst().dropLast()))
    }

    // Unquoted token. Accept only characters that can never change shell
    // parsing; hotspotd itself always writes quoted values, so anything
    // metacharacter-shaped here is a hand edit that would break sourcing.
    let forbidden: Set<Character> = [" ", "\t", "\"", "'", "`", "$", "\\", ";", "&", "|", "(", ")", "<", ">"]
    if let bad = raw.first(where: { forbidden.contains($0) }) {
        let shown = bad == "\t" ? "tab" : String(bad)
        return .failure("unquoted value contains \(shown) — the controller writes quoted values")
    }
    return .success(raw)
}

func isNumericKey(_ key: String) -> Bool {
    switch key {
    case ConfigKeys.checkInterval, ConfigKeys.cooldown, ConfigKeys.enabled, ConfigKeys.notify:
        return true
    default:
        return false
    }
}

/// Per-key type validation. Config values bind as strings (the controller
/// treats them as shell strings); numeric keys must actually be numeric or
/// the controller's arithmetic would fail on them.
func validateValue(_ key: String, _ value: String) -> String? {
    switch key {
    case ConfigKeys.checkInterval, ConfigKeys.cooldown, ConfigKeys.enabled, ConfigKeys.notify:
        if value.isEmpty || value.first == "-" || value.contains(where: { !"0123456789".contains($0) }) {
            return "expected a non-negative integer, got \(String(value.prefix(32)))"
        }
        return nil
    default:
        return nil
    }
}
