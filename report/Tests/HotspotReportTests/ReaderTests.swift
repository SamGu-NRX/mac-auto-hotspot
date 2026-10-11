import XCTest
@testable import HotspotReport

/// Fixture helpers: every test builds a synthetic state layout in a fresh
/// temp directory. No real user data is ever touched.
enum Fixtures {
    static func makeTempDir(_ name: String) -> String {
        let dir = NSTemporaryDirectory() + "/hotspot-report-tests-\(name)-\(UUID().uuidString.prefix(8))"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ path: String, _ content: String, mtime: Date? = nil) {
        FileManager.default.createFile(atPath: path, contents: content.data(using: .utf8))
        if let m = mtime {
            try! FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: path)
        }
    }

    static func writeBytes(_ path: String, _ content: [UInt8]) {
        FileManager.default.createFile(atPath: path, contents: Data(content))
    }

    static func mkdir(_ path: String, mtime: Date? = nil) {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let m = mtime {
            try! FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: path)
        }
    }

    /// A fixed clock at 2026-10-11T04:31:00Z (epoch 1791693060).
    static let clock = ReportClock.fixed(epochSeconds: 1_791_693_060)

    /// A full synthetic install: config, agent.status, log, state dir —
    /// mirroring what bin/hotspotd + the app write, with the mtime of every
    /// state file set 60s before the fixed clock (fresh).
    static func fullInstall() -> (root: String, inputs: ReportInputs) {
        let home = makeTempDir("home")
        let config = home + "/.config/auto-hotspot/config"
        let log = home + "/Library/Logs/auto-hotspot.log"
        let stateDir = home + "/.local/state/auto-hotspot"
        mkdir(home + "/.config/auto-hotspot")
        mkdir(home + "/Library/Logs")
        mkdir(stateDir, mtime: clock.now.addingTimeInterval(-60))

        write(config, """
        # managed by bin/hotspotd config_set (bare keys; the file is sourced)
        SSID="Home Wifi"
        CHECK_INTERVAL="300"
        ENABLED="1"
        COOLDOWN="45"
        WIFI_INTERFACE="en0"
        HOTSPOT_ROUTER="172.20.10.1"
        HOTSPOTD_BIN="/usr/local/bin/hotspotd"
        NOTIFY="0"
        """)

        let fresh = clock.now.addingTimeInterval(-60)
        write(stateDir + "/agent.status", """
        {"watcher_running":true,"location_authorized":true,"ssid_current":"Home Wifi","last_join_result":"joined","updated":1791693000}
        """, mtime: fresh)
        write(log, """
        [2026-10-11T03:30:00+0130] [info] watcher started
        [2026-10-11T06:00:00+0130] [error] captive portal check failed
        [2026-10-11T06:00:05+0130] [info] joined SSID Home Wifi
        """)
        write(stateDir + "/last-join-attempt", "1791693000\n")
        mkdir(stateDir + "/lock", mtime: fresh)

        return (home, ReportInputs(
            configPath: config, logPath: log, stateDir: stateDir, homeDirectory: home
        ))
    }
}

final class ConfigReaderTests: XCTestCase {
    func testAllEightKeysBindWithCounts() {
        let (_, inputs) = Fixtures.fullInstall()
        let r = readConfig(at: inputs.configPath)
        XCTAssertEqual(r.fileState, "present")
        XCTAssertEqual(r.counts.linesAccepted, 8)
        XCTAssertEqual(r.counts.linesRefused, 0)
        XCTAssertEqual(r.counts.linesIgnored, 1)  // the comment line
        XCTAssertEqual(r.effectiveSSID, "Home Wifi")
        XCTAssertEqual(r.effectiveCheckInterval, 300)
        XCTAssertTrue(r.effectiveEnabled)
        XCTAssertEqual(r.effectiveCooldown, 45)
        XCTAssertEqual(r.effectiveWifiInterface, "en0")
        XCTAssertEqual(r.effectiveHotspotRouter, "172.20.10.1")
        XCTAssertEqual(r.effectiveHotspotdBin, "/usr/local/bin/hotspotd")
        XCTAssertFalse(r.effectiveNotify)
    }

    func testMissingFileBindsDefaultsExplicitly() {
        let dir = Fixtures.makeTempDir("cfg-missing")
        let r = readConfig(at: dir + "/nope")
        XCTAssertEqual(r.fileState, "missing")
        // Controller defaults (verified in bin/hotspotd load_config): the
        // default SSID is 'Andrew’s iPhone' with U+2019, ENABLED=1, NOTIFY=1.
        XCTAssertEqual(r.effectiveSSID, "Andrew\u{2019}s iPhone")
        XCTAssertTrue(r.effectiveEnabled)
        XCTAssertTrue(r.effectiveNotify)
        XCTAssertEqual(r.effectiveCheckInterval, 300)
        XCTAssertEqual(r.effectiveCooldown, 30)
        for key in ConfigKeys.all {
            guard case .missing = r.observation(key) else {
                return XCTFail("expected missing state for \(key)")
            }
        }
    }

    func testLastAssignmentWinsPerKey() {
        let dir = Fixtures.makeTempDir("cfg-lastwins")
        let path = dir + "/config"
        Fixtures.write(path, """
        COOLDOWN="10"
        COOLDOWN="20"
        """)
        let r = readConfig(at: path)
        XCTAssertEqual(r.counts.linesAccepted, 2)
        XCTAssertEqual(r.effectiveCooldown, 20)
        guard case .present(.int(20))? = r.observation(ConfigKeys.cooldown) else {
            return XCTFail("expected present state after last-wins")
        }
    }

    func testUnknownKeyIsRefusedAndCounted() {
        let dir = Fixtures.makeTempDir("cfg-unknown")
        let path = dir + "/config"
        Fixtures.write(path, """
        SSID="x"
        HOTSPOT_TYPO="1"
        """)
        let r = readConfig(at: path)
        XCTAssertEqual(r.counts.linesAccepted, 1)
        XCTAssertEqual(r.counts.linesRefused, 1)
        XCTAssertEqual(r.counts.unknownKeys, ["HOTSPOT_TYPO"])
        XCTAssertNil(r.observation("HOTSPOT_TYPO"))  // never binds
    }

    func testQuotingFormsDecode() {
        let dir = Fixtures.makeTempDir("cfg-quote")
        let path = dir + "/config"
        // hotspotd's config_set escaping (\\ \" \` \$), single quotes (the
        // app's unquoteConfigValue), and an unquoted token.
        Fixtures.write(path, """
        SSID="back\\\\slash"
        WIFI_INTERFACE='single'
        HOTSPOT_ROUTER=plain
        """)
        let r = readConfig(at: path)
        XCTAssertEqual(r.effectiveSSID, "back\\slash")
        XCTAssertEqual(r.effectiveWifiInterface, "single")
        XCTAssertEqual(r.effectiveHotspotRouter, "plain")
        XCTAssertEqual(r.counts.linesRefused, 0)
    }

    func testMetacharacterValueIsRefusedNotGuessed() {
        let dir = Fixtures.makeTempDir("cfg-meta")
        let path = dir + "/config"
        // Would hijack `. "$CONFIG"` if it reached a shell.
        Fixtures.write(path, "SSID=x;rm -rf /\n")
        let r = readConfig(at: path)
        XCTAssertEqual(r.counts.linesRefused, 1)
        guard case .malformed? = r.observation(ConfigKeys.ssid) else {
            return XCTFail("expected malformed state")
        }
        XCTAssertEqual(r.effectiveSSID, "Andrew\u{2019}s iPhone")  // controller default
    }

    func testNumericKeyWithGarbageIsMalformedWithDefault() {
        let dir = Fixtures.makeTempDir("cfg-num")
        let path = dir + "/config"
        Fixtures.write(path, "COOLDOWN=\"soon\"\n")
        let r = readConfig(at: path)
        XCTAssertEqual(r.counts.linesRefused, 1)
        guard case .malformed? = r.observation(ConfigKeys.cooldown) else {
            return XCTFail("expected malformed state")
        }
        XCTAssertEqual(r.effectiveCooldown, 30)  // controller default
    }
}

final class AgentStatusTests: XCTestCase {
    func testFreshFileBindsAllFiveFields() {
        let (_, inputs) = Fixtures.fullInstall()
        let r = readAgentStatus(at: inputs.agentStatusPath, clock: Fixtures.clock)
        XCTAssertEqual(r.fileState, "present")
        XCTAssertFalse(r.isStale)
        XCTAssertEqual(r.stalenessSource, "mtime")
        guard case .present(.bool(true))? = r.observation(AgentStatusKeys.watcherRunning),
              case .present(.bool(true))? = r.observation(AgentStatusKeys.locationAuthorized),
              case .present(.string("Home Wifi"))? = r.observation(AgentStatusKeys.ssidCurrent),
              case .present(.string("joined"))? = r.observation(AgentStatusKeys.lastJoinResult),
              case .present(.int)? = r.observation(AgentStatusKeys.updated)
        else { return XCTFail("expected all five fields present: \(r.fields)") }
        XCTAssertEqual(r.mtimeAgeSeconds, 60)
    }

    func testMissingFileBindsDefaults() {
        let dir = Fixtures.makeTempDir("as-missing")
        let r = readAgentStatus(at: dir + "/agent.status", clock: Fixtures.clock)
        XCTAssertEqual(r.fileState, "missing")
        // hotspotd's agent_status_field falls back to defaults for a missing
        // file; the reader binds those defaults with .missing state.
        guard case .missing(.bool(false)) = r.observation(AgentStatusKeys.watcherRunning) else {
            return XCTFail("watcher_running must bind missing with false default")
        }
        // ssid_current binds missing (its default is the empty string, but
        // the state is missing, not present-empty).
        guard case .missing? = r.observation(AgentStatusKeys.ssidCurrent) else {
            return XCTFail("ssid_current binds missing when file absent")
        }
    }

    func testStaleFileByMtimeSwapsToDefaults() {
        let dir = Fixtures.makeTempDir("as-stale")
        let path = dir + "/agent.status"
        // Written 700s before the fixed clock — past the 600s window.
        let old = Fixtures.clock.now.addingTimeInterval(-700)
        Fixtures.write(path, #"{"watcher_running":true,"updated":1791692360}"#, mtime: old)
        let r = readAgentStatus(at: path, clock: Fixtures.clock)
        XCTAssertTrue(r.isStale)
        guard case .stale(700, .bool(false))? = r.observation(AgentStatusKeys.watcherRunning) else {
            return XCTFail("expected stale with controller default, got \(String(describing: r.observation(AgentStatusKeys.watcherRunning)))")
        }
    }

    func testUpdatedFieldAgeTrackedAlongsideMtime() {
        let dir = Fixtures.makeTempDir("as-updated")
        let path = dir + "/agent.status"
        // updated epoch is 700s before the clock; the mtime is fresh — mtime
        // wins for staleness, and the updated age is still reported.
        Fixtures.write(path, #"{"watcher_running":true,"updated":1791692360}"#)
        let r = readAgentStatus(at: path, clock: Fixtures.clock)
        XCTAssertEqual(r.stalenessSource, "mtime")
        XCTAssertEqual(r.updatedAgeSeconds, 700)
        XCTAssertFalse(r.isStale)
    }

    func testWrongTypesAreMalformedNotCoerced() {
        let dir = Fixtures.makeTempDir("as-types")
        let path = dir + "/agent.status"
        // The lenient sed reader in hotspotd would accept these; a schema
        // binding must not.
        Fixtures.write(path, #"{"watcher_running":1,"location_authorized":"yes","ssid_current":42,"updated":"soon"}"#)
        let r = readAgentStatus(at: path, clock: Fixtures.clock)
        guard case .malformed? = r.observation(AgentStatusKeys.watcherRunning),
              case .malformed? = r.observation(AgentStatusKeys.locationAuthorized),
              case .malformed? = r.observation(AgentStatusKeys.ssidCurrent),
              case .malformed? = r.observation(AgentStatusKeys.updated)
        else { return XCTFail("expected malformed states, got \(r.fields)") }
        // Controller defaults still bind as effective values.
        guard case .malformed(_, .bool(false))? = r.observation(AgentStatusKeys.watcherRunning) else {
            return XCTFail("watcher_running malformed must carry the false default")
        }
    }

    func testUnknownKeysListed() {
        let dir = Fixtures.makeTempDir("as-unknown")
        let path = dir + "/agent.status"
        Fixtures.write(path, #"{"watcher_running":true,"future_field":"x"}"#)
        let r = readAgentStatus(at: path, clock: Fixtures.clock)
        XCTAssertEqual(r.unknownKeys, ["future_field"])
        XCTAssertEqual(r.fileState, "present")
    }

    func testUnparsableJSONFailsAll() {
        let dir = Fixtures.makeTempDir("as-bad")
        let path = dir + "/agent.status"
        Fixtures.write(path, #"{"watcher_running": tru"#)
        let r = readAgentStatus(at: path, clock: Fixtures.clock)
        XCTAssertEqual(r.fileState, "unparsable")
        for key in AgentStatusKeys.all {
            guard case .malformed? = r.observation(key) else {
                return XCTFail("expected malformed for \(key)")
            }
        }
    }
}
