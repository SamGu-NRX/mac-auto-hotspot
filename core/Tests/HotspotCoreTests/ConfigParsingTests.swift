import XCTest
@testable import HotspotCore

/// Config parsing parity with the shell contract (bin/hotspotd's
/// load_config, the check script's config sourcing): defaults, quoting,
/// last-assignment-wins, malformed-value fallbacks, and exact byte-level
/// handling of the SSID the user actually typed (the typographic apostrophe
/// is load-bearing — quoting it wrong joins the wrong network).
final class ConfigParsingTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = TestEnv.makeHome("config")
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

    func testMissingConfigFallsBackToDefaults() {
        XCTAssertEqual(loadRuntimeConfig(), RuntimeConfig())
    }

    func testDefaultsMatchTheShellWorkerContract() {
        let config = RuntimeConfig()
        XCTAssertEqual(config.ssid, "Andrew\u{2019}s iPhone")
        XCTAssertEqual(config.checkInterval, 300)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.cooldown, 30)
        XCTAssertEqual(config.interface, "en0")
        XCTAssertEqual(config.hotspotRouter, "172.20.10.1")
        XCTAssertTrue(config.notify)
    }

    func testLastAssignmentWinsForSSID() throws {
        try writeConfig("SSID=First\nSSID=Second\n")
        XCTAssertEqual(loadRuntimeConfig().ssid, "Second")
    }

    func testQuotingVariantsAreUnquoted() throws {
        try writeConfig("SSID=\"Quoted Wifi\"\nHOTSPOT_ROUTER='172.20.10.1'\n")
        let config = loadRuntimeConfig()
        XCTAssertEqual(config.ssid, "Quoted Wifi")
        XCTAssertEqual(config.hotspotRouter, "172.20.10.1")
    }

    func testUnicodeSSIDWithTypographicApostropheRoundTrips() throws {
        try writeConfig("SSID=Andrew\u{2019}s iPhone\n")
        XCTAssertEqual(loadRuntimeConfig().ssid, "Andrew\u{2019}s iPhone")
    }

    func testUnicodeSSIDWithAccentsRoundTrips() throws {
        try writeConfig("SSID=Caf\u{e9} \u{d6}ffnet\n")
        XCTAssertEqual(loadRuntimeConfig().ssid, "Caf\u{e9} \u{d6}ffnet")
    }

    func testMalformedNumericFallsBackToDefault() throws {
        try writeConfig("CHECK_INTERVAL=abc\n")
        XCTAssertEqual(loadRuntimeConfig().checkInterval, 300)
    }

    func testMalformedNumericFallbackDoesNotCorruptOtherKeys() throws {
        try writeConfig("CHECK_INTERVAL=abc\nCOOLDOWN=7\n")
        let config = loadRuntimeConfig()
        XCTAssertEqual(config.checkInterval, 300)
        XCTAssertEqual(config.cooldown, 7)
    }

    func testEnabledZeroDisables() throws {
        try writeConfig("ENABLED=0\n")
        XCTAssertFalse(loadRuntimeConfig().enabled)
    }

    func testEveryKeyIsHonored() throws {
        try writeConfig("""
        SSID=Pixel Hotspot
        CHECK_INTERVAL=42
        ENABLED=1
        COOLDOWN=7
        WIFI_INTERFACE=en5
        HOTSPOT_ROUTER=192.168.43.1
        NOTIFY=0
        """)
        let config = loadRuntimeConfig()
        XCTAssertEqual(config.ssid, "Pixel Hotspot")
        XCTAssertEqual(config.checkInterval, 42)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.cooldown, 7)
        XCTAssertEqual(config.interface, "en5")
        XCTAssertEqual(config.hotspotRouter, "192.168.43.1")
        XCTAssertFalse(config.notify)
    }

    func testEmptyValueLinesDoNotCrashTheParser() throws {
        try writeConfig("SSID=\nENABLED=\n")
        let config = loadRuntimeConfig()
        XCTAssertEqual(config.ssid, RuntimeConfig().ssid, "empty SSID keeps the default")
        XCTAssertFalse(config.enabled, "ENABLED= unconditionally applies, mirroring the shell contract")
    }

    func testCommentsAndUnknownLinesAreIgnored() throws {
        try writeConfig("# comment\nUNKNOWN=1\nSSID=Real\n\n")
        XCTAssertEqual(loadRuntimeConfig().ssid, "Real")
    }
}
