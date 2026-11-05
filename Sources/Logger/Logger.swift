import Foundation
import SwiftyBeaver

public final class SwiftyBeaverLogger: @unchecked Sendable {
    public let isDebugEnabled: Bool
    public let logFileURL: URL
    private let destination: RotatingFileDestination

    public convenience init() {
        let process = ProcessInfo.processInfo
        self.init(
            logFileURL: URL(fileURLWithPath: "/tmp/sourcekit-bsp/\(process.processIdentifier).log"),
            debugEnabled: Self.debugEnabled(environment: process.environment, arguments: process.arguments)
        )
    }

    init(logFileURL: URL, debugEnabled: Bool) {
        self.logFileURL = logFileURL
        self.isDebugEnabled = debugEnabled
        self.destination = RotatingFileDestination(url: logFileURL)
    }

    static func debugEnabled(environment: [String: String], arguments: [String]) -> Bool {
        arguments.contains("--debug") || ["1", "true", "yes", "on"]
            .contains(environment["BSP_DEBUG"]?.lowercased() ?? "")
    }

    public func info(
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        write(
            .info,
            message: message(),
            location: Location(file: file, function: function, line: line),
            context: context
        )
    }

    public func debug(
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        guard isDebugEnabled else { return }
        write(
            .debug,
            message: message(),
            location: Location(file: file, function: function, line: line),
            context: context
        )
    }

    public func error(
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        write(
            .error,
            message: message(),
            location: Location(file: file, function: function, line: line),
            context: context
        )
    }

    public func warning(
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        write(
            .warning,
            message: message(),
            location: Location(file: file, function: function, line: line),
            context: context
        )
    }

    public func flush() {
        destination.execute(synchronously: true) {}
    }

    private struct Location {
        let file: String
        let function: String
        let line: Int
    }

    private func write(
        _ level: SwiftyBeaver.Level,
        message: String,
        location: Location,
        context: Any?
    ) {
        let destination = self.destination
        destination.execute(synchronously: false) {
            _ = destination.send(
                level,
                msg: message,
                thread: "",
                file: location.file,
                function: location.function,
                line: location.line,
                context: context
            )
        }
    }
}

public let logger = SwiftyBeaverLogger()
