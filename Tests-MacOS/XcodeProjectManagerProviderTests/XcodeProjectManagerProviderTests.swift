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
    @Test(arguments: [
        "generic/platform=iOS Simulator",
        "generic/platform=iOS",
        "platform=macOS,arch=arm64",
        "SIM-UDID"
    ])
    func preservesDestinationArguments(destination: String) throws {
        let projectURL = URL(fileURLWithPath: "/tmp/Hello.xcodeproj")
        let target = XcodeTarget(
            targetIdentifier: XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Hello"),
            name: "Hello",
            projectURL: projectURL,
            productName: "Hello",
            xcodeProductType: .application,
            destinations: [XcodeDestination(name: "Destination", id: destination, platform: .iOS, type: .simulator)]
        )
        let bspTarget = try #require(target.asBSPBuildTarget())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bspTarget)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let selectors = try #require(data["selectors"] as? [[String: Any]])
        let values = try #require(selectors[1]["values"] as? [[String: Any]])
        let expected = destination.contains("platform=") ? destination : "id=\(destination)"
        #expect(values[0]["arguments"] as? [String] == ["-destination", expected])
    }

    @Test
    func xcodeProjectManagerProvider() {}

    @Test(arguments: [XcodeProductType.unitTestBundle, .uiTestBundle, .application])
    func advertisesTestDebuggingForUnitTests(productType: XcodeProductType) throws {
        let projectURL = URL(fileURLWithPath: "/tmp/Hello.xcodeproj")
        let target = XcodeTarget(
            targetIdentifier: XcodeTargetIdentifier(projectFilePath: projectURL.path, targetName: "Tests"),
            name: "Tests",
            projectURL: projectURL,
            productName: "Tests",
            xcodeProductType: productType
        )
        #expect(try #require(target.asBSPBuildTarget()).capabilities.canDebug == (productType != .uiTestBundle))
    }
}
