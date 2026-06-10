import Foundation

#if canImport(os)
import os
#endif

/// Severity levels used by ``FBLogger``.
public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
    case none = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Minimal logging facade for the SDK, replacing the .NET SDK's `ILoggerFactory`.
///
/// Provide your own implementation via ``FBOptions/Builder/logger(_:)`` to forward SDK logs into
/// your app's logging pipeline. The `debug` message is supplied as a closure so that no string is
/// built when debug logging is disabled.
public protocol FBLogger: Sendable {
    func debug(_ message: () -> String)
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String, _ error: Error?)
}

public extension FBLogger {
    func error(_ message: String) { error(message, nil) }
}

/// A logger that discards all messages.
public struct NoOpLogger: FBLogger {
    public init() {}
    public func debug(_ message: () -> String) {}
    public func info(_ message: String) {}
    public func warn(_ message: String) {}
    public func error(_ message: String, _ error: Error?) {}
}

/// Default ``FBLogger`` that writes to the unified logging system (`os.Logger`/`OSLog`) on Apple
/// platforms, falling back to standard streams elsewhere (e.g. Linux). Messages below `minLevel`
/// are dropped.
public struct DefaultLogger: FBLogger {
    private let subsystem: String
    private let minLevel: LogLevel

    public init(subsystem: String = "co.featbit", minLevel: LogLevel = .info) {
        self.subsystem = subsystem
        self.minLevel = minLevel
    }

    private func enabled(_ level: LogLevel) -> Bool { level >= minLevel }

    public func debug(_ message: () -> String) {
        guard enabled(.debug) else { return }
        write(.debug, message())
    }

    public func info(_ message: String) {
        guard enabled(.info) else { return }
        write(.info, message)
    }

    public func warn(_ message: String) {
        guard enabled(.warn) else { return }
        write(.warn, message)
    }

    public func error(_ message: String, _ error: Error?) {
        guard enabled(.error) else { return }
        if let error {
            write(.error, "\(message) — \(error)")
        } else {
            write(.error, message)
        }
    }

    private func write(_ level: LogLevel, _ message: String) {
        #if canImport(os)
        let logger = os.Logger(subsystem: subsystem, category: "FeatBit")
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .none: break
        }
        #else
        let prefix: String
        switch level {
        case .debug: prefix = "DEBUG"
        case .info: prefix = "INFO"
        case .warn: prefix = "WARN"
        case .error: prefix = "ERROR"
        case .none: return
        }
        if level >= .warn {
            FileHandle.standardError.write(Data("[FeatBit] \(prefix): \(message)\n".utf8))
        } else {
            print("[FeatBit] \(prefix): \(message)")
        }
        #endif
    }
}
