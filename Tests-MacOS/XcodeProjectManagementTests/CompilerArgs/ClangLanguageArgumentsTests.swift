import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct ClangLanguageArgumentsTests {
    private let settings = [
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++14",
        "OTHER_CFLAGS": "-DC_ONLY",
        "OTHER_CPLUSPLUSFLAGS": "-DCXX_ONLY -std=gnu++14"
    ]

    private func context(file: URL, settings: [String: String]) -> ArgContext {
        ArgContext(
            buildSettings: settings,
            languageDialect: XcodeLanguageDialect(fileExtension: file.pathExtension),
            compiler: .clang,
            fileURL: file,
            sourceItems: [],
            derivedDataPath: file.deletingLastPathComponent(),
            xcodeInstallation: nil
        )
    }

    @Test(arguments: ["c", "m", "cpp", "mm", "cc", "cxx", "C"])
    func clangAcceptsLanguageSpecificArguments(fileExtension: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClangLanguages-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sample.\(fileExtension)")
        let source = """
        #if defined(__cplusplus)
        #if !defined(CXX_ONLY) || defined(C_ONLY) || __cplusplus != 201402L
        #error Incorrect C++ options
        #endif
        #else
        #if !defined(C_ONLY) || defined(CXX_ONLY) || __STDC_VERSION__ != 201112L
        #error Incorrect C options
        #endif
        #endif
        #if defined(__OBJC__)
        __attribute__((objc_root_class)) @interface Sample @end
        #endif
        int sample(void) { return 0; }
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let context = context(file: file, settings: settings)
        #expect(context.languageDialect.isClang)
        let arguments = CompileArgGenerator(
            argContext: context,
            providers: [ClangProvider(), LanguageStandardProvider()]
        ).compileArguments()
        let result = try await ProcessExecutor().execute(
            executable: "/usr/bin/xcrun",
            arguments: ["clang", "-fsyntax-only"] + arguments,
            timeout: 30
        )
        #expect(result.exitCode == 0, "\(result.error ?? result.output)")
    }

    @Test(arguments: ["cpp", "mm"])
    func cppFlagsUseTheCDefaultOnlyWhenUnset(fileExtension: String) {
        let file = URL(fileURLWithPath: "/tmp/Sample.\(fileExtension)")
        let inherited = ClangProvider().arguments(for: context(file: file, settings: ["OTHER_CFLAGS": "-DCOMMON"]))
        let inheritedCommonCount = inherited.count { $0 == "-DCOMMON" }
        #expect(inheritedCommonCount == 1)

        let explicitlyEmpty = ClangProvider().arguments(for: context(file: file, settings: [
            "OTHER_CFLAGS": "-DCOMMON", "OTHER_CPLUSPLUSFLAGS": ""
        ]))
        #expect(!explicitlyEmpty.contains("-DCOMMON"))

        let resolvedInheritance = ClangProvider().arguments(for: context(file: file, settings: [
            "OTHER_CFLAGS": "-DCOMMON", "OTHER_CPLUSPLUSFLAGS": "-DCOMMON -DCXX"
        ]))
        let resolvedCommonCount = resolvedInheritance.count { $0 == "-DCOMMON" }
        #expect(resolvedCommonCount == 1)
        #expect(resolvedInheritance.contains("-DCXX"))
    }

    @Test
    func mixedTargetTemplatesKeepLanguageOptionsSeparate() {
        let objc = URL(fileURLWithPath: "/tmp/Sample.m")
        let objcCpp = URL(fileURLWithPath: "/tmp/Sample.mm")
        let objcTemplate = CompileArgumentsTemplate(context: context(file: objc, settings: settings))
        let cppTemplate = CompileArgumentsTemplate(context: context(file: objcCpp, settings: settings))

        for _ in 0 ..< 2 {
            let cArguments = objcTemplate.arguments(for: objc)
            #expect(cArguments.contains("-std=gnu11"))
            #expect(!cArguments.contains("-std=gnu++14"))
            #expect(!cArguments.contains("-DCXX_ONLY"))

            let cppArguments = cppTemplate.arguments(for: objcCpp)
            #expect(cppArguments.contains("-std=gnu++14"))
            #expect(!cppArguments.contains("-std=gnu11"))
            #expect(!cppArguments.contains("-DC_ONLY"))
        }
    }
}
