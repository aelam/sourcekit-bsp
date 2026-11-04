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
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
        try await manager.initialize()
        let base = try #require(await manager.xcodeProjectBaseInfo)
        let app = try #require(base.xcodeTargets.first { $0.name == "Hello" })
        let renamedScheme = try #require(base.schemes.first { $0.name == "CustomApp" })
        let selected = try await manager.findOrCreateScheme(
            for: app,
            in: [renamedScheme],
            buildConfiguration: "Release"
        )
        #expect(selected.name == "CustomApp")
        let project = try await manager.buildConfiguration(for: app)
        if case let .project(_, .scheme(name)) = project {
            #expect(name != "Hello")
            #expect(base.schemes.contains { $0.name == name })
        } else {
            Issue.record("Expected a project scheme")
        }

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
        let debugArguments = try await manager.testDebugArguments(for: testTarget, arguments: testDebugInput)
        #expect(debugArguments == testArguments + ["SWIFT_DEBUG_INFORMATION_VERSION=dwarf4"])
        #expect(!defaults.contains { $0.hasPrefix("SWIFT_DEBUG_INFORMATION_VERSION=") })
        for version in ["dwarf4", "dwarf5", "compiler-default"] {
            let input = testDebugInput + ["SWIFT_DEBUG_INFORMATION_VERSION=\(version)"]
            let normal = try await manager.testArguments(for: testTarget, arguments: input)
            let debug = try await manager.testDebugArguments(for: testTarget, arguments: input)
            #expect(debug == normal)
        }

        let testSettings = try await manager.resolvedBuildSettings(for: testTarget, arguments: defaults)
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
        let generated = try await manager.findOrCreateScheme(for: testTarget, in: [])
        let scheme = try XCScheme(pathString: generated.path.path)
        let projectFile = try XcodeProj(pathString: projectURL.path)
        let nativeTarget = try #require(projectFile.pbxproj.nativeTargets.first { $0.name == "HelloTests" })
        #expect(scheme.testAction?.testables.first?.buildableReference.blueprintIdentifier == nativeTarget.uuid)
        #expect(generated.primaryTarget == "HelloTests")
    }
}
