import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Testing
@testable import BSPServer

struct BuildTargetRunTests {
    @Test
    func cancelledRunReturnsCancelledWithoutAConfigurationError() async throws {
        let service = BSPServerService.createStdioService(projectManagerProvider: ProjectManagerFactory())
        let handler = BSPMessageHandler()
        handler.setBSPServerService(service)
        let request = try BuildTargetRunRequest(
            id: .int(20),
            jsonrpc: "2.0",
            params: .init(target: BSPBuildTargetIdentifier(uri: URI(string: "file:///Hello")))
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await request.handle(contextualHandler: handler, id: .int(20))
        }
        let response = try #require(await task.value as? BuildTargetRunResponse)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["statusCode"] as? Int == StatusCode.cancelled.rawValue)
    }
}
