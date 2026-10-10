import Foundation

// MARK: - Runtime config
//
// Mirrors bin/hotspotd's load_config / libexec/auto-hotspot-check.sh's config
// sourcing: same defaults, same keys. Reloaded from disk on every evaluation
// (see Watcher.performEvaluation in AutoHotspot.swift) so editing the config
// file takes effect without a reinstall or restart.

public struct RuntimeConfig: Equatable {
    public var ssid: String
    public var checkInterval: Int
    public var enabled: Bool
    public var cooldown: Int
    public var interface: String
    public var hotspotRouter: String
    public var notify: Bool

    public init(
        ssid: String = "Andrew\u{2019}s iPhone",
        checkInterval: Int = 300,
        enabled: Bool = true,
        cooldown: Int = 30,
        interface: String = "en0",
        hotspotRouter: String = "172.20.10.1",
        notify: Bool = true
    ) {
        self.ssid = ssid
        self.checkInterval = checkInterval
        self.enabled = enabled
        self.cooldown = cooldown
        self.interface = interface
        self.hotspotRouter = hotspotRouter
        self.notify = notify
    }
}

public func unquoteConfigValue(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if value.count >= 2, let first = value.first, let last = value.last,
       (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        value = String(value.dropFirst().dropLast())
    }
    return value
}

/// Loads and parses the config file. Missing file -> defaults. Malformed
/// values fall back to the default for that key (behavior preserved from the
/// original menubar/Wifi.swift implementation); range validation and issue
/// reporting land with the validation contract — see HotspotCore's
/// loadValidatedConfig.
public func loadRuntimeConfig() -> RuntimeConfig {
    var config = RuntimeConfig()

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
        }
    }

    return config
}
