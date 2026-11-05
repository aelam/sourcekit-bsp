//
//  XcodeProjectManagerTests.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Testing
@testable import XcodeProjectManagement

struct XcodeProjectManagerTests {
    @Test
    func loadProjectFromWorkspace() async throws {
        let projectFolder = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("DemoProjects")
            .appendingPathComponent("HelloWorkspace"))

        let toolchain = XcodeToolchain()
        let projectManager = XcodeProjectManager(
            rootURL: projectFolder,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(
                commandBuilder: XcodeBuildCommandBuilder(),
                toolchain: toolchain
            )
        )
        try await projectManager.initialize()
        guard let projectSnapshot = await projectManager.projectSnapshot else {
            throw NSError(domain: "XcodeProjectManagerTests", code: 1, userInfo: nil)
        }

        #expect(projectSnapshot.rootURL == projectFolder)

        switch projectSnapshot.projectLocation {
        case let .explicitWorkspace(url):
            #expect(url.lastPathComponent == "Hello.xcworkspace")
        case .implicitWorkspace:
            Issue.record("Expected explicit workspace, got implicit project workspace")
        case .standaloneProject:
            Issue.record("Expected explicit workspace, got standalone project")
        }
    }

    @Test
    func loadProjectFromXcodeproj() async throws {
        let projectFolder = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("DemoProjects")
            .appendingPathComponent("HelloProject"))
        let toolchain = XcodeToolchain()
        let projectManager = XcodeProjectManager(
            rootURL: projectFolder,
            toolchain: toolchain,
            projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(
                commandBuilder: XcodeBuildCommandBuilder(),
                toolchain: toolchain
            )
        )
        try await projectManager.initialize()
        guard let projectSnapshot = await projectManager.projectSnapshot else {
            throw NSError(domain: "XcodeProjectManagerTests", code: 1, userInfo: nil)
        }
        #expect(projectSnapshot.rootURL == projectFolder)

        switch projectSnapshot.projectLocation {
        case .explicitWorkspace:
            Issue.record("Expected implicit project workspace, got explicit workspace")
        case let .implicitWorkspace(_, url):
            #expect(url.path.contains("Hello.xcodeproj/project.xcworkspace"))
        case .standaloneProject:
            Issue.record("Expected implicit project workspace, got standalone project")
        }
    }
}
