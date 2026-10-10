import Foundation

// MARK: - Effect interface
//
// The dependency-free decision logic needs to reach a handful of system
// facilities: the clock, the reachability probe, the DHCP router read, the
// Wi-Fi radio and join engine, the shared state files, the log, the
// agent.status file, and user notifications. Everything concrete (CoreWLAN,
// CoreLocation, UserNotifications, and the reachability and DHCP router
// probes) stays behind this
// protocol so the decision logic itself is portable and testable with a
// recorder that refuses unexpected calls — and so the core can never touch
// a real network, radio, or framework by accident.

public protocol ControllerEffects {
    /// Wall clock, epoch seconds. (Fake time in tests.)
    func now() -> Double
    /// The SSID the interface is currently associated to, or "" when unknown.
    func currentSSID() -> String
    /// Whether Location Services grants this process SSID visibility.
    func locationAuthorized() -> Bool
    /// Reachability probe bound to the given interface (curl --interface +
    /// the captive-portal check). "Some interface is online" is not good
    /// enough — see libexec/auto-hotspot-check.sh.
    func probeOnline(interface: String) -> Bool
    /// The interface's DHCP router, or "" when undeterminable.
    func currentRouter(interface: String) -> String
    /// Checks Wi-Fi power and, if off, turns it back on. Reports whether the
    /// radio ended up on. (Never called during a test run.)
    func ensureWifiPowerOn() -> Bool
    /// Attempts to associate with the target SSID. `forceRejoin` skips the
    /// alreadyJoined shortcut and disassociates first (stale-association
    /// recovery). The implementation verifies CoreWLAN's own call; the
    /// caller verifies the join against router + reachability.
    func join(ssid: String, forceRejoin: Bool) -> JoinResult
    /// Recorded wait (the DHCP settle pause). Must not actually sleep in tests.
    func settle(seconds: Double)
    /// Single-flight lock, shared with the shell fallback.
    func acquireLock() -> Bool
    func releaseLock()
    func readLastJoinAttempt() -> TimeInterval?
    func writeLastJoinAttempt(at time: TimeInterval)
    func clearLastJoinAttempt()
    /// Atomic publication of the agent's own status JSON.
    func writeAgentStatus(watcherRunning: Bool, locationAuthorized: Bool,
                          ssidCurrent: String, lastJoinResult: String)
    /// Shared log ("[ts] [level] msg", same file as the shell fallback).
    func log(_ level: String, _ message: String)
    /// The once-per-offline-episode user notification.
    func notifyOffline(ssid: String, result: JoinResult, locationAuthorized: Bool)
}

// MARK: - Join verification
//
// A join only counts once the DHCP router fingerprint matches the iOS
// tethering gateway AND the reachability probe succeeds — either alone can
// be a false positive (e.g. a stale lease, or a captive portal answering
// on a different interface). Permission-free on purpose.

public func verifyJoin(config: RuntimeConfig, effects: ControllerEffects) -> Bool {
    let router = effects.currentRouter(interface: config.interface)
    guard router == config.hotspotRouter else {
        effects.log("warn", "verifyJoin: router is \(router.isEmpty ? "(none)" : router), expected \(config.hotspotRouter)")
        return false
    }
    return effects.probeOnline(interface: config.interface)
}

// MARK: - Controller
//
// The event-driven agent's decision core. This is the whole contract:
// config invalid -> refuse before any effect; disabled -> skip; lock busy ->
// skip; online -> clear the cooldown stamp; offline within cooldown -> log
// and skip; otherwise stamp, restore the radio, attempt the join, and
// verify it against the router fingerprint plus the interface-bound
// reachability probe. One notification per offline episode, and a stale
// association (alreadyJoined but unverified) forces a disassociate+rejoin
// on the next cycle instead of looping forever.
//
// State (`forceRejoinNext`, `offlineEpisodeNotified`) lives here so the
// Watcher stays a thin dispatcher: its four event sources (the path
// monitor,
// wake notifications, the safety-net timer, the trigger file) debounce onto
// one serial queue and call `evaluate`.

public final class Controller {
    /// Set when a cycle sees .alreadyJoined but then fails verification —
    /// the next join() call forces a disassociate+rejoin instead of
    /// repeating the identical alreadyJoined->verify-fail loop forever.
    public private(set) var forceRejoinNext = false
    private var offlineEpisodeNotified = false

    public init() {}

    public func evaluate(reason: String, effects: ControllerEffects) {
        let config = loadRuntimeConfig()

        guard config.enabled else {
            effects.log("info", "evaluate (\(reason)): disabled, skipping")
            return
        }

        guard effects.acquireLock() else {
            effects.log("warn", "evaluate (\(reason)): another check is running, skipping")
            return
        }
        defer { effects.releaseLock() }

        let ssidNow = effects.currentSSID()
        let locationAuthorized = effects.locationAuthorized()

        if effects.probeOnline(interface: config.interface) {
            effects.log("info", "evaluate (\(reason)): online via \(ssidNow.isEmpty ? "other/none" : ssidNow)")
            effects.clearLastJoinAttempt()
            offlineEpisodeNotified = false
            effects.writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: ssidNow, lastJoinResult: "online")
            return
        }

        if let last = effects.readLastJoinAttempt() {
            let elapsed = effects.now() - last
            if elapsed < Double(config.cooldown) {
                let remaining = Int(Double(config.cooldown) - elapsed)
                effects.log("info", "evaluate (\(reason)): offline but in cooldown (\(remaining)s left), skipping")
                return
            }
        }

        // Stamp BEFORE attempting the join so a crash mid-attempt still throttles.
        effects.writeLastJoinAttempt(at: effects.now())

        // Restore Wi-Fi power before touching anything else: a radio left
        // off (e.g. by sleep/wake) makes scanning and association fail in a
        // way indistinguishable from "hotspot not found" unless this is
        // checked first. Mirrors the shell fallback's power-cycle recovery.
        guard effects.ensureWifiPowerOn() else {
            effects.log("error", "evaluate (\(reason)): Wi-Fi is off and could not be turned back on")
            effects.writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: ssidNow, lastJoinResult: JoinResult.wifiOff.rawValue)
            if config.notify && !offlineEpisodeNotified {
                offlineEpisodeNotified = true
                effects.notifyOffline(ssid: config.ssid, result: .wifiOff, locationAuthorized: locationAuthorized)
            }
            return
        }

        effects.log("info", "evaluate (\(reason)): offline, attempting join to \(config.ssid)")
        let result = effects.join(ssid: config.ssid, forceRejoin: forceRejoinNext)
        forceRejoinNext = false

        var verified = false
        if result == .success || result == .alreadyJoined {
            // Give DHCP a moment to hand out a lease before checking the
            // router fingerprint, matching the shell worker's settle time.
            effects.settle(seconds: 3)
            verified = verifyJoin(config: config, effects: effects)
        }

        if verified {
            effects.log("info", "evaluate (\(reason)): joined \u{201C}\(config.ssid)\u{201D} and verified online")
            effects.clearLastJoinAttempt()
            offlineEpisodeNotified = false
            effects.writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: config.ssid, lastJoinResult: "success")
        } else {
            if result == .alreadyJoined {
                // Stale association: verifyJoin failed against an SSID we
                // were already on. Force a real disassociate+rescan+rejoin
                // next cycle instead of reporting the same alreadyJoined
                // shortcut and looping forever.
                forceRejoinNext = true
            }
            effects.log("error", "evaluate (\(reason)): join failed or unverified (result=\(result.rawValue))")
            effects.writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: ssidNow, lastJoinResult: result.rawValue)
            if config.notify && !offlineEpisodeNotified {
                offlineEpisodeNotified = true
                effects.notifyOffline(ssid: config.ssid, result: result, locationAuthorized: locationAuthorized)
            }
        }
    }
}
