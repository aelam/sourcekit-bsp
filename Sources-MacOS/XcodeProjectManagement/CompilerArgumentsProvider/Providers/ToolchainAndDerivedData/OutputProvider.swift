import Foundation

// "-o",
// "/Users/wang.lun/Work/line-stickers-ios/build/Pods.build/Debug-iphoneos/LCSComponents.build/Objects-normal/arm64/LCSComponents-dummy.o",
// "-index-unit-output-path",
// "/Pods.build/Debug-iphoneos/LCSComponents.build/Objects-normal/arm64/LCSComponents-dummy.o",

struct OutputProvider: CompileArgProvider, Sendable {
    var dependency: CompileArgDependency {
        .file
    }

    func arguments(for context: ArgContext) -> [String] {
        guard
            let fileURL = context.fileURL
        else {
            return []
        }

        let derivedDataPath = context.derivedDataPath

        return buildArgumentsForClang(
            settings: context.buildSettings,
            fileURL: fileURL,
            derivedDataPath: derivedDataPath
        )
    }

    private func buildArgumentsForClang(
        settings: [String: String],
        fileURL: URL,
        derivedDataPath: URL
    ) -> [String] {
        guard
            let configurationTempDir = settings["CONFIGURATION_TEMP_DIR"],
            let arch = settings["NATIVE_ARCH"]
        else {
            return []
        }

        let fileName = fileURL.deletingPathExtension().lastPathComponent + ".o"
        let configurationTempDirURL = URL(fileURLWithPath: configurationTempDir)

        let outputFilePath = configurationTempDirURL
            .appendingPathComponent("Objects-normal")
            .appendingPathComponent(arch)
            .appendingPathComponent(fileName)

        let parentDirectory = derivedDataPath.appendingPathComponent("Build/Intermediates.noindex")
        let indexUnitOutputPath = outputFilePath.path.replacingOccurrences(
            of: parentDirectory.path, with: ""
        )
        return [
            "-o", outputFilePath.path,
            "-index-unit-output-path", indexUnitOutputPath
        ]
    }
}
