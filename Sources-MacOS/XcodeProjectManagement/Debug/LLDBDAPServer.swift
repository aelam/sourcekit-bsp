import Foundation
import Logger
import Support

/// A running debug-adapter endpoint the client connects to over TCP.
public struct DebugAdapterEndpoint: Sendable {
    public let uri: String // "tcp://127.0.0.1:<port>"
    public let terminate: @Sendable () -> Void
    var waitForTermination: (@Sendable () async -> Void)?

    public init(uri: String, terminate: @escaping @Sendable () -> Void) {
        self.uri = uri
        self.terminate = terminate
    }

    func stop() async {
        terminate()
        await waitForTermination?()
    }
}

/// Seam so `DebugSessionManager` can be unit-tested without spawning lldb-dap.
public protocol DebugAdapterServing: Sendable {
    func start() async throws -> DebugAdapterEndpoint
}

public enum LLDBDAPError: Error, LocalizedError {
    case notFound
    case failedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "lldb-dap not found in the active Xcode toolchain"
        case let .failedToStart(msg): "lldb-dap failed to start: \(msg)"
        }
    }
}

/// Locates `lldb-dap` in the active Xcode toolchain and runs it in TCP listen
/// mode. The returned `DebugAdapterEndpoint` carries the `tcp://` URI and a
/// teardown closure. lldb-dap is long-lived, so we spawn it with `Process` and
/// do NOT wait for it to exit.
public struct LLDBDAPServer: DebugAdapterServing {
    private let developerDirectory: URL?

    public init(developerDirectory: URL? = nil) {
        self.developerDirectory = developerDirectory
    }

    public func start() async throws -> DebugAdapterEndpoint {
        let lldbDAPPath = try await Self.locateLLDBDAP(developerDirectory: developerDirectory)
        let port = try Self.reserveFreePort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lldbDAPPath)
        process.arguments = ["--connection", "listen://127.0.0.1:\(port)"]
        if let developerDirectory {
            var environment = ProcessInfo.processInfo.environment
            environment["DEVELOPER_DIR"] = developerDirectory.path
            process.environment = environment
        }
        // Long-lived: do NOT wait for exit. Detach stdin so it doesn't touch ours.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            let launch: () throws -> Void = process.run
            try launch()
        } catch {
            throw LLDBDAPError.failedToStart(error.localizedDescription)
        }

        do {
            try await Self.waitUntilListening(port: port, process: process, timeout: 10)
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        logger.info("lldb-dap listening on tcp://127.0.0.1:\(port) (pid \(process.processIdentifier))")

        return DebugAdapterEndpoint(uri: "tcp://127.0.0.1:\(port)") {
            if process.isRunning { process.terminate() }
        }
    }

    /// Check the bound port without consuming the adapter's only client connection.
    static func waitUntilListening(port: Int, process: Process, timeout: TimeInterval) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw LLDBDAPError
                    .failedToStart("lldb-dap exited before listening (status \(process.terminationStatus))")
            }
            if isPortBound(port: port) { return }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LLDBDAPError.failedToStart("lldb-dap did not start listening on port \(port) within \(Int(timeout))s")
    }

    private static func isPortBound(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == -1 && errno == EADDRINUSE
    }

    /// `xcrun --find lldb-dap`.
    static func locateLLDBDAP(developerDirectory: URL? = nil) async throws -> String {
        let environment = developerDirectory.map { ["DEVELOPER_DIR": $0.path] } ?? [:]
        let result: ProcessExecutionResult
        do {
            result = try await ProcessExecutor().execute(
                executable: "/usr/bin/xcrun", arguments: ["--find", "lldb-dap"], environment: environment
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLDBDAPError.notFound
        }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isSuccess, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw LLDBDAPError.notFound
        }
        return path
    }

    /// Bind 127.0.0.1:0, read the OS-assigned port, close — then hand it to lldb-dap.
    static func reserveFreePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LLDBDAPError.failedToStart("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw LLDBDAPError.failedToStart("bind() failed") }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { throw LLDBDAPError.failedToStart("getsockname() failed") }
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }
}
