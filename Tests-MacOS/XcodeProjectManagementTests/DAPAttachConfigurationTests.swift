import Foundation
import Testing
@testable import XcodeProjectManagement

struct DAPAttachConfigurationTests {
    @Test
    func configuresOnlyAttachAndPreservesClientOptions() throws {
        let configuration = DAPAttachConfiguration.device(id: "PHONE", pid: 42, executable: "/tmp/Hello.app/Hello")
        let attach = Data(#"{"seq":9,"type":"request","command":"attach","arguments":{"pid":42,"stopOnEntry":true}}"#
            .utf8)
        let message = try #require(JSONSerialization
            .jsonObject(with: configuration.configure(attach)) as? [String: Any])
        let arguments = try #require(message["arguments"] as? [String: Any])
        #expect(message["seq"] as? Int == 9)
        #expect(arguments["stopOnEntry"] as? Bool == true)
        #expect(arguments["pid"] as? Int == 42)
        #expect(arguments["program"] as? String == "/tmp/Hello.app/Hello")
        #expect(arguments["attachCommands"] as? [String] == DAPAttachConfiguration.deviceCommandSetup + [
            DAPAttachConfiguration.checkedDeviceCommand("device select \"PHONE\""),
            DAPAttachConfiguration.checkedDeviceCommand("device process attach --pid 42")
        ])
        for command in ["initialize", "setBreakpoints", "continue", "disconnect", "cancel"] {
            let body = Data("{\"seq\":10,\"type\":\"request\",\"command\":\"\(command)\"}".utf8)
            #expect(try configuration.configure(body) == body)
        }
    }

    @Test
    func framesHandleFragmentationAndUnicode() throws {
        let bodies = [Data(#"{"message":"设备已连接"}"#.utf8), Data(#"{"seq":2}"#.utf8)]
        let bytes = bodies.reduce(into: Data()) { $0 += DAPFrameBuffer.frame($1) }
        var parser = DAPFrameBuffer()
        var received: [Data] = []
        for byte in bytes {
            received += try parser.append(Data([byte]))
        }
        #expect(received == bodies)
        #expect(try parser.append(bytes) == bodies)
    }

    @Test(arguments: [
        "Content-Length: -1", "Content-Length: 9999999999999999999999", "Content-Length: 67108865",
        "Content-Length: 1\r\nContent-Length: 1", "Other: 1"
    ])
    func rejectsInvalidHeaders(header: String) {
        var parser = DAPFrameBuffer()
        #expect(throws: DAPRelayError.self) { try parser.append(Data((header + "\r\n\r\n{}").utf8)) }
    }

    @Test
    func deviceNamesCannotInjectAdditionalCommands() {
        let config = DAPAttachConfiguration.device(id: "Phone\"\nquit\\", pid: 42, executable: "/tmp/Hello")
        #expect(config.commands.dropFirst(2).first == DAPAttachConfiguration.checkedDeviceCommand(
            "device select \"Phone\\\"\\nquit\\\\\""
        ))
        #expect(config.commands.allSatisfy { !$0.contains("\n") })
    }
}
