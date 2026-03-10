import AppKit
import Foundation

// MARK: - Version

let kVersion = "1.0.0"

// MARK: - CLI Flags

enum CLIFlag: String {
    case help = "--help"
    case helpShort = "-h"
    case version = "--version"
    case versionShort = "-v"
    case dryRun = "--dry-run"
    case verbose = "--verbose"
    case once = "--once"
    case interval = "--interval"
    case graceTerm = "--grace-term"
    case graceKill = "--grace-kill"
    case noNotify = "--no-notify"
    case maxKills = "--max-kills"
}

func printUsage() {
    let usage = """
        autokill-unresponsive-process v\(kVersion)

        A background daemon that monitors macOS for unresponsive GUI applications
        (the same "Not Responding" state shown in Activity Monitor) and kills them
        after a configurable grace period.

        USAGE:
            autokill-unresponsive-process [OPTIONS]

        OPTIONS:
            -h, --help              Print this help message and exit
            -v, --version           Print version and exit
            --dry-run               Log what would be done without actually killing anything
            --verbose               Enable debug-level logging
            --once                  Run a single scan cycle and exit (useful for testing)
            --interval <seconds>    Override scan interval (default: 10)
            --grace-term <seconds>  Seconds before sending SIGTERM (default: 30)
            --grace-kill <seconds>  Seconds after SIGTERM before SIGKILL (default: 10)
            --no-notify             Disable macOS user notifications on kill
            --max-kills <count>     Max processes to kill per scan cycle (default: 5)

        CONFIGURATION:
            The daemon reads configuration from (in order of precedence):
              1. Command-line flags (highest)
              2. Environment variables (AUTOKILL_CHECK_INTERVAL, AUTOKILL_DRY_RUN, etc.)
              3. JSON config file at ~/.config/autokill-unresponsive/config.json
              4. Built-in defaults (lowest)

        ENVIRONMENT VARIABLES:
            AUTOKILL_CHECK_INTERVAL   Scan interval in seconds
            AUTOKILL_GRACE_TERM       Grace period before SIGTERM in seconds
            AUTOKILL_GRACE_KILL       Grace period before SIGKILL in seconds
            AUTOKILL_DRY_RUN          Set to 1/true/yes to enable dry-run mode
            AUTOKILL_NOTIFY           Set to 0/false/no to disable notifications
            AUTOKILL_MAX_KILLS        Max kills per scan cycle

        INSTALL AS DAEMON:
            Use the provided install.sh script to register a launchd agent that
            starts automatically on login.

        """
    print(usage)
}

func printVersion() {
    print("autokill-unresponsive-process v\(kVersion)")
}

// MARK: - Argument Parsing

func parseArguments() -> Configuration {
    var config = Configuration.load()
    let args = CommandLine.arguments

    var i = 1  // skip argv[0]
    while i < args.count {
        let arg = args[i]

        switch arg {
        case CLIFlag.help.rawValue, CLIFlag.helpShort.rawValue:
            printUsage()
            exit(0)

        case CLIFlag.version.rawValue, CLIFlag.versionShort.rawValue:
            printVersion()
            exit(0)

        case CLIFlag.dryRun.rawValue:
            config.dryRun = true

        case CLIFlag.verbose.rawValue:
            Logger.shared.minimumLevel = .debug

        case CLIFlag.once.rawValue:
            // Handled later in the run loop; we just set a flag via UserDefaults
            // or a simpler approach: global variable.
            runOnce = true

        case CLIFlag.noNotify.rawValue:
            config.notifyOnKill = false

        case CLIFlag.interval.rawValue:
            i += 1
            guard i < args.count, let val = TimeInterval(args[i]) else {
                fputs("Error: --interval requires a numeric value\n", stderr)
                exit(1)
            }
            config.checkIntervalSeconds = val

        case CLIFlag.graceTerm.rawValue:
            i += 1
            guard i < args.count, let val = TimeInterval(args[i]) else {
                fputs("Error: --grace-term requires a numeric value\n", stderr)
                exit(1)
            }
            config.graceBeforeTermSeconds = val

        case CLIFlag.graceKill.rawValue:
            i += 1
            guard i < args.count, let val = TimeInterval(args[i]) else {
                fputs("Error: --grace-kill requires a numeric value\n", stderr)
                exit(1)
            }
            config.graceBeforeKillSeconds = val

        case CLIFlag.maxKills.rawValue:
            i += 1
            guard i < args.count, let val = Int(args[i]) else {
                fputs("Error: --max-kills requires an integer value\n", stderr)
                exit(1)
            }
            config.maxKillsPerCycle = val

        default:
            fputs("Unknown option: \(arg)\nRun with --help for usage information.\n", stderr)
            exit(1)
        }

        i += 1
    }

    return config
}

// MARK: - Signal Handling

/// Atomic flag that the signal handler sets to request a clean shutdown.
private var shutdownRequested = false

/// Atomic flag that the signal handler sets to request a configuration reload.
private var reloadRequested = false

func installSignalHandlers() {
    // SIGTERM / SIGINT → graceful shutdown
    let termHandler: @convention(c) (Int32) -> Void = { sig in
        shutdownRequested = true
    }
    signal(SIGTERM, termHandler)
    signal(SIGINT, termHandler)

    // SIGHUP → reload configuration
    let hupHandler: @convention(c) (Int32) -> Void = { _ in
        reloadRequested = true
    }
    signal(SIGHUP, hupHandler)
}

// MARK: - Global State

/// When `true`, the daemon performs a single scan cycle and exits.
var runOnce = false

// MARK: - Main Entry Point

let log = Logger.shared

log.info("autokill-unresponsive-process v\(kVersion) starting up")

// Parse configuration from file → env → CLI flags.
var config = parseArguments()

log.info("\(config)")

if config.dryRun {
    log.warning("Running in DRY RUN mode – no processes will actually be killed")
}

// Install signal handlers for graceful shutdown and config reload.
installSignalHandlers()

// Create the core components.
var monitor = ProcessMonitor(configuration: config)
var killer = ProcessKiller(configuration: config)

log.info(
    "Daemon ready. Scanning every \(Int(config.checkIntervalSeconds))s. "
        + "Grace: \(Int(config.graceBeforeTermSeconds))s SIGTERM, "
        + "\(Int(config.graceBeforeKillSeconds))s SIGKILL."
)

// MARK: - Scan Loop

/// Performs a single scan-and-act cycle.
func performScanCycle() {
    killer.resetCycleCounter()

    let results = monitor.scan()

    if !results.isEmpty {
        let summary = results.map { result -> String in
            switch result {
            case .detected(let p):
                return "  ⏳ \(p.displayName) (pid \(p.pid)) — detected as unresponsive"
            case .recovered(let p):
                return "  ✅ \(p.displayName) (pid \(p.pid)) — recovered"
            case .shouldTerminate(let p):
                return "  ⚠️  \(p.displayName) (pid \(p.pid)) — sending SIGTERM"
            case .shouldKill(let p):
                return "  🛑 \(p.displayName) (pid \(p.pid)) — sending SIGKILL"
            }
        }.joined(separator: "\n")
        log.info("Scan results:\n\(summary)")
    }

    killer.handle(results: results, monitor: monitor)
}

if runOnce {
    // Single-shot mode: scan once and exit.
    log.info("Running in --once mode: performing a single scan cycle")
    performScanCycle()

    let tracked = monitor.unresponsiveProcesses
    if tracked.isEmpty {
        log.info("No unresponsive processes found.")
    } else {
        log.info("Currently tracking \(tracked.count) unresponsive process(es).")
    }

    log.info("Single scan complete. Exiting.")
    Logger.shared.flush()
    exit(0)
}

// MARK: - Timer-Based Run Loop (Daemon Mode)

// We use a GCD timer on the main queue so that `NSWorkspace.shared` and other
// AppKit/Cocoa APIs (which must be called from the main thread) work correctly.
// The RunLoop is pumped by `dispatchMain()` / `RunLoop.current.run()`.

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(
    deadline: .now() + config.checkIntervalSeconds,
    repeating: config.checkIntervalSeconds,
    leeway: .seconds(1)
)
timer.setEventHandler {
    // Check for shutdown request from signal handler.
    if shutdownRequested {
        log.info("Shutdown signal received. Cleaning up...")
        timer.cancel()
        Logger.shared.flush()
        exit(0)
    }

    // Check for config reload request (SIGHUP).
    if reloadRequested {
        reloadRequested = false
        log.info("SIGHUP received – reloading configuration")
        config = Configuration.load()
        monitor = ProcessMonitor(configuration: config)
        killer = ProcessKiller(configuration: config)
        log.info("Configuration reloaded:\n\(config)")

        // Reschedule the timer if the interval changed.
        timer.schedule(
            deadline: .now() + config.checkIntervalSeconds,
            repeating: config.checkIntervalSeconds,
            leeway: .seconds(1)
        )
    }

    performScanCycle()
}

timer.resume()

// Also perform an immediate first scan so we don't wait for the first interval.
DispatchQueue.main.async {
    log.info("Performing initial scan...")
    performScanCycle()
}

log.info("Daemon entering run loop")

// Keep the process alive. RunLoop.current.run() on the main thread pumps
// both RunLoop sources and GCD/libdispatch sources.
RunLoop.current.run()

// This line is technically unreachable, but serves as a safety net.
dispatchMain()
