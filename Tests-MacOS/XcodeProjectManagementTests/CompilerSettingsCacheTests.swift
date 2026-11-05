import Foundation
import Testing
@testable import XcodeProjectManagement

struct CompilerSettingsCacheTests {
    private func key(target: String = "Demo", configuration: String = "Debug") -> CompilerSettingsCache.Key {
        CompilerSettingsCache.Key(
            target: XcodeTargetIdentifier(projectFilePath: "/tmp/Demo.xcodeproj", targetName: target),
            configuration: configuration,
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
            buildVersion: "test",
            derivedData: URL(fileURLWithPath: "/tmp/CompilerSettingsCache")
        )
    }

    @Test
    func reusesSettingsAndKeepsTargetsAndConfigurationsSeparate() {
        var cache = CompilerSettingsCache()
        var resolutions = 0
        func load() -> [String: String] {
            resolutions += 1
            return ["VERSION": String(resolutions)]
        }
        let first = cache.settings(for: key(), load: load)
        #expect(cache.settings(for: key(), load: load) == first)
        #expect(resolutions == 1)
        #expect(cache.settings(for: key(target: "Other"), load: load) != first)
        #expect(cache.settings(for: key(configuration: "Release"), load: load) != first)
        cache.invalidate()
        #expect(cache.settings(for: key(), load: load) != first)
        #expect(resolutions == 4)
    }

    @Test
    func retriesFailuresAndInvalidatesSettingsAfterBuildInputsChange() throws {
        enum Failure: Error { case unresolved }
        var store = XcodeProjectStore()
        #expect(throws: Failure.self) {
            try store.compilerSettings.settings(for: key()) { throw Failure.unresolved }
        }
        let first = store.compilerSettings.settings(for: key()) { ["VALUE": "before"] }
        #expect(first["VALUE"] == "before")
        store.invalidateSources()
        let updated = store.compilerSettings.settings(for: key()) { ["VALUE": "after"] }
        #expect(updated["VALUE"] == "after")
    }
}
