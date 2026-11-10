import Foundation
import Testing
@testable import XcodeProjectManagement

struct LanguageStandardProviderTests {
    @Test(arguments: [XcodeLanguageDialect.c, .objc])
    func cLanguagesUseOnlyTheCStandard(dialect: XcodeLanguageDialect) {
        #expect(clangArguments(dialect: dialect, settings: [
            "GCC_C_LANGUAGE_STANDARD": "gnu11",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++14"
        ]) == ["-std=gnu11"])
        #expect(clangArguments(dialect: dialect, settings: ["CLANG_CXX_LANGUAGE_STANDARD": "gnu++14"]).isEmpty)
    }

    @Test(arguments: [XcodeLanguageDialect.cpp, .objcCpp])
    func cppLanguagesUseOnlyTheCppStandard(dialect: XcodeLanguageDialect) {
        #expect(clangArguments(dialect: dialect, settings: [
            "GCC_C_LANGUAGE_STANDARD": "gnu11",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++14"
        ]) == ["-std=gnu++14"])
        #expect(clangArguments(dialect: dialect, settings: ["GCC_C_LANGUAGE_STANDARD": "gnu11"]).isEmpty)
    }

    @Test(arguments: [XcodeLanguageDialect.c, .objc, .cpp, .objcCpp])
    func absentOrDefaultStandardsDoNotAddAFlag(dialect: XcodeLanguageDialect) {
        for value in ["", "compiler-default"] {
            #expect(clangArguments(dialect: dialect, settings: [
                "GCC_C_LANGUAGE_STANDARD": value,
                "CLANG_CXX_LANGUAGE_STANDARD": value
            ]).isEmpty)
        }
        #expect(clangArguments(dialect: dialect, settings: [:]).isEmpty)
    }

    @Test(arguments: [XcodeLanguageDialect.c, .objc])
    func ansiCUsesTheClangAnsiOption(dialect: XcodeLanguageDialect) {
        #expect(clangArguments(dialect: dialect, settings: ["GCC_C_LANGUAGE_STANDARD": "ansi"]) == ["-ansi"])
    }

    private func clangArguments(dialect: XcodeLanguageDialect, settings: [String: String]) -> [String] {
        LanguageStandardProvider().arguments(for: ArgContext(
            buildSettings: settings,
            languageDialect: dialect,
            compiler: .clang,
            fileURL: nil,
            sourceItems: [],
            derivedDataPath: URL(fileURLWithPath: "/tmp/DerivedData/Project"),
            xcodeInstallation: nil
        ))
    }

    @Test
    func normalizesXcodeSwiftVersions() {
        let cases = [
            (xcode: "4.0", compiler: "4"),
            (xcode: "4.2", compiler: "4.2"),
            (xcode: "5.0", compiler: "5"),
            (xcode: "5.10", compiler: "5"),
            (xcode: "6.0", compiler: "6"),
            (xcode: "6.1", compiler: "6"),
            (xcode: "6", compiler: "6"),
        ]

        for item in cases {
            let arguments = LanguageStandardProvider().arguments(
                for: context(swiftVersion: item.xcode)
            )
            #expect(arguments == ["-swift-version", item.compiler])
        }
    }

    private func context(swiftVersion: String) -> ArgContext {
        ArgContext(
            buildSettings: ["SWIFT_VERSION": swiftVersion],
            languageDialect: XcodeLanguageDialect(fileExtension: "swift"),
            compiler: .swift,
            fileURL: nil,
            sourceItems: [],
            derivedDataPath: URL(fileURLWithPath: "/tmp/DerivedData/Project"),
            xcodeInstallation: nil
        )
    }
}
