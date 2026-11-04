import Foundation
import Testing
@testable import XcodeProjectManagement

struct SDKStatCacheProviderTests {
    @Test(arguments: [
        "",
        "688ef53f1462e2c8f657fdc38a81448f",
    ])
    func usesExistingXcodeStatCache(additionalHash: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sdkPath = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk"
        let cacheName = "iphonesimulator26.5-23F81a-\(additionalHash)\(sdkPath.md5()).sdkstatcache"
        let cacheURL = fixture.cacheDirectory.appendingPathComponent(cacheName)
        try Data().write(to: cacheURL)

        let arguments = SDKStatCacheProvider().arguments(for: fixture.context(
            sdkPath: sdkPath,
            sdkVersion: "26.5.1",
            compiler: .swift
        ))

        #expect(Array(arguments.prefix(3)) == [
            "-Xcc", "-ivfsstatcache", "-Xcc",
        ])
        let returnedPath = try #require(arguments.last)
        #expect(URL(fileURLWithPath: returnedPath).lastPathComponent == cacheName)
        #expect(FileManager.default.fileExists(atPath: returnedPath))
    }

    @Test
    func omitsMissingStatCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let arguments = SDKStatCacheProvider().arguments(for: fixture.context(
            sdkPath: "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk",
            sdkVersion: "26.5.1",
            compiler: .swift
        ))

        #expect(arguments.isEmpty)
    }

    private struct Fixture {
        let root: URL
        let derivedDataPath: URL
        let cacheDirectory: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            derivedDataPath = root.appendingPathComponent("Project-hash")
            cacheDirectory = root.appendingPathComponent("SDKStatCaches.noindex")
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        }

        func context(
            sdkPath: String,
            sdkVersion: String,
            compiler: CompilerType
        ) -> ArgContext {
            ArgContext(
                buildSettings: [
                    "SDK_BUILD_VERSION": "23F81a",
                    "SDKROOT_PATH": sdkPath,
                    "SDK_VERSION": sdkVersion,
                    "PLATFORM_NAME": "iphonesimulator",
                ],
                languageDialect: XcodeLanguageDialect(fileExtension: "swift"),
                compiler: compiler,
                fileURL: nil,
                sourceItems: [],
                derivedDataPath: derivedDataPath,
                xcodeInstallation: nil
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
