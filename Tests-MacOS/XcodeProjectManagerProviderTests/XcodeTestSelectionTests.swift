import BuildServerProtocol
import Foundation
import Testing
import XcodeProjectManagement
@testable import XcodeProjectManagerProvider

struct XcodeTestSelectionTests {
    private func target() -> XcodeTarget {
        let project = URL(fileURLWithPath: "/tmp/App.xcodeproj")
        return XcodeTarget(
            targetIdentifier: .init(projectFilePath: project.path, targetName: "Tests With Spaces"),
            name: "Tests With Spaces",
            projectURL: project,
            productName: "CustomModule",
            xcodeProductType: .unitTestBundle
        )
    }

    @Test
    func advertisesTestDiscoveryAndTheSelectedToolchain() throws {
        let target = try #require(target()
            .asBSPBuildTarget(toolchain: URL(fileURLWithPath: "/Xcode/Swift.xctoolchain")))
        let data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any])
        #expect(data["tags"] as? [String] == ["test"])
        let metadata = try #require(data["data"] as? [String: Any])
        #expect(metadata["toolchain"] as? String == "file:///Xcode/Swift.xctoolchain")
        let discovery = try #require(metadata["testDiscovery"] as? [String: Any])
        #expect(discovery["selectionDataKind"] as? String == "sourcekit-test-selection")
    }

    @Test(arguments: ["XCTest", "swift-testing"])
    func mapsIdentifiersWithoutUsingModuleOrDisplayNames(style: String) throws {
        let target = target()
        let id = target.targetIdentifier.bspIdentifier
        let data = selection(id: id, style: style)
        let arguments = try XcodeTestSelection.arguments(
            targets: [target],
            requested: [id],
            arguments: ["-configuration", "Debug"],
            dataKind: XcodeTestSelection.dataKind,
            data: data
        )
        let suffix = style == "XCTest" ? "Suite/example" : "Suite/example()"
        #expect(arguments == ["-configuration", "Debug", "-only-testing:Tests With Spaces/\(suffix)"])
    }

    private func selection(id: BSPBuildTargetIdentifier, style: String) -> LSPAny {
        let test: LSPAny = [
            "target": ["uri": .string(id.uri.stringValue)],
            "id": "Suite/example()",
            "style": .string(style)
        ]
        return ["tests": .array([test])]
    }

    @Test
    func rejectsEmptyMalformedForeignAndConflictingSelections() throws {
        let target = target()
        let id = target.targetIdentifier.bspIdentifier
        let invalid: [LSPAny] = [
            ["tests": []], [:],
            ["tests": [["target": ["uri": "file:///Other"], "id": "Suite/example()", "style": "XCTest"]]],
            ["tests": [["target": ["uri": .string(id.uri.stringValue)], "id": "", "style": "XCTest"]]],
            ["tests": [["target": ["uri": .string(id.uri.stringValue)], "id": "*", "style": "XCTest"]]],
            ["tests": [["target": ["uri": .string(id.uri.stringValue)], "id": "Suite/example()", "style": "unknown"]]]
        ]
        for data in invalid {
            #expect(throws: (any Error).self) {
                try XcodeTestSelection.arguments(
                    targets: [target],
                    requested: [id],
                    arguments: nil,
                    dataKind: XcodeTestSelection.dataKind,
                    data: data
                )
            }
        }
        let valid = selection(id: id, style: "XCTest")
        for argument in ["-only-testing:Tests", "-skip-testing:Tests", "-testPlan"] {
            #expect(throws: (any Error).self) {
                try XcodeTestSelection.arguments(
                    targets: [target],
                    requested: [id],
                    arguments: [argument],
                    dataKind: XcodeTestSelection.dataKind,
                    data: valid
                )
            }
        }
        #expect(throws: (any Error).self) {
            try XcodeTestSelection.arguments(
                targets: [target],
                requested: [id],
                arguments: nil,
                dataKind: "unknown",
                data: valid
            )
        }
    }
}
