import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum HostAttachError: Error, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): "Attach: \(message)"
        }
    }
}

/// A PID is insufficient: retain the executable and kernel process start identity.
public struct HostProcessIdentity: Sendable, Equatable {
    public let pid: Int
    public let executable: String
    public let startToken: String

    public init(pid: Int, executable: String, startToken: String) {
        self.pid = pid
        self.executable = executable
        self.startToken = startToken
    }

    public func validate() throws {
        guard pid != Int(ProcessInfo.processInfo.processIdentifier) else {
            throw HostAttachError
                .invalid("Cannot attach to this BSP server: stopping it would also stop its debug relay.")
        }
        guard Self.read(pid: pid) == self else {
            throw HostAttachError.invalid("The process exited or its identity changed. Start attach again.")
        }
    }

    /// Enumerates only processes owned by the server user with this exact executable.
    public static func processes(executable: String) throws -> [Self] {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let pids: [Int]
        #if os(macOS)
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { throw HostAttachError.invalid("Cannot read the host process list.") }
        var buffer = [Int32](repeating: 0, count: Int(capacity) + 1024)
        let size = Int32(buffer.count * MemoryLayout<Int32>.stride)
        let actual = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, size) }
        guard actual > 0, actual <= buffer.count else {
            throw HostAttachError.invalid("Cannot read the host process list. Try again.")
        }
        pids = buffer.prefix(Int(actual)).map(Int.init)
        #elseif os(Linux)
        pids = try FileManager.default.contentsOfDirectory(atPath: "/proc").compactMap(Int.init)
        #else
        throw HostAttachError.invalid("Host attach supports macOS and Linux only.")
        #endif
        return pids.filter { $0 != Int(ProcessInfo.processInfo.processIdentifier) }
            .compactMap { read(pid: $0) }
            .filter { $0.executable == path }
            .sorted { $0.pid < $1.pid }
    }

    public static func read(pid: Int) -> Self? {
        guard let rawPID = Int32(exactly: pid), rawPID > 0 else { return nil }
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(rawPID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(rawPID, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var current = proc_bsdinfo()
        guard proc_pidinfo(rawPID, PROC_PIDTBSDINFO, 0, &current, size) == size,
              current.pbi_start_tvsec == info.pbi_start_tvsec,
              current.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
        return Self(
            pid: pid,
            executable: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
            startToken: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
        )
        #elseif os(Linux)
        let root = "/proc/\(rawPID)"
        guard let status = try? String(contentsOfFile: root + "/status", encoding: .utf8),
              let uidLine = status.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }),
              uidLine.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init) == String(getuid()),
              let stat = try? String(contentsOfFile: root + "/stat", encoding: .utf8),
              let start = linuxStartToken(stat),
              let boot = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8),
              let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/exe"),
              !executable.hasSuffix(" (deleted)"),
              let current = try? String(contentsOfFile: root + "/stat", encoding: .utf8),
              linuxStartToken(current) == start else { return nil }
        return Self(
            pid: pid,
            executable: executable,
            startToken: boot.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + start
        )
        #else
        return nil
        #endif
    }

    /// Field 22 follows a command name that can itself contain spaces and parentheses.
    package static func linuxStartToken(_ stat: String) -> String? {
        guard let end = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: end)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 19, fields[0] != "Z", UInt64(fields[19]) != nil else { return nil }
        return String(fields[19])
    }
}
