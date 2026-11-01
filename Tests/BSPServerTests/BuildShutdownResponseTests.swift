import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

struct BuildShutdownResponseTests {
    @Test
    func encodesNullResult() throws {
        let response = BuildShutdownResponse(jsonrpc: "2.0", id: .int(42), result: .null)
        let data = try JSONEncoder().encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 42)
        #expect(object["result"] is NSNull)
        #expect(object["error"] == nil)
    }
}
