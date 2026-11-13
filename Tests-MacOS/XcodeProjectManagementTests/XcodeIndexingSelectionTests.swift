import Foundation
import Testing
@testable import XcodeProjectManagement

struct XcodeIndexingSelectionTests {
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
