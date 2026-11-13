import Foundation
import SourceKitBSPProtocol
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMDiscoveryTests {
    @Test
    func resolvesToolchainFromSwiftShimAndRequiresLanguageServer() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let toolchain = fixture.root.appendingPathComponent("Toolchain 空", isDirectory: true)
        let executable = fixture.root.appendingPathComponent("shims/swift")
        let metadata = try JSONSerialization.data(withJSONObject: [
            "paths": ["runtimeResourcePath": toolchain.appendingPathComponent("usr/lib/swift").path]
        ])
        let executor = FixtureCommandExecutor(metadata)
        #expect(try await SwiftPMDiscoveryToolchain.resolve(
            executable: executable, executor: executor, root: fixture.root
        ) == nil)
        try fixture.write("", to: "usr/bin/sourcekit-lsp", in: toolchain)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: toolchain.appendingPathComponent("usr/bin/sourcekit-lsp").path
        )
        #expect(try await SwiftPMDiscoveryToolchain.resolve(
            executable: executable, executor: executor, root: fixture.root
        ) == toolchain)
        #expect(await executor.calls.allSatisfy {
            $0.executable == executable && $0.arguments == ["-print-target-info"]
        })
        await executor.set(metadata, code: 1)
        #expect(try await SwiftPMDiscoveryToolchain.resolve(
            executable: executable, executor: executor, root: fixture.root
        ) == nil)
        await executor.set(Data("not JSON".utf8))
        #expect(try await SwiftPMDiscoveryToolchain.resolve(
            executable: executable, executor: executor, root: fixture.root
        ) == nil)
    }

    @Test
    func advertisesDiscoveryForTestTargetsWithExactModuleName() async throws {
        let fixture = try TemporarySwiftPMPackage()
        let metadata = try fixture.describe(targets: [
            describedTarget("Core"), describedTarget("Core-Tests", type: "test")
        ])
        let toolchain = fixture.root.appendingPathComponent("toolchain", isDirectory: true)
        let manager = SwiftPMProjectManager(
            rootURL: fixture.root,
            executable: fixture.root.appendingPathComponent("swift"),
            executor: FixtureCommandExecutor(metadata),
            discoveryToolchain: toolchain
        )
        try await manager.initialize()
        let targets = await manager.getTargetList()
        let tests = try #require(targets.first { $0.displayName == "Core-Tests" })
        #expect(tests.dataKind == .sourceKit)
        #expect(tests.data == .dictionary([
            "toolchain": .string(toolchain.absoluteString),
            "testDiscovery": .dictionary([
                "provider": .string("sourcekit-lsp"), "version": .int(1),
                "selectionDataKind": .string("sourcekit-test-selection"), "moduleName": .string("Core_Tests")
            ])
        ]))
        #expect(targets.first { $0.displayName == "Core" }?.data == nil)
        let withoutToolchain = fixture.manager(executor: FixtureCommandExecutor(metadata))
        try await withoutToolchain.initialize()
        #expect(await withoutToolchain.getTargetList().allSatisfy { $0.dataKind == nil && $0.data == nil })
    }
}
