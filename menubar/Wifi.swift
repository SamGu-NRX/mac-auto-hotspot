import Foundation
import CoreLocation
import CoreWLAN
import UserNotifications

// MARK: - Shared contract paths (see CLAUDE.md "shared contract")
//
// These mirror bin/hotspotd and libexec/auto-hotspot-check.sh. Every value
// here has an env override so tests never touch the real install.

enum WifiPaths {
    static var logPath: String {
        ProcessInfo.processInfo.environment["AUTO_HOTSPOT_LOG"]
            ?? (NSHomeDirectory() + "/Library/Logs/auto-hotspot.log")
    }

    static var stateDir: String {
        ProcessInfo.processInfo.environment["AUTO_HOTSPOT_STATE"]
            ?? (NSHomeDirectory() + "/.local/state/auto-hotspot")
    }

    static var configPath: String {
        ProcessInfo.processInfo.environment["AUTO_HOTSPOT_CONFIG"]
            ?? (NSHomeDirectory() + "/.config/auto-hotspot/config")
    }

    static var agentStatusPath: String { stateDir + "/agent.status" }
    static var triggerPath: String { stateDir + "/trigger" }
    static var lockPath: String { stateDir + "/lock" }
    static var lastJoinAttemptPath: String { stateDir + "/last-join-attempt" }
    static var failbackAttemptPath: String { stateDir + "/failback-attempt" }
    static var failbackBackoffPath: String { stateDir + "/failback-backoff" }
}

// MARK: - Runtime config
//
// Mirrors bin/hotspotd's load_config / libexec/auto-hotspot-check.sh's config
// sourcing: same defaults, same keys. Reloaded from disk on every evaluation
// (see Watcher.performEvaluation in AutoHotspot.swift) so editing the config
// file takes effect without a reinstall or restart.

struct RuntimeConfig {
    var ssid: String
    var checkInterval: Int
    var enabled: Bool
    var cooldown: Int
    var interface: String
    var hotspotRouter: String
    var notify: Bool
    /// Consecutive failed probes required before leaving Wi-Fi for the
    /// hotspot. Upstream failed over on a single 4s-timeout probe, which a
    /// congested-but-working campus network trips routinely.
    var failoverStrikes: Int
    /// Seconds between those probes.
    var strikeInterval: Int
    /// Whether to return to Wi-Fi once it works again. Upstream had no
    /// failback at all: once on the hotspot the probe succeeds *through* the
    /// hotspot, so nothing ever moves you back.
    var failback: Bool
    /// Minimum seconds between failback attempts, and the base of the
    /// exponential backoff applied after each failed one.
    var failbackInterval: Int
    /// Ceiling for that backoff.
    var failbackBackoffMax: Int
    /// Seconds to wait for association + DHCP after leaving the hotspot.
    /// 802.1X (eduroam/utexas) needs an EAP+RADIUS handshake, so this is
    /// deliberately longer than the 3s the hotspot join settles for.
    var failbackSettle: Int
    /// Candidate networks weaker than this are not worth dropping a working
    /// hotspot for.
    var failbackMinRSSI: Int
}

private func unquoteConfigValue(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if value.count >= 2, let first = value.first, let last = value.last,
       (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        value = String(value.dropFirst().dropLast())
    }
    return value
}

func loadRuntimeConfig() -> RuntimeConfig {
    var config = RuntimeConfig(
        ssid: "Sam Gu\u{2019}s iPhone",
        checkInterval: 300,
        enabled: true,
        cooldown: 30,
        interface: "en0",
        hotspotRouter: "172.20.10.1",
        notify: true,
        failoverStrikes: 3,
        strikeInterval: 5,
        failback: true,
        failbackInterval: 180,
        failbackBackoffMax: 1200,
        failbackSettle: 12,
        failbackMinRSSI: -75
    )

    guard let contents = try? String(contentsOfFile: WifiPaths.configPath, encoding: .utf8) else {
        return config
    }

    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix("SSID=") {
            let v = unquoteConfigValue(String(line.dropFirst("SSID=".count)))
            if !v.isEmpty { config.ssid = v }
        } else if line.hasPrefix("CHECK_INTERVAL=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("CHECK_INTERVAL=".count)))) { config.checkInterval = n }
        } else if line.hasPrefix("ENABLED=") {
            config.enabled = unquoteConfigValue(String(line.dropFirst("ENABLED=".count))) == "1"
        } else if line.hasPrefix("COOLDOWN=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("COOLDOWN=".count)))) { config.cooldown = n }
        } else if line.hasPrefix("WIFI_INTERFACE=") {
            let v = unquoteConfigValue(String(line.dropFirst("WIFI_INTERFACE=".count)))
            if !v.isEmpty { config.interface = v }
        } else if line.hasPrefix("HOTSPOT_ROUTER=") {
            let v = unquoteConfigValue(String(line.dropFirst("HOTSPOT_ROUTER=".count)))
            if !v.isEmpty { config.hotspotRouter = v }
        } else if line.hasPrefix("NOTIFY=") {
            config.notify = unquoteConfigValue(String(line.dropFirst("NOTIFY=".count))) == "1"
        } else if line.hasPrefix("FAILOVER_STRIKES=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("FAILOVER_STRIKES=".count)))), n >= 1 { config.failoverStrikes = n }
        } else if line.hasPrefix("STRIKE_INTERVAL=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("STRIKE_INTERVAL=".count)))), n >= 0 { config.strikeInterval = n }
        } else if line.hasPrefix("FAILBACK=") {
            config.failback = unquoteConfigValue(String(line.dropFirst("FAILBACK=".count))) == "1"
        } else if line.hasPrefix("FAILBACK_INTERVAL=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("FAILBACK_INTERVAL=".count)))), n >= 30 { config.failbackInterval = n }
        } else if line.hasPrefix("FAILBACK_BACKOFF_MAX=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("FAILBACK_BACKOFF_MAX=".count)))), n >= 30 { config.failbackBackoffMax = n }
        } else if line.hasPrefix("FAILBACK_SETTLE=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("FAILBACK_SETTLE=".count)))), n >= 1 { config.failbackSettle = n }
        } else if line.hasPrefix("FAILBACK_MIN_RSSI=") {
            if let n = Int(unquoteConfigValue(String(line.dropFirst("FAILBACK_MIN_RSSI=".count)))) { config.failbackMinRSSI = n }
        }
    }

    return config
}

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

/// Upstream collapsed "no route at all" and "a captive portal answered" into
/// one boolean. They need different handling: both mean no internet, but a
/// portal means the network is physically fine and just wants a login, which
/// is worth saying out loud instead of silently burning cellular all day.
enum ProbeStatus: String {
    case online
    case captivePortal
    case offline
}

func probeStatus(interface: String) -> ProbeStatus {
    let (rc, out) = runTool("/usr/bin/curl", ["-sS", "-m", "4", "--interface", interface,
                                              "http://captive.apple.com/hotspot-detect.html"])
    if out.contains("<TITLE>Success</TITLE>") { return .online }
    // Something answered on this interface but it is not Apple's page: the
    // signature of a portal intercepting the request.
    if rc == 0 && !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .captivePortal }
    return .offline
}

func probeOnline(interface: String) -> Bool {
    return probeStatus(interface: interface) == .online
}

/// One probe decides "online" (fast path, unchanged). Only a *failure* costs
/// extra: it is re-tried `failoverStrikes` times `strikeInterval` apart, and
/// any single success aborts the whole thing. This is the asymmetry that
/// keeps a 4-second timeout on congested campus Wi-Fi from being read as an
/// outage, at the price of ~15s before a genuine one triggers failover.
func confirmProbe(config: RuntimeConfig) -> ProbeStatus {
    var last = probeStatus(interface: config.interface)
    if last == .online { return last }

    let extra = max(0, config.failoverStrikes - 1)
    for i in 0..<extra {
        Thread.sleep(forTimeInterval: Double(config.strikeInterval))
        last = probeStatus(interface: config.interface)
        if last == .online {
            wifiLog("info", "probe: recovered on attempt \(i + 2)/\(config.failoverStrikes), no failover")
            return last
        }
    }
    if config.failoverStrikes > 1 {
        wifiLog("info", "probe: \(config.failoverStrikes) consecutive failures (last=\(last.rawValue))")
    }
    return last
}

func currentRouter(interface: String) -> String {
    let (_, out) = runTool("/usr/sbin/ipconfig", ["getoption", interface, "router"])
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A join only counts once the DHCP router fingerprint matches the iOS
/// tethering gateway AND the reachability probe succeeds — either alone can
/// be a false positive (e.g. a stale lease, or a captive portal answering
/// on a different interface).
func verifyJoin(config: RuntimeConfig) -> Bool {
    let router = currentRouter(interface: config.interface)
    guard router == config.hotspotRouter else {
        wifiLog("warn", "verifyJoin: router is \(router.isEmpty ? "(none)" : router), expected \(config.hotspotRouter)")
        return false
    }
    return probeOnline(interface: config.interface)
}

// MARK: - Single-flight lock
//
// Same mkdir-style lock, same path, same 5-minute staleness window as
// libexec/auto-hotspot-check.sh's acquire_lock — so the app and the
// degraded-mode script can never race each other.

private let lockStaleSeconds: TimeInterval = 300

func acquireLock() -> Bool {
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: WifiPaths.lockPath, withIntermediateDirectories: false)
        return true
    } catch {
        // Lock dir likely already exists; fall through to the staleness check.
    }
    if let attrs = try? fm.attributesOfItem(atPath: WifiPaths.lockPath),
       let modified = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(modified) > lockStaleSeconds {
        try? fm.removeItem(atPath: WifiPaths.lockPath)
        if (try? fm.createDirectory(atPath: WifiPaths.lockPath, withIntermediateDirectories: false)) != nil {
            return true
        }
    }
    return false
}

func releaseLock() {
    try? FileManager.default.removeItem(atPath: WifiPaths.lockPath)
}

// MARK: - last-join-attempt stamp
//
// Same file, same format (epoch seconds, plain text) as the shell worker's
// LAST_JOIN_FILE, so cooldown state is shared regardless of which one wrote it.

func readLastJoinAttempt() -> TimeInterval? {
    guard let s = try? String(contentsOfFile: WifiPaths.lastJoinAttemptPath, encoding: .utf8) else { return nil }
    return TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func writeLastJoinAttempt() {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: WifiPaths.stateDir, withIntermediateDirectories: true)
    let ts = Int(Date().timeIntervalSince1970)
    try? "\(ts)".write(toFile: WifiPaths.lastJoinAttemptPath, atomically: true, encoding: .utf8)
}

func clearLastJoinAttempt() {
    try? FileManager.default.removeItem(atPath: WifiPaths.lastJoinAttemptPath)
}

// MARK: - Failback state
//
// Two files: when failback was last attempted, and how long to wait before
// the next one. The wait doubles on each failure so a campus network that is
// up-but-portalled does not get probed every three minutes forever.

func readFailbackAttempt() -> TimeInterval? {
    guard let s = try? String(contentsOfFile: WifiPaths.failbackAttemptPath, encoding: .utf8) else { return nil }
    return TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func writeFailbackAttempt() {
    try? FileManager.default.createDirectory(atPath: WifiPaths.stateDir, withIntermediateDirectories: true)
    try? "\(Int(Date().timeIntervalSince1970))".write(toFile: WifiPaths.failbackAttemptPath, atomically: true, encoding: .utf8)
}

func readFailbackBackoff() -> Int? {
    guard let s = try? String(contentsOfFile: WifiPaths.failbackBackoffPath, encoding: .utf8) else { return nil }
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func writeFailbackBackoff(_ seconds: Int) {
    try? FileManager.default.createDirectory(atPath: WifiPaths.stateDir, withIntermediateDirectories: true)
    try? "\(seconds)".write(toFile: WifiPaths.failbackBackoffPath, atomically: true, encoding: .utf8)
}

/// Called whenever we are online on something that is not the hotspot, so a
/// later offline episode starts from a clean slate rather than inheriting a
/// stale 20-minute backoff.
func clearFailbackState() {
    let fm = FileManager.default
    try? fm.removeItem(atPath: WifiPaths.failbackAttemptPath)
    try? fm.removeItem(atPath: WifiPaths.failbackBackoffPath)
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

// MARK: - Filesystem helpers

func ensureFileExists(atPath path: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                             withIntermediateDirectories: true)
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }
}

// MARK: - Logging
//
// Same "[ts] [level] msg" format as libexec/auto-hotspot-check.sh's log(),
// appended to the same file so `hotspotd` and the app interleave in one log.

private let wifiLogFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func wifiLog(_ level: String, _ message: String) {
    let ts = wifiLogFormatter.string(from: Date())
    let line = "[\(ts)] [\(level)] \(message)\n"
    let path = WifiPaths.logPath
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                             withIntermediateDirectories: true)
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
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

// MARK: - Join result

enum JoinResult: String {
    case success
    case alreadyJoined = "already_joined"
    case notFound = "not_found"
    case authFailed = "auth_failed"
    case interfaceError = "interface_error"
    case verificationFailed = "verification_failed"
    case wifiOff = "wifi_off"
}

// MARK: - agent.status
//
// Written atomically (temp file + rename) on every engine event so `hotspotd
// status` can merge it in without ever seeing a half-written file.

struct AgentStatus: Codable {
    var watcher_running: Bool
    var location_authorized: Bool
    var ssid_current: String
    var last_join_result: String
    var updated: Int
}

func writeAgentStatus(watcherRunning: Bool, locationAuthorized: Bool,
                       ssidCurrent: String, lastJoinResult: String) {
    let dir = WifiPaths.stateDir
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
        wifiLog("error", "agent.status: could not create state dir: \(error.localizedDescription)")
        return
    }

    let status = AgentStatus(
        watcher_running: watcherRunning,
        location_authorized: locationAuthorized,
        ssid_current: ssidCurrent,
        last_join_result: lastJoinResult,
        updated: Int(Date().timeIntervalSince1970)
    )

    guard let data = try? JSONEncoder().encode(status) else {
        wifiLog("error", "agent.status: encode failed")
        return
    }

    let finalPath = WifiPaths.agentStatusPath
    let tmpPath = finalPath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
    do {
        try data.write(to: URL(fileURLWithPath: tmpPath))
        _ = try fm.replaceItemAt(URL(fileURLWithPath: finalPath),
                                  withItemAt: URL(fileURLWithPath: tmpPath))
    } catch {
        wifiLog("error", "agent.status: atomic write failed: \(error.localizedDescription)")
        try? fm.removeItem(atPath: tmpPath)
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

        writeAgentStatus(
            watcherRunning: true,
            locationAuthorized: isLocationAuthorized(),
            ssidCurrent: currentSSID,
            lastJoinResult: "none"
        )
    }
}

// MARK: - Failback
//
// The hotspot and every real network share one radio, so returning to Wi-Fi
// is an action, not a preference: something has to actively leave the
// hotspot. And while we are on the hotspot we cannot measure whether campus
// Wi-Fi recovered without giving up the connection we have. So the sequence
// is deliberately conservative: prove a saved network is in range and strong
// enough FIRST, only then drop the hotspot, and treat "landed back on the
// hotspot" as a failure rather than a success.
//
// Nothing here reads, stores, or transmits a credential. Leaving the hotspot
// hands the choice to macOS auto-join, which reuses the keychain profile —
// including 802.1X enterprise ones like utexas — exactly as if you had
// clicked the network yourself.

extension WifiEngine {

    /// Saved networks that are in range, strong enough, and not the hotspot.
    ///
    /// Matching against the whole saved-profile list rather than one
    /// configured "home SSID" is what makes this survive campus networks that
    /// split or rename themselves (MyResNet-2G / MyResNet-5G / "MyResNet 5G"
    /// are three separate saved entries for one place).
    func failbackCandidates(config: RuntimeConfig) -> [String] {
        let saved = Set(savedProfileSSIDs()).subtracting([config.ssid])
        guard !saved.isEmpty else { return [] }
        guard let interface = CWWiFiClient.shared().interface() else { return [] }

        let scanned: [CWNetwork]
        do {
            scanned = Array(try interface.scanForNetworks(withSSID: nil))
        } catch {
            wifiLog("warn", "failbackCandidates: scan failed: \(error.localizedDescription)")
            return []
        }

        var seen = Set<String>()
        var out: [String] = []
        for net in scanned {
            guard let ssid = net.ssid, saved.contains(ssid), !seen.contains(ssid) else { continue }
            guard net.rssiValue >= config.failbackMinRSSI else {
                wifiLog("info", "failbackCandidates: skipping \(ssid) at \(net.rssiValue) dBm (floor \(config.failbackMinRSSI))")
                continue
            }
            seen.insert(ssid)
            out.append(ssid)
        }
        return out
    }

    /// Leaves the hotspot and lets macOS auto-join, then verifies real
    /// internet on whatever it picked.
    ///
    /// Returns true only when we end up associated to a NON-hotspot SSID with
    /// a passing probe. Auto-join is free to pick the hotspot again (it is a
    /// saved network in range like any other); that counts as a failure, and
    /// the caller backs off. The engine self-corrects rather than trying to
    /// out-guess macOS's ranking.
    func attemptFailback(config: RuntimeConfig) -> Bool {
        guard let interface = CWWiFiClient.shared().interface() else { return false }

        let candidates = failbackCandidates(config: config)
        guard !candidates.isEmpty else {
            wifiLog("info", "failback: no saved non-hotspot network in range; staying on hotspot")
            return false
        }
        wifiLog("info", "failback: candidates in range: \(candidates.joined(separator: ", "))")

        interface.disassociate()

        let deadline = Date().addingTimeInterval(Double(config.failbackSettle))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            let now = interface.ssid() ?? ""
            if now.isEmpty || now == config.ssid { continue }
            let status = probeStatus(interface: config.interface)
            if status == .online {
                wifiLog("info", "failback: back on \(now) with verified internet")
                return true
            }
            if status == .captivePortal {
                wifiLog("warn", "failback: \(now) is up but behind a captive portal; sign in to use it")
                return false
            }
        }

        wifiLog("warn", "failback: gave up after \(config.failbackSettle)s (now on \(interface.ssid() ?? "nothing"))")
        return false
    }
}
