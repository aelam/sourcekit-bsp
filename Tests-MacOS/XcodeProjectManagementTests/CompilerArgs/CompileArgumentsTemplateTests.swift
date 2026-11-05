import Foundation
import Testing
@testable import XcodeProjectManagement

struct CompileArgumentsTemplateTests {
    private func context(
        root: URL,
        sources: [SourceItem],
        dialect: XcodeLanguageDialect,
        file: URL? = nil
    ) -> ArgContext {
        ArgContext(
            buildSettings: [
                "CONFIGURATION_TEMP_DIR": root.appendingPathComponent("Demo.build").path,
                "CONFIGURATION_BUILD_DIR": root.appendingPathComponent("Products").path,
                "NATIVE_ARCH": "arm64",
                "TARGET_TRIPLE": "arm64-apple-ios18.0-simulator",
                "OTHER_CFLAGS": "-DTEST",
                "SWIFT_VERSION": "5",
                "GENERATE_ASSET_SYMBOLS": "YES"
            ],
            languageDialect: dialect,
            compiler: dialect.isSwift ? .swift : .clang,
            fileURL: file,
            sourceItems: sources,
            derivedDataPath: root,
            xcodeInstallation: nil
        )
    }

    @Test
    func preservesArgumentsForSwiftAndClangFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompilerTemplate-\(UUID())")
        let directory = root.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: directory.appendingPathComponent("Generated.swift"))
        let files = ["B.swift", "A.swift", "Sample.c", "Sample.cpp", "Sample.m", "Sample.mm"].map {
            root.appendingPathComponent($0)
        }
        let sources = files.map { SourceItem(path: $0, itemKind: .file) } + [
            SourceItem(path: files[0], itemKind: .file), SourceItem(path: directory, itemKind: .directory)
        ]
        for file in files {
            let dialect = XcodeLanguageDialect(fileExtension: file.pathExtension)
            let expected = CompileArgGenerator(
                argContext: context(root: root, sources: sources, dialect: dialect, file: file),
                providers: CompileArgGenerator.standardProviders
            ).compileArguments()
            let template = CompileArgumentsTemplate(context: context(root: root, sources: sources, dialect: dialect))
            #expect(template.arguments(for: file) == expected)
        }
    }

    @Test
    func snapshotsTrackGeneratedInputsAndSourceMembership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompilerSnapshot-\(UUID())")
        let maps = root.appendingPathComponent("Build/Intermediates.noindex/GeneratedModuleMaps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("A.swift")
        let added = root.appendingPathComponent("B.swift")
        let sources = [SourceItem(path: file, itemKind: .file)]
        func snapshot(_ sources: [SourceItem]) -> CompilerOptionsSnapshot {
            CompileArgumentsTemplate(context: context(root: root, sources: sources, dialect: .swift))
                .snapshot(for: sources.map(\.path))
        }
        let initial = snapshot(sources)
        #expect(snapshot(sources) == initial)
        let moduleMap = maps.appendingPathComponent("New.modulemap")
        try Data("module New {}".utf8).write(to: moduleMap)
        #expect(snapshot(sources) != initial)
        try FileManager.default.removeItem(at: moduleMap)
        #expect(snapshot(sources) == initial)
        #expect(snapshot(sources + [SourceItem(path: added, itemKind: .file)]) != initial)
    }

    @Test
    func snapshotStoresTheSwiftFileListOnce() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompactSnapshot-\(UUID())")
        let sources = (0 ..< 1000).map {
            SourceItem(path: root.appendingPathComponent("File\($0).swift"), itemKind: .file)
        }
        let template = CompileArgumentsTemplate(context: context(root: root, sources: sources, dialect: .swift))
        let snapshot = template.snapshot(for: sources.map(\.path))
        let stored = snapshot.commonArguments.flatMap(\.self) + snapshot.fileArguments.values.flatMap(\.self)
        #expect(snapshot.fileArguments.count == sources.count)
        let swiftPaths = stored.count { $0.hasSuffix(".swift") }
        #expect(swiftPaths == sources.count + 1)
        #expect(stored.count < 10 * sources.count)
    }
}
