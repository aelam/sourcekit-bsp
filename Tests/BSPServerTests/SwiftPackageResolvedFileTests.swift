import Foundation
import Support
import Testing

struct SwiftPackageResolvedFileTests {
    @Test(arguments: [1, 2, 3])
    func readsResolvedVersionsAndRevisions(format: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Package.resolved")
        #expect(try SwiftPackageResolvedFile(url: url).pins.isEmpty)
        let pins: [[String: Any]] = [
            [
                format == 1 ? "repositoryURL" : "location": "https://example.com/Library.git/",
                "state": ["version": "1.2.3", "revision": "abcdef"]
            ],
            [
                format == 1 ? "repositoryURL" : "location": "https://example.com/Branch.git",
                "state": ["branch": "main", "revision": "012345"]
            ]
        ]
        let file: [String: Any] = format == 1
            ? ["version": format, "object": ["pins": pins]] : ["version": format, "pins": pins]
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let resolved = try SwiftPackageResolvedFile(url: url)
        #expect(resolved.pin(identity: "LIBRARY")?.version == "1.2.3")
        #expect(resolved.pin(repository: "https://example.com/Library")?.version == "1.2.3")
        #expect(resolved.pin(identity: "branch")?.version == "012345")
        #expect(resolved.pin(repository: "https://different.example.com/Library") == nil)
        try Data("invalid".utf8).write(to: url)
        #expect(throws: DecodingError.self) { try SwiftPackageResolvedFile(url: url) }
    }
}
