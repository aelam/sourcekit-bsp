import Foundation

struct ModuleProvider: CompileArgProvider, Sendable {
    /// `-fmodules`,   `-fmodule-name  Foo`
    func arguments(for context: ArgContext) -> [String] {
        let moduleCachePath = context.derivedDataPath
            .deletingLastPathComponent()
            .appendingPathComponent("ModuleCache.noindex")
        switch context.compiler {
        case .swift:
            return buildSwiftFlags(settings: context.buildSettings, moduleCachePath: moduleCachePath)
        case .clang:
            return buildClangFlags(settings: context.buildSettings, moduleCachePath: moduleCachePath)
        }
    }

    private func buildSwiftFlags(settings: [String: String], moduleCachePath: URL) -> [String] {
        var flags: [String] = []

        if let moduleName = settings["PRODUCT_MODULE_NAME"] {
            flags.append(contentsOf: ["-module-name", moduleName])
        }

        flags.append(contentsOf: ["-module-cache-path", moduleCachePath.path])
        flags.append(contentsOf: ["-Xcc", "-Xclang", "-Xcc", "-fmodule-format=raw"])
        flags.append(contentsOf: ["-Xcc", "-fmodules-validate-system-headers"])
        flags.append(contentsOf: ["-Xcc", "-fretain-comments-from-system-headers"])
        return flags
    }

    private func buildClangFlags(settings: [String: String], moduleCachePath: URL) -> [String] {
        guard settings["CLANG_ENABLE_MODULES"] == "YES" else {
            return []
        }

        var flags: [String] = []
        flags.append("-fmodules")
        flags.append(contentsOf: ["-fmodules-cache-path=\(moduleCachePath.path)"])
        flags.append(contentsOf: ["-Xclang", "-fmodule-format=raw"])
        flags.append("-fmodules-validate-system-headers")
        flags.append("-fretain-comments-from-system-headers")
        flags.append(contentsOf: [
            "-fmodules-prune-interval=86400",
            "-fmodules-prune-after=345600"
        ])

        if let moduleName = settings["PRODUCT_MODULE_NAME"] {
            flags.append("-fmodule-name=\(moduleName)")
        }

        // Warning
        // flags.append("-Wnon-modular-include-in-framework-module")
        // flags.append("-Werror=non-modular-include-in-framework-module")
        flags.append("-Wno-error=non-modular-include-in-framework-module")

        return flags
    }
}
