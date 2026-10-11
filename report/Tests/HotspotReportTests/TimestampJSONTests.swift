import XCTest
@testable import HotspotReport

final class TimestampTests: XCTestCase {
    func testParsesUTCZ() {
        let d = ISOTimestamp.parse("2026-10-11T04:31:00Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(d!.timeIntervalSince1970, 1791693060.0)
        XCTAssertEqual(ISOTimestamp.format(d!), "2026-10-11T04:31:00Z")
    }

    func testParsesPositiveOffset() {
        // 06:31:00 at +0200 == 04:31:00Z
        let d = ISOTimestamp.parse("2026-10-11T06:31:00+0200")
        XCTAssertEqual(d!.timeIntervalSince1970, 1791693060.0)
    }

    func testParsesNegativeOffset() {
        // 02:31:00 at -0200 == 04:31:00Z
        let d = ISOTimestamp.parse("2026-10-11T02:31:00-0200")
        XCTAssertEqual(d!.timeIntervalSince1970, 1791693060.0)
    }

    func testOffsetFormattingRoundTrip() {
        // The repo's log stamp shape parses back to absolute UTC.
        let d = ISOTimestamp.parse("2026-10-11T03:14:05+0530")
        XCTAssertNotNil(d)
        // 03:14:05 - 05:30 == 21:44:05 the previous day UTC
        XCTAssertEqual(ISOTimestamp.format(d!), "2026-10-10T21:44:05Z")
    }

    func testRejectsBadShapes() {
        XCTAssertNil(ISOTimestamp.parse("2026-10-11T04:31:00"))           // no zone
        XCTAssertNil(ISOTimestamp.parse("2026-10-11T04:31:00+020"))       // offset truncated
        XCTAssertNil(ISOTimestamp.parse("not a timestamp"))
        XCTAssertNil(ISOTimestamp.parse("2026-10-11 04:31:00Z"))          // space, not T
        XCTAssertNil(ISOTimestamp.parse("2026-13-01T00:00:00Z"))          // month 13
        XCTAssertNil(ISOTimestamp.parse("2026-02-30T00:00:00Z"))          // Feb 30
        XCTAssertNil(ISOTimestamp.parse("2026-02-29T00:00:00Z"))          // 2026 not leap
        XCTAssertNil(ISOTimestamp.parse("2026-10-11T24:00:00Z"))          // hour 24
        XCTAssertNil(ISOTimestamp.parse("2026-10-11T04:60:00Z"))          // minute 60
        XCTAssertNil(ISOTimestamp.parse("2026-10-11T04:31:60Z"))          // second 60
        XCTAssertNil(ISOTimestamp.parse("2026-10-11T04:31:00+2400"))      // offset hour 24
        XCTAssertNil(ISOTimestamp.parse("2026-10-11T04:31:00+0260"))      // offset minute 60
    }

    func testAcceptsLeapDay() {
        XCTAssertNotNil(ISOTimestamp.parse("2024-02-29T00:00:00Z"))
        XCTAssertNotNil(ISOTimestamp.parse("2000-02-29T00:00:00Z"))
        XCTAssertNil(ISOTimestamp.parse("1900-02-29T00:00:00Z"))  // century, not leap
    }

    func testShapeCheck() {
        XCTAssertTrue(ISOTimestamp.isShape("2026-10-11T03:14:05+0200"))
        XCTAssertFalse(ISOTimestamp.isShape("2026-10-11T04:31:00Z"))  // Z is not the log shape
        XCTAssertFalse(ISOTimestamp.isShape("garbage"))
        XCTAssertFalse(ISOTimestamp.isShape("2026-10-11T03:14:05+02:0"))
    }
}

final class JSONTests: XCTestCase {
    func testRoundTripObject() throws {
        let text = #"{"a":1,"b":[true,null,"x"],"c":{"d":"e"}}"#
        let v = try JSON.parse(text)
        XCTAssertEqual(JSON.write(v), text)
    }

    func testObjectPreservesKeyOrder() throws {
        let v = try JSON.parse(#"{"z":1,"a":2,"m":3}"#)
        guard case .object(let pairs) = v else { return XCTFail() }
        XCTAssertEqual(pairs.map(\.0), ["z", "a", "m"])
    }

    func testDuplicateKeysAreRejected() throws {
        // The parser is strict: duplicate object keys are malformed, so a
        // hand-edited agent.status cannot silently mean "last one wins".
        XCTAssertThrowsError(try JSON.parse(#"{"k":1,"k":2}"#))
    }

    func testEscapeRoundTrip() throws {
        let text = #"{"k":"a\"b\\c/d\n\t"}"#
        let v = try JSON.parse(text)
        XCTAssertEqual(JSON.write(v), text)
    }

    func testUnicodeEscapeBecomesUTF8() throws {
        let v = try JSON.parse(#""é""#)
        XCTAssertEqual(JSON.write(v), "\"é\"")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try JSON.parse(#"{"a":}"#))
        XCTAssertThrowsError(try JSON.parse(#"{"a":1"#))
        XCTAssertThrowsError(try JSON.parse("[1,2,]"))
        XCTAssertThrowsError(try JSON.parse("nope"))
        XCTAssertThrowsError(try JSON.parse(#""unterminated"#))
        XCTAssertThrowsError(try JSON.parse(#"{"a" 1}"#))
        XCTAssertThrowsError(try JSON.parse("{} {}"))   // trailing content
        XCTAssertThrowsError(try JSON.parse("01"))      // leading zero
        XCTAssertThrowsError(try JSON.parse("1e999999999999"))  // overflow
        XCTAssertThrowsError(try JSON.parse(""))        // empty
    }

    func testSubscriptAccess() throws {
        let v = try JSON.parse(#"{"a":{"b":[10,20]}}"#)
        guard case .int(let n)? = v["a"]?["b"]?[1] else { return XCTFail() }
        XCTAssertEqual(n, 20)
        XCTAssertNil(v["missing"])
    }

    func testNumbers() throws {
        XCTAssertEqual(JSON.write(try JSON.parse("0")), "0")
        // The writer canonicalizes: -0 folds to 0 and exponent notation
        // becomes the plain value. Round-trip fidelity applies to our own
        // output bytes, not to re-serializing foreign files.
        XCTAssertEqual(JSON.write(try JSON.parse("-0")), "0")
        XCTAssertEqual(JSON.write(try JSON.parse("1.5e3")), "1500")
        XCTAssertEqual(JSON.write(try JSON.parse("-12.25")), "-12.25")
        // Integers preserve their integer-ness for epoch fields.
        guard case .int(let n) = try JSON.parse("1791693060") else { return XCTFail() }
        XCTAssertEqual(n, 1791693060)
    }
}
