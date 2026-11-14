import Foundation
import Logger
import SwiftBuild

/// Owns the resources and target metadata for one loaded workspace.
struct SwiftBuildIndexingWorkspace: Sendable {
    let service: SWBBuildService
    let session: SWBBuildServiceSession
    let targetInfos: [SWBTargetInfo]
    var targetGUIDs: [XcodeTargetIdentifier: String] = [:]

    static func load(snapshot: XcodeProjectSnapshot, serviceExecutable: URL) async throws -> Self {
        guard FileManager.default.isExecutableFile(atPath: serviceExecutable.path) else {
            throw XcodeProjectError.invalidConfig("Missing matching Swift Build service: \(serviceExecutable.path)")
        }
        // The service must match the linked framework, not Xcode's bundled framework version.
        setenv("SWBBUILDSERVICE_PATH", serviceExecutable.path, 1)
        setenv("UseSynchronousBuildDescriptionSerialization", "YES", 1)
        let service = try await SWBBuildService(connectionMode: .outOfProcess)
        do {
            let (result, diagnostics) = await service.createSession(
                name: "sourcekit-bsp-indexing",
                developerPath: snapshot.xcodeInstallation.developerDir.path,
                cachePath: nil,
                inferiorProductsPath: nil,
                environment: nil
            )
            for diagnostic in diagnostics {
                logger.debug("Swift Build: \(diagnostic)")
            }
            let session = try result.get()
            do {
                try await session.loadWorkspace(containerPath: snapshot.projectLocation.workspaceOrProjectFileURL.path)
                try await session.setSystemInfo(.default())
                let targetInfos = try await session.workspaceInfo().targetInfos
                try Task.checkCancellation()
                return Self(service: service, session: session, targetInfos: targetInfos)
            } catch {
                try? await session.close()
                throw error
            }
        } catch {
            await service.close()
            throw error
        }
    }

    func close() async {
        try? await session.close()
        await service.close()
    }
}
