import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct DeviceDAPRelayTests {
    @Test(arguments: [true, false])
    func deviceCommandsAcceptStartedStatusAndStopOnErrors(started: Bool) async throws {
        let upstream = try await LLDBDAPServer().start()
        let result = started ? "result.SetStatus(lldb.eReturnStatusStarted)" : "result.SetError('Device is locked')"
        let relay = DeviceDAPRelay(
            upstream: upstream,
            configuration: DAPAttachConfiguration(pid: 2_147_483_647, program: "/bin/sleep", commands: [
                "!script exec(\"def bsp_device_result(debugger, command, result, internal_dict):\\n    \(result)\")",
                "!command script add -f bsp_device_result bsp_device_result"
            ] + DAPAttachConfiguration.deviceCommandSetup + [
                DAPAttachConfiguration.checkedDeviceCommand("bsp_device_result"),
                "!bsp_after_device_command"
            ])
        ) {}
        let endpoint = try await relay.start()
        defer { endpoint.terminate() }
        var client = try DAPTestSocket(uri: endpoint.uri)
        defer { client.close() }
        try client.send(#"""
        {"seq":1,"type":"request","command":"initialize","arguments":{
          "adapterID":"lldb","pathFormat":"path","linesStartAt1":true,"columnsStartAt1":true
        }}
        """#)
        #expect(try client.response(sequence: 1)["success"] as? Bool == true)
        try client.send(#"{"seq":2,"type":"request","command":"attach","arguments":{"pid":2147483647}}"#)
        #expect(try client.response(sequence: 2)["success"] as? Bool == false)
        #expect(client.output.contains("bsp_after_device_command") == started, "\(client.output)")
        if !started { #expect(client.output.contains("error: Device is locked"), "\(client.output)") }
        await relay.close(reason: nil)
    }

    @Test
    func plainDAPClientReceivesNativeAdapterErrorsAndCleanup() async throws {
        let upstream = try await LLDBDAPServer().start()
        let cleaned = CrossPlatformLock(initialState: 0)
        let relay = DeviceDAPRelay(
            upstream: upstream,
            configuration: DAPAttachConfiguration(
                pid: 2_147_483_647, program: "/bin/sleep", commands: ["!bsp_test_missing_attach_command"]
            )
        ) { cleaned.withLock { $0 += 1 } }
        let endpoint = try await relay.start()
        defer { endpoint.terminate() }
        var client = try DAPTestSocket(uri: endpoint.uri)
        defer { client.close() }
        try client.send(#"""
        {"seq":1,"type":"request","command":"initialize","arguments":{
          "adapterID":"lldb","pathFormat":"path","linesStartAt1":true,"columnsStartAt1":true
        }}
        """#)
        let initialized = try client.response(sequence: 1)
        #expect(initialized["success"] as? Bool == true, "\(initialized)")
        try client.send(#"{"seq":2,"type":"request","command":"attach","arguments":{"pid":2147483647}}"#)
        let attached = try client.response(sequence: 2)
        #expect(attached["success"] as? Bool == false)
        #expect(client.output.contains("bsp_test_missing_attach_command"))
        await relay.close(reason: nil)
        #expect(cleaned.withLock { $0 } == 1)
    }

    @Test
    func idleSessionCleansUpWithoutAClient() async throws {
        let cleaned = AsyncStream<Void>.makeStream()
        let stopped = CrossPlatformLock(initialState: 0)
        let relay = DeviceDAPRelay(
            upstream: DebugAdapterEndpoint(uri: "tcp://127.0.0.1:1") { stopped.withLock { $0 += 1 } },
            configuration: .device(id: "PHONE", pid: 42, executable: "/tmp/Hello")
        ) {
            #expect(!Task.isCancelled)
            cleaned.continuation.yield(())
            cleaned.continuation.finish()
        }
        _ = try await relay.start(timeout: .seconds(1))
        let didClean = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in cleaned.stream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(didClean)
        await relay.close(reason: nil)
        #expect(stopped.withLock { $0 } == 1)
    }
}

private struct DAPTestSocket {
    let fd: Int32
    var parser = DAPFrameBuffer()
    var pending: [Data] = []
    var output = ""

    init(uri: String) throws {
        let port = try #require(URL(string: uri)?.port)
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DAPRelayError.closed }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            ) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw DAPRelayError.closed
        }
    }

    func close() {
        Darwin.close(fd)
    }

    func send(_ text: String) throws {
        let data = DAPFrameBuffer.frame(Data(text.utf8))
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset, 0)
                guard count > 0 else { throw DAPRelayError.closed }
                offset += count
            }
        }
    }

    mutating func response(sequence: Int) throws -> [String: Any] {
        while true {
            while !pending.isEmpty {
                let body = pending.removeFirst()
                let message = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if message["event"] as? String == "output", let event = message["body"] as? [String: Any] {
                    output += event["output"] as? String ?? ""
                }
                if message["request_seq"] as? Int == sequence { return message }
            }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { throw DAPRelayError.closed }
            pending += try parser.append(Data(bytes.prefix(count)))
        }
    }
}
