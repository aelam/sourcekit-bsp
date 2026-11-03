//
//  XcodeToolchainTests.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

@Suite("XcodeToolchain Tests")
struct XcodeToolchainTests {
    @Test
    func prefersSelectedXcode() async throws {
        let toolchain = XcodeToolchain()
        try await toolchain.initialize()
        let selected = try #require(await toolchain.getSelectedInstallation())
        let expected: String
        if let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            expected = developerDir
        } else {
            let result = try await ProcessExecutor().execute(
                executable: "/usr/bin/xcode-select", arguments: ["--print-path"]
            )
            #expect(result.exitCode == 0)
            expected = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(selected.isXcodeSelectedVersion)
        }
        #expect(selected.developerDir.resolvingSymlinksInPath() == URL(fileURLWithPath: expected)
            .resolvingSymlinksInPath())
        let adapter = try await LLDBDAPServer.locateLLDBDAP(developerDirectory: selected.developerDir)
        #expect(adapter.hasPrefix(selected.developerDir.path + "/"))
    }

    @Test("Toolchain can be initialized")
    func toolchainInitialization() async throws {
        let toolchain = XcodeToolchain()

        #expect(await toolchain.getSelectedInstallation() == nil)

        try await toolchain.initialize()

        // After initialization, should have selected an installation
        let installation = await toolchain.getSelectedInstallation()
        #expect(installation != nil)

        if let installation {
            #expect(!installation.version.isEmpty)
            #expect(installation.path.pathExtension == "app")
            #expect(installation.xcodebuildPath.lastPathComponent == "xcodebuild")
        }
    }

    @Test("Toolchain can check if xcodebuild is available")
    func xcodeBuildAvailability() async throws {
        let toolchain = XcodeToolchain()
        try await toolchain.initialize()

        let isAvailable = await toolchain.isXcodeBuildAvailable()

        // Should be true on macOS with Xcode installed
        #expect(isAvailable == true)
    }

    @Test("Toolchain can execute xcodebuild version")
    func xcodeBuildVersion() async throws {
        let toolchain = XcodeToolchain()
        try await toolchain.initialize()

        let version = try await toolchain.getXcodeVersion()

        #expect(!version.isEmpty)
        #expect(version.contains("Xcode"))

        // In CI, also log the Xcode version for debugging
        if ProcessInfo.processInfo.environment["CI"] != nil {
            print("🔧 CI Xcode version: \(version)")
        }
    }

    @Test("Toolchain can execute xcodebuild with arguments")
    func xcodeBuildExecution() async throws {
        let toolchain = XcodeToolchain()
        try await toolchain.initialize()

        let result = try await toolchain.executeXcodeBuild(arguments: ["-version"])

        #expect(result.exitCode == 0)
        #expect(!result.output.isEmpty)
        #expect(result.output.contains("Xcode"))
    }

    @Test("Toolchain with custom DEVELOPER_DIR")
    func testCustomDeveloperDir() async throws {
        // Skip this test in CI environments as it depends on specific local paths
        if ProcessInfo.processInfo.environment["CI"] != nil {
            print("⏭️  Skipping testCustomDeveloperDir in CI environment")
            return // Skip in CI
        }

        // Test with a custom developer directory
        let customDir = "/Applications/Xcode.app/Contents/Developer"

        // Only run if the standard Xcode path exists
        guard FileManager.default.fileExists(atPath: customDir) else {
            print("⏭️  Skipping testCustomDeveloperDir - Xcode not found at standard location")
            return // Skip if Xcode not found at standard location
        }

        let toolchain = XcodeToolchain(customDeveloperDir: customDir)
        try await toolchain.initialize()

        let installation = await toolchain.getSelectedInstallation()
        #expect(installation != nil)

        // The key test: when we explicitly set DEVELOPER_DIR, it should be marked as such
        #expect(installation?.isDeveloperDirVersion == true)
    }

    @Test("Toolchain handles invalid paths gracefully")
    func invalidPaths() async {
        let toolchain = XcodeToolchain(customDeveloperDir: "/invalid/path")

        do {
            try await toolchain.initialize()

            // If initialization succeeds, it found other Xcode installations
            let installation = await toolchain.getSelectedInstallation()
            #expect(installation != nil)
        } catch {
            // It's okay if it fails with an invalid path, as long as it doesn't crash
            #expect(error is XcodeToolchainError)
        }
    }
}
