import Foundation

struct LanguageStandardProvider: CompileArgProvider, Sendable {
    func arguments(for context: ArgContext) -> [String] {
        if context.compiler == .swift {
            buildSwiftFlags(settings: context.buildSettings)
        } else {
            buildClangFlags(settings: context.buildSettings, dialect: context.languageDialect)
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

    private func buildClangFlags(settings: [String: String], dialect: XcodeLanguageDialect) -> [String] {
        let standard: String?
        switch dialect {
        case .c, .objc:
            standard = settings["GCC_C_LANGUAGE_STANDARD"]
        case .cpp, .objcCpp:
            standard = settings["CLANG_CXX_LANGUAGE_STANDARD"]
        default:
            return []
        }
        guard let standard, !standard.isEmpty, standard != "compiler-default" else { return [] }
        if standard == "ansi", dialect == .c || dialect == .objc { return ["-ansi"] }
        return ["-std=\(standard)"]
    }
}
