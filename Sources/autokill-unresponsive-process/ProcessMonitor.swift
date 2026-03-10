import AppKit
import Foundation

// MARK: - Private SkyLight / CoreGraphics API bindings

// The macOS Window Server tracks whether each GUI application is processing
// events from its event queue. Activity Monitor reads this state through private
// SPI in the SkyLight (or older CoreGraphics) framework. We dynamically load
// these symbols so we can do the same thing without linking against a private
// framework directly.

// We also dynamically load GetProcessForPID because modern SDKs mark it as
// unavailable in Swift, even though the symbol still exists at runtime.

private let skyLightHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
}()

private let hiServicesHandle: UnsafeMutableRawPointer? = {
    dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_LAZY
    )
}()

private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
private typealias SLSEventIsAppUnresponsiveFunc =
    @convention(c) (Int32, UnsafeMutableRawPointer) -> Bool
private typealias GetProcessForPIDFunc =
    @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus

private let _SLSMainConnectionID: SLSMainConnectionIDFunc? = {
    guard let handle = skyLightHandle,
        let sym = dlsym(handle, "SLSMainConnectionID")
    else { return nil }
    return unsafeBitCast(sym, to: SLSMainConnectionIDFunc.self)
}()

private let _SLSEventIsAppUnresponsive: SLSEventIsAppUnresponsiveFunc? = {
    guard let handle = skyLightHandle,
        let sym = dlsym(handle, "SLSEventIsAppUnresponsive")
    else { return nil }
    return unsafeBitCast(sym, to: SLSEventIsAppUnresponsiveFunc.self)
}()

// Fallback: try the older CoreGraphics names.
private let _CGSMainConnectionID: SLSMainConnectionIDFunc? = {
    guard _SLSMainConnectionID == nil else { return nil }
    guard let handle = dlopen(nil, RTLD_LAZY),
        let sym = dlsym(handle, "CGSMainConnectionID")
    else { return nil }
    return unsafeBitCast(sym, to: SLSMainConnectionIDFunc.self)
}()

private let _CGSEventIsAppUnresponsive: SLSEventIsAppUnresponsiveFunc? = {
    guard _SLSEventIsAppUnresponsive == nil else { return nil }
    guard let handle = dlopen(nil, RTLD_LAZY),
        let sym = dlsym(handle, "CGSEventIsAppUnresponsive")
    else { return nil }
    return unsafeBitCast(sym, to: SLSEventIsAppUnresponsiveFunc.self)
}()

// Dynamically loaded GetProcessForPID — marked unavailable in Swift on modern
// SDKs but the symbol is still present at runtime in HIServices / Carbon.
private let _GetProcessForPID: GetProcessForPIDFunc? = {
    // Try HIServices first (where it actually lives)
    if let handle = hiServicesHandle, let sym = dlsym(handle, "GetProcessForPID") {
        return unsafeBitCast(sym, to: GetProcessForPIDFunc.self)
    }
    // Fallback: search all loaded images
    if let handle = dlopen(nil, RTLD_LAZY), let sym = dlsym(handle, "GetProcessForPID") {
        return unsafeBitCast(sym, to: GetProcessForPIDFunc.self)
    }
    return nil
}()

// MARK: - Resolved helpers

/// Returns the Window Server connection ID for this process, or `nil` if the
/// private API is unavailable.
private func mainConnectionID() -> Int32? {
    if let f = _SLSMainConnectionID { return f() }
    if let f = _CGSMainConnectionID { return f() }
    return nil
}

/// Asks the Window Server whether the application identified by the given PID
/// is currently unresponsive.  Returns `nil` when the private API is not
/// available (so the caller can fall back to another strategy).
private func isAppUnresponsiveViaSkyLight(pid: pid_t) -> Bool? {
    guard let connID = mainConnectionID() else { return nil }
    let isUnresponsive = _SLSEventIsAppUnresponsive ?? _CGSEventIsAppUnresponsive
    guard let check = isUnresponsive else { return nil }
    guard let getProcess = _GetProcessForPID else { return nil }

    // The API wants a ProcessSerialNumber. We obtain one from the PID via the
    // (deprecated but still functional) GetProcessForPID Carbon call, loaded
    // dynamically to avoid Swift's unavailability annotation.
    //
    // ProcessSerialNumber is a simple struct of two UInt32 fields (8 bytes).
    // We allocate raw memory for it to keep things type-safe from dlsym's
    // perspective.
    let psnSize = MemoryLayout<ProcessSerialNumber>.size
    let psnPtr = UnsafeMutableRawPointer.allocate(
        byteCount: psnSize,
        alignment: MemoryLayout<ProcessSerialNumber>.alignment
    )
    defer { psnPtr.deallocate() }

    // Zero-initialize
    psnPtr.initializeMemory(as: UInt8.self, repeating: 0, count: psnSize)

    let status = getProcess(pid, psnPtr)
    guard status == noErr else { return nil }

    return check(connID, psnPtr)
}

// MARK: - Tracked Process State

/// Represents a single GUI application that we are keeping an eye on.
struct TrackedProcess: Hashable {
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String?

    /// The human-readable label we use in log messages.
    var displayName: String {
        localizedName ?? bundleIdentifier ?? "pid:\(pid)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: TrackedProcess, rhs: TrackedProcess) -> Bool {
        lhs.pid == rhs.pid
    }
}

/// The lifecycle state of an unresponsive process as tracked by the monitor.
enum UnresponsiveState {
    /// First noticed as unresponsive at the given date.
    case detected(since: Date)
    /// We already sent SIGTERM at the given date.
    case termSent(at: Date)
    /// We already sent SIGKILL – nothing more to do.
    case killSent
}

// MARK: - ProcessMonitor

/// Periodically scans for GUI applications that the Window Server considers
/// unresponsive and tracks how long they have been in that state.
final class ProcessMonitor {
    // MARK: - Properties

    private let config: Configuration
    private let log = Logger.shared

    /// Processes that are currently considered unresponsive, keyed by PID.
    private(set) var unresponsiveProcesses:
        [pid_t: (process: TrackedProcess, state: UnresponsiveState)] = [:]

    /// Whether the private SkyLight API is available on this system.
    private(set) var skyLightAvailable: Bool = false

    // MARK: - Init

    init(configuration: Configuration) {
        self.config = configuration

        // Probe once at startup so we know which detection path to use.
        skyLightAvailable =
            (mainConnectionID() != nil)
            && (_SLSEventIsAppUnresponsive != nil || _CGSEventIsAppUnresponsive != nil)

        if skyLightAvailable {
            log.info("ProcessMonitor: using SkyLight private API for responsiveness checks")
        } else {
            log.warning(
                "ProcessMonitor: SkyLight API unavailable – falling back to Apple Events timeout detection"
            )
        }
    }

    // MARK: - Public API

    /// Run a single scan cycle.  Returns an array of processes that are ready
    /// to be acted upon (i.e. they have exceeded the grace period).
    @discardableResult
    func scan() -> [ScanResult] {
        // Scan ALL running applications — not just .regular (Dock) apps.
        // Activity Monitor flags apps of any activation policy as "Not Responding"
        // (regular, accessory / UIElement, and prohibited / BackgroundOnly).
        let runningApps = NSWorkspace.shared.runningApplications
        log.debug("Scanning \(runningApps.count) running applications")

        var currentlyUnresponsivePIDs = Set<pid_t>()
        var results: [ScanResult] = []

        for app in runningApps {
            let pid = app.processIdentifier
            let tracked = TrackedProcess(
                pid: pid,
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName
            )

            // Skip excluded processes.
            if config.isExcluded(
                bundleIdentifier: tracked.bundleIdentifier, processName: tracked.displayName)
            {
                continue
            }

            // Skip processes that are currently being terminated (zombie/exiting state).
            if app.isTerminated {
                continue
            }

            let isUnresponsive = checkUnresponsive(app: app)

            guard isUnresponsive else {
                // If the app was previously tracked as unresponsive it has recovered.
                if unresponsiveProcesses.removeValue(forKey: pid) != nil {
                    log.info(
                        "\(tracked.displayName) (pid \(pid)) has recovered and is now responsive")
                    results.append(.recovered(tracked))
                }
                continue
            }

            // The app IS unresponsive right now.
            currentlyUnresponsivePIDs.insert(pid)

            if let existing = unresponsiveProcesses[pid] {
                // Already tracking – evaluate state progression.
                let result = evaluateState(tracked: tracked, state: existing.state)
                if let r = result {
                    results.append(r)
                }
            } else {
                // First time we see this process as unresponsive.
                let now = Date()
                unresponsiveProcesses[pid] = (tracked, .detected(since: now))
                log.warning(
                    "\(tracked.displayName) (pid \(pid)) is unresponsive – starting grace period")
                results.append(.detected(tracked))
            }
        }

        // Prune any tracked PIDs that are no longer running at all.
        let stalePIDs = Set(unresponsiveProcesses.keys).subtracting(
            Set(runningApps.map(\.processIdentifier))
        )
        for pid in stalePIDs {
            if let entry = unresponsiveProcesses.removeValue(forKey: pid) {
                log.info(
                    "\(entry.process.displayName) (pid \(pid)) is no longer running – removing from tracker"
                )
            }
        }

        return results
    }

    // MARK: - Detection

    /// Determines whether a given `NSRunningApplication` is unresponsive.
    /// Uses the SkyLight private API if available, otherwise falls back to
    /// Apple Events timeout detection.
    private func checkUnresponsive(app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier

        // Strategy 1: SkyLight private API (fast, in-process)
        if skyLightAvailable, let result = isAppUnresponsiveViaSkyLight(pid: pid) {
            return result
        }

        // Strategy 2: Apple Events timeout detection (slower but reliable)
        // Send a trivial Apple Event to the process with a very short timeout.
        // If the process is not responding to its event loop, the send will
        // time out, which is the exact condition Activity Monitor checks for.
        return checkUnresponsiveViaAppleEvents(pid: pid)
    }

    /// Sends a no-op Apple Event to the target process with a 2-second timeout.
    /// If the event times out the process is considered unresponsive.
    private func checkUnresponsiveViaAppleEvents(pid: pid_t) -> Bool {
        // Build an address descriptor targeting the process by PID.
        var targetPID = pid
        var addressDesc = AEDesc(descriptorType: typeNull, dataHandle: nil)
        var status: OSStatus = OSStatus(
            AECreateDesc(
                typeKernelProcessID,
                &targetPID,
                MemoryLayout<pid_t>.size,
                &addressDesc
            ))
        guard status == noErr else {
            log.debug("AECreateDesc failed for pid \(pid): \(status)")
            return false
        }
        defer { AEDisposeDesc(&addressDesc) }

        // Create a simple event — we use the AppleScript "get AETE" event which
        // every scriptable (and most non-scriptable) app handles.  The specific
        // event doesn't matter much; what matters is whether the target's event
        // loop responds at all.
        //
        // FourCharCode values:
        //   'ascr' = 0x61736372
        //   'gdut' = 0x67647574
        let kASAppleScriptSuite: AEEventClass = AEEventClass(0x6173_6372)
        let kGetAEUT: AEEventID = AEEventID(0x6764_7574)

        var event = AEDesc(descriptorType: typeNull, dataHandle: nil)
        status = OSStatus(
            AECreateAppleEvent(
                kASAppleScriptSuite,
                kGetAEUT,
                &addressDesc,
                Int16(kAutoGenerateReturnID),
                Int32(kAnyTransactionID),
                &event
            ))
        guard status == noErr else {
            log.debug("AECreateAppleEvent failed for pid \(pid): \(status)")
            return false
        }
        defer { AEDisposeDesc(&event) }

        // Send with a short timeout (in ticks; 60 ticks ≈ 1 second).
        var reply = AEDesc(descriptorType: typeNull, dataHandle: nil)
        status = AESendMessage(
            &event,
            &reply,
            Int32(kAEWaitReply),
            2 * 60  // 2 seconds in ticks
        )
        AEDisposeDesc(&reply)

        // errAETimeout (-1712) means the app didn't respond in time →
        // unresponsive.  Any other error (e.g. the app doesn't handle the
        // event) still means the event loop is alive → responsive.
        if status == errAETimeout {
            return true
        }
        return false
    }

    // MARK: - State Evaluation

    /// Checks how long the process has been unresponsive and returns an
    /// appropriate `ScanResult` if the state should progress.
    private func evaluateState(tracked: TrackedProcess, state: UnresponsiveState) -> ScanResult? {
        let now = Date()

        switch state {
        case .detected(let since):
            let elapsed = now.timeIntervalSince(since)
            if elapsed >= config.graceBeforeTermSeconds {
                log.warning(
                    "\(tracked.displayName) (pid \(tracked.pid)) has been unresponsive for "
                        + "\(Int(elapsed))s – recommending SIGTERM"
                )
                return .shouldTerminate(tracked)
            }
            // Still within grace period – no action yet.
            log.debug(
                "\(tracked.displayName) (pid \(tracked.pid)) still unresponsive "
                    + "(\(Int(elapsed))s / \(Int(config.graceBeforeTermSeconds))s grace)"
            )
            return nil

        case .termSent(let at):
            let elapsed = now.timeIntervalSince(at)
            if elapsed >= config.graceBeforeKillSeconds {
                log.error(
                    "\(tracked.displayName) (pid \(tracked.pid)) did not exit after SIGTERM "
                        + "(\(Int(elapsed))s) – recommending SIGKILL"
                )
                return .shouldKill(tracked)
            }
            log.debug(
                "\(tracked.displayName) (pid \(tracked.pid)) waiting for SIGTERM to take effect "
                    + "(\(Int(elapsed))s / \(Int(config.graceBeforeKillSeconds))s)"
            )
            return nil

        case .killSent:
            // Nothing more we can do.
            return nil
        }
    }

    // MARK: - State Mutation (called by ProcessKiller after acting)

    /// Updates the internal state after a SIGTERM has been sent.
    func markTermSent(pid: pid_t) {
        guard var entry = unresponsiveProcesses[pid] else { return }
        entry.state = .termSent(at: Date())
        unresponsiveProcesses[pid] = entry
    }

    /// Updates the internal state after a SIGKILL has been sent.
    func markKillSent(pid: pid_t) {
        guard var entry = unresponsiveProcesses[pid] else { return }
        entry.state = .killSent
        unresponsiveProcesses[pid] = entry
    }

    /// Removes a process from tracking entirely (e.g. after confirmed death).
    func removeTracking(pid: pid_t) {
        unresponsiveProcesses.removeValue(forKey: pid)
    }
}

// MARK: - Scan Result

/// The outcome for a single process after a scan cycle.
enum ScanResult {
    /// Process was just noticed as unresponsive (grace period started).
    case detected(TrackedProcess)

    /// Process was previously unresponsive but is now responding again.
    case recovered(TrackedProcess)

    /// Process has exceeded the grace period and should receive SIGTERM.
    case shouldTerminate(TrackedProcess)

    /// Process did not exit after SIGTERM and should receive SIGKILL.
    case shouldKill(TrackedProcess)

    var process: TrackedProcess {
        switch self {
        case .detected(let p), .recovered(let p), .shouldTerminate(let p), .shouldKill(let p):
            return p
        }
    }
}
