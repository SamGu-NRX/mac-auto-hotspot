import Foundation

// Reader for the shared log — $HOME/Library/Logs/auto-hotspot.log plus its
// `.1` rotation (the checker rotates at 1 MiB). Both the app (wifiLog) and
// the checker (log()) append lines in the same shape:
//
//     [2026-10-11T03:14:05+0200] [info] joined after verify
//
// The reader is bounded: it reads at most the last `tailCapBytes` bytes
// (default 256 KiB), dropping any partial line at the head of the window and
// saying so (truncated_head). A multi-megabyte log can never balloon a
// report run. The rotated file is noted but not read.
//
// Lines that do not match the shape are counted as refused with their line
// numbers — never silently skipped. Message text is not classified here;
// redaction happens in Redaction.swift at report/bundle time.

public struct LogReading {
    /// present | missing | empty
    public var fileState = "missing"
    public var rotatedFilePresent = false
    public var tailCapBytes = 0
    public var bytesRead = 0
    /// True when the tail window cut off older lines.
    public var truncatedHead = false
    public var linesRead = 0
    public var linesAccepted = 0
    public var linesRefused = 0
    /// First N refusals, with line numbers relative to the read window.
    public var refusals: [String] = []
    /// Histogram over levels of accepted lines (info/warn/error plus any
    /// other tokens that turn up).
    public var levels: [String: Int] = [:]
    /// Accepted lines whose level is outside the known info/warn/error set.
    public var unknownLevels = 0
    public var firstTimestamp: String?
    public var lastTimestamp: String?
    /// Absolute epoch of the last accepted line's timestamp, offset-aware —
    /// the diagnostic anchor for "when did this last happen".
    public var lastEventEpochSeconds: Int64?
    /// The parsed lines, kept for report/bundle stages. (Bounded by the tail
    /// cap.)
    public var lines: [LogLine] = []
}

public struct LogLine {
    public var timestamp: String
    public var level: String
    public var message: String
    public var lineNo: Int
}

public func readLog(at path: String, rotatedPath: String, tailCapBytes: Int = 262_144) -> LogReading {
    var reading = LogReading()
    reading.tailCapBytes = tailCapBytes
    reading.rotatedFilePresent = FileRead.exists(rotatedPath)

    guard let size = FileRead.fileSize(path) else {
        reading.fileState = "missing"
        return reading
    }
    reading.fileState = size == 0 ? "empty" : "present"
    guard reading.fileState == "present" else { return reading }

    let tail = FileRead.readTailLines(path, capBytes: tailCapBytes)
    reading.bytesRead = tail.bytesRead
    reading.truncatedHead = tail.truncatedHead
    reading.linesRead = tail.lines.count

    for (idx, rawLine) in tail.lines.enumerated() {
        let windowLineNo = idx + 1
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        guard let parsed = parseLogLine(line) else {
            reading.linesRefused += 1
            if reading.refusals.count < 20 {
                let shown = line.count > 64 ? String(line.prefix(64)) + "..." : line
                reading.refusals.append("line \(windowLineNo): does not match [ts] [level] message — \(shown)")
            }
            continue
        }
        reading.linesAccepted += 1
        reading.levels[parsed.level, default: 0] += 1
        if !["info", "warn", "error"].contains(parsed.level) {
            reading.unknownLevels += 1
        }
        if reading.firstTimestamp == nil { reading.firstTimestamp = parsed.timestamp }
        reading.lastTimestamp = parsed.timestamp
        if let epoch = ISOTimestamp.parse(parsed.timestamp) {
            reading.lastEventEpochSeconds = Int64(epoch.timeIntervalSince1970)
        }
        reading.lines.append(LogLine(
            timestamp: parsed.timestamp, level: parsed.level,
            message: parsed.message, lineNo: windowLineNo
        ))
    }
    return reading
}

/// Strict shape parse for `[ts] [level] message`:
/// - ts must match the repo's 24-char log timestamp shape (structurally).
/// - level must be non-empty; the message may be empty.
func parseLogLine(_ line: String) -> (timestamp: String, level: String, message: String)? {
    guard line.hasPrefix("["), let close1 = line.firstIndex(of: "]") else { return nil }
    let ts = String(line[line.index(after: line.startIndex)..<close1])
    guard ISOTimestamp.isShape(ts) else { return nil }
    let after1 = line.index(after: close1)
    guard after1 < line.endIndex, line[after1] == " " else { return nil }
    let rest = line[line.index(after: after1)...]
    guard rest.hasPrefix("["), let relClose = rest.firstIndex(of: "]") else { return nil }
    let level = String(rest[rest.index(after: rest.startIndex)..<relClose])
    guard !level.isEmpty else { return nil }
    let after2 = rest.index(after: relClose)
    guard after2 < rest.endIndex, rest[after2] == " " else { return nil }
    let message = String(rest[rest.index(after: after2)...])
    return (ts, level, message)
}
