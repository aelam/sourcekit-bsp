import Foundation
import Logger
import SwiftBuild

actor SwiftBuildIndexingBackend: XcodeIndexingBackend {
    nonisolated let indexStoreURL: URL
    nonisolated let indexDatabaseURL: URL

    private let snapshot: XcodeProjectSnapshot
    private let serviceExecutable: URL
    private var workspace: SwiftBuildIndexingWorkspace?
    private var context: SwiftBuildIndexingContext
    private var operations = SwiftBuildIndexingOperations()

    struct Statistics {
        var workspaceLoads = 0
        var buildDescriptions = 0
        var compilerArgumentQueries = 0
        var compilerArgumentCacheHits = 0
        var sourceQueries = 0
    }

    private(set) var statistics = Statistics()

    init(snapshot: XcodeProjectSnapshot, serviceExecutable: URL? = nil) throws {
        self.snapshot = snapshot
        if let serviceExecutable {
            self.serviceExecutable = serviceExecutable
        } else if let executable = Bundle.main.executableURL {
            self.serviceExecutable = executable.resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("SWBBuildServiceBundle")
        } else {
            throw XcodeProjectError.invalidConfig("Cannot locate the running BSP executable")
        }
        self.context = try SwiftBuildIndexingContext(
            snapshot: snapshot,
            buildContext: XcodeIndexingSelection.load(in: snapshot.xcodeGlobalSettings.derivedDataPath)
        )
        self.indexStoreURL = snapshot.xcodeGlobalSettings.indexStoreURL
        self.indexDatabaseURL = snapshot.xcodeGlobalSettings.indexDatabaseURL
    }

    private func ensureLoaded() async throws {
        guard !operations.isStopped else { throw CancellationError() }
        guard workspace == nil else { return }
        _ = try await operations.initialization.prepare(for: "workspace") { _ in
            try await self.perform("load workspace", serializeBuild: false) { backend in
                guard backend.workspace == nil else { return true }
                backend.workspace = try await SwiftBuildIndexingWorkspace.load(
                    snapshot: backend.snapshot, serviceExecutable: backend.serviceExecutable
                )
                backend.statistics.workspaceLoads += 1
                return true
            }
        }
    }

    func compilerArguments(for target: XcodeTargetIdentifier, file: URL) async throws -> [String] {
        let version = context.version
        try checkContext(version)
        let key = SwiftBuildIndexingArgumentsCache.Key(target: target, file: file)
        while true {
            try checkContext(version)
            if let arguments = context.arguments.cached(for: key) {
                statistics.compilerArgumentCacheHits += 1
                return arguments
            }
            let inputs = context.arguments.version
            let request = SwiftBuildIndexingOperations.ArgumentsKey(
                entry: key, contextVersion: version, inputsVersion: inputs
            )
            let result = try await operations.arguments.prepare(for: request) { _ in
                try await self.perform("compiler arguments", serializeBuild: false) { backend in
                    try await backend.queryArguments(for: request)
                }
            }
            try checkContext(version)
            guard context.arguments.version == inputs, let result else { continue }
            return result
        }
    }

    private func queryArguments(for request: SwiftBuildIndexingOperations.ArgumentsKey) async throws -> [String]? {
        try checkContext(request.contextVersion)
        guard context.arguments.version == request.inputsVersion else { return nil }
        if let cached = context.arguments.cached(for: request.entry) { return cached }
        let plan = try await plan(for: request.entry.target, version: request.contextVersion)
        guard context.arguments.version == request.inputsVersion else { return nil }
        let result = try await arguments(for: request.entry.target, file: request.entry.file, plan: plan)
        try checkContext(request.contextVersion)
        // Publish before shared work completes so a later caller cannot start the same query again.
        guard context.arguments.publish(result, for: request.entry, version: request.inputsVersion) else { return nil }
        return result
    }

    func updateSelection(_ buildContext: XcodeIndexingSelection?) throws {
        try checkContext(context.version)
        guard context.buildContext != buildContext else { return }
        context = SwiftBuildIndexingContext(snapshot: snapshot, buildContext: buildContext)
        logger.info("Swift Build indexing configuration updated; reusing workspace session")
    }

    private func checkContext(_ version: UUID) throws {
        try Task.checkCancellation()
        guard !operations.isStopped, context.version == version else { throw CancellationError() }
    }

    private func arguments(for target: XcodeTargetIdentifier, file: URL, plan: Plan) async throws -> [String] {
        defer { withExtendedLifetime(plan) {} }
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        let version = context.version
        let paths = try await sourcePaths(for: target, plan: plan, version: version)
        try checkContext(version)
        // PIF loading can spell symlinked paths differently from the client's document URI.
        let path = try paths[file.resolvingSymlinksInPath()] ?? AbsolutePath(validating: file.path)
        statistics.compilerArgumentQueries += 1
        return try await session.indexCompilerArguments(
            of: path, in: plan.target,
            buildDescription: plan.descriptionID, buildRequest: plan.request
        )
    }

    private func sourcePaths(
        for target: XcodeTargetIdentifier, plan: Plan, version: UUID
    ) async throws -> [URL: AbsolutePath] {
        if let cached = context.plans.paths(for: target, descriptionVersion: plan.description.version) {
            return cached
        }
        let key = SwiftBuildIndexingOperations.SourcesKey(
            target: target, contextVersion: version, descriptionVersion: plan.description.version
        )
        return try await operations.sources.prepare(for: key) { _ in
            try await self.querySourcePaths(for: target, plan: plan, version: version)
        }
    }

    private func querySourcePaths(
        for target: XcodeTargetIdentifier, plan: Plan, version: UUID
    ) async throws -> [URL: AbsolutePath] {
        defer { withExtendedLifetime(plan) {} }
        try checkContext(version)
        if let cached = context.plans.paths(for: target, descriptionVersion: plan.description.version) { return cached }
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        statistics.sourceQueries += 1
        let sources = try await session.sources(
            of: [plan.target],
            buildDescription: plan.descriptionID, buildRequest: plan.request
        )
        let paths = Dictionary(sources.flatMap(\.sourceFiles).map {
            (URL(fileURLWithPath: $0.path.pathString).resolvingSymlinksInPath(), $0.path)
        }, uniquingKeysWith: { first, _ in first })
        try checkContext(version)
        context.plans.storePaths(paths, for: target, descriptionVersion: plan.description.version)
        return paths
    }

    private func resolveGUID(_ target: XcodeTargetIdentifier) async throws -> String {
        if let cached = workspace?.targetGUIDs[target] { return cached }
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var matches: [SWBTargetInfo] = []
        for candidate in workspace?.targetInfos ?? [] where candidate.targetName == target.targetName {
            let project = try await session.evaluateMacroAsString(
                "PROJECT_FILE_PATH", level: .target(candidate.guid), buildParameters: context.request.parameters,
                overrides: nil
            )
            if URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: target.projectFilePath).standardizedFileURL.resolvingSymlinksInPath() {
                matches.append(candidate)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw XcodeProjectError.invalidConfig("Swift Build target match count \(matches.count): \(target.rawValue)")
        }
        workspace?.targetGUIDs[target] = match.guid
        return match.guid
    }

    func prepare(
        targets: [XcodeTargetIdentifier],
        log: (@Sendable (String) -> Void)?
    ) async throws -> [XcodeTargetIdentifier] {
        let targets = Array(Set(targets)).sorted { $0.rawValue < $1.rawValue }
        guard !targets.isEmpty else { return [] }
        let version = context.version
        try checkContext(version)
        let key = SwiftBuildIndexingOperations.PreparationKey(
            targets: targets, generation: context.preparationGeneration
        )
        let changes = try await operations.preparation.prepare(for: key, logHandler: log) { sharedLog in
            try await self.ensureLoaded()
            let targets = try await self.perform("prepare") { backend in
                try backend.checkContext(version)
                return try await backend.prepareOperation(targets: targets, version: version, log: sharedLog)
            }
            return IndexPreparationChanges(targets)
        }
        try checkContext(version)
        return changes.take()
    }

    func invalidateInputs(preservingArguments: Bool) {
        context.invalidateInputs(preservingArguments: preservingArguments)
    }

    private func prepareOperation(
        targets: [XcodeTargetIdentifier], version: UUID, log: @escaping @Sendable (String) -> Void
    ) async throws -> [XcodeTargetIdentifier] {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var guids: [String] = []
        for target in targets {
            try Task.checkCancellation()
            try await guids.append(resolveGUID(target))
        }
        try checkContext(version)
        let shared = try await sharedDescription(for: targets, guids: Set(guids), version: version)
        var batchRequest = shared.request
        batchRequest.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: guids, enableIndexBuildArena: true)
        let operation = try await session.createBuildOperation(
            request: batchRequest, delegate: IndexPlanningDelegate(), retainBuildDescription: true
        )
        let description = try await consumeDescription(operation, log: log)
        try checkContext(version)
        // Compiler arguments come from the description's task graph, not the generated file contents.
        // A no-op preparation must not invalidate options or query every previously indexed file.
        // Swift Build can recreate a graph under the same ID after file-system inputs change.
        guard description.id != shared.description.id || description.wasLoadedOrCreated else { return [] }
        let updated = try await describe(request: shared.request, description: description, version: version)
        let affectedGUIDs = context.plans.replace(shared, with: updated)
        let changed = Set(context.arguments.targets.filter { target in
            guard let guid = workspace?.targetGUIDs[target] else { return false }
            return affectedGUIDs.contains(guid)
        })
        context.arguments.invalidate(targets: changed)
        return changed.sorted { $0.rawValue < $1.rawValue }
    }

    private func consume(
        _ operation: SWBBuildOperation, log: (@Sendable (String) -> Void)?,
        eventHandler: (SwiftBuildMessage) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            // A failed start has no completion event to wait for.
            let events: AsyncStream<SwiftBuildMessage>
            do {
                try Task.checkCancellation()
                events = try await operation.start()
            } catch {
                operation.cancel()
                throw error
            }
            do {
                for await event in events {
                    eventHandler(event)
                    switch event {
                    case .buildStarted: log?("Index preparation build started")
                    case let .taskStarted(info): log?(info.executionDescription)
                    case let .targetStarted(info): log?("Preparing \(info.targetName)")
                    case let .taskDiagnostic(info): log?(info.message)
                    case let .buildDiagnostic(info): log?(info.message)
                    case let .diagnostic(info): log?(info.message)
                    default: break
                    }
                }
                await operation.waitForCompletion()
                try Task.checkCancellation()
                guard operation.state == .succeeded else {
                    throw XcodeProjectError.invalidConfig("Swift Build indexing failed: \(operation.state)")
                }
            } catch {
                operation.cancel()
                await operation.waitForCompletion()
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    private func perform<Result: Sendable>(
        _ name: String,
        serializeBuild: Bool = true,
        _ body: @escaping @Sendable (isolated SwiftBuildIndexingBackend) async throws -> Result
    ) async throws -> Result {
        guard !operations.isStopped else { throw CancellationError() }
        let id = UUID()
        let start = ContinuousClock.now
        if serializeBuild { logger.info("Swift Build \(name): queued") }
        let task = Task {
            try Task.checkCancellation()
            if serializeBuild {
                return try await XcodeBuildScheduler.shared
                    .withBuild(in: snapshot.xcodeGlobalSettings.derivedDataPath) {
                        try Task.checkCancellation()
                        logger.info("Swift Build \(name): started after \(ContinuousClock.now - start)")
                        return try await body(self)
                    }
            }
            return try await body(self)
        }
        operations.track(task, id: id)
        defer {
            operations.remove(id)
            if serializeBuild {
                logger.info("Swift Build \(name): \(ContinuousClock.now - start)")
            } else {
                logger.debug("Swift Build \(name): \(ContinuousClock.now - start)")
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func shutdown() async {
        operations.stopAcceptingWork()
        await operations.arguments.stop()
        await operations.preparation.stop()
        await operations.planning.stop()
        await operations.primaryPlanning.stop()
        await operations.sources.stop()
        await operations.initialization.stop()
        for completion in operations.cancelPending() {
            await completion.value
        }
        context.plans = SwiftBuildIndexingPlanCache()
        await workspace?.close()
        workspace = nil
    }
}

private extension SwiftBuildIndexingBackend {
    typealias Plan = SwiftBuildIndexingPlan
    typealias BuildDescription = Plan.BuildDescription

    func plan(for target: XcodeTargetIdentifier, version: UUID) async throws -> Plan {
        try await ensureLoaded()
        try checkContext(version)
        if let cached = context.plans.plan(for: target) { return cached }
        let key = SwiftBuildIndexingOperations.PlanningKey(
            target: target, contextVersion: version, inputsVersion: context.arguments.version
        )
        return try await operations.planning.prepare(for: key) { _ in
            let guid = try await self.resolveGUID(target)
            return try await self.existingOrNewPlan(for: target, guid: guid, version: version)
        }
    }

    func existingOrNewPlan(for target: XcodeTargetIdentifier, guid: String, version: UUID) async throws -> Plan {
        try checkContext(version)
        if let cached = context.plans.plan(for: target) { return cached }
        if !context.plans.hasPrimaryDescription, let roots = context.buildContext?.rootTargets, !roots.isEmpty {
            _ = try await operations.primaryPlanning.prepare(for: version) { _ in
                try await self.perform("plan selected targets") { backend in
                    try backend.checkContext(version)
                    if !backend.context.plans.hasPrimaryDescription {
                        _ = try await backend.createDescription(roots: roots, primary: true, version: version)
                    }
                    return true
                }
            }
            try checkContext(version)
        }
        if let shared = context.plans.description(covering: [guid]) {
            return try await bindPlan(for: target, guid: guid, shared: shared, version: version)
        }
        return try await perform("plan \(target.targetName)") { backend in
            try backend.checkContext(version)
            let shared = try await backend.sharedDescription(for: [target], guids: [guid], version: version)
            return try await backend.bindPlan(for: target, guid: guid, shared: shared, version: version)
        }
    }

    /// Called under the build lock; another request may have already planned the requested targets.
    func sharedDescription(
        for targets: [XcodeTargetIdentifier], guids: Set<String>, version: UUID
    ) async throws -> SwiftBuildIndexingDescription {
        if let shared = context.plans.description(covering: guids) { return shared }
        if !context.plans.hasPrimaryDescription, let roots = context.buildContext?.rootTargets, !roots.isEmpty {
            _ = try await createDescription(roots: roots, primary: true, version: version)
            if let shared = context.plans.description(covering: guids) { return shared }
        }
        return try await createDescription(roots: targets, primary: false, version: version)
    }

    func createDescription(
        roots: [XcodeTargetIdentifier], primary: Bool, version: UUID
    ) async throws -> SwiftBuildIndexingDescription {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var request = context.request
        for root in roots {
            try await request.add(target: SWBConfiguredTarget(guid: resolveGUID(root)))
        }
        try checkContext(version)
        statistics.buildDescriptions += 1
        let operation = try await session.createBuildOperationForBuildDescriptionOnly(
            request: request, delegate: IndexPlanningDelegate(), retainBuildDescription: true
        )
        let description = try await consumeDescription(operation) { logger.debug("Index planning: \($0)") }
        let shared = try await describe(request: request, description: description, version: version)
        context.plans.insert(shared, primary: primary)
        return shared
    }

    func describe(
        request: SWBBuildRequest, description: BuildDescription, version: UUID
    ) async throws -> SwiftBuildIndexingDescription {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        let targets = try await session.configuredTargets(buildDescription: description.id, buildRequest: request)
        try checkContext(version)
        return SwiftBuildIndexingDescription(
            request: request,
            description: description,
            targetGUIDs: Set(targets.map(\.identifier.targetGUID.rawValue))
        )
    }

    func bindPlan(
        for target: XcodeTargetIdentifier, guid: String, shared: SwiftBuildIndexingDescription, version: UUID
    ) async throws -> Plan {
        let plan = try await makePlan(request: shared.request, description: shared.description, guid: guid)
        try checkContext(version)
        context.plans.insert(plan, for: target)
        return plan
    }

    func consumeDescription(
        _ operation: SWBBuildOperation, log: (@Sendable (String) -> Void)?
    ) async throws -> BuildDescription {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var identifier: String?
        var wasLoadedOrCreated = false
        do {
            try await consume(operation, log: log) { event in
                switch event {
                case let .reportBuildDescription(info): identifier = info.buildDescriptionID
                case let .taskStarted(info) where info.ruleInfo == "CreateBuildDescription":
                    wasLoadedOrCreated = true
                default: break
                }
            }
            guard let identifier
            else { throw XcodeProjectError.invalidConfig("Swift Build returned no build description") }
            return BuildDescription(
                id: SWBBuildDescriptionID(identifier), session: session, wasLoadedOrCreated: wasLoadedOrCreated
            )
        } catch {
            if let identifier { await session.releaseBuildDescription(id: SWBBuildDescriptionID(identifier)) }
            throw error
        }
    }

    func makePlan(
        request: SWBBuildRequest,
        description: BuildDescription,
        guid: String
    ) async throws -> Plan {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        let targets = try await session.selectConfiguredTargetsForIndex(
            targets: [SWBTargetGUID(rawValue: guid)], buildDescription: description.id, buildRequest: request
        )
        guard targets.count == 1, let identifier = targets.first else {
            throw XcodeProjectError.invalidConfig("Swift Build cannot select one index configuration: \(guid)")
        }
        return Plan(request: request, description: description, target: identifier)
    }
}

private final class IndexPlanningDelegate: SWBPlanningOperationDelegate, Sendable {
    func provisioningTaskInputs(
        targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData
    ) async -> SWBProvisioningTaskInputs {
        SWBProvisioningTaskInputs()
    }

    func executeExternalTool(
        commandLine: [String], workingDirectory: String?, environment: [String: String]
    ) async throws -> SWBExternalToolResult {
        .deferred
    }
}
