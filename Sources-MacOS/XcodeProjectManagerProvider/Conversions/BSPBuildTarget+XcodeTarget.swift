import Foundation
import SourceKitBSPProtocol
import XcodeProjectManagement

extension XcodeTarget {
    func asBSPBuildTarget(
        dependencies: [BSPBuildTargetIdentifier] = [], toolchain: URL? = nil
    ) -> BSPBuildTarget {
        let capabilities = BuildTargetCapabilities(
            canCompile: true,
            canTest: self.xcodeProductType.isTestBundle,
            canRun: self.xcodeProductType.isApplication,
            canDebug: self.xcodeProductType.isApplication || (
                self.xcodeProductType == .unitTestBundle &&
                    (self.xcodeTargetPlatform == .iOS || self.xcodeTargetPlatform == .iOSSimulator)
            )
        )

        return BSPBuildTarget(
            id: self.targetIdentifier.bspIdentifier,
            displayName: self.targetName,
            baseDirectory: URI(self.projectURL.deletingLastPathComponent()),
            tags: self.xcodeProductType.isTestBundle ? [.test] : [],
            languageIds: [.swift, .objective_c, .cpp, .c],
            dependencies: dependencies,
            capabilities: capabilities,
            dataKind: BuildTargetDataKind(rawValue: "sourceKit"),
            data: createXcodeData(toolchain: toolchain)
        )
    }

    private func createXcodeData(toolchain: URL?) -> LSPAny {
        var data: [String: LSPAny] = [:]
        if let toolchain { data["toolchain"] = .string(toolchain.absoluteString) }
        if xcodeProductType.isTestBundle {
            data["testDiscovery"] = .dictionary([
                "provider": .string("sourcekit-lsp"),
                "version": .int(1),
                "selectionDataKind": .string(XcodeTestSelection.dataKind)
            ])
        }
        return .dictionary(data)
    }
}
