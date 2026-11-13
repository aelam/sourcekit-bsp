import Foundation
import SourceKitBSPProtocol
import Testing
@testable import BSPServer

struct DebugSessionResponseTests {
    @Test
    func deferredEndpointEncodesOnlyTheStandardURI() throws {
        let response = DebugSessionStartResponse(connection: .init(uri: "tcp://127.0.0.1:12345"))
        let object = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(response.result)) as? [String: Any])
        #expect(Set(object.keys) == ["uri"])
        #expect(object["uri"] as? String == "tcp://127.0.0.1:12345")
    }

    @Test(arguments: [false, true])
    func preservesOptionalLaunchConfiguration(configured: Bool) throws {
        let connection = DebugSessionConnection(
            uri: "tcp://127.0.0.1:12345",
            request: .launch,
            program: "/Applications/Toolchain/usr/bin/xctest",
            args: configured ? ["-XCTest", "SelectedTests", "/tmp/中文 tests/Package.xctest"] : nil,
            env: configured ? ["TEST_FILTER": "SelectedTests", "EMPTY": ""] : nil,
            cwd: configured ? "/tmp/中文 tests" : nil
        )
        let response = DebugSessionStartResponse(connection: connection)
        let encoded = try JSONEncoder().encode(response.result)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let data = try #require(json["data"] as? [String: Any])
        #expect(data["request"] as? String == "launch")
        #expect(data["program"] as? String == connection.program)
        #expect(data["args"] as? [String] == connection.args)
        #expect(data["env"] as? [String: String] == connection.env)
        #expect(data["cwd"] as? String == connection.cwd)
        if !configured {
            #expect(data["args"] == nil)
            #expect(data["env"] == nil)
            #expect(data["cwd"] == nil)
        }
    }
}
