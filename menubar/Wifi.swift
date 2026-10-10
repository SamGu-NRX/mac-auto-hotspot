import Foundation
import CoreLocation
import CoreWLAN
import UserNotifications

// The shared contract paths, the runtime config parser, the agent.status
// writer, the single-flight lock, the cooldown stamp, the shared log, the
// join-result vocabulary, and the controller decision logic live in the
// portable HotspotCore package (core/) and are compiled directly into this
// target. This file keeps only the macOS glue — CoreWLAN, CoreLocation,
// UserNotifications, and the curl/ipconfig probes — bound to HotspotCore
// through SystemEffects (see below).

// MARK: - Shelling out
//
// Same pattern as AutoHotspot.swift's `run(_:)`, but for absolute-path
// system tools the watcher needs directly (curl, ipconfig) rather than
// hotspotd.

@discardableResult
func runTool(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Reachability + join verification
//
// Permission-free on purpose: no networksetup exit-code trust (it's
// worthless — see libexec/auto-hotspot-check.sh), no SSID read required.
// Bound to the Wi-Fi interface via curl --interface so the probe reflects
// that interface's route, not whichever interface currently owns default.
// These raw implementations are exposed to HotspotCore's Controller
// through SystemEffects (probeOnline(interface:) /
// currentRouter(interface:)); the verifyJoin decision itself lives in
// HotspotCore.

/// The raw reachability probe: curl bound to the given interface plus the
/// captive-portal check.
func probeOnlineWithCurl(interface: String) -> Bool {
    let (_, out) = runTool("/usr/bin/curl", ["-sS", "-m", "4", "--interface", interface,
                                              "http://captive.apple.com/hotspot-detect.html"])
    return out.contains("<TITLE>Success</TITLE>")
}

/// The raw DHCP router read (ipconfig getoption).
func currentRouterViaIpconfig(interface: String) -> String {
    let (_, out) = runTool("/usr/sbin/ipconfig", ["getoption", interface, "router"])
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Offline notification
//
// Gated by the NOTIFY config key; Watcher is responsible for firing this at
// most once per offline episode (it resets the flag as soon as a check
// finds itself back online).

func requestNotificationAuthorizationIfNeeded() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        guard settings.authorizationStatus == .notDetermined else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                wifiLog("warn", "notification authorization request failed: \(error.localizedDescription)")
            } else {
                wifiLog("info", "notification authorization requested, granted=\(granted)")
            }
        }
    }
}

/// Notification copy is picked from the *actual* failure (`result`) and
/// whether Location is authorized, rather than always blaming the phone.
/// The phone-idle case (`.notFound` with Location authorized) is the one
/// scenario this app genuinely cannot resolve itself: turning on the
/// phone's Personal Hotspot from an idle state is only exposed through the
/// Mac's Wi-Fi menu (Instant Hotspot), a private mechanism, and
/// UI-scripting that menu is explicitly out of scope for this app — so
/// that case still asks the user to do it by hand, but says so accurately
/// instead of implying the app tried and failed to flip a phone-side
/// setting it never touched.
func postOfflineNotification(ssid: String, result: JoinResult, locationAuthorized: Bool) {
    let content = UNMutableNotificationContent()
    content.title = "Offline"
    if !locationAuthorized {
        content.body = "Location Services access is needed to see nearby Wi-Fi networks. Grant it in System Settings \u{203A} Privacy & Security \u{203A} Location Services."
    } else {
        switch result {
        case .notFound:
            content.body = "\(ssid) isn\u{2019}t broadcasting. Open the Wi-Fi menu and select it under Personal Hotspots to turn it on."
        case .wifiOff:
            content.body = "Wi-Fi is off and couldn\u{2019}t be turned back on automatically."
        case .interfaceError:
            content.body = "No Wi-Fi interface is available \u{2014} check the Wi-Fi hardware."
        case .authFailed:
            content.body = "Couldn\u{2019}t authenticate to \(ssid). Join it once manually to refresh the saved password."
        case .verificationFailed:
            content.body = "Joined \(ssid) but it isn\u{2019}t providing internet \u{2014} check the phone\u{2019}s cellular connection."
        case .alreadyJoined:
            content.body = "Associated to \(ssid) but not getting internet. Forcing a fresh rejoin."
        case .success:
            content.body = "Joined \(ssid) but it isn\u{2019}t providing internet yet."
        }
    }
    content.sound = .default
    let request = UNNotificationRequest(identifier: "com.andrewwang.autohotspot.offline",
                                         content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
        if let error = error {
            wifiLog("error", "postOfflineNotification: \(error.localizedDescription)")
        }
    }
}

// MARK: - Target SSID
//
// U+2019 RIGHT SINGLE QUOTATION MARK, encoded as a raw unicode scalar so no
// editor/shell normalizes it to ASCII '. See the matching literals (with
// this same comment) in bin/hotspotd and libexec/auto-hotspot-check.sh.

func targetSSID() -> String {
    let fallback = "Andrew\u{2019}s iPhone"
    guard let contents = try? String(contentsOfFile: WifiPaths.configPath, encoding: .utf8) else {
        return fallback
    }
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        guard line.hasPrefix("SSID=") else { continue }
        var value = String(line.dropFirst("SSID=".count))
        value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        if !value.isEmpty { return value }
    }
    return fallback
}

// MARK: - System effects
//
// The concrete ControllerEffects implementation: binds HotspotCore's
// dependency-free Controller to the real facilities — CoreWLAN through
// WifiEngine, the curl/ipconfig probes above, the shared state files
// (StateStore), the shared log, and user notifications.

final class SystemEffects: ControllerEffects {
    static let shared = SystemEffects()
    private init() {}

    func now() -> Double {
        Date().timeIntervalSince1970
    }

    func currentSSID() -> String {
        CWWiFiClient.shared().interface()?.ssid() ?? ""
    }

    func locationAuthorized() -> Bool {
        WifiEngine.shared.isLocationAuthorized()
    }

    func probeOnline(interface: String) -> Bool {
        probeOnlineWithCurl(interface: interface)
    }

    func currentRouter(interface: String) -> String {
        currentRouterViaIpconfig(interface: interface)
    }

    func ensureWifiPowerOn() -> Bool {
        WifiEngine.shared.ensureWifiPowerOn()
    }

    func join(ssid: String, forceRejoin: Bool) -> JoinResult {
        WifiEngine.shared.join(ssid: ssid, forceRejoin: forceRejoin)
    }

    func settle(seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func acquireLock() -> Bool {
        StateStore.acquireLock()
    }

    func releaseLock() {
        StateStore.releaseLock()
    }

    func readLastJoinAttempt() -> TimeInterval? {
        StateStore.readLastJoinAttempt()
    }

    func writeLastJoinAttempt(at time: TimeInterval) {
        StateStore.writeLastJoinAttempt(at: time)
    }

    func clearLastJoinAttempt() {
        StateStore.clearLastJoinAttempt()
    }

    func writeAgentStatus(watcherRunning: Bool, locationAuthorized: Bool,
                          ssidCurrent: String, lastJoinResult: String) {
        writeAgentStatusFile(watcherRunning: watcherRunning,
                             locationAuthorized: locationAuthorized,
                             ssidCurrent: ssidCurrent,
                             lastJoinResult: lastJoinResult)
    }

    func log(_ level: String, _ message: String) {
        wifiLog(level, message)
    }

    func notifyOffline(ssid: String, result: JoinResult, locationAuthorized: Bool) {
        postOfflineNotification(ssid: ssid, result: result, locationAuthorized: locationAuthorized)
    }
}

// MARK: - Location authorization
//
// A CLLocationManager whose delegate is not retained never calls back — both
// the manager and the delegate are held here for the app's lifetime.

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        wifiLog("info", "location authorization changed: \(WifiEngine.shared.authorizationSummary())")
    }
}

// MARK: - Join engine

final class WifiEngine {
    static let shared = WifiEngine()

    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationDelegate()

    private init() {
        locationManager.delegate = locationDelegate
    }

    /// Kicks off the Location Services prompt if we've never asked. Safe to
    /// call repeatedly; only fires the system prompt once per install.
    func requestLocationIfNeeded() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            wifiLog("info", "requesting location authorization")
            locationManager.requestWhenInUseAuthorization()
        } else {
            wifiLog("info", "location authorization already \(authorizationSummary())")
        }
    }

    // CLAuthorizationStatus.authorizedWhenInUse is declared unavailable on
    // macOS (the SDK marks it @available(macOS, unavailable)) — macOS's
    // location model doesn't distinguish when-in-use from always the way
    // iOS does, so requestWhenInUseAuthorization() here still resolves to
    // .authorizedAlways. Handled generically via rawValue so this keeps
    // compiling (and keeps working) if that ever changes.
    func authorizationSummary() -> String {
        switch locationManager.authorizationStatus {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        default:
            // rawValue 3 is CLAuthorizationStatus.authorizedWhenInUse on
            // platforms where the case is available.
            if locationManager.authorizationStatus.rawValue == 3 { return "authorizedWhenInUse" }
            return "unknown"
        }
    }

    func isLocationAuthorized() -> Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedAlways || status.rawValue == 3
    }

    /// SSIDs from the interface's configured (preferred) network list.
    /// VERIFIED to return real SSIDs (58 on the dev machine, including the
    /// target with its U+2019 intact) WITHOUT any Location grant — this is
    /// the reliable way to confirm the target is a known network even when
    /// Location is denied or not yet requested.
    func savedProfileSSIDs() -> [String] {
        guard let interface = CWWiFiClient.shared().interface() else {
            wifiLog("error", "savedProfileSSIDs: no CWInterface")
            return []
        }
        guard let profiles = interface.configuration()?.networkProfiles else {
            wifiLog("warn", "savedProfileSSIDs: no networkProfiles")
            return []
        }
        var ssids: [String] = []
        for case let profile as CWNetworkProfile in profiles {
            if let ssid = profile.ssid { ssids.append(ssid) }
        }
        return ssids
    }

    /// Loose-matches SSIDs across the U+2019/U+2018/U+02BC-vs-ASCII-apostrophe
    /// footgun: lowercases and folds all three quote-like code points to a
    /// plain `'`. Used only for near-miss *detection* in logging — never for
    /// the actual join decision, which stays an exact string match.
    private func looseSSIDKey(_ ssid: String) -> String {
        var folded = ssid.lowercased()
        for quote in ["\u{2019}", "\u{2018}", "\u{02BC}"] {
            folded = folded.replacingOccurrences(of: quote, with: "'")
        }
        return folded
    }

    /// Targeted scan for one SSID; on an empty result, falls back to a full
    /// sweep filtered by name. This is the only code path in the repo that
    /// can see SSIDs on macOS 26 (requires Location authorization).
    ///
    /// `verbose` controls whether a full sweep's diagnostics are written to
    /// the log: `join(ssid:forceRejoin:)` passes `true` so a failed join is
    /// self-explanatory from the log alone, while the startup gate's own
    /// scan (which doesn't call this at all) and any other routine polling
    /// stay count-only so the user's network neighbourhood isn't written to
    /// disk on every background cycle.
    func scanFor(ssid: String, verbose: Bool = false) -> [CWNetwork] {
        guard let interface = CWWiFiClient.shared().interface() else {
            wifiLog("error", "scanFor(\(ssid)): no CWInterface")
            return []
        }

        do {
            let targeted = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
            if !targeted.isEmpty {
                wifiLog("info", "scanFor(\(ssid)): targeted scan found \(targeted.count)")
                return Array(targeted)
            }
            wifiLog("info", "scanFor(\(ssid)): targeted scan found 0, falling back to sweep")
        } catch {
            wifiLog("warn", "scanFor(\(ssid)): targeted scan failed: \(error.localizedDescription)")
        }

        do {
            let all = try interface.scanForNetworks(withSSID: nil)
            let matches = all.filter { $0.ssid == ssid }
            wifiLog("info", "scanFor(\(ssid)): sweep found \(all.count) total, \(matches.count) matching")

            if verbose {
                let seen = all.compactMap { $0.ssid }.filter { !$0.isEmpty }
                let deduped = Array(Set(seen)).sorted()
                let joined = deduped.joined(separator: ", ")
                if joined.count > 1200 {
                    // Truncate at a whole-item boundary so the "+K more"
                    // count is exact, rather than cutting mid-SSID.
                    var kept: [String] = []
                    var length = 0
                    for item in deduped {
                        let addedLength = length == 0 ? item.count : length + 2 + item.count
                        if addedLength > 1200 { break }
                        kept.append(item)
                        length = addedLength
                    }
                    let truncated = kept.joined(separator: ", ")
                    let more = deduped.count - kept.count
                    wifiLog("info", "scanFor(\(ssid)): sweep saw: \(truncated)…(+\(more) more)")
                } else {
                    wifiLog("info", "scanFor(\(ssid)): sweep saw: \(joined)")
                }

                let targetKey = looseSSIDKey(ssid)
                for candidate in deduped where candidate != ssid {
                    if looseSSIDKey(candidate) == targetKey {
                        wifiLog("warn", "scanFor(\(ssid)): near-miss \"\(candidate)\" loose-matches target but is not an exact match (apostrophe/quote variant?)")
                    }
                }

                if matches.isEmpty {
                    let hex = ssid.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
                    wifiLog("info", "scanFor(\(ssid)): target SSID UTF-8 bytes: \(hex)")
                }
            }

            return Array(matches)
        } catch {
            wifiLog("error", "scanFor(\(ssid)): sweep failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Checks Wi-Fi power and, if it's off, turns it back on — mirroring the
    /// shell fallback's power-cycle recovery (auto-hotspot-check.sh's power
    /// section). Without this the primary event-driven watcher had no way to
    /// recover from a radio left off by sleep/wake or anything else.
    @discardableResult
    func ensureWifiPowerOn() -> Bool {
        guard let interface = CWWiFiClient.shared().interface() else {
            wifiLog("error", "ensureWifiPowerOn: no CWInterface")
            return false
        }
        if interface.powerOn() {
            return true
        }
        wifiLog("warn", "ensureWifiPowerOn: Wi-Fi is off, turning on")
        do {
            try interface.setPower(true)
        } catch {
            wifiLog("error", "ensureWifiPowerOn: setPower(true) failed: \(error.localizedDescription)")
            return false
        }
        Thread.sleep(forTimeInterval: 1)
        let nowOn = interface.powerOn()
        if !nowOn {
            wifiLog("error", "ensureWifiPowerOn: still off after setPower(true)")
        }
        return nowOn
    }

    /// Associates to `ssid` with a nil password (the PSK is already in the
    /// keychain for a preferred network). Verification of a *real* successful
    /// join (router fingerprint + reachability) is the caller's job — this
    /// only reports whether CoreWLAN's own association call and post-check
    /// succeeded, unlike `networksetup`, whose exit code is worthless.
    ///
    /// `forceRejoin` skips the alreadyJoined shortcut and disassociates
    /// first: without it, a stale/dead association (associated to `ssid`
    /// but not actually passing traffic) would report `.alreadyJoined`
    /// forever with no way to escape the loop once `verifyJoin` starts
    /// failing against it. The caller is responsible for setting this once
    /// it has seen exactly that pattern.
    func join(ssid: String, forceRejoin: Bool = false) -> JoinResult {
        guard let interface = CWWiFiClient.shared().interface() else {
            wifiLog("error", "join(\(ssid)): no CWInterface")
            return .interfaceError
        }

        if forceRejoin && interface.ssid() == ssid {
            wifiLog("info", "join(\(ssid)): forcing disassociate before rejoin (stale association)")
            interface.disassociate()
        } else if interface.ssid() == ssid {
            wifiLog("info", "join(\(ssid)): already associated")
            return .alreadyJoined
        }

        let candidates = scanFor(ssid: ssid, verbose: true)
        guard let network = candidates.first else {
            wifiLog("warn", "join(\(ssid)): not found in scan")
            return .notFound
        }

        do {
            try interface.associate(to: network, password: nil)
            if interface.ssid() == ssid {
                wifiLog("info", "join(\(ssid)): associated successfully")
                return .success
            }
            wifiLog("warn", "join(\(ssid)): associate returned but current ssid is \(interface.ssid() ?? "nil")")
            return .verificationFailed
        } catch {
            wifiLog("error", "join(\(ssid)): associate failed: \(error.localizedDescription)")
            return .authFailed
        }
    }

    /// GATE: the first thing the engine logs on startup. Confirms whether
    /// the CoreWLAN join path is viable on this machine before anything is
    /// built on top of it — see the item-3 plan note for what to do if the
    /// named count is still 0 once Location is granted.
    func runStartupGate() {
        requestLocationIfNeeded()
        let locationStatus = authorizationSummary()

        var totalNetworks = 0
        var namedNetworks = 0
        var currentSSID = ""

        if let interface = CWWiFiClient.shared().interface() {
            currentSSID = interface.ssid() ?? ""
            do {
                let scanned = try interface.scanForNetworks(withSSID: nil)
                totalNetworks = scanned.count
                namedNetworks = scanned.filter { !($0.ssid ?? "").isEmpty }.count
            } catch {
                wifiLog("warn", "startup scan failed: \(error.localizedDescription)")
            }
        } else {
            wifiLog("error", "startup: no CWInterface available")
        }

        wifiLog("info", "scan: \(totalNetworks) networks, \(namedNetworks) named, location=\(locationStatus)")

        let profiles = savedProfileSSIDs()
        let target = targetSSID()
        let present = profiles.contains(target) ? "yes" : "no"
        wifiLog("info", "profiles: \(profiles.count) saved, target present=\(present)")

        writeAgentStatusFile(
            watcherRunning: true,
            locationAuthorized: isLocationAuthorized(),
            ssidCurrent: currentSSID,
            lastJoinResult: "none"
        )
    }
}
