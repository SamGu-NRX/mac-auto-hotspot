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

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var infoItem: NSMenuItem!
    var agentItem: NSMenuItem!
    var toggleItem: NSMenuItem!
    var checkNowItem: NSMenuItem!

    var refreshTimer: Timer?

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

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: "Auto Hotspot") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                button.title = "AH"
            }
        }

        menu = NSMenu()
        menu.delegate = self

        infoItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        agentItem = NSMenuItem(title: "Agent: unknown", action: nil, keyEquivalent: "")
        agentItem.isEnabled = false
        menu.addItem(agentItem)

        menu.addItem(NSMenuItem.separator())

        toggleItem = NSMenuItem(title: "Auto-Join: OFF", action: #selector(toggleAutoJoin), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        checkNowItem = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "")
        checkNowItem.target = self
        menu.addItem(checkNowItem)

        let logsItem = NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        let reinstallItem = NSMenuItem(title: "Reinstall Agent", action: #selector(reinstallAgent), keyEquivalent: "")
        reinstallItem.target = self
        menu.addItem(reinstallItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
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
        var agentLoaded: Bool = false
        var online: Bool = false
        var ssid: String = ""
        var ssidCurrent: String = ""
        var interface: String = ""
        var wifiPower: String = "Off"
        var checkInterval: Int = 0
        var cooldown: Int = 0
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
        result.online = (obj["online"] as? Bool) ?? false
        result.ssid = (obj["ssid"] as? String) ?? ""
        result.ssidCurrent = (obj["ssid_current"] as? String) ?? ""
        result.interface = (obj["interface"] as? String) ?? ""
        result.wifiPower = (obj["wifi_power"] as? String) ?? "Off"
        result.checkInterval = (obj["check_interval"] as? Int) ?? 0
        result.cooldown = (obj["cooldown"] as? Int) ?? 0
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
                self.applyStatus(status)
            }
        }
    }

    func applyStatus(_ status: Status) {
        if let button = statusItem.button {
            let symbolName = status.enabled ? "wifi" : "wifi.slash"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Auto Hotspot") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                button.title = "AH"
            }
        }

        if !status.ok {
            infoItem.title = "hotspotd unavailable"
            agentItem.title = "Agent: unknown"
            toggleItem.title = "Auto-Join: OFF"
            toggleItem.state = .off
            return
        }

        if status.wifiPower != "On" {
            infoItem.title = "Wi-Fi off"
        } else if status.online {
            infoItem.title = "Online — \(status.ssidCurrent)"
        } else {
            infoItem.title = "Offline"
        }

        agentItem.title = status.agentLoaded
            ? "Agent: loaded (every \(status.checkInterval)s)"
            : "Agent: not installed"

        toggleItem.title = status.enabled ? "Auto-Join: ON" : "Auto-Join: OFF"
        toggleItem.state = status.enabled ? .on : .off
    }

    // MARK: - Actions

    @objc func toggleAutoJoin() {
        let currentlyEnabled = (toggleItem.state == .on)
        let args = currentlyEnabled ? ["off"] : ["on"]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(args)
            self?.refresh()
        }
    }

    @objc func checkNow() {
        checkNowItem.title = "Checking…"
        checkNowItem.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(["check"])
            DispatchQueue.main.async {
                self?.checkNowItem.title = "Check Now"
                self?.checkNowItem.isEnabled = true
            }
            self?.refresh()
        }
    }

    @objc func openLogs() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(["logs", "--open"])
        }
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
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
