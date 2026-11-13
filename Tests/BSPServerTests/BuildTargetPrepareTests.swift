import Foundation
import JSONRPCConnection
import SourceKitBSPProtocol
import Testing
@testable import BSPServer

struct BuildTargetPrepareTests {
    @Test
    func uninitializedPreparationReturnsAnError() async throws {
        let service = BSPServerService.createStdioService(projectManagerProvider: ProjectManagerFactory())
        let handler = BSPMessageHandler()
        handler.setBSPServerService(service)
        let request = BuildTargetPrepareRequest(id: .int(10), jsonrpc: "2.0", params: .init(targets: []))
        let response = await request.handle(contextualHandler: handler, id: .int(10))
        let error = try #require(response as? JSONRPCErrorResponse)
        #expect(error.id == .int(10))
        let data = try JSONEncoder().encode(error)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let details = try #require(object["error"] as? [String: Any])
        #expect(details["code"] as? Int == -32603)
        #expect((details["message"] as? String)?.contains("Project not initialized") == true)
    }

    @Test
    func encodesPrepareResultAndTargetChangeMethod() throws {
        let data = try JSONEncoder().encode(BuildTargetPrepareResponse(jsonrpc: "2.0", id: .int(11)))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["result"] as? [String: String] == [:])
        #expect(BuildTargetDidChangeNotification.method() == "buildTarget/didChange")
    }
}
