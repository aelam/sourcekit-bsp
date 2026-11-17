import Foundation
import Testing
@testable import XcodeProjectManagement

struct XcodeIndexingSelectionTests {
    @Test
    func normalizesRootsAndReadsSelectionsFromOlderServers() throws {
        let first = XcodeTargetIdentifier(projectFilePath: "/tmp/App.xcodeproj", targetName: "App")
        let second = XcodeTargetIdentifier(projectFilePath: "/tmp/App.xcodeproj", targetName: "Tests")
        let selection = XcodeIndexingSelection(platform: "macosx", rootTargets: [second, first, second])
        #expect(selection == XcodeIndexingSelection(platform: "macosx", rootTargets: [first, second]))
        let encoded = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(XcodeIndexingSelection.self, from: encoded) == selection)
        let legacy = Data(#"{"platform":"macosx","configuration":"Debug"}"#.utf8)
        let decoded = try JSONDecoder().decode(XcodeIndexingSelection.self, from: legacy)
        #expect(decoded.rootTargets == nil)
        #expect(decoded.configuration == "Debug")
    }

    @Test
    func persistsAcrossReadersAndDoesNotRewriteUnchangedSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try XcodeIndexingSelection.load(in: root) == nil)
        let simulator = XcodeIndexingSelection(
            platform: "iphonesimulator",
            architecture: "arm64",
            configuration: "Debug"
        )
        #expect(try simulator.save(in: root))
        #expect(try XcodeIndexingSelection.load(in: root) == simulator)
        let file = XcodeIndexingSelection.file(in: root)
        let before = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(try !simulator.save(in: root))
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
        let device = XcodeIndexingSelection(platform: "iphoneos", configuration: "Release")
        #expect(try device.save(in: root))
        #expect(try XcodeIndexingSelection.load(in: root) == device)
        try Data("invalid".utf8).write(to: file)
        #expect(throws: DecodingError.self) { try XcodeIndexingSelection.load(in: root) }
    }
}
