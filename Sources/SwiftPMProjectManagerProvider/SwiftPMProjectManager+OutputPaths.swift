import BuildServerProtocol
import Foundation

public extension SwiftPMProjectManager {
    func outputPaths(for targets: [BSPBuildTargetIdentifier]) async throws
        -> [BuildTargetOutputPathsResult.OutputPathsItem] {
        guard !isShutDown else { throw SwiftPMProjectError.shutDown }
        guard let project else { throw SwiftPMProjectError.notInitialized }
        for target in targets where project.target(for: target) == nil {
            throw SwiftPMProjectError.unknownTarget(target.uri.stringValue)
        }
        let selections = targets.map { ($0, outputBuildArguments[$0] ?? []) }
        var directories: [[String]: URL] = [:]
        var result: [BuildTargetOutputPathsResult.OutputPathsItem] = []
        for (target, arguments) in selections {
            let directory: URL
            if let cached = directories[arguments] {
                directory = cached
            } else {
                directory = try await binaryDirectory(arguments: arguments)
                directories[arguments] = directory
            }
            result.append(.init(target: target, outputPaths: [.init(uri: URI(directory), kind: .directory)]))
        }
        return result
    }
}

extension SwiftPMProjectManager {
    func recordOutputArguments(_ arguments: [String], for targets: [BSPBuildTargetIdentifier]) {
        let pathOptions: Set = [
            "--configuration", "-c", "--scratch-path", "--sdk", "--triple",
            "--swift-sdk", "--toolchain", "--arch", "--build-system"
        ]
        let otherValues: Set = [
            "--cache-path", "--config-path", "--security-path", "--jobs", "-j",
            "-Xswiftc", "-Xcc", "-Xcxx", "-Xlinker", "-Xmanifest", "--traits", "--num-workers",
            "--sanitize", "--xunit-output", "--attachments-path"
        ]
        var options: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let option = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            let hasValue = !argument.contains("=") && (pathOptions.contains(option) || otherValues.contains(option))
            if pathOptions.contains(option) { options.append(argument) }
            if hasValue, index + 1 < arguments.count {
                index += 1
                if pathOptions.contains(option) { options.append(arguments[index]) }
            }
            index += 1
        }
        for target in project?.dependencyClosure(for: targets) ?? [] {
            outputBuildArguments[target] = options
        }
    }
}
