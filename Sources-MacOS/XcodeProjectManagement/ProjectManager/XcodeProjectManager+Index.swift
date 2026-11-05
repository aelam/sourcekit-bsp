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

public extension XcodeProjectManager {
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
    }
}

extension XcodeProjectManager {
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

    private func prepareIndexTargets(
        _ targets: [XcodeTarget], logHandler: (@Sendable (String) -> Void)?
    ) async throws -> [XcodeTargetIdentifier] {
        var changedTargets: [XcodeTargetIdentifier] = []
        for target in targets {
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
            // Notify only when options changed, so preparation does not trigger an indexing loop.
            if try await indexingOptions(for: identifier) != before {
                changedTargets.append(identifier)
            }
        }
        return changedTargets
    }

    private func indexingOptions(for target: XcodeTargetIdentifier) async throws -> [URL: [String]] {
        var result: [URL: [String]] = [:]
        for item in getSourcesItems(targetIdentifiers: [target]).flatMap(\.sources) where item.itemKind == .file {
            switch XcodeLanguageDialect(fileExtension: item.path.pathExtension) {
            case .swift, .c, .cpp, .objc, .objcCpp:
                result[item.path] = try await getCompileArguments(targetIdentifier: target, sourceFileURL: item.path)
            default:
                break
            }
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
