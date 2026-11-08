import BuildServerProtocol
import Foundation

extension BSPServerService {
    func negotiateBuildContext(_ data: LSPAny?) async -> BuildContextExtension? {
        guard case let .dictionary(data) = data,
              case let .dictionary(extensions) = data["bspExtensions"],
              case let .dictionary(context) = extensions[BuildContextExtension.name],
              context["version"] == .string("0.1"),
              let projectManager, await projectManager.supportsBuildContexts else { return nil }
        let capabilities = await projectManager.capabilities
        let operations = BuildContextOperation.allCases.filter { operation in
            ProjectManagerCapability(rawValue: operation.rawValue).map(capabilities.contains) ?? false
        }
        let negotiated = await BuildContextExtension(
            operations: operations,
            buildPolicies: projectManager.supportedBuildPolicies
        )
        buildContextExtension = negotiated
        return negotiated
    }

    func contextOptions(_ params: BuildContextOptionsParams) async throws -> BuildContextOptionsResult {
        let manager = try await contextManager(scope: params.scope, operation: nil)
        return try await manager.contextOptions(params)
    }

    func resolveContext(_ params: BuildContextParams) async throws -> BuildContextResolution {
        let manager = try await contextManager(scope: params.scope, operation: params.operation)
        try params.buildPolicy.validate(for: params.operation)
        guard buildContextExtension?.buildPolicies.contains(params.buildPolicy) == true else {
            throw BuildContextError.invalid("The build policy was not negotiated.")
        }
        let revision = buildContextRevision
        let context = try await manager.resolveContext(params)
        guard revision == buildContextRevision else {
            throw BuildContextError.invalid("The project changed while resolving. Resolve a new context.")
        }
        guard context.buildPolicy == params.buildPolicy, context.operation == params.operation,
              !context.targets.isEmpty,
              Set(context.targets).count == context.targets.count else {
            throw BuildContextError.invalid("The provider returned an invalid operation, build policy, or target set.")
        }
        if let targets = params.scope?.targets, !targets.isEmpty, Set(targets) != Set(context.targets) {
            throw BuildContextError.invalid("The resolved targets differ from the requested targets.")
        }
        if context.operation == .run, context.targets.count != 1 {
            throw BuildContextError.invalid("Run requires exactly one target.")
        }
        let id = UUID().uuidString
        if buildContextOrder.count >= 128 {
            buildContexts.removeValue(forKey: buildContextOrder.removeFirst())
        }
        buildContexts[id] = context
        buildContextOrder.append(id)
        return BuildContextResolution(id: id, context: context)
    }

    func executionContext(
        _ reference: BuildContextReference?,
        operation: BuildContextOperation,
        targets: [BSPBuildTargetIdentifier]
    ) async throws -> BuildContext? {
        guard let negotiated = buildContextExtension else {
            guard reference == nil else {
                throw BuildContextError.invalid("The extension was not negotiated during initialization.")
            }
            return nil
        }
        guard negotiated.operations.contains(operation), let reference else {
            throw BuildContextError.invalid("A resolved executionContext is required for this operation.")
        }
        guard let context = buildContexts[reference.id] else {
            throw BuildContextError.invalid("The context is unknown or expired. Resolve a new context.")
        }
        guard context.operation == operation, Set(context.targets) == Set(targets), !targets.isEmpty,
              Set(targets).count == targets.count else {
            throw BuildContextError.invalid("The operation or target set does not match the resolved context.")
        }
        let params = BuildContextParams(
            scope: .init(targets: targets),
            operation: operation,
            selection: context.selection,
            buildPolicy: context.buildPolicy
        )
        let manager = try await contextManager(scope: params.scope, operation: params.operation)
        let revision = buildContextRevision
        let current = try await manager.resolveContext(params)
        guard revision == buildContextRevision, buildContexts[reference.id] != nil,
              current.operation == operation, Set(current.targets) == Set(targets),
              current.selection == context.selection, current.buildPolicy == context.buildPolicy else {
            throw BuildContextError.invalid("The resolved selection is stale. Resolve a new context.")
        }
        return context
    }

    func invalidateBuildContexts() {
        buildContextRevision += 1
        buildContexts.removeAll()
        buildContextOrder.removeAll()
    }

    private func contextManager(scope: BuildContextScope?, operation: BuildContextOperation?)
        async throws -> any ProjectManager {
        guard let negotiated = buildContextExtension, operation.map(negotiated.operations.contains) ?? true,
              let projectManager else {
            throw BuildContextError.invalid("The extension or operation was not negotiated.")
        }
        if let targets = scope?.targets {
            guard !targets.isEmpty, Set(targets).count == targets.count else {
                throw BuildContextError.invalid("The scope must contain a nonempty set of distinct targets.")
            }
        }
        if let workspace = scope?.workspaceUri {
            let root = await projectManager.workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
            guard workspace.fileURL?.standardizedFileURL.resolvingSymlinksInPath().path == root.path else {
                throw BuildContextError.invalid("The workspace does not belong to this connection.")
            }
        }
        return projectManager
    }
}
