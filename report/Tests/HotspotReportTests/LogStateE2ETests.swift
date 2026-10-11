import XCTest
@testable import HotspotReport

final class LogReaderTests: XCTestCase {
    func testParsesWellFormedLines() {
        let dir = Fixtures.makeTempDir("log-ok")
        let path = dir + "/auto-hotspot.log"
        Fixtures.write(path, """
        [2026-10-11T03:30:00+0130] [info] watcher started
        [2026-10-11T06:00:00+0130] [error] captive portal check failed
        [2026-10-11T06:00:05+0130] [warn] retry scheduled
        """)
        let r = readLog(at: path, rotatedPath: path + ".1")
        XCTAssertEqual(r.fileState, "present")
        XCTAssertEqual(r.linesAccepted, 3)
        XCTAssertEqual(r.linesRefused, 0)
        XCTAssertEqual(r.levels, ["info": 1, "warn": 1, "error": 1])
        XCTAssertEqual(r.firstTimestamp, "2026-10-11T03:30:00+0130")
        XCTAssertEqual(r.lastTimestamp, "2026-10-11T06:00:05+0130")
        // Offset-aware absolute time of the last line (06:00:05+0130 == 04:30:05Z).
        XCTAssertEqual(r.lastEventEpochSeconds, 1_791_693_005)
    }

    func testRefusedLinesCountedWithNumbers() {
        let dir = Fixtures.makeTempDir("log-bad")
        let path = dir + "/auto-hotspot.log"
        Fixtures.write(path, """
        [2026-10-11T06:00:00+0130] [info] good line
        this line has no shape at all
        [not-a-timestamp] [info] bad ts
        """)
        let r = readLog(at: path, rotatedPath: path + ".1")
        XCTAssertEqual(r.linesAccepted, 1)
        XCTAssertEqual(r.linesRefused, 2)
        XCTAssertEqual(r.refusals.count, 2)
        XCTAssertTrue(r.refusals[0].contains("line 2"))
        XCTAssertTrue(r.refusals[1].contains("line 3"))
    }

    func testEmptyAndMissingFiles() {
        let dir = Fixtures.makeTempDir("log-empty")
        let path = dir + "/auto-hotspot.log"
        Fixtures.write(path, "")
        var r = readLog(at: path, rotatedPath: path + ".1")
        XCTAssertEqual(r.fileState, "empty")
        XCTAssertEqual(r.linesAccepted, 0)

        r = readLog(at: dir + "/absent.log", rotatedPath: path + ".1")
        XCTAssertEqual(r.fileState, "missing")
    }

    func testTailWindowTruncationReported() {
        let dir = Fixtures.makeTempDir("log-big")
        let path = dir + "/auto-hotspot.log"
        // 200 lines x ~60 bytes = ~12 KB; cap at 4 KB so the head is cut.
        var body = ""
        for i in 1...200 {
            body += String(format: "[2026-10-11T%02d:%02d:00+0130] [info] event number %03d\n",
                           1 + i / 60, i % 60, i)
        }
        Fixtures.write(path, body)
        let r = readLog(at: path, rotatedPath: path + ".1", tailCapBytes: 4096)
        XCTAssertTrue(r.truncatedHead)
        XCTAssertGreaterThan(r.bytesRead, 0)
        XCTAssertLessThanOrEqual(r.bytesRead, 4096)
        XCTAssertEqual(r.linesRefused, 0)
        // The byte cap may land exactly on a line boundary — then no partial
        // head line exists. At most one line (the partial head) is lost.
        XCTAssertTrue(r.linesRead == r.linesAccepted || r.linesRead == r.linesAccepted + 1,
                      "at most the partial head line is dropped")
        XCTAssertNotNil(r.lastTimestamp)
    }

    func testProseRedactionRedactsWholePhrasesAndFragments() {
        // Known secret: multi-word SSID disappears completely, any case.
        XCTAssertEqual(
            redactProse("joined SSID Secret Garden", secrets: ["Secret Garden"]),
            "joined SSID REDACTED"
        )
        XCTAssertEqual(
            redactProse("seen at secret garden again", secrets: ["Secret Garden"]),
            "seen at REDACTED again"
        )
        // Unknown SSID: the keyword pass catches the single token after SSID
        // (deliberately conservative — without knowing the secret, the extent
        // of a multi-word SSID is unknowable; the known-secret pass handles
        // the case where the readers did bind it).
        XCTAssertEqual(
            redactProse("joined SSID Coffee Shop Wifi", secrets: []),
            "joined SSID REDACTED Shop Wifi"
        )
        // Prose without any SSID mention is untouched.
        XCTAssertEqual(redactProse("watcher started", secrets: ["Secret Garden"]), "watcher started")
    }

    func testUnknownLevelCounted() {
        let dir = Fixtures.makeTempDir("log-level")
        let path = dir + "/auto-hotspot.log"
        Fixtures.write(path, "[2026-10-11T06:00:00+0130] [debug] new level\n")
        let r = readLog(at: path, rotatedPath: path + ".1")
        XCTAssertEqual(r.linesAccepted, 1)
        XCTAssertEqual(r.unknownLevels, 1)
        XCTAssertEqual(r.levels["debug"], 1)
    }
}

final class StateReaderTests: XCTestCase {
    func testMissingStateFilesBindControllerDefaults() {
        let dir = Fixtures.makeTempDir("st-missing")
        let r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 45, clock: Fixtures.clock)
        guard case .missing(.int(0)) = r.lastJoinAttempt else {
            return XCTFail("missing last-join-attempt must bind effective 0")
        }
        XCTAssertEqual(r.lockState, "absent")
        guard case .missing = r.trigger else { return XCTFail("trigger should be missing") }
        guard case .missing = r.buildFingerprint else { return XCTFail("fingerprint should be missing") }
        XCTAssertFalse(r.installPlistPresent)
        XCTAssertFalse(r.agentExecPresent)
    }

    func testLastJoinAttemptForms() {
        let dir = Fixtures.makeTempDir("st-lja")
        // Present numeric (with trailing newline, as echo writes it).
        Fixtures.write(dir + "/last-join-attempt", "1791693000\n")
        var r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 45, clock: Fixtures.clock)
        guard case .present(.int(1_791_693_000)) = r.lastJoinAttempt else {
            return XCTFail("numeric form should bind: \(r.lastJoinAttempt)")
        }

        // Malformed content: hotspotd would fall back to 0; the reader
        // reports malformed-with-0.
        Fixtures.write(dir + "/last-join-attempt", "soon")
        r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 45, clock: Fixtures.clock)
        guard case .malformed(_, .int(0)) = r.lastJoinAttempt else {
            return XCTFail("malformed form must carry effective 0")
        }
    }

    func testLockStates() {
        let dir = Fixtures.makeTempDir("st-lock")
        // Fresh lock (60s old): held. The stale window is 4x cooldown with a
        // 300s floor — cooldown 100 gives 400s so the multiplication shows.
        let fresh = Fixtures.clock.now.addingTimeInterval(-60)
        Fixtures.mkdir(dir + "/lock", mtime: fresh)
        var r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 100, clock: Fixtures.clock)
        XCTAssertEqual(r.lockState, "held")
        XCTAssertEqual(r.lockAgeSeconds, 60)
        XCTAssertEqual(r.lockStaleWindowSeconds, 400)  // 100 * 4

        // Ancient lock: present_but_stale, same formula as the checker.
        let ancient = Fixtures.clock.now.addingTimeInterval(-2000)
        Fixtures.mkdir(dir + "/lock", mtime: ancient)
        r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 100, clock: Fixtures.clock)
        XCTAssertEqual(r.lockState, "present_but_stale")

        // Cooldown 0 still gets the 300s floor.
        Fixtures.mkdir(dir + "/lock", mtime: fresh)
        r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 0, clock: Fixtures.clock)
        XCTAssertEqual(r.lockState, "held")
        XCTAssertEqual(r.lockStaleWindowSeconds, 300)
    }

    func testBuildFingerprintShape() {
        let dir = Fixtures.makeTempDir("st-fp")
        let hex64 = String(repeating: "0123456789abcdef", count: 4)   // 64 chars
        XCTAssertEqual(hex64.count, 64)
        Fixtures.write(dir + "/build-fingerprint", hex64)
        var r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 45, clock: Fixtures.clock)
        guard case .present(.string(hex64)) = r.buildFingerprint else {
            return XCTFail("64 lowercase hex should bind: \(r.buildFingerprint)")
        }

        // Wrong length is malformed.
        Fixtures.write(dir + "/build-fingerprint", hex64 + "zz")
        r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 45, clock: Fixtures.clock)
        guard case .malformed = r.buildFingerprint else {
            return XCTFail("non-64-char content should be malformed")
        }

        // Uppercase hex is not what sha256sum writes; refused.
        Fixtures.write(dir + "/build-fingerprint", hex64.uppercased())
        r = readState(stateDir: dir, homeDirectory: dir, effectiveCooldownSeconds: 45, clock: Fixtures.clock)
        guard case .malformed = r.buildFingerprint else {
            return XCTFail("uppercase hex should be malformed")
        }
    }

    func testInstallPathExistenceOnly() {
        let home = Fixtures.makeTempDir("st-install")
        let plist = home + "/Library/LaunchAgents"
        Fixtures.mkdir(plist)
        Fixtures.write(plist + "/com.andrewwang.autohotspot.plist", "<plist/>")
        let r = readState(stateDir: home, homeDirectory: home, effectiveCooldownSeconds: 45, clock: Fixtures.clock)
        XCTAssertTrue(r.installPlistPresent)
        XCTAssertFalse(r.agentExecPresent)
    }
}

final class EndToEndTests: XCTestCase {
    func testFullCollectProducesDeterministicJSON() throws {
        let (_, inputs) = Fixtures.fullInstall()
        let a = InputSummary.collect(inputs: inputs, clock: Fixtures.clock)
        let b = InputSummary.collect(inputs: inputs, clock: Fixtures.clock)

        let ja = String(data: serialize(a), encoding: .utf8)!
        let jb = String(data: serialize(b), encoding: .utf8)!
        XCTAssertEqual(ja, jb, "same inputs + fixed clock must give byte-identical JSON")
        let doc = try JSON.parse(ja)
        guard case .string("auto-hotspot.report/1")? = doc["schema"] else {
            return XCTFail("schema stamp missing")
        }
    }

    func testSSIDRedactedInJSONAndMarkdown() throws {
        let (_, inputs) = Fixtures.fullInstall()
        let s = InputSummary.collect(inputs: inputs, clock: Fixtures.clock)
        let json = String(data: serialize(s), encoding: .utf8)!
        let md = renderMarkdown(s)
        let terminal = renderTerminal(s)

        XCTAssertFalse(json.contains("Home Wifi"), "SSID must never appear in the JSON envelope")
        XCTAssertTrue(json.contains("REDACTED"))
        XCTAssertFalse(md.contains("Home Wifi"))
        XCTAssertFalse(terminal.contains("Home Wifi"))
        XCTAssertTrue(json.contains("\"effective\":\"REDACTED\""))
    }

    func testFreshInstallJSONShape() throws {
        let (_, inputs) = Fixtures.fullInstall()
        let s = InputSummary.collect(inputs: inputs, clock: Fixtures.clock)
        let doc = try JSON.parse(String(data: serialize(s), encoding: .utf8)!)

        let config = try XCTUnwrap(doc["config"])
        let lines = try XCTUnwrap(config["lines"])
        guard case .int(let accepted)? = lines["accepted"], accepted == 8 else {
            return XCTFail("expected 8 accepted config lines")
        }
        let agent = try XCTUnwrap(doc["agent_status"])
        guard case .bool(false)? = agent["stale"] else { return XCTFail("expected fresh agent status") }
        let state = try XCTUnwrap(doc["state"])
        let lock = try XCTUnwrap(state["lock"])
        guard case .string("held")? = lock["state"] else { return XCTFail("expected held lock") }
    }

    func testBundleWritesAndRedacts() throws {
        let (_, inputs) = Fixtures.fullInstall()
        let s = InputSummary.collect(inputs: inputs, clock: Fixtures.clock)
        let dest = Fixtures.makeTempDir("bundle-dest") + "/out"
        let result = try writeBundle(s, to: dest, redacted: true)

        XCTAssertEqual(result.files, ["report.json", "log.tail.txt", "manifest.txt"])
        let tail = try String(contentsOfFile: dest + "/log.tail.txt", encoding: .utf8)
        XCTAssertFalse(tail.contains("Home Wifi"), "bundle log prose must be redacted by default")
        // No fragments either: a multi-word SSID must vanish as a whole phrase.
        XCTAssertFalse(tail.contains("Wifi"), "SSID fragment leaked through redaction")
        XCTAssertTrue(tail.contains("REDACTED"))
        XCTAssertTrue(tail.contains("[info]"))
        let manifest = try String(contentsOfFile: dest + "/manifest.txt", encoding: .utf8)
        XCTAssertTrue(manifest.contains("redacted: true"))

        // Unredacted bundle carries the SSID — explicit opt-in only.
        let dest2 = Fixtures.makeTempDir("bundle-raw") + "/out"
        _ = try writeBundle(s, to: dest2, redacted: false)
        let rawTail = try String(contentsOfFile: dest2 + "/log.tail.txt", encoding: .utf8)
        XCTAssertTrue(rawTail.contains("Home Wifi"))
        // report.json in the bundle is the redacted envelope in both cases.
        let rawJSON = try String(contentsOfFile: dest2 + "/report.json", encoding: .utf8)
        XCTAssertFalse(rawJSON.contains("Home Wifi"))
    }

    func testEmptyEnvironmentDefaults() {
        // No HOME, no overrides: paths build from "" and bind missing.
        let inputs = ReportInputs.fromEnvironment([:])
        XCTAssertEqual(inputs.configPath, "/.config/auto-hotspot/config")
        XCTAssertEqual(inputs.logPath, "/Library/Logs/auto-hotspot.log")
        XCTAssertEqual(inputs.stateDir, "/.local/state/auto-hotspot")
        let r = readConfig(at: inputs.configPath)
        XCTAssertEqual(r.fileState, "missing")
    }
}
