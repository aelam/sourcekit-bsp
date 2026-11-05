import Foundation

public extension XcodeProjectManager {
    func getCompileArguments(targetIdentifier: XcodeTargetIdentifier, sourceFileURL: URL) async throws -> [String] {
        try compilerArgumentsTemplate(
            for: targetIdentifier,
            dialect: XcodeLanguageDialect(fileExtension: sourceFileURL.pathExtension)
        )?.arguments(for: sourceFileURL) ?? []
    }
}

extension XcodeProjectManager {
    func compilerArgumentsTemplate(
        for target: XcodeTargetIdentifier, dialect: XcodeLanguageDialect
    ) throws -> CompileArgumentsTemplate? {
        let projectURL = URL(fileURLWithPath: target.projectFilePath)
        guard let snapshot = projectSnapshot, let project = loadXcodeProjCache(projectURL: projectURL) else {
            return nil
        }
        let key = CompilerSettingsCache.Key(
            target: XcodeTargetIdentifier(
                projectFilePath: projectURL.resolvingSymlinksInPath().standardizedFileURL.path,
                targetName: target.targetName
            ),
            configuration: snapshot.configuration,
            developerDirectory: snapshot.xcodeInstallation.developerDir,
            buildVersion: snapshot.xcodeInstallation.buildVersion,
            derivedData: snapshot.xcodeGlobalSettings.derivedDataPath
        )
        let settings = try projectStore.compilerSettings.settings(for: key) {
            try BuildSettingResolver(
                xcodeInstallation: snapshot.xcodeInstallation,
                xcodeGlobalSettings: snapshot.xcodeGlobalSettings,
                xcodeProj: project,
                target: target.targetName,
                configuration: snapshot.configuration
            ).resolvedBuildSettings
        }
        let sources = getSourcesItems(targetIdentifiers: [target]).first?.sources ?? []
        return CompileArgumentsTemplate(context: ArgContext(
            buildSettings: settings,
            languageDialect: dialect,
            compiler: dialect.isSwift ? .swift : .clang,
            fileURL: nil,
            sourceItems: sources,
            derivedDataPath: snapshot.xcodeGlobalSettings.derivedDataPath,
            xcodeInstallation: snapshot.xcodeInstallation
        ))
    }
}
