import Foundation
import Testing
@testable import XcodeProjectManagement

struct LLDBDAPServerTests {
    @Test(arguments: [true, false])
    func checksReadinessBeforeReportingAnExpiredDeadline(listening: Bool) async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        try #require(named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        if listening {
            try #require(listen(fd, 1) == 0)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        if listening {
            try await LLDBDAPServer.waitUntilListening(port: port, process: process, timeout: 0)
            try #require(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
            let client = accept(fd, nil, nil)
            if client >= 0 { close(client) }
            #expect(client == -1)
            #expect(errno == EWOULDBLOCK)
        } else {
            // A reserved port is bound too; use a free port for the timeout case.
            let unused = try LLDBDAPServer.reserveFreePort()
            await #expect(throws: LLDBDAPError.self) {
                try await LLDBDAPServer.waitUntilListening(port: unused, process: process, timeout: 0)
            }
        }
    }

    @Test
    func preservesCancellationDuringAdapterLookup() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await LLDBDAPServer.locateLLDBDAP()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
