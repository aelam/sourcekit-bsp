import Foundation
import PathKit
import Testing
import XcodeProj
@testable import XcodeProjectManagement

struct BuildSettingResolverTests {
    @Test
    func resolveForKey() async throws {
        let projectFolder = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("DemoProjects")
            .appendingPathComponent("HelloProject"))
        let projectFilePath = projectFolder
            .appendingPathComponent("Hello.xcodeproj").path
        let derivedDataPath = PathHash.derivedDataFullPath(for: projectFilePath)
        let xcodeGlobalSettings =
            XcodeGlobalSettings(derivedDataPath: derivedDataPath)

        let xcodeToolchain = XcodeToolchain()
        try await xcodeToolchain.initialize()
        guard let xcodeInstallation = await xcodeToolchain
            .getSelectedInstallation() else {
            return
        }
        let xcodeProj = try XcodeProj(path: Path(projectFilePath))
        guard let resolver = try? BuildSettingResolver(
            xcodeInstallation: xcodeInstallation,
            xcodeGlobalSettings: xcodeGlobalSettings,
            xcodeProj: xcodeProj,
            target: "HelloTests",
            configuration: "Debug"
        ) else {
            return
        }

        for key in BuildSettingKey.allCases {
            let value = resolver.resolve(forKey: key.rawValue)
            print("Resolved \(key.rawValue): \(value ?? "nil")")
        }
    }
}
