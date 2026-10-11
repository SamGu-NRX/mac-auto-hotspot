import Foundation
import XCTest
@testable import HotspotCore

/// Records every effect the Controller attempts and REFUSES unexpected
/// system calls: any call whose kind (or exact arguments, for the
/// network-touching effects) was not registered up front lands in
/// `refused` and fails the test. Nothing here reaches a real network,
/// radio, clock, or filesystem beyond caller-owned temporary paths — the
/// recorder IS the system.
///
/// Statefulness that mirrors the real files: written join-attempt stamps
/// become readable again (the stamp file persists across cycles), and
/// cleared stamps disappear — so multi-cycle recovery tests behave like the
/// real state dir does.
final class RecordingEffects: ControllerEffects {
    struct Call: Hashable, CustomStringConvertible {
        let name: String
        let detail: String

        init(_ name: String, _ detail: String = "") {
            self.name = name
            self.detail = detail
        }

        var description: String { detail.isEmpty ? name : "\(name) \(detail)" }

        static func join(ssid: String, forceRejoin: Bool) -> Call {
            Call("join", "ssid=\(ssid) forceRejoin=\(forceRejoin)")
        }
        static func probeOnline(interface: String) -> Call {
            Call("probeOnline", "interface=\(interface)")
        }
        static func currentRouter(interface: String) -> Call {
            Call("currentRouter", "interface=\(interface)")
        }
        static func notify(result: JoinResult) -> Call {
            Call("notifyOffline", "result=\(result.rawValue)")
        }
        static func ensureWifiPowerOn() -> Call { Call("ensureWifiPowerOn") }
        static func acquireLock() -> Call { Call("acquireLock") }
        static func releaseLock() -> Call { Call("releaseLock") }
        static func readLastJoinAttempt() -> Call { Call("readLastJoinAttempt") }
        static func writeLastJoinAttempt(at: Int) -> Call { Call("writeLastJoinAttempt", "at=\(at)") }
        static func clearLastJoinAttempt() -> Call { Call("clearLastJoinAttempt") }
        static func settle(seconds: Double) -> Call { Call("settle", "\(seconds)s") }
        static func status(result: String) -> Call { Call("writeAgentStatus", "result=\(result)") }
    }

    private(set) var trace: [Call] = []
    private(set) var refused: [Call] = []

    /// Effect kinds the test deems expected, by bare name (mechanical calls
    /// like `now`, `log`, status writes). Anything not listed here and not
    /// in `allowedCalls` is refused.
    var allowedNames: Set<String> = []
    /// Exact calls (kind + arguments) the test expects, for the
    /// argument-carrying effects: join, probeOnline, currentRouter,
    /// ensureWifiPowerOn, notifyOffline.
    var allowedCalls: Set<Call> = []
    /// Convenience switch the join-related tests set when the test only
    /// cares that a join was attempted (the join's own verification is the
    /// recorder's business, not the real radio's).
    var joinCallsAllowed = false {
        didSet { if joinCallsAllowed { allowedNames.insert("join") } }
    }

    // Stubbed results (and observations for assertions).
    var clock = Clock()
    /// Optional per-interface answer; when set it wins over the sequence and
    /// the static result.
    var probeOnlineHandler: ((String) -> Bool)?
    /// Per-call answers consumed in order — e.g. [false, true] models an
    /// offline first probe and an online verification probe.
    var probeOnlineSequence: [Bool] = []
    var probeOnlineResult = false
    var routerValue = ""
    var powerOnResult = true
    var joinResult: JoinResult = .success
    var lockAcquireResult = true
    var lastJoinStamp: Double?
    var locationAuthorizedValue = true
    var currentSSIDValue = ""

    private(set) var joinCalls: [(ssid: String, forceRejoin: Bool)] = []
    private(set) var probedInterfaces: [String] = []
    private(set) var routerInterfaces: [String] = []
    private(set) var writtenStamps: [Double] = []
    private(set) var clearedStampCount = 0
    private(set) var statusWrites: [(watcherRunning: Bool, locationAuthorized: Bool, ssidCurrent: String, lastJoinResult: String)] = []
    private(set) var logLines: [(level: String, message: String)] = []
    private(set) var notifications: [(ssid: String, result: JoinResult, locationAuthorized: Bool)] = []
    private(set) var settles: [Double] = []

    private func record(_ call: Call, forceAllow: Bool = false) {
        trace.append(call)
        if !forceAllow && !allowedNames.contains(call.name) && !allowedCalls.contains(call) {
            refused.append(call)
        }
    }

    func allowAll(_ names: [String]) {
        allowedNames.formUnion(names)
    }

    func assertNothingRefused(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(refused.isEmpty, "unexpected system calls \(context): \(refused)", file: file, line: line)
    }

    // MARK: - ControllerEffects

    func now() -> Double {
        record(Call("now"))
        return clock.time
    }

    func currentSSID() -> String {
        record(Call("currentSSID"))
        return currentSSIDValue
    }

    func locationAuthorized() -> Bool {
        record(Call("locationAuthorized"))
        return locationAuthorizedValue
    }

    func probeOnline(interface: String) -> Bool {
        record(Call.probeOnline(interface: interface))
        probedInterfaces.append(interface)
        if let handler = probeOnlineHandler { return handler(interface) }
        if !probeOnlineSequence.isEmpty { return probeOnlineSequence.removeFirst() }
        return probeOnlineResult
    }

    func currentRouter(interface: String) -> String {
        record(Call.currentRouter(interface: interface))
        routerInterfaces.append(interface)
        return routerValue
    }

    func ensureWifiPowerOn() -> Bool {
        record(Call.ensureWifiPowerOn())
        return powerOnResult
    }

    func join(ssid: String, forceRejoin: Bool) -> JoinResult {
        record(Call.join(ssid: ssid, forceRejoin: forceRejoin), forceAllow: joinCallsAllowed)
        joinCalls.append((ssid, forceRejoin))
        return joinResult
    }

    func settle(seconds: Double) {
        record(Call.settle(seconds: seconds))
        settles.append(seconds)
    }

    func acquireLock() -> Bool {
        record(Call.acquireLock())
        return lockAcquireResult
    }

    func releaseLock() {
        record(Call.releaseLock())
    }

    func readLastJoinAttempt() -> TimeInterval? {
        record(Call.readLastJoinAttempt())
        return lastJoinStamp
    }

    func writeLastJoinAttempt(at time: TimeInterval) {
        record(Call.writeLastJoinAttempt(at: Int(time)))
        writtenStamps.append(time)
        lastJoinStamp = time
    }

    func clearLastJoinAttempt() {
        record(Call.clearLastJoinAttempt())
        clearedStampCount += 1
        lastJoinStamp = nil
    }

    func writeAgentStatus(watcherRunning: Bool, locationAuthorized: Bool,
                          ssidCurrent: String, lastJoinResult: String) {
        record(Call.status(result: lastJoinResult))
        statusWrites.append((watcherRunning, locationAuthorized, ssidCurrent, lastJoinResult))
    }

    func log(_ level: String, _ message: String) {
        record(Call("log", "[\(level)]"))
        logLines.append((level, message))
    }

    func notifyOffline(ssid: String, result: JoinResult, locationAuthorized: Bool) {
        record(Call.notify(result: result))
        notifications.append((ssid, result, locationAuthorized))
    }
}

extension RecordingEffects {
    /// A recorder pre-loaded with every effect a legitimate evaluate run
    /// performs; join stays refused until the test flips joinCallsAllowed,
    /// and per-scenario emptiness is asserted directly (the disabled and
    /// lock-busy cases assert no probe ran at all).
    static func controller() -> RecordingEffects {
        let effects = RecordingEffects()
        effects.allowAll([
            "now", "log", "currentSSID", "locationAuthorized", "writeAgentStatus",
            "acquireLock", "releaseLock", "readLastJoinAttempt",
            "writeLastJoinAttempt", "clearLastJoinAttempt", "settle",
            // The remaining legitimate evaluate surface; the join effect
            // stays strict via joinCallsAllowed.
            "probeOnline", "currentRouter", "ensureWifiPowerOn", "notifyOffline",
        ])
        return effects
    }
}
