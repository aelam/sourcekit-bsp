import Foundation
import Logger

/// A running debug-adapter endpoint the client connects to over TCP.
public struct DebugAdapterEndpoint: Sendable {
    public let uri: String // "tcp://127.0.0.1:<port>"
    public let terminate: @Sendable () -> Void
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
    public init() {}

    public func start() async throws -> DebugAdapterEndpoint {
        let lldbDAPPath = try Self.locateLLDBDAP()
        let port = try Self.reserveFreePort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lldbDAPPath)
        process.arguments = ["--connection", "listen://127.0.0.1:\(port)"]
        // Long-lived: do NOT wait for exit. Detach stdin so it doesn't touch ours.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LLDBDAPError.failedToStart(error.localizedDescription)
        }

        // Block until lldb-dap is actually accepting connections. Without this
        // we return the tcp:// URI before the listen socket is bound; the client
        // (VS Code) then connects too early, gets ECONNREFUSED, and the debug
        // session dies silently — leaving a `--wait-for-debugger` app suspended
        // forever with no visible session in the editor.
        try Self.waitUntilListening(port: port, process: process, timeout: 10)
        logger.info("lldb-dap listening on tcp://127.0.0.1:\(port) (pid \(process.processIdentifier))")

        return DebugAdapterEndpoint(
            uri: "tcp://127.0.0.1:\(port)",
            terminate: { if process.isRunning { process.terminate() } }
        )
    }

    /// Poll-connect to 127.0.0.1:<port> until lldb-dap accepts, the process
    /// exits, or the timeout elapses. Retries every 50ms.
    static func waitUntilListening(port: Int, process: Process, timeout: TimeInterval) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            guard process.isRunning else {
                throw LLDBDAPError
                    .failedToStart("lldb-dap exited before listening (status \(process.terminationStatus))")
            }
            if canConnect(port: port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw LLDBDAPError.failedToStart("lldb-dap did not start listening on port \(port) within \(Int(timeout))s")
    }

    /// One connect() attempt to the loopback port; true if the socket accepts.
    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// `xcrun --find lldb-dap`.
    static func locateLLDBDAP() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "lldb-dap"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !path.isEmpty,
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
