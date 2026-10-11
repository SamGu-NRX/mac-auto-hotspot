import Foundation

/// The clock every reader and report receives. Real runs use the wall clock;
/// tests and replays inject a fixed instant so every age, staleness verdict
/// and captured_at stamp is deterministic. No reader reads the system time
/// on its own — that is what makes fake-time replay trustworthy.
public struct ReportClock {
    public let now: Date
    public let isFake: Bool

    public init(now: Date, isFake: Bool) {
        self.now = now
        self.isFake = isFake
    }

    public static func live() -> ReportClock {
        ReportClock(now: Date(), isFake: false)
    }

    public static func fixed(epochSeconds: Int64) -> ReportClock {
        ReportClock(now: Date(timeIntervalSince1970: TimeInterval(epochSeconds)), isFake: true)
    }

    public static func fixed(iso8601: String) -> ReportClock? {
        guard let d = ISOTimestamp.parse(iso8601) else { return nil }
        return ReportClock(now: d, isFake: true)
    }

    public var epochSeconds: Int64 { Int64(now.timeIntervalSince1970) }
}

/// Strict parsing/formatting for the timestamp formats this repo writes:
/// log lines use `2026-10-11T03:14:05+0200` (24 chars: `date
/// +%Y-%m-%dT%H:%M:%S%z` in bin/hotspotd and the checker; the same shape
/// from menubar/Wifi.swift's wifiLogFormatter), while this tool's own
/// machine-readable stamps use the same clock in UTC with a `Z` suffix
/// (`2026-10-11T04:31:00Z`, 20 chars). Parsed and formatted by hand: no
/// locale, no platform date-format variance, deterministic bytes.
public enum ISOTimestamp {
    /// Parses `yyyy-MM-ddTHH:mm:ssZ` (20 chars, UTC) or
    /// `yyyy-MM-ddTHH:mm:ss±HHMM` (24 chars, numeric offset). Returns nil for
    /// anything else — shape or semantic validity (month 1-12, a real day,
    /// hour < 24, minute < 60, second < 60).
    public static func parse(_ s: String) -> Date? {
        let chars = Array(s.unicodeScalars)
        var offsetSeconds = 0
        if chars.count == 20 {
            guard chars[19] == "Z" else { return nil }
        } else if chars.count == 24 {
            guard chars[19] == "+" || chars[19] == "-" else { return nil }
            guard let offHour = digits(chars, 20, 21), let offMin = digits(chars, 22, 23),
                  offHour < 24, offMin < 60
            else { return nil }
            offsetSeconds = (offHour * 3600 + offMin * 60) * (chars[19] == "+" ? 1 : -1)
        } else {
            return nil
        }
        func digit(_ c: Unicode.Scalar) -> Int? {
            guard c.value >= 0x30 && c.value <= 0x39 else { return nil }
            return Int(c.value - 0x30)
        }
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for k in a...b {
                guard let d = digit(chars[k]) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard chars[4] == "-", chars[7] == "-", chars[10] == "T",
              chars[13] == ":", chars[16] == ":"
        else { return nil }
        guard let year = num(0, 3), let month = num(5, 6), let day = num(8, 9),
              let hour = num(11, 12), let minute = num(14, 15), let second = num(17, 18)
        else { return nil }
        guard month >= 1 && month <= 12,
              day >= 1 && day <= daysInMonth(year: year, month: month),
              hour < 24, minute < 60, second < 60
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        guard let base = utc.date(from: components) else { return nil }
        // A local wall time of `base + offset` corresponds to absolute time
        // `base + offset - offset` — i.e. the epoch is base minus offset.
        return base.addingTimeInterval(TimeInterval(-offsetSeconds))
    }

    /// Same strictness, but only validates the *shape* of the repo's log
    /// timestamp token (24 chars with a numeric offset) — used to classify
    /// log lines without a full semantic parse.
    public static func isShape(_ s: String) -> Bool {
        let chars = Array(s.unicodeScalars)
        guard chars.count == 24 else { return false }
        func isDigit(_ c: Unicode.Scalar) -> Bool {
            c.value >= 0x30 && c.value <= 0x39
        }
        let digitSlots = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 22, 23]
        for k in digitSlots where !isDigit(chars[k]) { return false }
        return chars[4] == "-" && chars[7] == "-" && chars[10] == "T"
            && chars[13] == ":" && chars[16] == ":" && (chars[19] == "+" || chars[19] == "-")
    }

    /// Formats as `2026-10-11T04:31:00Z` (UTC) — for machine-readable stamps
    /// this tool itself emits (captured_at, bundle manifest).
    public static func format(_ date: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard month >= 1 && month <= 12 else { return 0 }
        var days = lengths[month - 1]
        if month == 2 && isLeapYear(year) { days = 29 }
        return days
    }

    static func isLeapYear(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    private static func digits(_ chars: [Unicode.Scalar], _ a: Int, _ b: Int) -> Int? {
        var v = 0
        for k in a...b {
            let c = chars[k]
            guard c.value >= 0x30 && c.value <= 0x39 else { return nil }
            v = v * 10 + Int(c.value - 0x30)
        }
        return v
    }
}
