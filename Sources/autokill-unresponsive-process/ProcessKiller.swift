import AppKit
import Foundation
import UserNotifications

/// Responsible for actually terminating unresponsive processes and notifying
/// the user about what happened.
///
/// This type works hand-in-hand with `ProcessMonitor`: the monitor decides
/// *what* to do and `ProcessKiller` carries it out, updating the monitor's
/// internal bookkeeping afterwards.
final class ProcessKiller {
    // MARK: - Properties

    private let config: Configuration
    private let log = Logger.shared

    /// Running tally of kills performed in the current scan cycle.
    private(set) var killsThisCycle: Int = 0

    // MARK: - Init

    init(configuration: Configuration) {
        self.config = configuration
    }

    // MARK: - Public API

    /// Resets the per-cycle kill counter. Call this at the start of every scan.
    func resetCycleCounter() {
        killsThisCycle = 0
    }

    /// Processes an array of `ScanResult`s produced by `ProcessMonitor.scan()`
    /// and performs the appropriate action for each one.
    func handle(results: [ScanResult], monitor: ProcessMonitor) {
        for result in results {
            switch result {
            case .detected:
                // Nothing to do yet – the monitor is tracking the grace period.
                break

            case .recovered:
                // The process recovered on its own; no action needed.
                break

            case .shouldTerminate(let process):
                guard killsThisCycle < config.maxKillsPerCycle else {
                    log.warning(
                        "Kill cap reached (\(config.maxKillsPerCycle)/cycle) – "
                            + "skipping SIGTERM for \(process.displayName) (pid \(process.pid))"
                    )
                    continue
                }
                sendTerm(process: process, monitor: monitor)

            case .shouldKill(let process):
                guard killsThisCycle < config.maxKillsPerCycle else {
                    log.warning(
                        "Kill cap reached (\(config.maxKillsPerCycle)/cycle) – "
                            + "skipping SIGKILL for \(process.displayName) (pid \(process.pid))"
                    )
                    continue
                }
                sendKill(process: process, monitor: monitor)
            }
        }
    }

    // MARK: - Signal Delivery

    /// Sends SIGTERM (graceful termination) to the process.
    private func sendTerm(process: TrackedProcess, monitor: ProcessMonitor) {
        let pid = process.pid
        let name = process.displayName

        if config.dryRun {
            log.info("[DRY RUN] Would send SIGTERM to \(name) (pid \(pid))")
            monitor.markTermSent(pid: pid)
            return
        }

        log.warning("Sending SIGTERM to \(name) (pid \(pid))")

        // Prefer NSRunningApplication.terminate() because it goes through the
        // standard Cocoa application lifecycle (the app gets a chance to save
        // state, run atexit handlers, etc.).  Fall back to raw kill(2) if the
        // Cocoa path is unavailable.
        let cocoaApp = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == pid
        }

        var sent = false
        if let app = cocoaApp {
            sent = app.terminate()
        }

        if !sent {
            // Raw POSIX signal.
            let result = kill(pid, SIGTERM)
            if result != 0 {
                let err = String(cString: strerror(errno))
                log.error("Failed to send SIGTERM to \(name) (pid \(pid)): \(err)")
                return
            }
        }

        monitor.markTermSent(pid: pid)
        killsThisCycle += 1

        if config.notifyOnKill {
            postNotification(
                title: "Terminating Unresponsive App",
                body: "\(name) (pid \(pid)) is not responding and was sent a termination signal."
            )
        }
    }

    /// Sends SIGKILL (forceful, non-catchable) to the process.
    private func sendKill(process: TrackedProcess, monitor: ProcessMonitor) {
        let pid = process.pid
        let name = process.displayName

        if config.dryRun {
            log.info("[DRY RUN] Would send SIGKILL to \(name) (pid \(pid))")
            monitor.markKillSent(pid: pid)
            return
        }

        log.error("Sending SIGKILL to \(name) (pid \(pid))")

        // Try the Cocoa API first (forceTerminate), then fall back to kill(2).
        let cocoaApp = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == pid
        }

        var sent = false
        if let app = cocoaApp {
            sent = app.forceTerminate()
        }

        if !sent {
            let result = kill(pid, SIGKILL)
            if result != 0 {
                let err = String(cString: strerror(errno))
                log.error("Failed to send SIGKILL to \(name) (pid \(pid)): \(err)")
                return
            }
        }

        monitor.markKillSent(pid: pid)
        killsThisCycle += 1

        // Schedule cleanup – the process should be gone very shortly after SIGKILL.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            monitor.removeTracking(pid: pid)
        }

        if config.notifyOnKill {
            postNotification(
                title: "Force-Killed Unresponsive App",
                body: "\(name) (pid \(pid)) did not respond to termination and was force-killed."
            )
        }
    }

    // MARK: - User Notifications

    /// Posts a macOS user notification so the user knows what the daemon did.
    private func postNotification(title: String, body: String) {
        // We use the legacy NSUserNotification-style approach via
        // DistributedNotificationCenter for broad compatibility. However, the
        // modern way is UNUserNotificationCenter.  Because we are a background
        // daemon (no UI), we use a pragmatic approach: shell out to
        // `osascript` which can display a notification without any entitlements.
        let script = """
            display notification "\(escapeForAppleScript(body))" \
            with title "\(escapeForAppleScript(title))"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.debug(
                "Failed to post user notification via osascript: \(error.localizedDescription)")
        }
    }

    /// Minimal escaping so that arbitrary process names don't break the
    /// AppleScript string literal.
    private func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
