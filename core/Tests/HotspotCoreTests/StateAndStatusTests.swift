import XCTest
@testable import HotspotCore

/// agent.status writes and the shared state files (lock, cooldown stamp) —
/// the pieces `hotspotd status` and libexec/auto-hotspot-check.sh also
/// read, so the exact file formats and atomicity matter.
final class StateAndStatusTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = TestEnv.makeHome("state")
        TestEnv.activate(home: home)
    }

    override func tearDownWithError() throws {
        TestEnv.deactivate()
        try? FileManager.default.removeItem(atPath: home)
        home = nil
    }

    // MARK: agent.status

    func testWrittenStatusParsesBackWithTheSameFields() throws {
        writeAgentStatusFile(watcherRunning: true, locationAuthorized: false,
                             ssidCurrent: "Hotspot", lastJoinResult: "success")

        let data = try Data(contentsOf: URL(fileURLWithPath: WifiPaths.agentStatusPath))
        let status = try JSONDecoder().decode(AgentStatus.self, from: data)
        XCTAssertTrue(status.watcher_running)
        XCTAssertFalse(status.location_authorized)
        XCTAssertEqual(status.ssid_current, "Hotspot")
        XCTAssertEqual(status.last_join_result, "success")
        XCTAssertGreaterThan(status.updated, 0)
    }

    func testSecondWriteReplacesTheFileWithoutTempResidue() throws {
        writeAgentStatusFile(watcherRunning: true, locationAuthorized: true,
                             ssidCurrent: "A", lastJoinResult: "online")
        writeAgentStatusFile(watcherRunning: true, locationAuthorized: true,
                             ssidCurrent: "B", lastJoinResult: "not_found")

        let contents = try String(contentsOfFile: WifiPaths.agentStatusPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("not_found"))
        XCTAssertFalse(contents.contains("ssid_current\":\"A\""),
                       "the second write must fully replace the first")

        let residue = try FileManager.default.contentsOfDirectory(atPath: WifiPaths.stateDir)
            .filter { $0.contains(".tmp") }
        XCTAssertEqual(residue, [], "no temp files may be left behind")
    }

    func testStatusWriterCreatesTheStateDirWhenMissing() throws {
        try FileManager.default.removeItem(atPath: WifiPaths.stateDir)
        writeAgentStatusFile(watcherRunning: true, locationAuthorized: true,
                             ssidCurrent: "", lastJoinResult: "online")
        XCTAssertTrue(FileManager.default.fileExists(atPath: WifiPaths.agentStatusPath))
    }

    // MARK: single-flight lock

    func testLockIsSingleFlightAndReleasable() {
        XCTAssertTrue(StateStore.acquireLock())
        XCTAssertFalse(StateStore.acquireLock(), "a second taker must be refused")
        StateStore.releaseLock()
        XCTAssertTrue(StateStore.acquireLock(), "the lock must be releasable")
        StateStore.releaseLock()
    }

    func testStaleLockIsBrokenAfterTheStalenessWindow() throws {
        XCTAssertTrue(StateStore.acquireLock())
        // Age the lock past the 300s staleness window (same window as the
        // shell worker's lock) and confirm the next acquisition breaks it.
        let stale = Date().addingTimeInterval(-301)
        try FileManager.default.setAttributes([.modificationDate: stale],
                                              ofItemAtPath: WifiPaths.lockPath)
        XCTAssertTrue(StateStore.acquireLock(), "a stale lock must be broken")
        StateStore.releaseLock()
    }

    func testFreshLockIsNotBrokenEarly() throws {
        XCTAssertTrue(StateStore.acquireLock())
        XCTAssertFalse(StateStore.acquireLock(), "a fresh lock must not be breakable")
        StateStore.releaseLock()
    }

    // MARK: join-attempt stamp

    func testJoinStampRoundTripsAndClears() {
        XCTAssertNil(StateStore.readLastJoinAttempt())
        StateStore.writeLastJoinAttempt(at: 1_234_567)
        XCTAssertEqual(StateStore.readLastJoinAttempt(), 1_234_567)
        StateStore.clearLastJoinAttempt()
        XCTAssertNil(StateStore.readLastJoinAttempt())
    }

    func testJoinStampFileIsPlainEpochSecondsForShellInterop() {
        StateStore.writeLastJoinAttempt(at: 1_234_567)
        let contents = (try? String(contentsOfFile: WifiPaths.lastJoinAttemptPath,
                                     encoding: .utf8)) ?? ""
        XCTAssertEqual(contents.trimmingCharacters(in: .whitespacesAndNewlines), "1234567",
                       "the shell worker reads this file as plain epoch seconds")
    }

    func testJoinStampWriterCreatesTheStateDirWhenMissing() throws {
        try FileManager.default.removeItem(atPath: WifiPaths.stateDir)
        StateStore.writeLastJoinAttempt(at: 42)
        XCTAssertEqual(StateStore.readLastJoinAttempt(), 42)
    }
}
