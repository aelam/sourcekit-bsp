import Foundation
import Logger
import SwiftBuild

actor SwiftBuildIndexingBackend: XcodeIndexingBackend {
    nonisolated let indexStoreURL: URL
    nonisolated let indexDatabaseURL: URL
    private typealias Plan = SwiftBuildIndexingPlan
    private typealias BuildDescription = Plan.BuildDescription

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
            try await self.perform("load workspace") { backend in
                guard backend.workspace == nil else { return true }
                backend.workspace = try await SwiftBuildIndexingWorkspace.load(
                    snapshot: backend.snapshot, serviceExecutable: backend.serviceExecutable
                )
                backend.statistics.workspaceLoads += 1
                return true
            }
        }
    }

    private func plan(for target: XcodeTargetIdentifier, version: UUID) async throws -> Plan {
        try await ensureLoaded()
        try checkContext(version)
        if let cached = context.plans.plan(for: target) { return cached }
        let key = SwiftBuildIndexingOperations.PlanningKey(target: target, contextVersion: version)
        return try await operations.planning.prepare(for: key) { _ in
            try await self.perform("plan \(target.targetName)") { backend in
                try backend.checkContext(version)
                if let cached = backend.context.plans.plan(for: target) { return cached }
                return try await backend.createPlan(for: target, version: version)
            }
        }
    }

    private func createPlan(for target: XcodeTargetIdentifier, version: UUID) async throws -> Plan {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        let (targetRequest, guid) = try await makeTargetRequest(for: target)
        try checkContext(version)
        statistics.buildDescriptions += 1
        let operation = try await session.createBuildOperationForBuildDescriptionOnly(
            request: targetRequest, delegate: IndexPlanningDelegate(), retainBuildDescription: true
        )
        let plan = try await consumePlan(operation, request: targetRequest, guid: guid) {
            logger.debug("Index planning: \($0)")
        }
        try checkContext(version)
        context.plans.insert(plan, for: target)
        return plan
    }

    private func makeTargetRequest(for target: XcodeTargetIdentifier) async throws -> (SWBBuildRequest, String) {
        let guid = try await resolveGUID(target)
        var targetRequest = context.request
        targetRequest.add(target: SWBConfiguredTarget(guid: guid))
        targetRequest.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [guid], enableIndexBuildArena: true)
        return (targetRequest, guid)
    }

    private func consumePlan(
        _ operation: SWBBuildOperation, request: SWBBuildRequest, guid: String,
        log: (@Sendable (String) -> Void)?
    ) async throws -> Plan {
        let description = try await consumeDescription(operation, log: log)
        return try await makePlan(request: request, description: description, guid: guid)
    }

    private func consumeDescription(
        _ operation: SWBBuildOperation, log: (@Sendable (String) -> Void)?
    ) async throws -> BuildDescription {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var identifier: String?
        do {
            try await consume(operation, log: log) { event in
                if case let .reportBuildDescription(info) = event { identifier = info.buildDescriptionID }
            }
            guard let identifier
            else { throw XcodeProjectError.invalidConfig("Swift Build returned no build description") }
            return BuildDescription(id: SWBBuildDescriptionID(identifier), session: session)
        } catch {
            if let identifier { await session.releaseBuildDescription(id: SWBBuildDescriptionID(identifier)) }
            throw error
        }
    }

    private func makePlan(
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
            let plan = try await plan(for: target, version: version)
            let result = try await perform("compiler arguments", serializeBuild: false) { backend in
                try backend.checkContext(version)
                return try await backend.arguments(for: target, file: file, plan: plan)
            }
            try checkContext(version)
            guard context.arguments.publish(result, for: key, version: inputs) else { continue }
            return result
        }
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
        let paths: [URL: AbsolutePath]
        if let cached = context.plans.paths(for: target, descriptionID: plan.descriptionID) {
            paths = cached
        } else {
            let sources = try await session.sources(
                of: [plan.target],
                buildDescription: plan.descriptionID,
                buildRequest: plan.request
            )
            paths = Dictionary(sources.flatMap(\.sourceFiles).map {
                (URL(fileURLWithPath: $0.path.pathString).resolvingSymlinksInPath(), $0.path)
            }, uniquingKeysWith: { first, _ in first })
            try checkContext(version)
            context.plans.storePaths(paths, for: target, descriptionID: plan.descriptionID)
        }
        // PIF loading can spell symlinked paths differently from the client's document URI.
        let path = try paths[file.resolvingSymlinksInPath()] ?? AbsolutePath(validating: file.path)
        statistics.compilerArgumentQueries += 1
        return try await session.indexCompilerArguments(
            of: path, in: plan.target,
            buildDescription: plan.descriptionID, buildRequest: plan.request
        )
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

    func invalidateInputs() {
        context.invalidateInputs()
    }

    private func prepareOperation(
        targets: [XcodeTargetIdentifier], version: UUID, log: @escaping @Sendable (String) -> Void
    ) async throws -> [XcodeTargetIdentifier] {
        guard let session = workspace?.session
        else { throw XcodeProjectError.invalidConfig("Swift Build is not ready") }
        var batchRequest = context.request
        var guids: [String] = []
        for target in targets {
            try Task.checkCancellation()
            let guid = try await resolveGUID(target)
            guids.append(guid)
            batchRequest.add(target: SWBConfiguredTarget(guid: guid))
        }
        try checkContext(version)
        batchRequest.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: guids, enableIndexBuildArena: true)
        let operation = try await session.createBuildOperation(
            request: batchRequest, delegate: IndexPlanningDelegate(), retainBuildDescription: true
        )
        let description = try await consumeDescription(operation, log: log)
        try checkContext(version)
        context.arguments.invalidate()
        let inputs = context.arguments.version
        var changed: Set<XcodeTargetIdentifier> = []
        for (target, guid) in zip(targets, guids) {
            try Task.checkCancellation()
            let prepared = try await makePlan(request: batchRequest, description: description, guid: guid)
            try checkContext(version)
            context.plans.insert(prepared, for: target)
            // Refresh this target before another preparation can evict its description.
            // Unrelated targets can hold expired IDs and must not fail this preparation.
            let previousOptions = context.arguments.published(for: target)
            for (key, previous) in previousOptions {
                let current = try await arguments(for: target, file: key.file, plan: prepared)
                try checkContext(version)
                if current != previous { changed.insert(target) }
                context.arguments.publish(current, for: key, version: inputs)
            }
        }
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
        await operations.preparation.stop()
        await operations.planning.stop()
        await operations.initialization.stop()
        for completion in operations.cancelPending() {
            await completion.value
        }
        context.plans = SwiftBuildIndexingPlanCache()
        await workspace?.close()
        workspace = nil
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
