//
//  CompileTests.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/09/07.
//
import Foundation
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct CompileTests {
    @Test
    func resolvesSchemesAndBuildArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("Hello.xcodeproj")
        let schemesURL = projectURL.appendingPathComponent("xcshareddata/xcschemes")
        let original = schemesURL.appendingPathComponent("Hello.xcscheme")
        let renamed = schemesURL.appendingPathComponent("CustomApp.xcscheme")
        try FileManager.default.moveItem(at: original, to: renamed)
        let toolchain = XcodeToolchain(workingDirectory: root)
        let manager = XcodeProjectManager(
            rootURL: root,
            xcodeProjectReference: XcodeProjectReference(scheme: "CustomApp"),
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        try await manager.initialize()
        let base = try #require(await manager.projectSnapshot)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" })
        try await verifySchemeSelection(manager: manager, base: base, app: app, renamed: renamed)

        let defaults = await manager.buildArguments(for: app, configuration: nil, arguments: nil)
        #expect(defaults.contains("generic/platform=iOS Simulator"))
        #expect(defaults.contains(base.xcodeGlobalSettings.derivedDataPath.path))
        let explicit = ["-configuration", "Release", "-destination", "id=SIM", "-derivedDataPath", "/tmp/Custom"]
        let forwarded = await manager.buildArguments(for: app, configuration: "Debug", arguments: explicit)
        #expect(forwarded == explicit)

        let settings = try await manager.resolvedBuildSettings(for: app, arguments: defaults)
        #expect(settings["PLATFORM_NAME"] == "iphonesimulator")
        #expect(settings["CONFIGURATION"] == "Debug")
        #expect(settings["TARGET_BUILD_DIR"]?.hasPrefix(base.xcodeGlobalSettings.derivedDataPath.path) == true)

        let failedRun = await manager.run(
            xcodeTargetIdentifier: app.targetIdentifier,
            arguments: ["-destination", "id=BSP-NOT-A-DEVICE", "-destination-timeout", "1"],
            environmentVariables: nil,
            workingDirectory: nil
        )
        #expect(failedRun.statusCode == .error)
        #expect(failedRun.message?.contains("BSP-NOT-A-DEVICE") == true)

        let testTarget = try #require(base.xcodeTargets.first { $0.name == "HelloTests" })
        let testDebugInput = [
            "-destination", "id=SIM", "-configuration", "Debug", "-derivedDataPath", "/tmp/Custom",
            "OTHER_SWIFT_FLAGS=$(inherited) -DTEST_DEBUG", "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"
        ]
        let testArguments = try await manager.testArguments(for: testTarget, arguments: testDebugInput)
        let buildArguments = await manager.buildArguments(
            for: testTarget, configuration: nil, arguments: testDebugInput
        )
        #expect(buildArguments == testDebugInput + ["SWIFT_DEBUG_INFORMATION_VERSION=dwarf4"])
        #expect(testArguments.contains("SWIFT_DEBUG_INFORMATION_VERSION=dwarf4"))
        #expect(!defaults.contains { $0.hasPrefix("SWIFT_DEBUG_INFORMATION_VERSION=") })
        for version in ["dwarf4", "dwarf5", "compiler-default"] {
            let setting = "SWIFT_DEBUG_INFORMATION_VERSION=\(version)"
            let input = testDebugInput + [setting]
            let normal = try await manager.testArguments(for: testTarget, arguments: input)
            let build = await manager.buildArguments(for: testTarget, configuration: nil, arguments: input)
            #expect(build == input)
            #expect(normal.filter { $0.hasPrefix("SWIFT_DEBUG_INFORMATION_VERSION=") } == [setting])
        }

        let testSettings = try await manager.resolvedBuildSettings(for: testTarget, arguments: defaults)
        #expect(testSettings["SWIFT_DEBUG_INFORMATION_VERSION"] == "dwarf4")
        #expect(testSettings["FULL_PRODUCT_NAME"] == "HelloTests.xctest")
        #expect(testSettings["TEST_HOST"]?.contains("Hello.app/") == true)
        #expect(testSettings["PLATFORM_NAME"] == "iphonesimulator")
        for arguments in [["-only-testing:HelloTests/example"], ["-testPlan", "Plan"]] {
            await #expect(throws: XcodeProjectError.self) {
                try await manager.startDebugSession(
                    xcodeTargetIdentifier: testTarget.targetIdentifier, arguments: arguments
                )
            }
        }
        let schemeFiles = try FileManager.default.contentsOfDirectory(atPath: schemesURL.path).sorted()
        await #expect(throws: XcodeProjectError.self) {
            try await manager.findExistingScheme(for: testTarget, in: [])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: schemesURL.path).sorted() == schemeFiles)
    }

    private func verifySchemeSelection(
        manager: XcodeProjectManager, base: XcodeProjectSnapshot, app: XcodeTarget, renamed: URL
    ) async throws {
        let projectURL = app.projectURL
        let schemesURL = renamed.deletingLastPathComponent()
        let renamedScheme = try #require(base.schemes.first { $0.name == "CustomApp" })
        let selected = try await manager.findExistingScheme(
            for: app,
            in: [renamedScheme],
            buildConfiguration: "Release"
        )
        #expect(selected.name == "CustomApp")
        let disabled = try XCScheme(pathString: renamed.path)
        disabled.name = "DevelopmentTests"
        disabled.buildAction?.buildActionEntries.forEach { $0.buildFor = [] }
        let disabledURL = schemesURL.appendingPathComponent("DevelopmentTests.xcscheme")
        try disabled.write(path: .init(disabledURL.path), override: true)
        let disabledScheme = XcodeScheme(
            xcscheme: disabled,
            isInWorkspace: false,
            isUserScheme: false,
            projectURL: projectURL,
            path: disabledURL
        )
        let alternate = try XCScheme(pathString: renamed.path)
        alternate.name = "A-OtherApp"
        let alternateURL = schemesURL.appendingPathComponent("A-OtherApp.xcscheme")
        try alternate.write(path: .init(alternateURL.path), override: true)
        let alternateScheme = XcodeScheme(
            xcscheme: alternate,
            isInWorkspace: false,
            isUserScheme: false,
            projectURL: projectURL,
            path: alternateURL
        )
        let preferred = try await manager.findExistingScheme(
            for: app, in: [disabledScheme, alternateScheme, renamedScheme]
        )
        #expect(preferred.name == "CustomApp")
        let fallback = try await manager.findExistingScheme(
            for: app, in: [disabledScheme, alternateScheme]
        )
        #expect(fallback.name == "A-OtherApp")
        let project = try await manager.buildConfiguration(for: app)
        if case let .project(_, .scheme(name)) = project {
            #expect(name == "CustomApp")
            #expect(base.schemes.contains { $0.name == name })
        } else {
            Issue.record("Expected a project scheme")
        }
    }

    @Test
    func debugPreparationChecksProductsWithoutInvokingTheBuildExecutor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = try #require(Bundle.module.resourceURL?.appendingPathComponent("DemoProjects/HelloProject"))
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let toolchain = XcodeToolchain(workingDirectory: root)
        let manager = XcodeProjectManager(
            rootURL: root,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        try await manager.initialize()
        let base = try #require(await manager.projectSnapshot)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" })
        let arguments = [
            "-sdk", "iphonesimulator", "-derivedDataPath", root.appendingPathComponent("BuildData").path,
            "TARGET_DEVICE_IDENTIFIER=BSP-TEST-SIMULATOR"
        ]
        let resolved = try await manager.resolveDebugProduct(
            xcodeTargetIdentifier: app.targetIdentifier, arguments: arguments
        )
        // Any attempt to build after shutdown throws CancellationError.
        await manager.shutdownBuilds()
        do {
            _ = try await manager.prepareDebugProduct(
                xcodeTargetIdentifier: app.targetIdentifier, arguments: arguments
            )
            Issue.record("Expected a missing-product error")
        } catch let DebugSessionError.productNotFound(path) {
            #expect(path == resolved.binaryPath)
        }
        let executable = try URL(fileURLWithPath: #require(resolved.executablePath))
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: executable)
        let product = try await manager.prepareDebugProduct(
            xcodeTargetIdentifier: app.targetIdentifier, arguments: arguments
        )
        #expect(product.binaryPath == resolved.binaryPath)
    }
}
