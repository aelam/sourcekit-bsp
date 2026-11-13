import JSONRPCConnection
import SourceKitBSPProtocol

struct BuildTargetDependencyModulesRequest: ContextualRequestType, Sendable {
    typealias RequiredContext = BSPServerService

    static func method() -> String {
        "buildTarget/dependencyModules"
    }

    struct Params: Codable, Sendable {
        let targets: [BSPBuildTargetIdentifier]
    }

    let params: Params

    func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            do {
                let items = try await context.getDependencyModules(targetIds: params.targets)
                return BuildTargetDependencyModulesResponse(id: id, result: .init(items: items))
            } catch {
                let code: Int = switch error {
                case DependencyModulesError.unknownTarget: -32602
                case DependencyModulesError.unsupported: -32601
                default: -32603
                }
                return JSONRPCErrorResponse(id: id, error: .init(code: code, message: error.localizedDescription))
            }
        }
    }
}

struct BuildTargetDependencyModulesResponse: ResponseType {
    var jsonrpc = "2.0"
    let id: JSONRPCID?
    let result: DependencyModulesResult
}

struct DependencyModulesResult: Codable, Hashable, Sendable {
    let items: [DependencyModulesItem]
}
