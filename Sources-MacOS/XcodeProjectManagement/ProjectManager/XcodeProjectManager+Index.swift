import Foundation
import Logger
import Support

public enum IndexPreparationError: Error, LocalizedError {
    case projectNotInitialized
    case targetNotFound(String)
    case buildFailed(target: String, exitCode: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .projectNotInitialized:
            "Project not initialized"
        case let .targetNotFound(target):
            "Unknown index target: \(target)"
        case let .buildFailed(target, exitCode, output):
            "Index preparation for \(target) failed (exit \(exitCode)):\n\(output)"
        }
    }
}

struct IndexPreparationKey: Hashable, Sendable {
    let target: XcodeTargetIdentifier
    let buildGraphVersion: UUID
    let inputVersion: UUID
}

public extension XcodeProjectManager {
    /// Watched input changes must separate new requests from an active preparation.
    func invalidateIndexInputs() {
        indexInputVersion = UUID()
    }

    /// Build the inputs SourceKit-LSP needs before it indexes a target.
    func prepareForIndexing(
        targetIdentifiers: [XcodeTargetIdentifier],
        logHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> [XcodeTargetIdentifier] {
        guard let base = projectSnapshot else {
            throw IndexPreparationError.projectNotInitialized
        }
        var targets: [XcodeTarget] = []
        for identifier in targetIdentifiers {
            guard let target = base.xcodeTargets.first(where: { $0.targetIdentifier == identifier }) else {
                throw IndexPreparationError.targetNotFound(identifier.rawValue)
            }
            if !targets.contains(where: { $0.targetIdentifier == identifier }) {
                targets.append(target)
            }
        }
        guard !targets.isEmpty else { return [] }

        let id = UUID()
        let preparation = Task {
            try Task.checkCancellation()
            return try await self.prepareIndexTargets(targets, logHandler: logHandler)
        }
        indexPreparationTasks[id] = preparation
        defer {
            indexPreparationTasks[id] = nil
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    func stopIndexPreparation() async {
        let tasks = Array(indexPreparationTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.result
        }
        await indexPreparationCoordinator.cancelAll()
    }
}

extension XcodeProjectManager {
    private func prepareIndexTarget(
        _ target: XcodeTarget, key: IndexPreparationKey, logHandler: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        guard key.buildGraphVersion == buildGraphVersion else { throw CancellationError() }
        try Task.checkCancellation()
        let identifier = target.targetIdentifier
        let before = try await indexingOptions(for: identifier)
        let output = IndexPreparationOutput(logHandler: logHandler)
        logger.info("Preparing index inputs for \(target.name)")
        let status = try await compileTarget(
            targetIdentifier: identifier,
            configuration: nil,
            arguments: indexBuildArguments(for: target),
            outputHandler: output
        )
        guard status == 0 else {
            throw await IndexPreparationError.buildFailed(
                target: target.name, exitCode: status, output: output.summary
            )
        }
        guard key.buildGraphVersion == buildGraphVersion else { throw CancellationError() }
        // Notify only when options changed, so preparation does not trigger an indexing loop.
        return try await indexingOptions(for: identifier) != before
    }

    func indexBuildArguments(for target: XcodeTarget) -> [String] {
        var arguments = [
            "CODE_SIGNING_ALLOWED=NO",
            "COMPILER_INDEX_STORE_ENABLE=YES",
            "ONLY_ACTIVE_ARCH=YES"
        ]
        if let settings = projectSnapshot?.xcodeGlobalSettings {
            arguments.append("INDEX_DATA_STORE_DIR=\(settings.indexStoreURL.path)")
        }
        return buildArguments(for: target, configuration: nil, arguments: arguments)
    }

    func indexPreparationKey(for target: XcodeTargetIdentifier) -> IndexPreparationKey {
        IndexPreparationKey(target: target, buildGraphVersion: buildGraphVersion, inputVersion: indexInputVersion)
    }

    private func prepareIndexTargets(
        _ targets: [XcodeTarget], logHandler: (@Sendable (String) -> Void)?
    ) async throws -> [XcodeTargetIdentifier] {
        var changedTargets: [XcodeTargetIdentifier] = []
        for target in targets {
            try Task.checkCancellation()
            let key = indexPreparationKey(for: target.targetIdentifier)
            let handler: @Sendable (String) -> Void = logHandler ?? { logger.info($0) }
            let changed = try await indexPreparationCoordinator.prepare(for: key, logHandler: handler) { sharedLog in
                try await self.prepareIndexTarget(target, key: key, logHandler: sharedLog)
            }
            if changed { changedTargets.append(target.targetIdentifier) }
        }
        return changedTargets
    }

    private func indexingOptions(for target: XcodeTargetIdentifier) async throws -> [String: CompilerOptionsSnapshot] {
        let files = getSourcesItems(targetIdentifiers: [target])
            .flatMap(\.sources)
            .filter { $0.itemKind == .file }
            .map(\.path)
        var result: [String: CompilerOptionsSnapshot] = [:]
        for dialect in [XcodeLanguageDialect.swift, .c, .cpp, .objc, .objcCpp] {
            let matching = files.filter { XcodeLanguageDialect(fileExtension: $0.pathExtension) == dialect }
            guard !matching.isEmpty, let template = try compilerArgumentsTemplate(for: target, dialect: dialect) else {
                continue
            }
            result[dialect.rawValue] = template.snapshot(for: matching)
        }
        return result
    }
}

private actor IndexPreparationOutput: ProcessOutputHandler {
    private var lines: [String] = []
    private let logHandler: (@Sendable (String) -> Void)?

    init(logHandler: (@Sendable (String) -> Void)?) {
        self.logHandler = logHandler
    }

    var summary: String {
        lines.joined(separator: "\n")
    }

    func handleProcess(output: FileHandle, error: FileHandle) async {
        await withTaskGroup(of: Void.self) { group in
            for handle in [output, error] {
                group.addTask {
                    await StreamingFileHandleReader.streamPipe(handle) { line in
                        await self.append(line)
                    }
                }
            }
        }
    }

    private func append(_ line: String) {
        if let logHandler { logHandler(line) } else { logger.info(line) }
        lines.append(line)
        if lines.count > 40 { lines.removeFirst() }
    }

    func handleCompletion(_ exitCode: Int32) async {}
}
