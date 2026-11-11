import Foundation
import Testing
@testable import XcodeProjectManagement
@testable import XcodeProjectManagerProvider

struct SourcesItemConversionTests {
    @Test
    func preservesSourceRootsAndExplicitFileMembershipInProtocolResponse() throws {
        let target = XcodeTargetIdentifier(projectFilePath: "/tmp/App.xcodeproj", targetName: "App")
        let root = URL(fileURLWithPath: "/tmp/源码 100%20", isDirectory: true)
        let file = SourceItem(path: root.appendingPathComponent("App.swift"), itemKind: .file)
        let item = SourcesItem(target: target, sources: [file], roots: [root])
        let result = item.asBSPSourcesItems()
        #expect(result.target == target.bspIdentifier)
        #expect(result.roots?.map(\.stringValue) == [root.absoluteString])
        #expect(result.sources.count == 1)
        #expect(result.sources[0].uri.stringValue == file.path.absoluteString)
        #expect(result.sources[0].kind == .file)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(object["roots"] as? [String] == [root.absoluteString])
    }

    @Test
    func preservesMissingAndEmptyRoots() throws {
        let target = XcodeTargetIdentifier(projectFilePath: "/tmp/App.xcodeproj", targetName: "App")
        let missing = SourcesItem(target: target, sources: []).asBSPSourcesItems()
        #expect(missing.roots == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(missing)) as? [String: Any])
        #expect(object["roots"] == nil)
        #expect(SourcesItem(target: target, sources: [], roots: []).asBSPSourcesItems().roots == [])
    }
}
