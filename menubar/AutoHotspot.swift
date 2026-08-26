import Cocoa
import Foundation

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

// MARK: - Formatting helpers

func humanDuration(_ seconds: Int) -> String {
    if seconds <= 0 { return "—" }
    if seconds < 60 { return "\(seconds)s" }
    if seconds % 60 == 0 {
        let m = seconds / 60
        if m % 60 == 0 { return "\(m / 60)h" }
        return "\(m)m"
    }
    return "\(seconds / 60)m \(seconds % 60)s"
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) { return "~" + String(path.dropFirst(home.count)) }
    return path
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var headlineItem: NSMenuItem!
    var subheadItem: NSMenuItem!
    var toggleItem: NSMenuItem!
    var targetItem: NSMenuItem!
    var checkNowItem: NSMenuItem!

    var settingsMenu: NSMenu!
    var rowInterface: NSMenuItem!
    var rowInterval: NSMenuItem!
    var rowCooldown: NSMenuItem!
    var rowAgent: NSMenuItem!
    var rowLog: NSMenuItem!
    var rowConfig: NSMenuItem!

    var refreshTimer: Timer?
    var last = Status()
    var busy = false

    let hotspotdPath: String = locateHotspotd()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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

    /// A non-interactive caption row. Built with an explicit attributedTitle so it renders
    /// in the secondary style instead of AppKit's washed-out "disabled item" grey.
    func captionRow(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        setCaption(item, text)
        return item
    }

    func setCaption(_ item: NSMenuItem, _ text: String) {
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// A "Label   value" settings row, value in secondary colour so the pair reads as one line.
    func setSettingRow(_ item: NSMenuItem, _ label: String, _ value: String) {
        let s = NSMutableAttributedString(
            string: label + "  ",
            attributes: [.font: NSFont.menuFont(ofSize: 0),
                         .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(
            string: value,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = s
    }

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
        setIcon(enabled: false, ok: false)

        menu = NSMenu()
        menu.delegate = self
        // Without this AppKit auto-validates every item and overrides isEnabled,
        // which is why caption rows and the busy state used to render wrong.
        menu.autoenablesItems = false

        headlineItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
        headlineItem.isEnabled = false
        setHeadline(headlineItem, dot: .tertiaryLabelColor, "Checking…")
        menu.addItem(headlineItem)

        subheadItem = captionRow("")
        menu.addItem(subheadItem)

        menu.addItem(NSMenuItem.separator())

        toggleItem = NSMenuItem(title: "Auto-Join Hotspot", action: #selector(toggleAutoJoin), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        targetItem = captionRow("")
        menu.addItem(targetItem)

        menu.addItem(NSMenuItem.separator())

        checkNowItem = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "r")
        checkNowItem.target = self
        menu.addItem(checkNowItem)

        let logsItem = NSMenuItem(title: "Open Log", action: #selector(openLogs), keyEquivalent: "l")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(NSMenuItem.separator())

        // Settings submenu: every field hotspotd reports, actually displayed.
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false

        rowInterface = NSMenuItem(title: "Interface", action: nil, keyEquivalent: "")
        rowInterface.isEnabled = false
        rowInterval  = NSMenuItem(title: "Check every", action: nil, keyEquivalent: "")
        rowInterval.isEnabled = false
        rowCooldown  = NSMenuItem(title: "Retry cooldown", action: nil, keyEquivalent: "")
        rowCooldown.isEnabled = false
        rowAgent     = NSMenuItem(title: "Background agent", action: nil, keyEquivalent: "")
        rowAgent.isEnabled = false
        rowLog       = NSMenuItem(title: "Log", action: nil, keyEquivalent: "")
        rowLog.isEnabled = false
        rowConfig    = NSMenuItem(title: "Config", action: nil, keyEquivalent: "")
        rowConfig.isEnabled = false

        for r in [rowInterface, rowInterval, rowCooldown, rowAgent, rowLog, rowConfig] {
            settingsMenu.addItem(r!)
        }

        settingsMenu.addItem(NSMenuItem.separator())

        let editConfig = NSMenuItem(title: "Edit Config…", action: #selector(editConfig), keyEquivalent: "")
        editConfig.target = self
        settingsMenu.addItem(editConfig)

        let revealLog = NSMenuItem(title: "Reveal Log in Finder", action: #selector(revealLog), keyEquivalent: "")
        revealLog.target = self
        settingsMenu.addItem(revealLog)

        let reinstallItem = NSMenuItem(title: "Reinstall Agent", action: #selector(reinstallAgent), keyEquivalent: "")
        reinstallItem.target = self
        settingsMenu.addItem(reinstallItem)

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Auto Hotspot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// personalhotspot is Apple's own Personal Hotspot glyph — it reads as "hotspot",
    /// where the old wifi/wifi.slash pair read as "your Wi-Fi is broken".
    func setIcon(enabled: Bool, ok: Bool) {
        guard let button = statusItem.button else { return }
        let name = (ok && enabled) ? "personalhotspot" : "personalhotspot.slash"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Auto Hotspot") {
            image.isTemplate = true
            image.size = NSSize(width: 17, height: 17)
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = enabled ? "AH" : "ah"
        }
        button.appearsDisabled = !(ok && enabled)
        button.toolTip = ok
            ? (enabled ? "Auto-join hotspot: on" : "Auto-join hotspot: off")
            : "hotspotd unavailable"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
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
        var agentInstalled: Bool = false
        var agentLoaded: Bool = false
        var online: Bool = false
        var ssid: String = ""
        var ssidCurrent: String = ""
        var interface: String = ""
        var wifiPower: String = "Off"
        var checkInterval: Int = 0
        var cooldown: Int = 0
        var logPath: String = ""
        var configPath: String = ""
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
        result.agentInstalled = (obj["agent_installed"] as? Bool) ?? false
        result.agentLoaded = (obj["agent_loaded"] as? Bool) ?? false
        result.online = (obj["online"] as? Bool) ?? false
        result.ssid = (obj["ssid"] as? String) ?? ""
        result.ssidCurrent = (obj["ssid_current"] as? String) ?? ""
        result.interface = (obj["interface"] as? String) ?? ""
        result.wifiPower = (obj["wifi_power"] as? String) ?? "Off"
        result.checkInterval = (obj["check_interval"] as? Int) ?? 0
        result.cooldown = (obj["cooldown"] as? Int) ?? 0
        result.logPath = (obj["log_path"] as? String) ?? ""
        result.configPath = (obj["config_path"] as? String) ?? ""
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
        setIcon(enabled: s.enabled, ok: s.ok)

        guard s.ok else {
            setHeadline(headlineItem, dot: .systemRed, "hotspotd unavailable")
            setCaption(subheadItem, abbreviateHome(hotspotdPath))
            toggleItem.state = .off
            toggleItem.isEnabled = false
            setCaption(targetItem, "—")
            setSettingRow(rowInterface, "Interface", "—")
            setSettingRow(rowInterval, "Check every", "—")
            setSettingRow(rowCooldown, "Retry cooldown", "—")
            setSettingRow(rowAgent, "Background agent", "unknown")
            setSettingRow(rowLog, "Log", "—")
            setSettingRow(rowConfig, "Config", "—")
            return
        }

        // Headline: what the network is doing right now.
        if s.wifiPower != "On" {
            setHeadline(headlineItem, dot: .systemOrange, "Wi-Fi is off")
        } else if s.online {
            let where_ = s.ssidCurrent.isEmpty ? "connected" : s.ssidCurrent
            setHeadline(headlineItem, dot: .systemGreen, "Online \u{2014} \(where_)")
        } else {
            setHeadline(headlineItem, dot: .systemRed, "Offline")
        }

        // Subhead: what the daemon will do about it.
        if !s.enabled {
            setCaption(subheadItem, "Auto-join paused")
        } else if !s.agentLoaded {
            setCaption(subheadItem, "Agent not running \u{2014} reinstall to resume")
        } else {
            setCaption(subheadItem, "Checking every \(humanDuration(s.checkInterval))")
        }

        toggleItem.isEnabled = !busy
        toggleItem.state = s.enabled ? .on : .off
        setCaption(targetItem, s.ssid.isEmpty ? "No hotspot configured" : "Joins \u{201C}\(s.ssid)\u{201D} when offline")

        setSettingRow(rowInterface, "Interface", s.interface.isEmpty ? "—" : s.interface)
        setSettingRow(rowInterval, "Check every", humanDuration(s.checkInterval))
        setSettingRow(rowCooldown, "Retry cooldown", humanDuration(s.cooldown))
        setSettingRow(rowAgent, "Background agent",
                      s.agentLoaded ? "running" : (s.agentInstalled ? "installed, stopped" : "not installed"))
        setSettingRow(rowLog, "Log", abbreviateHome(s.logPath))
        setSettingRow(rowConfig, "Config", abbreviateHome(s.configPath))
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

    @objc func checkNow() {
        guard !busy else { return }
        busy = true
        checkNowItem.title = "Checking…"
        checkNowItem.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(["check"])
            DispatchQueue.main.async {
                self?.checkNowItem.title = "Check Now"
                self?.checkNowItem.isEnabled = true
                self?.busy = false
            }
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

    @objc func revealLog() {
        let path = last.logPath.isEmpty
            ? NSHomeDirectory() + "/Library/Logs/auto-hotspot.log"
            : last.logPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func editConfig() {
        let path = last.configPath.isEmpty
            ? NSHomeDirectory() + "/.config/auto-hotspot/config"
            : last.configPath
        guard FileManager.default.fileExists(atPath: path) else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).deletingLastPathComponent()])
            return
        }
        // Force a text editor: the config file has no extension, so a plain open can miss.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", path]
        try? p.run()
    }

    @objc func reinstallAgent() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(["install"])
            self?.refresh()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
