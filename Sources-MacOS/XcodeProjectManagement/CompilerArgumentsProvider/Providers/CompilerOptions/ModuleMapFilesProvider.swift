import Foundation

struct ModuleMapFilesProvider: CompileArgProvider, Sendable {
    func arguments(for context: ArgContext) -> [String] {
        buildModuleMapFilesFlag(derivedDataPath: context.derivedDataPath, compiler: context.compiler)
    }

    private func buildModuleMapFilesFlag(derivedDataPath: URL, compiler: CompilerType) -> [String] {
        let moduleMapsFolder = derivedDataPath
            .appendingPathComponent("Build/Intermediates.noindex")
            .appendingPathComponent("GeneratedModuleMaps")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: moduleMapsFolder,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let moduleMapFiles = contents.filter { $0.pathExtension.lowercased() == "modulemap" }.map(\.path).sorted()

        return moduleMapFiles.flatMap { moduleMapFile in
            if compiler == .swift {
                ["-Xcc", "-fmodule-map-file=\(moduleMapFile)"]
            } else {
                ["-fmodule-map-file=\(moduleMapFile)"]
            }
        }
    }
}
