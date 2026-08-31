import Cocoa
import Foundation
import Network
import CoreWLAN

// MARK: - hotspotd location

func locateHotspotd() -> String {
    let fm = FileManager.default

    if let env = ProcessInfo.processInfo.environment["AUTO_HOTSPOT_HOTSPOTD"], !env.isEmpty {
        return env
    }

    let configPath = NSHomeDirectory() + "/.config/auto-hotspot/config"
    if let contents = try? String(contentsOfFile: configPath, encoding: .utf8) {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("HOTSPOTD_BIN=") {
                var value = String(line.dropFirst("HOTSPOTD_BIN=".count))
                value = value.trimmingCharacters(in: .whitespaces)
                if value.count >= 2 {
                    let first = value.first!
                    let last = value.last!
                    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                        value = String(value.dropFirst().dropLast())
                    }
                }
                if !value.isEmpty {
                    return value
                }
            }
        }
    }

    let bundleCandidate = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("bin/hotspotd")
        .path
    if fm.isExecutableFile(atPath: bundleCandidate) {
        return bundleCandidate
    }

    let fallback = NSHomeDirectory() + "/git repos/mac-auto-hotspot/bin/hotspotd"
    return fallback
}

// MARK: - Menu bar glyphs
//
// iphone.radiowaves.left.and.right / iphone.slash. The ON glyph's own .slash
// variant — iphone.radiowaves.left.and.right.slash — doesn't exist on this SDK
// (NSImage(systemSymbolName:) returns nil), so the OFF state uses the plain,
// Apple-drawn iphone.slash instead. It isn't a slash variant of the ON glyph,
// but it shares the same phone silhouette, so the pair still reads as one
// family. Not wifi/wifi.slash — that pair reads as "your Wi-Fi is broken"
// rather than "auto-join is off".
let iconOnSymbol = "iphone.radiowaves.left.and.right"
let iconOffSymbol = "iphone.slash"

// MARK: - Watcher
//
// The event-driven agent core. Four sources funnel onto one serial queue,
// debounced to at most one evaluation per 5 seconds:
//   (a) NWPathMonitor           - path transitions (verified: no TCC needed, no hot-spin)
//   (b) NSWorkspace wake        - sleep/wake so a dropped join survives suspend
//   (c) a self-rescheduling timer at CHECK_INTERVAL - safety net, config reread each fire
//   (d) a file-system-object source on $STATE_DIR/trigger - lets the CLI poke a running agent
//
// Deliberately NOT `scutil -w`: on this machine (macOS 26) that loop returns
// in ~5ms on an existing key and there is no `n.wait` subcommand to block on,
// so it would burn a core. NWPathMonitor already covers the same transitions.
final class Watcher {
    static let shared = Watcher()

    private let queue = DispatchQueue(label: "com.andrewwang.autohotspot.watcher")
    private var pathMonitor: NWPathMonitor?
    private var safetyTimer: DispatchSourceTimer?
    private var triggerSource: DispatchSourceFileSystemObject?
    private var triggerFD: Int32 = -1
    private var wakeObserver: NSObjectProtocol?

    private var lastEvalTime: Date = .distantPast
    private var debounceWorkItem: DispatchWorkItem?
    private var offlineEpisodeNotified = false
    // Set when a cycle sees .alreadyJoined but then fails verification — the
    // next join() call forces a disassociate+rejoin instead of repeating the
    // identical alreadyJoined->verify-fail loop forever.
    private var forceRejoinNext = false

    private init() {}

    func start() {
        requestNotificationAuthorizationIfNeeded()
        startPathMonitor()
        startWakeObserver()
        startTriggerWatch()
        queue.async { [weak self] in self?.scheduleSafetyTimer() }
        // RunAtLoad implies "a check just happened" — run one immediately.
        queue.async { [weak self] in self?.performEvaluation(reason: "startup") }
    }

    /// Lets `hotspotd check`'s successor (or a human) wake the agent without
    /// waiting for the trigger-file round trip.
    func triggerNow(reason: String) {
        queue.async { [weak self] in self?.scheduleDebounced(reason: reason) }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Already invoked on `queue` below via start(queue:).
            self?.scheduleDebounced(reason: "path-update:\(path.status)")
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func startWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                // Waking somewhere new invalidates a backoff earned at the
                // last location, so failback starts fresh rather than
                // sitting out a 20-minute penalty from another building.
                clearFailbackState()
                self.scheduleDebounced(reason: "wake")
            }
        }
    }

    private func startTriggerWatch() {
        let path = WifiPaths.triggerPath
        ensureFileExists(atPath: path)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            wifiLog("error", "trigger watch: could not open \(path)")
            return
        }
        triggerFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .attrib, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self = self else { return }
            let flags = source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                // The trigger file was replaced rather than touched-in-place;
                // re-open on the same path so future pokes still land.
                source?.cancel()
                self.startTriggerWatch()
                return
            }
            self.scheduleDebounced(reason: "trigger")
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.triggerFD, fd >= 0 { close(fd) }
        }
        source.resume()
        triggerSource = source
    }

    /// Self-rescheduling rather than a fixed-period repeat: each fire reads
    /// CHECK_INTERVAL fresh from disk before arming the next one, so editing
    /// the config takes effect without a restart.
    private func scheduleSafetyTimer() {
        safetyTimer?.cancel()
        let config = loadRuntimeConfig()
        let interval = max(30, config.checkInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.scheduleDebounced(reason: "safety-net")
            self?.scheduleSafetyTimer()
        }
        timer.resume()
        safetyTimer = timer
    }

    /// Must run on `queue`. Coalesces bursts (Wi-Fi power-cycles fire path
    /// updates several times in under a second) into one evaluation.
    private func scheduleDebounced(reason: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEvalTime)
        debounceWorkItem?.cancel()
        if elapsed >= 5 {
            performEvaluation(reason: reason)
        } else {
            let delay = 5 - elapsed
            let work = DispatchWorkItem { [weak self] in self?.performEvaluation(reason: reason) }
            debounceWorkItem = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Must run on `queue`. This is the whole contract from the plan:
    /// disabled -> skip; online -> clear cooldown stamp; offline within
    /// cooldown -> log and skip; otherwise stamp then attempt the join.
    private func performEvaluation(reason: String) {
        lastEvalTime = Date()
        let config = loadRuntimeConfig()

        guard config.enabled else {
            wifiLog("info", "evaluate (\(reason)): disabled, skipping")
            return
        }

        guard acquireLock() else {
            wifiLog("warn", "evaluate (\(reason)): another check is running, skipping")
            return
        }
        defer { releaseLock() }

        let ssidNow = CWWiFiClient.shared().interface()?.ssid() ?? ""
        let locationAuthorized = WifiEngine.shared.isLocationAuthorized()

        let probe = confirmProbe(config: config)

        if probe == .online {
            // Online *through the hotspot* is the case upstream never
            // handled: the probe passes, so nothing ever moves back to Wi-Fi.
            var healthy = true
            if config.failback && !config.ssid.isEmpty && ssidNow == config.ssid {
                healthy = maybeFailback(config: config)
            } else {
                clearFailbackState()
            }

            // Failback drops the hotspot on purpose. If it could neither reach
            // Wi-Fi nor get the hotspot back, we are offline *now* — reporting
            // the pre-failback probe as "online" would clear the retry stamp
            // and hide a real outage until the next safety-net tick.
            if !healthy {
                wifiLog("error", "evaluate (\(reason)): failback left no working connection")
                writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                                  ssidCurrent: CWWiFiClient.shared().interface()?.ssid() ?? "",
                                  lastJoinResult: "failback_stranded")
                return
            }

            let ssidAfter = CWWiFiClient.shared().interface()?.ssid() ?? ssidNow
            wifiLog("info", "evaluate (\(reason)): online via \(ssidAfter.isEmpty ? "other/none" : ssidAfter)")
            clearLastJoinAttempt()
            offlineEpisodeNotified = false
            writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: ssidAfter, lastJoinResult: "online")
            return
        }

        if probe == .captivePortal {
            wifiLog("warn", "evaluate (\(reason)): \(ssidNow.isEmpty ? "this network" : ssidNow) answers HTTP but is behind a captive portal — no internet, failing over; sign in to use it directly")
        }

        if let last = readLastJoinAttempt() {
            let elapsed = Date().timeIntervalSince1970 - last
            if elapsed < Double(config.cooldown) {
                let remaining = Int(Double(config.cooldown) - elapsed)
                wifiLog("info", "evaluate (\(reason)): offline but in cooldown (\(remaining)s left), skipping")
                return
            }
        }

        // Stamp BEFORE attempting the join so a crash mid-attempt still throttles.
        writeLastJoinAttempt()

        // Restore Wi-Fi power before touching anything else: a radio left
        // off (e.g. by sleep/wake) makes scanning and association fail in a
        // way indistinguishable from "hotspot not found" unless this is
        // checked first. Mirrors the shell fallback's power-cycle recovery.
        guard WifiEngine.shared.ensureWifiPowerOn() else {
            wifiLog("error", "evaluate (\(reason)): Wi-Fi is off and could not be turned back on")
            writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: ssidNow, lastJoinResult: JoinResult.wifiOff.rawValue)
            if config.notify && !offlineEpisodeNotified {
                offlineEpisodeNotified = true
                postOfflineNotification(ssid: config.ssid, result: .wifiOff, locationAuthorized: locationAuthorized)
            }
            return
        }

        wifiLog("info", "evaluate (\(reason)): offline, attempting join to \(config.ssid)")
        let result = WifiEngine.shared.join(ssid: config.ssid, forceRejoin: forceRejoinNext)
        forceRejoinNext = false

        var verified = false
        if result == .success || result == .alreadyJoined {
            // Give DHCP a moment to hand out a lease before checking the
            // router fingerprint, matching the shell worker's settle time.
            Thread.sleep(forTimeInterval: 3)
            verified = verifyJoin(config: config)
        }

        if verified {
            wifiLog("info", "evaluate (\(reason)): joined \u{201C}\(config.ssid)\u{201D} and verified online")
            clearLastJoinAttempt()
            offlineEpisodeNotified = false
            writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: config.ssid, lastJoinResult: "success")
        } else {
            if result == .alreadyJoined {
                // Stale association: verifyJoin failed against an SSID we
                // were already on. Force a real disassociate+rescan+rejoin
                // next cycle instead of reporting the same alreadyJoined
                // shortcut and looping forever.
                forceRejoinNext = true
            }
            wifiLog("error", "evaluate (\(reason)): join failed or unverified (result=\(result.rawValue))")
            writeAgentStatus(watcherRunning: true, locationAuthorized: locationAuthorized,
                              ssidCurrent: ssidNow, lastJoinResult: result.rawValue)
            if config.notify && !offlineEpisodeNotified {
                offlineEpisodeNotified = true
                postOfflineNotification(ssid: config.ssid, result: result, locationAuthorized: locationAuthorized)
            }
        }
    }

    /// Runs only while online *on the hotspot*. Rate-limited by an
    /// exponential backoff so a campus network that is up-but-unusable does
    /// not cost a connectivity blip every few minutes.
    ///
    /// Must run on `queue`, under the same lock as the rest of the evaluation.
    /// Returns true while we still have a working connection (failback
    /// succeeded, was skipped, or failed but the hotspot came back). Returns
    /// false only when we are left with nothing.
    @discardableResult
    private func maybeFailback(config: RuntimeConfig) -> Bool {
        let wait = readFailbackBackoff() ?? config.failbackInterval
        if let last = readFailbackAttempt() {
            let elapsed = Date().timeIntervalSince1970 - last
            if elapsed < Double(wait) {
                wifiLog("info", "failback: next attempt in \(Int(Double(wait) - elapsed))s")
                return true
            }
        }

        writeFailbackAttempt()

        if WifiEngine.shared.attemptFailback(config: config) {
            clearFailbackState()
            return true
        }

        // Failed: back off, then get the hotspot back immediately rather than
        // waiting out another full strike cycle to rediscover we are offline.
        let next = min(max(wait * 2, config.failbackInterval), config.failbackBackoffMax)
        writeFailbackBackoff(next)
        wifiLog("info", "failback: unsuccessful, next attempt in \(next)s; restoring hotspot")

        let restore = WifiEngine.shared.join(ssid: config.ssid, forceRejoin: true)
        if restore != .success && restore != .alreadyJoined {
            wifiLog("error", "failback: could not restore hotspot (result=\(restore.rawValue))")
            return false
        }
        // Association is not connectivity: confirm before claiming health.
        Thread.sleep(forTimeInterval: 3)
        return probeStatus(interface: config.interface) == .online
    }
}

// MARK: - AppDelegate

// MARK: - Problem rows
//
// A problem exists only while its condition is true; rebuildMenu() re-derives
// this list from the cached Status every time the menu is rebuilt, so a row
// physically does not exist in the menu when its condition is false rather
// than being pre-built and hidden.
enum Problem {
    case locationDenied
    case wifiOff
    case agentDown
    case lastJoinFailed
}

private let actionableJoinFailures: Set<String> = [
    "not_found", "auth_failed", "verification_failed", "interface_error",
]

func problems(_ s: AppDelegate.Status) -> [Problem] {
    var result: [Problem] = []
    if !s.locationAuthorized { result.append(.locationDenied) }
    if s.wifiPower != "On" { result.append(.wifiOff) }
    if !s.agentLoaded || !s.watcherRunning { result.append(.agentDown) }
    if !s.online && actionableJoinFailures.contains(s.lastJoinResult) { result.append(.lastJoinFailed) }
    return result
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var headlineItem: NSMenuItem!
    var toggleItem: NSMenuItem!

    var refreshTimer: Timer?
    var last = Status()
    var busy = false
    // Tracks whether the menu is currently open so applyStatus knows it may
    // only update titles/state in place, never add or remove items, while
    // the user has it open (rows must never appear/vanish under the cursor).
    var menuIsOpen = false

    let hotspotdPath: String = locateHotspotd()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // First thing the process does: run the join-engine gate (item 3's
        // Location + CoreWLAN probe). See menubar/Wifi.swift.
        WifiEngine.shared.runStartupGate()

        // Start the event-driven watcher (item 4): NWPathMonitor, sleep/wake,
        // the safety-net timer, and the trigger-file watch all funnel onto
        // one serial queue from here on. See the Watcher class above.
        Watcher.shared.start()

        buildStatusItem()

        if !FileManager.default.isExecutableFile(atPath: hotspotdPath) {
            let alert = NSAlert()
            alert.messageText = "hotspotd not found"
            alert.informativeText = "Could not locate the hotspotd binary at:\n\(hotspotdPath)\n\nRun ./install.sh, then reopen this app."
            alert.alertStyle = .warning
            alert.runModal()
        }

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Menu construction

    func setHeadline(_ item: NSMenuItem, dot: NSColor, _ text: String) {
        let s = NSMutableAttributedString(
            string: "\u{25CF} ",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: dot])
        s.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.labelColor]))
        item.attributedTitle = s
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(enabled: false, ok: false, attention: false)

        menu = NSMenu()
        menu.delegate = self
        // Without this AppKit auto-validates every item and overrides isEnabled,
        // which is why caption rows and the busy state used to render wrong.
        menu.autoenablesItems = false

        headlineItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
        headlineItem.isEnabled = false
        setHeadline(headlineItem, dot: .tertiaryLabelColor, "Checking…")

        toggleItem = NSMenuItem(title: "Auto-Join Hotspot", action: #selector(toggleAutoJoin), keyEquivalent: "")
        toggleItem.target = self

        rebuildMenu()
        statusItem.menu = menu
    }

    /// Rebuilds the whole menu from `last`: removeAllItems() + addItem is
    /// safe on macOS 14+ and is the only way a problem row can physically
    /// not exist when its condition is false, rather than being pre-built
    /// and hidden. Order: status line, zero or more problem rows, separator,
    /// toggle, separator, Quit.
    func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(headlineItem)

        for problem in problems(last) {
            menu.addItem(menuItem(for: problem))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Auto Hotspot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    func menuItem(for problem: Problem) -> NSMenuItem {
        let item: NSMenuItem
        switch problem {
        case .locationDenied:
            item = NSMenuItem(title: "Grant Location Access…", action: #selector(openLocationPrefs), keyEquivalent: "")
        case .wifiOff:
            item = NSMenuItem(title: "Turn Wi-Fi On", action: #selector(turnWifiOn), keyEquivalent: "")
        case .agentDown:
            item = NSMenuItem(title: "Restart Background Agent", action: #selector(restartAgent), keyEquivalent: "")
        case .lastJoinFailed:
            item = NSMenuItem(title: "Last Join Failed (\(last.lastJoinResult)) — Open Log", action: #selector(openLogs), keyEquivalent: "")
        }
        item.target = self
        item.isEnabled = true
        return item
    }

    /// personalhotspot is Apple's own Personal Hotspot glyph — it reads as "hotspot",
    /// where the old Wi-Fi glyph pair read as "your Wi-Fi is broken". The off
    /// state is carried entirely by the .slash variant; `appearsDisabled` used to
    /// also grey out the button, which read as "this whole item is inert" rather
    /// than "auto-join is off". Online/offline is deliberately not encoded here —
    /// it flips too often and macOS's own Wi-Fi menu already shows it. Instead
    /// `attention` composites a small filled dot onto the symbol whenever a
    /// problem row is showing (or hotspotd is unreachable), so the icon alone
    /// tells the user "something here needs a look".
    func setIcon(enabled: Bool, ok: Bool, attention: Bool) {
        guard let button = statusItem.button else { return }
        let name = (ok && enabled) ? iconOnSymbol : iconOffSymbol
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let base = NSImage(systemSymbolName: name, accessibilityDescription: "Auto Hotspot")?
            .withSymbolConfiguration(config) {
            let image = attention ? withAttentionDot(base) : base
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = enabled ? "AH" : "ah"
        }
        button.toolTip = ok
            ? (enabled ? "Auto-join hotspot: on" : "Auto-join hotspot: off")
            : "hotspotd unavailable"
    }

    /// Composites a small filled dot into the top-right corner of `base`.
    /// The result stays template-renderable (isTemplate = true) so it still
    /// tints correctly for the menu bar's light/dark appearance.
    func withAttentionDot(_ base: NSImage) -> NSImage {
        let size = base.size
        let result = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dotDiameter: CGFloat = 5
            let dotRect = NSRect(
                x: rect.maxX - dotDiameter, y: rect.maxY - dotDiameter,
                width: dotDiameter, height: dotDiameter)
            let path = NSBezierPath(ovalIn: dotRect)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        result.isTemplate = true
        return result
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // Rebuild synchronously from the cached status first, so the rows
        // reflect the same state the icon does the instant the menu opens;
        // the async refresh below then updates titles/state in place.
        rebuildMenu()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    // MARK: - Shelling out

    @discardableResult
    func run(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hotspotdPath)
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

    // MARK: - Status model

    struct Status {
        var enabled: Bool = false
        var agentLoaded: Bool = false
        var watcherRunning: Bool = false
        var locationAuthorized: Bool = false
        var online: Bool = false
        var ssid: String = ""
        var ssidCurrent: String = ""
        var wifiPower: String = "Off"
        var lastJoinResult: String = ""
        var logPath: String = ""
        var ok: Bool = false
    }

    func fetchStatus() -> Status {
        var result = Status()
        let (code, out) = run(["status", "--json"])
        guard code == 0, !out.isEmpty else { return result }

        guard let firstLine = out.split(separator: "\n").first else { return result }
        guard let data = firstLine.data(using: .utf8) else { return result }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return result }

        result.enabled = (obj["enabled"] as? Bool) ?? false
        result.agentLoaded = (obj["agent_loaded"] as? Bool) ?? false
        result.watcherRunning = (obj["watcher_running"] as? Bool) ?? false
        result.locationAuthorized = (obj["location_authorized"] as? Bool) ?? false
        result.online = (obj["online"] as? Bool) ?? false
        result.ssid = (obj["ssid"] as? String) ?? ""
        result.ssidCurrent = (obj["ssid_current"] as? String) ?? ""
        result.wifiPower = (obj["wifi_power"] as? String) ?? "Off"
        result.lastJoinResult = (obj["last_join_result"] as? String) ?? ""
        result.logPath = (obj["log_path"] as? String) ?? ""
        result.ok = true
        return result
    }

    // MARK: - Refresh

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let status = self.fetchStatus()
            DispatchQueue.main.async {
                self.last = status
                self.applyStatus(status)
            }
        }
    }

    func applyStatus(_ s: Status) {
        let attention = !s.ok || !problems(s).isEmpty
        setIcon(enabled: s.enabled, ok: s.ok, attention: attention)

        guard s.ok else {
            setHeadline(headlineItem, dot: .systemRed, "hotspotd unavailable")
            toggleItem.state = .off
            toggleItem.isEnabled = false
            // Nothing to click for "hotspotd unreachable" — no problem row
            // exists for it, so there is no menu content that could go stale
            // here even while the menu is open.
            return
        }

        // Status line: Wi-Fi power, online/offline, current or target SSID,
        // and whether auto-join is paused — all folded into one sentence.
        if s.wifiPower != "On" {
            setHeadline(headlineItem, dot: .systemOrange, "Wi-Fi is off")
        } else if s.online {
            if s.ssidCurrent.isEmpty || s.ssidCurrent == "<redacted>" {
                setHeadline(headlineItem, dot: .systemGreen, "Online")
            } else {
                setHeadline(headlineItem, dot: .systemGreen, "Online \u{2014} \(s.ssidCurrent)")
            }
        } else if s.enabled {
            setHeadline(headlineItem, dot: .systemRed, "Offline \u{2014} joining \u{201C}\(s.ssid)\u{201D}")
        } else {
            setHeadline(headlineItem, dot: .systemRed, "Offline \u{2014} auto-join paused")
        }

        toggleItem.isEnabled = !busy
        toggleItem.state = s.enabled ? .on : .off

        // Problem rows can only be added/removed while the menu is closed —
        // never while the user has it open, so a row never appears or
        // vanishes under the cursor. menuWillOpen already rebuilds
        // synchronously from `last` the instant the menu opens.
        if !menuIsOpen {
            rebuildMenu()
        }
    }

    // MARK: - Actions

    @objc func toggleAutoJoin() {
        guard !busy else { return }
        busy = true
        let args = last.enabled ? ["off"] : ["on"]
        toggleItem.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(args)
            DispatchQueue.main.async { self?.busy = false }
            self?.refresh()
        }
    }

    @objc func openLogs() {
        let path = last.logPath.isEmpty
            ? NSHomeDirectory() + "/Library/Logs/auto-hotspot.log"
            : last.logPath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).deletingLastPathComponent()])
        }
    }

    /// The Location Services problem row's action when access hasn't been
    /// granted — jumps straight to the Privacy > Location Services pane.
    @objc func openLocationPrefs() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The Wi-Fi-off problem row's action. In-process, no shell-out: the
    /// same CoreWLAN power-on path the watcher uses on every offline cycle.
    @objc func turnWifiOn() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = WifiEngine.shared.ensureWifiPowerOn()
            self?.refresh()
        }
    }

    /// The agent-down problem row's action. Only enables + bootstraps the
    /// already-installed plist via launchctl — it never rebuilds or re-signs
    /// the bundle, so the Location Services grant survives. If the repair
    /// fails the row simply stays visible on the next open.
    @objc func restartAgent() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(["agent", "load"])
            self?.refresh()
        }
    }
}

// Compiling AutoHotspot.swift alongside Wifi.swift means neither file is
// named main.swift, so top-level statements aren't allowed here — @main
// is the multi-file-safe equivalent. Still app.run(), not NSApplicationMain
// (no nib; the delegate is assigned by hand).
@main
struct AutoHotspotMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
