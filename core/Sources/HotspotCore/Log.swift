import Foundation

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

public func wifiLog(_ level: String, _ message: String) {
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
