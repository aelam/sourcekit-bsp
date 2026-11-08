//
//  XcodeProjectManagerProviderTests.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/22.
//

import Foundation
import Testing
import XcodeProjectManagement
@testable import XcodeProjectManagerProvider

struct XcodeProjectManagerProviderTests {
    @Test(arguments: [XcodeProductType.unitTestBundle, .uiTestBundle, .application])
    func targetMetadataPreservesLanguageServicesWithoutExecutionSelectors(productType: XcodeProductType) throws {
        let projectURL = URL(fileURLWithPath: "/tmp/Hello.xcodeproj")
        let toolchain = URL(fileURLWithPath: "/tmp/Xcode.xctoolchain")
        let target = XcodeTarget(
            targetIdentifier: XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello"),
            name: "Hello",
            projectURL: projectURL,
            productName: "Hello",
            xcodeProductType: productType,
            buildConfigurations: ["Debug", "Release", "Custom"],
            destinations: [XcodeDestination(name: "Simulator", id: "SIM-UDID", platform: .iOS, type: .simulator)]
        )
        let bspTarget = target.asBSPBuildTarget(toolchain: toolchain)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bspTarget)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        #expect(object["dataKind"] as? String == "sourceKit")
        #expect(data["toolchain"] as? String == toolchain.absoluteString)
        #expect(Set(data.keys) == (productType.isTestBundle ? ["toolchain", "testDiscovery"] : ["toolchain"]))
        if productType.isTestBundle {
            let discovery = try #require(data["testDiscovery"] as? [String: Any])
            #expect(discovery["provider"] as? String == "sourcekit-lsp")
            #expect(discovery["version"] as? Int == 1)
            #expect(discovery["selectionDataKind"] as? String == "sourcekit-test-selection")
        }
    }

    @Test
    func xcodeProjectManagerProvider() {}

    @Test(arguments: [XcodeProductType.unitTestBundle, .uiTestBundle, .application])
    func advertisesTestDebuggingForUnitTests(productType: XcodeProductType) {
        let projectURL = URL(fileURLWithPath: "/tmp/Hello.xcodeproj")
        let target = XcodeTarget(
            targetIdentifier: XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Tests"),
            name: "Tests",
            projectURL: projectURL,
            productName: "Tests",
            xcodeProductType: productType
        )
        #expect(target.asBSPBuildTarget().capabilities.canDebug == (productType != .uiTestBundle))
    }
}
