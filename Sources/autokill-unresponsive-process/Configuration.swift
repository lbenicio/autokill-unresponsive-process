import Foundation

/// Central configuration for the autokill daemon.
/// Values can be overridden via environment variables or a JSON config file.
struct Configuration {
    // MARK: - Timing

    /// How often (in seconds) to scan for unresponsive processes.
    var checkIntervalSeconds: TimeInterval = 10

    /// How long (in seconds) a process must remain continuously unresponsive
    /// before we attempt to terminate it gracefully (SIGTERM).
    var graceBeforeTermSeconds: TimeInterval = 30

    /// How long (in seconds) to wait after SIGTERM before escalating to SIGKILL.
    var graceBeforeKillSeconds: TimeInterval = 10

    // MARK: - Behaviour

    /// If `true`, the daemon only logs what it *would* do without actually killing anything.
    var dryRun: Bool = false

    /// If `true`, send a macOS notification when a process is killed.
    var notifyOnKill: Bool = true

    /// Maximum number of processes to kill in a single scan cycle (safety valve).
    var maxKillsPerCycle: Int = 5

    // MARK: - Exclusions

    /// Bundle identifiers that must never be killed, no matter what.
    /// These are critical system components whose termination could crash the session.
    var excludedBundleIdentifiers: Set<String> = [
        // Core session processes — killing these crashes/logs out the session
        "com.apple.loginwindow",
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.WindowManager",
        "com.apple.SystemUIServer",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.universalcontrol",
        "com.apple.AirPlayUIAgent",
        "com.apple.TextInputMenuAgent",

        // System XPC services and background agents that can falsely appear
        // unresponsive because they don't maintain a normal event loop
        "com.apple.hiservices-xpcservice",
        "com.apple.ViewBridgeAuxiliary",
        "com.apple.UIKitSystemApp",
        "com.apple.coreservices.uiagent",
        "com.apple.AccessibilityUIServer",
        "com.apple.talagent",
        "com.apple.CoreLocationAgent",
        "com.apple.RemoteDesktopAgent",
        "com.apple.chronod",
        "com.apple.SSMenuAgent",
        "com.apple.security.Keychain-Circle-Notification",
        "com.apple.inputmethod",
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.Networking",
        "com.apple.WebKit.GPU",
    ]

    /// Process names that must never be killed.
    /// Used as a fallback when a process has no bundle identifier.
    var excludedProcessNames: Set<String> = [
        "loginwindow",
        "Dock",
        "Finder",
        "WindowManager",
        "SystemUIServer",
        "Control Center",
        "NotificationCenter",
        "Spotlight",
        // System XPC / background agents (fallback by name)
        "hiservices-xpcservice",
        "ViewBridgeAuxiliary",
        "UIKitSystem",
        "CoreServicesUIAgent",
        "AccessibilityUIServer",
        "talagentd",
        "CoreLocationAgent",
        "ARDAgent",
        "chronod",
        "SSMenuAgent",
        "Keychain Circle Notification",
    ]

    // MARK: - Paths

    /// Path to a JSON configuration file that can override these defaults.
    static let configFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/autokill-unresponsive/config.json"
    }()

    /// Path to the log file.
    static let logDirectoryPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/log/autokill-unresponsive"
    }()

    // MARK: - Loading

    /// Loads configuration by layering: defaults → config file → environment variables.
    static func load() -> Configuration {
        var config = Configuration()

        // Layer 1: JSON config file (if it exists)
        config.loadFromFile()

        // Layer 2: Environment variable overrides
        config.loadFromEnvironment()

        return config
    }

    // MARK: - Private helpers

    private mutating func loadFromFile() {
        let path = Self.configFilePath
        guard FileManager.default.fileExists(atPath: path),
            let data = FileManager.default.contents(atPath: path)
        else {
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[config] Warning: could not parse config file at \(path)")
            return
        }

        if let v = json["checkIntervalSeconds"] as? TimeInterval { checkIntervalSeconds = v }
        if let v = json["graceBeforeTermSeconds"] as? TimeInterval { graceBeforeTermSeconds = v }
        if let v = json["graceBeforeKillSeconds"] as? TimeInterval { graceBeforeKillSeconds = v }
        if let v = json["dryRun"] as? Bool { dryRun = v }
        if let v = json["notifyOnKill"] as? Bool { notifyOnKill = v }
        if let v = json["maxKillsPerCycle"] as? Int { maxKillsPerCycle = v }

        if let arr = json["excludedBundleIdentifiers"] as? [String] {
            excludedBundleIdentifiers.formUnion(arr)
        }
        if let arr = json["excludedProcessNames"] as? [String] {
            excludedProcessNames.formUnion(arr)
        }
    }

    private mutating func loadFromEnvironment() {
        if let v = env("AUTOKILL_CHECK_INTERVAL") { checkIntervalSeconds = v }
        if let v = env("AUTOKILL_GRACE_TERM") { graceBeforeTermSeconds = v }
        if let v = env("AUTOKILL_GRACE_KILL") { graceBeforeKillSeconds = v }
        if let v = envBool("AUTOKILL_DRY_RUN") { dryRun = v }
        if let v = envBool("AUTOKILL_NOTIFY") { notifyOnKill = v }
        if let v = envInt("AUTOKILL_MAX_KILLS") { maxKillsPerCycle = v }
    }

    private func env(_ key: String) -> TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment[key],
            let val = TimeInterval(raw)
        else { return nil }
        return val
    }

    private func envBool(_ key: String) -> Bool? {
        guard let raw = ProcessInfo.processInfo.environment[key]?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private func envInt(_ key: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        return Int(raw)
    }

    // MARK: - Queries

    /// Returns `true` if the given process should never be killed.
    func isExcluded(bundleIdentifier: String?, processName: String) -> Bool {
        if let bid = bundleIdentifier, excludedBundleIdentifiers.contains(bid) {
            return true
        }
        if excludedProcessNames.contains(processName) {
            return true
        }
        return false
    }
}

extension Configuration: CustomStringConvertible {
    var description: String {
        """
        Configuration:
          checkIntervalSeconds : \(checkIntervalSeconds)
          graceBeforeTermSeconds: \(graceBeforeTermSeconds)
          graceBeforeKillSeconds: \(graceBeforeKillSeconds)
          dryRun               : \(dryRun)
          notifyOnKill         : \(notifyOnKill)
          maxKillsPerCycle     : \(maxKillsPerCycle)
          excludedBundleIDs    : \(excludedBundleIdentifiers.sorted().joined(separator: ", "))
          excludedProcessNames : \(excludedProcessNames.sorted().joined(separator: ", "))
        """
    }
}
