import Foundation
import os

/// A lightweight logger that writes to both Apple's unified logging system (`os_log`)
/// and a rotating log file on disk.
final class Logger {
    // MARK: - Types

    enum Level: String, Comparable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rank < rhs.rank
        }

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    // MARK: - Properties

    static let shared = Logger()

    /// Minimum level that will be emitted. Messages below this are discarded.
    var minimumLevel: Level = .info

    /// Whether stderr is connected to a terminal (TTY).
    /// When true, log messages are also printed to stderr for interactive use.
    private let isInteractive: Bool = isatty(STDERR_FILENO) != 0

    private let osLogger = os.Logger(
        subsystem: "com.autokill.unresponsive",
        category: "daemon"
    )

    private let logDirectory: String
    private let maxLogFileSize: UInt64 = 5 * 1024 * 1024  // 5 MB
    private let maxRotatedFiles: Int = 3
    private let logFileName = "autokill.log"

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.autokill.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    // MARK: - Lifecycle

    private init() {
        self.logDirectory = Configuration.logDirectoryPath
        ensureLogDirectory()
        openLogFile()
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public API

    func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.debug, message(), file: file, line: line)
    }

    func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.info, message(), file: file, line: line)
    }

    func warning(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.warning, message(), file: file, line: line)
    }

    func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.error, message(), file: file, line: line)
    }

    // MARK: - Core

    private func log(_ level: Level, _ message: String, file: String, line: Int) {
        guard level >= minimumLevel else { return }

        let timestamp = dateFormatter.string(from: Date())
        let sourceLocation = "\(file):\(line)"
        let formattedMessage = "[\(timestamp)] [\(level.rawValue)] [\(sourceLocation)] \(message)"

        // Always write to unified log
        switch level {
        case .debug:
            osLogger.debug("\(message, privacy: .public)")
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .warning:
            osLogger.warning("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        }

        // Print to stderr when running interactively so the user sees output
        if isInteractive {
            let prefix: String
            switch level {
            case .debug: prefix = "🔍"
            case .info: prefix = "ℹ️ "
            case .warning: prefix = "⚠️ "
            case .error: prefix = "🛑"
            }
            fputs("\(prefix) \(formattedMessage)\n", stderr)
        }

        // Write to file asynchronously
        queue.async { [weak self] in
            self?.writeToFile(formattedMessage)
        }
    }

    // MARK: - File Management

    private var logFilePath: String {
        return (logDirectory as NSString).appendingPathComponent(logFileName)
    }

    private func ensureLogDirectory() {
        if !fileManager.fileExists(atPath: logDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: logDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                // Fall back to stderr; nothing else we can do.
                fputs("[Logger] Failed to create log directory \(logDirectory): \(error)\n", stderr)
            }
        }
    }

    private func openLogFile() {
        let path = logFilePath

        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil, attributes: nil)
        }

        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }

        // Check if rotation is needed before writing
        rotateIfNeeded()

        fileHandle?.write(data)

        // Flush on every write so that logs aren't lost on crash.
        // The performance cost is negligible given our low write frequency.
        fileHandle?.synchronizeFile()
    }

    // MARK: - Log Rotation

    private func rotateIfNeeded() {
        let path = logFilePath

        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
            let size = attrs[.size] as? UInt64,
            size >= maxLogFileSize
        else {
            return
        }

        // Close the current handle
        fileHandle?.closeFile()
        fileHandle = nil

        // Shift existing rotated logs:  .3 → delete,  .2 → .3,  .1 → .2,  current → .1
        for i in stride(from: maxRotatedFiles, through: 1, by: -1) {
            let src = "\(path).\(i)"
            if i == maxRotatedFiles {
                try? fileManager.removeItem(atPath: src)
            } else {
                let dst = "\(path).\(i + 1)"
                try? fileManager.moveItem(atPath: src, toPath: dst)
            }
        }

        // Rotate the current file to .1
        let rotatedPath = "\(path).1"
        do {
            try fileManager.moveItem(atPath: path, toPath: rotatedPath)
        } catch {
            fputs("[Logger] Failed to rotate log file: \(error)\n", stderr)
        }

        // Open a fresh log file
        fileManager.createFile(atPath: path, contents: nil, attributes: nil)
        openLogFile()
    }

    // MARK: - Utility

    /// Flush any pending writes. Useful before exit.
    func flush() {
        queue.sync {
            fileHandle?.synchronizeFile()
        }
    }
}
