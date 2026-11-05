import Foundation
import XcodeProj

public enum CompilerType: Sendable { case swift, clang }

struct ArgContext: Sendable {
    let buildSettings: [String: String]
    let languageDialect: XcodeLanguageDialect
    let compiler: CompilerType
    let fileURL: URL?
    let sourceItems: [SourceItem]
    let derivedDataPath: URL
    let xcodeInstallation: XcodeInstallation?
}

enum CompileArgDependency {
    case target, file, swiftSources
}

protocol CompileArgProvider: Sendable {
    var dependency: CompileArgDependency { get }
    func arguments(for context: ArgContext) -> [String]
}

extension CompileArgProvider {
    /// Providers that read fileURL must declare a file dependency.
    var dependency: CompileArgDependency {
        .target
    }
}

protocol BuildSettingResolvable: Sendable {
    func resolve(forKey key: String) -> String?
    func resolveFileCompilerFlags(for fileURL: URL) -> [String]?
}

public struct CompileArgGenerator: Sendable {
    let argContext: ArgContext
    let providers: [CompileArgProvider]

    public func compileArguments() -> [String] {
        var args: [String] = []
        for provider in providers {
            args += provider.arguments(for: argContext)
        }
        return args
    }
}

public extension CompileArgGenerator {
    static func create(
        xcodeInstallation: XcodeInstallation,
        xcodeGlobalSettings: XcodeGlobalSettings,
        xcodeProj: XcodeProj,
        target: String,
        configurationName: String = "Debug",
        fileURL: URL,
        sourceItems: [SourceItem] = []
    ) throws -> CompileArgGenerator {
        let buildSettings = try BuildSettingResolver(
            xcodeInstallation: xcodeInstallation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: target,
            configuration: configurationName
        )

        let languageDialect = XcodeLanguageDialect(fileExtension: fileURL.pathExtension)
        let argContext = ArgContext(
            buildSettings: buildSettings.resolvedBuildSettings,
            languageDialect: languageDialect,
            compiler: languageDialect.isSwift ? .swift : .clang,
            fileURL: fileURL,
            sourceItems: sourceItems,
            derivedDataPath: xcodeGlobalSettings.derivedDataPath,
            xcodeInstallation: xcodeInstallation
        )

        return CompileArgGenerator(
            argContext: argContext,
            providers: standardProviders
        )
    }
}

extension CompileArgGenerator {
    static let standardProviders: [CompileArgProvider] = [
        WorkingDirectoryProvider(),
        // Platform
        SDKProvider(),
        TargetTripleProvider(),
        // CompilerOptions
        ClangProvider(),
        ClangWarningProvider(),
        GCCWarningProvider(),
        ModuleProvider(),
        ModuleMapFilesProvider(),
        ObjectiveCFeaturesProvider(),
        LanguageStandardProvider(),
        SwiftProvider(),
        SwiftFilesProvider(),
        PCHProvider(),

        // SearchPaths
        HeaderSearchPathProvider(),
        LibrarySearchPathProvider(),
        FrameworkSearchPathProvider(),
        HeaderMapProvider(),
        DerivedSourcesProvider(),
        VFSOverlayProvider(),
        TestSearchPathProvider(),

        // DebugInfo
        DebugInfoProvider(),
        ProfileProvider(),

        // Toolchain and DerivedData
        SDKStatCacheProvider(),
        IndexStoreProvider(),
        OutputProvider(),
    ]
}
