import Foundation

/// Retains common arguments once and expands file arguments only on request.
struct CompileArgumentsTemplate: Sendable {
    private enum Part: Sendable {
        case common([String])
        case file(any CompileArgProvider)
        case swiftSources([String], includePrimary: Bool)
    }

    private let context: ArgContext
    private let parts: [Part]

    init(context: ArgContext) {
        self.context = context
        self.parts = CompileArgGenerator.standardProviders.map { provider in
            switch provider.dependency {
            case .target:
                return .common(provider.arguments(for: context))
            case .file:
                return .file(provider)
            case .swiftSources:
                let files = Set(provider.arguments(for: context)).sorted()
                return .swiftSources(files, includePrimary: context.compiler == .swift && !context.sourceItems.isEmpty)
            }
        }
    }

    func arguments(for file: URL) -> [String] {
        let context = context(for: file)
        let primaryPath = file.path
        return parts.flatMap { part in
            switch part {
            case let .common(arguments): arguments
            case let .file(provider): provider.arguments(for: context)
            case let .swiftSources(files, includePrimary):
                includePrimary ? [primaryPath] + files.filter { $0 != primaryPath } : files
            }
        }
    }

    func snapshot(for files: [URL]) -> CompilerOptionsSnapshot {
        let common = parts.compactMap { part -> [String]? in
            switch part {
            case let .common(arguments), let .swiftSources(arguments, _): arguments
            case .file: nil
            }
        }
        var fileArguments: [URL: [String]] = [:]
        for file in files {
            let context = context(for: file)
            fileArguments[file] = parts.flatMap { part -> [String] in
                guard case let .file(provider) = part else { return [] }
                return provider.arguments(for: context)
            }
        }
        return CompilerOptionsSnapshot(commonArguments: common, fileArguments: fileArguments)
    }

    private func context(for file: URL) -> ArgContext {
        ArgContext(
            buildSettings: context.buildSettings,
            languageDialect: context.languageDialect,
            compiler: context.compiler,
            fileURL: file,
            sourceItems: context.sourceItems,
            derivedDataPath: context.derivedDataPath,
            xcodeInstallation: context.xcodeInstallation
        )
    }
}

struct CompilerOptionsSnapshot: Equatable, Sendable {
    let commonArguments: [[String]]
    let fileArguments: [URL: [String]]
}
