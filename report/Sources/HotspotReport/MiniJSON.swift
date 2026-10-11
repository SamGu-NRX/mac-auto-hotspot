import Foundation

// Minimal strict JSON parser and writer used by every HotspotReport module.
//
// Why not JSONSerialization / JSONDecoder:
//   1. The schema binding needs exact per-field type information so each
//      field can be classified present / missing / stale / malformed on its
//      own — not an all-or-nothing thrown error.
//   2. Byte-stable output: objects preserve insertion order, so identical
//      logical content serializes to identical bytes across replay runs.
//      The support bundle's integrity receipts (SHA-256 over files) rely on
//      that determinism.
//   3. No NSNumber bridging ambiguity between Darwin and Linux for
//      bool-vs-number (JSONSerialization on Linux bridges `1` and `true`
//      both into NSNumber; the strict schema must treat those as different).
//
// Scope: the RFC 8259 subset that the controller's files use and this tool
// writes. Strictly rejected: a leading BOM, trailing garbage, control
// characters inside strings, duplicate object keys, lone surrogates, numbers
// with leading zeros, and out-of-range numbers.

public enum JSONValue {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Insertion-ordered object; duplicate keys are a parse error.
    case object([(String, JSONValue)])
}

public enum JSONError: Error, Equatable {
    case malformed(offset: Int, detail: String)
}

extension JSONValue {
    /// First value stored under `key`, or nil when absent or not an object.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        for (k, v) in pairs where k == key { return v }
        return nil
    }

    /// Element at `index`, or nil when out of range or not an array.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

public enum JSON {
    // MARK: Parsing

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Array(text.utf8))
    }

    public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var parser = Parser(bytes)
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw parser.error("trailing data after JSON value")
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var n: Int { bytes.count }
        func byte(_ at: Int) -> UInt8 { bytes[at] }
        var isAtEnd: Bool { i >= n }
        func error(_ detail: String) -> JSONError { .malformed(offset: i, detail: detail) }

        mutating func skipWhitespace() {
            while i < n {
                let b = bytes[i]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 } else { break }
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            if depth > 100 { throw error("nesting deeper than 100 levels") }
            skipWhitespace()
            guard i < n else { throw error("unexpected end of input") }
            switch bytes[i] {
            case 0x7B: return try parseObject(depth: depth)      // {
            case 0x5B: return try parseArray(depth: depth)       // [
            case 0x22: return .string(try parseString())         // "
            case 0x74: try expectWord("true"); return .bool(true)
            case 0x66: try expectWord("false"); return .bool(false)
            case 0x6E: try expectWord("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expectWord(_ word: String) throws {
            for scalar in word.utf8 {
                guard i < n, bytes[i] == scalar else { throw error("expected \(word)") }
                i += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            i += 1 // consume {
            var pairs: [(String, JSONValue)] = []
            skipWhitespace()
            if i < n, bytes[i] == 0x7D { i += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard i < n, bytes[i] == 0x22 else { throw error("expected object key string") }
                let key = try parseString()
                skipWhitespace()
                guard i < n, bytes[i] == 0x3A else { throw error("expected ':' after object key") }
                i += 1
                let value = try parseValue(depth: depth + 1)
                if pairs.contains(where: { $0.0 == key }) {
                    throw error("duplicate object key \(key)")
                }
                pairs.append((key, value))
                skipWhitespace()
                guard i < n else { throw error("unterminated object") }
                if bytes[i] == 0x2C { i += 1; continue }          // ,
                if bytes[i] == 0x7D { i += 1; return .object(pairs) }
                throw error("expected ',' or '}' in object")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            i += 1 // consume [
            var items: [JSONValue] = []
            skipWhitespace()
            if i < n, bytes[i] == 0x5D { i += 1; return .array(items) }
            while true {
                let value = try parseValue(depth: depth + 1)
                items.append(value)
                skipWhitespace()
                guard i < n else { throw error("unterminated array") }
                if bytes[i] == 0x2C { i += 1; continue }          // ,
                if bytes[i] == 0x5D { i += 1; return .array(items) }
                throw error("expected ',' or ']' in array")
            }
        }

        mutating func parseString() throws -> String {
            i += 1 // consume opening quote
            var utf8Out: [UInt8] = []
            while true {
                guard i < n else { throw error("unterminated string") }
                let b = bytes[i]
                if b == 0x22 {                                     // "
                    i += 1
                    guard let s = String(bytes: utf8Out, encoding: .utf8) else {
                        throw error("invalid UTF-8 in string")
                    }
                    return s
                }
                if b < 0x20 { throw error("control character in string") }
                if b == 0x5C {                                     // backslash
                    i += 1
                    guard i < n else { throw error("unterminated escape") }
                    let e = bytes[i]
                    switch e {
                    case 0x22: utf8Out.append(0x22); i += 1        // \"
                    case 0x5C: utf8Out.append(0x5C); i += 1        // \\
                    case 0x2F: utf8Out.append(0x2F); i += 1        // \/
                    case 0x62: utf8Out.append(0x08); i += 1        // \b
                    case 0x66: utf8Out.append(0x0C); i += 1        // \f
                    case 0x6E: utf8Out.append(0x0A); i += 1        // \n
                    case 0x72: utf8Out.append(0x0D); i += 1        // \r
                    case 0x74: utf8Out.append(0x09); i += 1        // \t
                    case 0x75:                                      // \uXXXX
                        let scalar = try parseUnicodeEscape()
                        appendScalar(scalar, to: &utf8Out)
                    default:
                        throw error("invalid escape character")
                    }
                    continue
                }
                utf8Out.append(b)
                i += 1
            }
        }

        /// Parses \uXXXX; lone surrogates are rejected, a high surrogate must
        /// be followed by the matching low surrogate.
        mutating func parseUnicodeEscape() throws -> UInt32 {
            func hex4() throws -> UInt32 {
                guard i + 4 <= n else { throw error("truncated \\u escape") }
                var value: UInt32 = 0
                for k in 0..<4 {
                    let b = bytes[i + k]
                    let d: UInt32
                    switch b {
                    case 0x30...0x39: d = UInt32(b - 0x30)
                    case 0x61...0x66: d = UInt32(b - 0x61) + 10
                    case 0x41...0x46: d = UInt32(b - 0x41) + 10
                    default: throw error("invalid hex digit in \\u escape")
                    }
                    value = value << 4 | d
                }
                i += 4
                return value
            }
            let first = try hex4()
            if first >= 0xD800 && first <= 0xDBFF {
                guard i + 6 <= n, bytes[i] == 0x5C, bytes[i + 1] == 0x75 else {
                    throw error("lone high surrogate in \\u escape")
                }
                i += 2
                let second = try hex4()
                guard second >= 0xDC00 && second <= 0xDFFF else {
                    throw error("unmatched high surrogate in \\u escape")
                }
                return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            }
            if first >= 0xDC00 && first <= 0xDFFF {
                throw error("lone low surrogate in \\u escape")
            }
            return first
        }

        func appendScalar(_ scalar: UInt32, to out: inout [UInt8]) {
            guard let u = Unicode.Scalar(scalar) else { return }
            out.append(contentsOf: Array(String(u).utf8))
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = i
            if i < n, bytes[i] == 0x2D { i += 1 }                  // -
            guard i < n, bytes[i] >= 0x30 && bytes[i] <= 0x39 else {
                throw error("invalid number")
            }
            if bytes[i] == 0x30 {
                i += 1
                if i < n, bytes[i] >= 0x30 && bytes[i] <= 0x39 {
                    throw error("leading zero in number")
                }
            } else {
                while i < n, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
            }
            var isDouble = false
            if i < n, bytes[i] == 0x2E {                           // .
                isDouble = true
                i += 1
                guard i < n, bytes[i] >= 0x30 && bytes[i] <= 0x39 else {
                    throw error("digits required after decimal point")
                }
                while i < n, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
            }
            if i < n, bytes[i] == 0x65 || bytes[i] == 0x45 {       // e / E
                isDouble = true
                i += 1
                if i < n, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
                guard i < n, bytes[i] >= 0x30 && bytes[i] <= 0x39 else {
                    throw error("digits required in exponent")
                }
                while i < n, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if !isDouble {
                if let v = Int64(text) { return .int(v) }
            }
            guard let d = Double(text), d.isFinite else {
                throw error("number out of range")
            }
            return .double(d)
        }
    }

    // MARK: Writing

    /// Serializes with insertion-ordered objects and no insignificant
    /// whitespace — deterministic bytes for identical logical content.
    public static func write(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    public static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let n):
            out += String(n)
        case .double(let d):
            // Doubles never occur in schema output today; emit them without
            // pretending to be bit-exact. Non-finite doubles become null
            // rather than emitting invalid JSON.
            if d.isFinite {
                if d == d.rounded() && abs(d) < 1e15 {
                    out += String(Int64(d))
                } else {
                    out += String(d)
                }
            } else {
                out += "null"
            }
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (idx, item) in items.enumerated() {
                if idx > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (idx, pair) in pairs.enumerated() {
                if idx > 0 { out += "," }
                writeString(pair.0, into: &out)
                out += ":"
                write(pair.1, into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
