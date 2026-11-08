import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Nonblocking loopback sockets keep the relay portable without occupying executor threads.
package enum AttachDAPSocket {
    package static func create() throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw DebugAdapterRelayError.closed }
        #if os(macOS)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    package static func nonblocking(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw DebugAdapterRelayError.closed }
    }

    package static func listener() throws -> (Int32, Int) {
        let fd = try create()
        do {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0, listen(fd, 1) == 0 else { throw DebugAdapterRelayError.closed }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0 else { throw DebugAdapterRelayError.closed }
            try nonblocking(fd)
            return (fd, Int(UInt16(bigEndian: address.sin_port)))
        } catch {
            close(fd)
            throw error
        }
    }

    package static func connectTo(_ uri: String) throws -> Int32 {
        guard let url = URL(string: uri), url.host == "127.0.0.1",
              let port = url.port.flatMap(UInt16.init(exactly:)) else { throw DebugAdapterRelayError.closed }
        let fd = try create()
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        // The upstream is already listening on loopback.
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        do {
            guard connected == 0 else { throw DebugAdapterRelayError.closed }
            try nonblocking(fd)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    package static func read(_ fd: Int32) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &buffer, buffer.count, 0)
        if count > 0 { return Data(buffer.prefix(count)) }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
        throw DebugAdapterRelayError.closed
    }

    package static func flush(_ data: inout Data, to fd: Int32) throws {
        guard !data.isEmpty else { return }
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        let count = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, flags) }
        if count > 0 { data.removeFirst(count); return }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
        throw DebugAdapterRelayError.closed
    }
}
