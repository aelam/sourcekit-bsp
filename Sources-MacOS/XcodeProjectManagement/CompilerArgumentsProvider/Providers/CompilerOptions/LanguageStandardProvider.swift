import Foundation

struct LanguageStandardProvider: CompileArgProvider, Sendable {
    func arguments(for context: ArgContext) -> [String] {
        if context.compiler == .swift {
            buildSwiftFlags(settings: context.buildSettings)
        } else {
            buildClangFlags(settings: context.buildSettings)
        }
    }

    private func buildSwiftFlags(settings: [String: String]) -> [String] {
        var flags: [String] = []

        if let swiftVersion = settings["SWIFT_VERSION"] {
            flags.append(contentsOf: [
                "-swift-version",
                swiftLanguageMode(from: swiftVersion),
            ])
        }

        return flags
    }

    private func swiftLanguageMode(from xcodeVersion: String) -> String {
        let components = xcodeVersion.split(separator: ".")
        guard let majorVersion = components.first,
              Int(majorVersion) != nil
        else {
            return xcodeVersion
        }

        if majorVersion == "4", components.dropFirst().first == "2" {
            return "4.2"
        }
        return String(majorVersion)
    }

    private func buildClangFlags(settings: [String: String]) -> [String] {
        var flags: [String] = []

        if let std = settings["CLANG_CXX_LANGUAGE_STANDARD"] {
            flags.append("-std=\(std)")
        }
        if let std = settings["CLANG_C_LANGUAGE_STANDARD"] {
            flags.append("-std=\(std)")
        }

        return flags
    }
}
