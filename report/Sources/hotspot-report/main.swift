import Foundation
import HotspotReport

// hotspot-report — a read-only diagnostics reporter for the mac-auto-hotspot
// controller stack. It observes exactly the files the controller itself
// binds (config, agent.status, shared log, state dir, install paths) and
// binds each field to an explicit present/missing/stale/malformed state with
// the effective value the controller would compute. It never writes to
// anything it reads, never probes the network, and never runs the
// controller.

let usage = """
hotspot-report — read-only diagnostics for the auto-hotspot stack

USAGE:
  hotspot-report [summary] [--clock=<iso8601>] [--json|--markdown]
  hotspot-report bundle --output=<dir> [--redacted=false] [--clock=<iso8601>]
  hotspot-report --version

SUBCOMMANDS:
  summary (default)  Read every input, bind fields, print the report
  bundle             Also write report.json + log.tail.txt + manifest.txt

FLAGS:
  --clock=<iso8601>  Fixed capture instant, e.g. 2026-10-11T04:31:00Z
                     (deterministic replay; otherwise the wall clock)
  --json             Machine-readable report (schema auto-hotspot.report/1)
  --markdown         Human-readable report
  --output=<dir>     Bundle destination directory
  --redacted=false   Bundle only: include unredacted log prose (default:
                     SSIDs redacted; unclassifiable lines never exported)

INPUT BINDING (same paths the controller uses):
  $AUTO_HOTSPOT_CONFIG or ~/.config/auto-hotspot/config
  $AUTO_HOTSPOT_LOG    or ~/Library/Logs/auto-hotspot.log
  $AUTO_HOTSPOT_STATE  or ~/.local/state/auto-hotspot
  Install paths are $HOME-derived (no override), matching bin/hotspotd.

SAFETY: read-only on all inputs. No network probes. Default outputs are
redacted (SSID -> REDACTED, no log prose). The bundle is the explicit opt-in.

KNOWN LIMITS: rotated log (.1) is noted but not read; no live Wi-Fi state
beyond what the agent already recorded; on non-macOS hosts, install-path
checks reflect the filesystem as mounted, not launchd reality.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

func parseClock(_ flagValue: String?) throws -> ReportClock {
    guard let v = flagValue else { return .live() }
    guard let clock = ReportClock.fixed(iso8601: v) else {
        throw CLIError(description: "invalid --clock value: expected 2026-10-11T04:31:00Z or 2026-10-11T06:31:00+0200")
    }
    return clock
}

// Minimal flag parser: no dependencies, explicit errors on unknown flags.
func parseArgs(_ args: [String]) throws -> (subcommand: String, flags: [String: String]) {
    var subcommand: String?
    var flags: [String: String] = [:]
    for arg in args {
        if arg.hasPrefix("--") {
            let body = String(arg.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
            } else {
                flags[body] = ""
            }
        } else {
            if subcommand != nil {
                throw CLIError(description: "unexpected extra argument: \(arg)")
            }
            subcommand = arg
        }
    }
    let knownFlags: Set<String> = ["clock", "json", "markdown", "output", "redacted", "help", "version"]
    for f in flags.keys where !knownFlags.contains(f) {
        throw CLIError(description: "unknown flag --\(f)")
    }
    return (subcommand ?? "summary", flags)
}

func envDictionary() -> [String: String] {
    // Use getenv for the handful of variables we bind — ProcessInfo.environ
    // ordering/content varies more than we need, and getenv is exact.
    var out: [String: String] = [:]
    for key in ["HOME", "AUTO_HOTSPOT_CONFIG", "AUTO_HOTSPOT_LOG", "AUTO_HOTSPOT_STATE"] {
        if let v = getenv(key) {
            out[key] = String(cString: v)
        }
    }
    return out
}

func run() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        let (subcommand, flags) = try parseArgs(args)

        if flags["help"] != nil {
            print(usage)
            return 0
        }
        if flags["version"] != nil {
            print("hotspot-report 0.1.0 (report schema auto-hotspot.report/1)")
            return 0
        }

        let clock = try parseClock(flags["clock"])
        let inputs = ReportInputs.fromEnvironment(envDictionary())
        let summary = InputSummary.collect(inputs: inputs, clock: clock)

        switch subcommand {
        case "summary":
            if flags["json"] != nil {
                FileHandle.standardOutput.write(serialize(summary))
            } else if flags["markdown"] != nil {
                print(renderMarkdown(summary))
            } else {
                print(renderTerminal(summary))
            }
            return 0
        case "bundle":
            guard let dest = flags["output"], !dest.isEmpty else {
                throw CLIError(description: "bundle requires --output=<dir>")
            }
            var redacted = true
            if let r = flags["redacted"] {
                switch r {
                case "false": redacted = false
                case "true": redacted = true
                default: throw CLIError(description: "--redacted accepts true or false")
                }
            }
            let result = try writeBundle(summary, to: dest, redacted: redacted)
            print("bundle written to \(result.dir) (redacted: \(result.redacted))")
            for f in result.files {
                print("  \(f)")
            }
            return 0
        default:
            throw CLIError(description: "unknown subcommand: \(subcommand)")
        }
    } catch let e as CLIError {
        FileHandle.standardError.write(Data("error: \(e.description)\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 2
    }
}



// Entry point: exit codes 0 (report written), 2 (usage/parse error).
exit(run())
