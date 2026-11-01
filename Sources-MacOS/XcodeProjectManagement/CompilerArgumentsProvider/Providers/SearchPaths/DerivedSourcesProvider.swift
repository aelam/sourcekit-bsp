import Foundation

struct DerivedSourcesProvider: CompileArgProvider, Sendable {
    func arguments(for context: ArgContext) -> [String] {
        buildModuleProductIncludeDir(settings: context.buildSettings) +
            buildDerivedSourcesIncludeDir(settings: context.buildSettings) +
            buildGeneratedAssetSymbols(settings: context.buildSettings, compiler: context.compiler)
    }

    private func buildModuleProductIncludeDir(settings: [String: String]) -> [String] {
        guard
            let configurationBuildDir = settings["CONFIGURATION_BUILD_DIR"],
            let targetName = settings["TARGET_NAME"]
        else {
            return []
        }

        let moduleIncludePath = URL(fileURLWithPath: configurationBuildDir)
            .appendingPathComponent(targetName)
            .appendingPathComponent("include")

        return ["-I", moduleIncludePath.path]
    }

    private func buildDerivedSourcesIncludeDir(settings: [String: String]) -> [String] {
        guard
            let configurationTempDir = settings["CONFIGURATION_TEMP_DIR"],
            let nativeArch = settings["NATIVE_ARCH"]
        else {
            return []
        }

        let parentDir = URL(fileURLWithPath: configurationTempDir)

        let derivedNormalDir = parentDir
            .appendingPathComponent("DerivedSources-normal")
            .appendingPathComponent(nativeArch)
        let derivedArchDir = parentDir
            .appendingPathComponent("DerivedSources")
            .appendingPathComponent(nativeArch)
        let derivedDir = parentDir.appendingPathComponent("DerivedSources")

        return [
            "-I", derivedNormalDir.path,
            "-I", derivedArchDir.path,
            "-I", derivedDir.path
        ]
    }

    /// swift only
    private func buildGeneratedAssetSymbols(settings: [String: String], compiler: CompilerType) -> [String] {
        guard
            compiler == .swift,
            let configurationTempDir = settings["CONFIGURATION_TEMP_DIR"],
            settings["GENERATE_ASSET_SYMBOLS"] == "YES"
        else {
            return []
        }

        return [
            URL(fileURLWithPath: configurationTempDir)
                .appendingPathComponent("DerivedSources")
                .appendingPathComponent("GeneratedAssetSymbols.swift")
                .path
        ]
    }
}
