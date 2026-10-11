import XCTest
@testable import HotspotCore

/// File-local shorthand for the recorder's call type.
typealias Call = RecordingEffects.Call

/// The controller lifecycle, exercised against the recorder — the same
/// decision tree Watcher.performEvaluation used to implement inline, now
/// replayable end to end: disabled, lock-busy, online, cooldown,
/// wifi-off, join failure, failed verification (router mismatch and probe
/// failure), recovery, and the stale-association force-rejoin.
final class ControllerLifecycleTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = TestEnv.makeHome("lifecycle")
        TestEnv.activate(home: home)
    }

    override func tearDownWithError() throws {
        TestEnv.deactivate()
        try? FileManager.default.removeItem(atPath: home)
        home = nil
    }

    private func writeConfig(_ text: String) throws {
        try TestEnv.writeConfig(text, home: home)
    }

    // MARK: disabled

    func testDisabledConfigSkipsEverythingIncludingTheLock() throws {
        try writeConfig("ENABLED=0\n")
        let effects = RecordingEffects.controller()
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("disabled")
        XCTAssertTrue(effects.logLines.contains { $0.message.contains("disabled, skipping") })
        // Nothing ran: no probe, no lock, no status write, no join.
        XCTAssertTrue(effects.probedInterfaces.isEmpty)
        XCTAssertTrue(effects.joinCalls.isEmpty)
        XCTAssertTrue(effects.statusWrites.isEmpty)
        XCTAssertFalse(effects.trace.contains(Call("acquireLock")))
    }

    func testLockBusySkipsTheCycleAndNeverTakesTheLock() {
        let effects = RecordingEffects.controller()
        effects.lockAcquireResult = false
        let controller = Controller()

        controller.evaluate(reason: "timer", effects: effects)

        effects.assertNothingRefused("lock busy")
        XCTAssertTrue(effects.logLines.contains { $0.message.contains("another check is running, skipping") })
        // The guard fires before the defer registers, so releaseLock never runs.
        XCTAssertFalse(effects.trace.contains(Call.releaseLock()))
        XCTAssertTrue(effects.joinCalls.isEmpty)
        XCTAssertTrue(effects.statusWrites.isEmpty)
    }

    // MARK: online

    func testOnlineClearsCooldownStampAndReportsOnline() {
        let effects = RecordingEffects.controller()
        effects.probeOnlineResult = true
        effects.probeOnlineHandler = { _ in true }
        effects.lastJoinStamp = 123
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("online")
        XCTAssertTrue(effects.logLines.contains { $0.message.contains("online via") })
        XCTAssertEqual(effects.probedInterfaces, ["en0"])
        XCTAssertEqual(effects.clearedStampCount, 1)
        XCTAssertTrue(effects.writtenStamps.isEmpty)
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, "online")
        XCTAssertTrue(effects.joinCalls.isEmpty)
        XCTAssertTrue(effects.notifications.isEmpty)
    }

    func testReachabilityProbeIsBoundToTheConfiguredInterface() throws {
        try writeConfig("WIFI_INTERFACE=en7\n")
        let effects = RecordingEffects.controller()
        effects.probeOnlineResult = true
        effects.probeOnlineHandler = { _ in true }
        let controller = Controller()

        controller.evaluate(reason: "timer", effects: effects)

        effects.assertNothingRefused("interface")
        XCTAssertEqual(effects.probedInterfaces, ["en7"])
    }

    // MARK: cooldown

    func testRecentAttemptWithinCooldownSkipsTheJoinWithoutRewritingTheStamp() {
        let effects = RecordingEffects.controller()
        effects.lastJoinStamp = effects.clock.time
        effects.clock.advance(10) // stamped 10s ago -> 20s of cooldown left
        effects.routerValue = "172.20.10.1"
        effects.probeOnlineHandler = { _ in false }
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("cooldown")
        XCTAssertTrue(effects.logLines.contains { $0.message.contains("offline but in cooldown (20s left), skipping") })
        // The cooldown path must NOT refresh the stamp (that would extend
        // the outage window forever) and must not attempt a join.
        XCTAssertTrue(effects.writtenStamps.isEmpty)
        XCTAssertTrue(effects.joinCalls.isEmpty)
    }

    func testCooldownComesFromTheConfigFile() throws {
        try writeConfig("COOLDOWN=5\n")
        let effects = RecordingEffects.controller()
        effects.lastJoinStamp = effects.clock.time
        effects.clock.advance(10) // stamped 10s ago -> outside a 5s cooldown
        effects.joinResult = .notFound
        effects.joinCallsAllowed = true
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("cooldown expiry")
        XCTAssertEqual(effects.joinCalls.count, 1)
    }

    // MARK: wifi off

    func testWifiOffStampsThenNotifiesOnceAndNeverJoins() {
        let effects = RecordingEffects.controller()
        effects.powerOnResult = false
        let controller = Controller()

        controller.evaluate(reason: "wake", effects: effects)
        controller.evaluate(reason: "wake", effects: effects)

        effects.assertNothingRefused("wifi off")
        // Stamp written before the power check so a crash mid-cycle throttles;
        // the second cycle then lands in cooldown and changes nothing further.
        XCTAssertEqual(effects.writtenStamps, [effects.clock.time])
        XCTAssertTrue(effects.joinCalls.isEmpty)
        XCTAssertEqual(effects.statusWrites.count, 1)
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, JoinResult.wifiOff.rawValue)
        XCTAssertEqual(effects.notifications.count, 1, "one notification per offline episode")
        XCTAssertEqual(effects.notifications.first?.result, .wifiOff)
    }

    func testNotifyDisabledSuppressesTheNotificationButNotTheStatus() throws {
        try writeConfig("NOTIFY=0\n")
        let effects = RecordingEffects.controller()
        effects.powerOnResult = false
        let controller = Controller()

        controller.evaluate(reason: "wake", effects: effects)

        effects.assertNothingRefused("notify disabled")
        XCTAssertTrue(effects.notifications.isEmpty)
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, JoinResult.wifiOff.rawValue)
    }

    // MARK: join failure

    func testJoinFailureStampsFirstThenReportsWithoutVerification() {
        let effects = RecordingEffects.controller()
        effects.joinResult = .notFound
        effects.joinCallsAllowed = true
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("join failure")
        XCTAssertEqual(effects.joinCalls.map { "\($0.ssid)|forceRejoin=\($0.forceRejoin)" },
                       ["Andrew\u{2019}s iPhone|forceRejoin=false"])
        // Settle + verify only run for success/alreadyJoined.
        XCTAssertTrue(effects.settles.isEmpty)
        XCTAssertTrue(effects.routerInterfaces.isEmpty)
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, JoinResult.notFound.rawValue)
        XCTAssertEqual(effects.notifications.count, 1)
        // The stamp is retained (written before the join, never cleared), so
        // the next cycle is cooldown-throttled.
        XCTAssertEqual(effects.clearedStampCount, 0)
    }

    func testStampIsWrittenBeforeTheJoinAttempt() {
        let effects = RecordingEffects.controller()
        effects.joinResult = .notFound
        effects.joinCallsAllowed = true
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        let stampIndex = effects.trace.firstIndex { $0.name == "writeLastJoinAttempt" }
        let joinIndex = effects.trace.firstIndex { $0.name == "join" }
        XCTAssertNotNil(stampIndex)
        XCTAssertNotNil(joinIndex)
        XCTAssertLessThan(stampIndex!, joinIndex!, "stamp must precede the join attempt")
    }

    // MARK: verification

    func testSuccessfulJoinRequiresRouterFingerprintAndReachability() {
        let effects = RecordingEffects.controller()
        effects.probeOnlineSequence = [false, true] // offline, then verification online
        effects.routerValue = "172.20.10.1"
        effects.joinCallsAllowed = true
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("verified success")
        XCTAssertEqual(effects.settles, [3])
        XCTAssertEqual(effects.routerInterfaces, ["en0"])
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, "success")
        XCTAssertEqual(effects.clearedStampCount, 1)
        XCTAssertTrue(effects.notifications.isEmpty)
        XCTAssertTrue(effects.logLines.contains { $0.message.contains("and verified online") })
    }

    func testRouterMismatchFailsVerificationWithoutProbingReachability() {
        let effects = RecordingEffects.controller()
        effects.probeOnlineHandler = { _ in false }
        effects.routerValue = "192.168.1.1" // wrong router (not tethering)
        effects.joinCallsAllowed = true
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("router mismatch")
        XCTAssertTrue(effects.logLines.contains { $0.message.contains("verifyJoin: router is 192.168.1.1, expected 172.20.10.1") })
        // Router guard short-circuits: no reachability probe during verify.
        XCTAssertEqual(effects.probedInterfaces, ["en0"], "only the initial offline probe")
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, JoinResult.success.rawValue)
        XCTAssertEqual(effects.notifications.count, 1)
    }

    func testReachabilityProbeOnWrongInterfaceFailsVerification() {
        let effects = RecordingEffects.controller()
        effects.probeOnlineHandler = { interface in interface != "en0" } // only en7 is "online"
        effects.routerValue = "172.20.10.1"
        effects.joinCallsAllowed = true
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        effects.assertNothingRefused("interface-bound verification")
        XCTAssertEqual(effects.probedInterfaces, ["en0", "en0"])
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, JoinResult.success.rawValue)
        XCTAssertEqual(effects.notifications.count, 1)
    }

    // MARK: recovery + stale association

    func testFailedVerificationIsCooldownThrottledThenRecoversOnANextCycle() {
        let effects = RecordingEffects.controller()
        effects.routerValue = "" // verification fails on the first cycle
        effects.joinCallsAllowed = true
        let controller = Controller()

        // Cycle 1: join reports success but verification fails.
        controller.evaluate(reason: "path", effects: effects)
        XCTAssertEqual(effects.joinCalls.count, 1)
        XCTAssertEqual(effects.clearedStampCount, 0)
        XCTAssertEqual(effects.notifications.count, 1)

        // Cycle 2, 10s later: still inside the 30s cooldown -> no second join.
        effects.clock.advance(10)
        controller.evaluate(reason: "timer", effects: effects)
        XCTAssertEqual(effects.joinCalls.count, 1, "cooldown must suppress the immediate retry")
        XCTAssertEqual(effects.logLines.last?.message.contains("in cooldown"), true)

        // Cycle 3, 60s later: cooldown expired -> rejoin, verify, clear.
        // Gate probe: still offline; verification probe: online.
        effects.clock.advance(50)
        effects.routerValue = "172.20.10.1"
        effects.probeOnlineSequence = [false, true]
        controller.evaluate(reason: "timer", effects: effects)
        XCTAssertEqual(effects.joinCalls.count, 2)
        XCTAssertEqual(effects.clearedStampCount, 1)
        XCTAssertEqual(effects.statusWrites.last?.lastJoinResult, "success")
    }

    func testAlreadyJoinedButUnverifiedForcesARealRejoinNextCycle() {
        let effects = RecordingEffects.controller()
        effects.joinResult = .alreadyJoined
        effects.routerValue = "" // verification fails
        effects.joinCallsAllowed = true
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)
        XCTAssertTrue(controller.forceRejoinNext, "stale association must force a rejoin")

        // Expire the cooldown, then observe the forced rejoin. The gate
        // probe still reports offline (that's why a rejoin is warranted);
        // the verification probe after the join reports online.
        effects.clock.advance(60)
        effects.joinResult = .success
        effects.routerValue = "172.20.10.1"
        effects.probeOnlineSequence = [false, true]
        controller.evaluate(reason: "timer", effects: effects)

        XCTAssertEqual(effects.joinCalls.count, 2)
        XCTAssertEqual(effects.joinCalls[0].forceRejoin, false)
        XCTAssertEqual(effects.joinCalls[1].forceRejoin, true, "second cycle must disassociate and rejoin")
        XCTAssertFalse(controller.forceRejoinNext, "a verified join clears the forced-rejoin latch")
    }

    func testLocationUnauthorizedIsRecordedInTheStatusWrite() {
        let effects = RecordingEffects.controller()
        effects.probeOnlineResult = true
        effects.probeOnlineHandler = { _ in true }
        effects.locationAuthorizedValue = false
        let controller = Controller()

        controller.evaluate(reason: "path", effects: effects)

        XCTAssertEqual(effects.statusWrites.last?.locationAuthorized, false)
    }
}
