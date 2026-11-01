import Foundation

struct GCCWarningProvider: CompileArgProvider, Sendable {
    /// https://developer.apple.com/documentation/xcode/build-settings-reference
    /// https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/XcodeBuildSettingRef/1-Build_Setting_Reference/build_setting_ref.html
    let warnFlagMap: [String: [String: [String]]] = [
        "GCC_WARN_64_TO_32_BIT_CONVERSION": [
            "YES": ["-Wconversion"],
            "YES_ERROR": ["-Wconversion", "-Werror"]
        ],
        "GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS": [
            "YES": ["-Wdeprecated-declarations"],
            "YES_ERROR": ["-Wdeprecated-declarations", "-Werror"]
        ],
        "GCC_WARN_ABOUT_INVALID_OFFSETOF_MACRO": [
            "YES": ["-Winvalid-offsetof"],
            "YES_ERROR": ["-Winvalid-offsetof", "-Werror"]
        ],
        "GCC_WARN_ABOUT_MISSING_FIELD_INITIALIZERS": [
            "YES": ["-Wmissing-field-initializers"],
            "YES_ERROR": ["-Wmissing-field-initializers", "-Werror"]
        ],
        "GCC_WARN_ABOUT_RETURN_TYPE": [
            "YES": ["-Wreturn-type"],
            "YES_ERROR": ["-Werror=return-type"]
        ],
        "GCC_WARN_SHADOW": [
            "YES": ["-Wshadow"],
            "YES_ERROR": ["-Wshadow", "-Werror"]
        ],
        "GCC_WARN_SIGN_COMPARE": [
            "YES": ["-Wsign-compare"],
            "YES_ERROR": ["-Wsign-compare", "-Werror"]
        ],
        "GCC_WARN_STRICT_SELECTOR_MATCH": [
            "YES": ["-Wstrict-selector-match"],
            "YES_ERROR": ["-Wstrict-selector-match", "-Werror"]
        ],
        "GCC_WARN_TYPECHECK_CALLS_TO_PRINTF": [
            "YES": ["-Wformat"],
            "YES_ERROR": ["-Wformat", "-Werror"]
        ],
        "GCC_WARN_UNINITIALIZED_AUTOS": [
            "YES": ["-Wuninitialized"],
            "YES_AGGRESSIVE": ["-Wuninitialized", "-Wconditional-uninitialized"],
            "YES_ERROR": ["-Wuninitialized", "-Werror"]
        ],
        "GCC_WARN_UNUSED_FUNCTION": [
            "YES": ["-Wunused-function"],
            "YES_ERROR": ["-Wunused-function", "-Werror"]
        ],
        "GCC_WARN_UNUSED_LABEL": [
            "YES": ["-Wunused-label"],
            "YES_ERROR": ["-Wunused-label", "-Werror"]
        ],
        "GCC_WARN_UNUSED_PARAMETER": [
            "YES": ["-Wunused-parameter"],
            "YES_ERROR": ["-Wunused-parameter", "-Werror"]
        ],
        "GCC_WARN_UNUSED_VALUE": [
            "YES": ["-Wunused-value"],
            "YES_ERROR": ["-Wunused-value", "-Werror"]
        ],
        "GCC_WARN_UNUSED_VARIABLE": [
            "YES": ["-Wunused-variable"],
            "YES_ERROR": ["-Wunused-variable", "-Werror"]
        ],
        "GCC_WARN_UNDECLARED_SELECTOR": [
            "YES": ["-Wundeclared-selector"],
            "YES_ERROR": ["-Wundeclared-selector", "-Werror"]
        ],
        "GCC_WARN_UNREACHABLE_CODE": [
            "YES": ["-Wunreachable-code"],
            "YES_ERROR": ["-Wunreachable-code", "-Werror"]
        ]
    ]

    func arguments(for context: ArgContext) -> [String] {
        guard context.compiler == .clang else { return [] }
        return buildFlags(settings: context.buildSettings)
    }

    private func buildFlags(settings: [String: String]) -> [String] {
        var flags: [String] = []

        for (key, flagMap) in warnFlagMap {
            if let yesKey = settings[key], let flag = flagMap[yesKey] {
                flags.append(contentsOf: flag)
            }
        }

        return flags
    }
}
