import BuildServerProtocol
import Foundation
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
        var data: [String: LSPAny] = ["selectors": createSelectorsArray()]
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

    private func createSelectorsArray() -> LSPAny {
        var selectors: [LSPAny] = []

        // Configuration selector
        selectors.append(createConfigurationSelector())

        // Destination selector
        selectors.append(createDestinationSelector())

        return .array(selectors)
    }

    private func createConfigurationSelector() -> LSPAny {
        var values: [LSPAny] = []
        for config in buildConfigurations {
            values.append(.dictionary([
                "displayName": .string(config),
                "arguments": .array([
                    .string("-configuration"),
                    .string(config)
                ])
            ]))
        }

        return .dictionary([
            "keyName": .string("Configuration"),
            "displayLabel": .string("Select Build Configuration..."),
            "values": .array(values)
        ])
    }

    private func createDestinationSelector() -> LSPAny {
        var values: [LSPAny] = []
        for dest in destinations {
            values.append(createDestinationValue(destination: dest))
        }

        return .dictionary([
            "keyName": .string("Destination"),
            "displayLabel": .string("Select Destination..."),
            "values": .array(values)
        ])
    }

    private func createDestinationValue(destination: XcodeDestination) -> LSPAny {
        var metadata: [String: LSPAny] = [
            "platform": .string(destination.platform.rawValue),
            "id": .string(destination.id),
            "simulator": .bool(destination.type == .simulator),
            "isAvailable": .bool(destination.isAvailable),
            "isRunnable": .bool(destination.isRunnable)
        ]

        if let version = destination.version {
            metadata["version"] = .string(version)
        }

        let destinationArgument = if destination.id.contains("platform=") {
            destination.id
        } else {
            "id=\(destination.id)"
        }

        return .dictionary([
            "displayName": .string(destination.fullDescription),
            "description": .string(destination.id),
            "arguments": .array([
                .string("-destination"),
                .string(destinationArgument)
            ]),
            "metadata": .dictionary(metadata)
        ])
    }

    private func createConfigurationsArray() -> LSPAny {
        var configArray: [LSPAny] = []
        for config in buildConfigurations {
            configArray.append(.string(config))
        }
        return .array(configArray)
    }

    private func createDestinationsArray() -> LSPAny {
        var destArray: [LSPAny] = []
        for dest in destinations {
            destArray.append(createBSPDestination(destination: dest))
        }
        return .array(destArray)
    }

    private func createBSPDestination(destination: XcodeDestination) -> LSPAny {
        .dictionary([
            "name": .string(destination.name),
            "platform": .string(destination.platform.rawValue),
            "id": .string(destination.id),
            "version": .string(destination.version ?? ""),
            "simulator": .bool(destination.type == .simulator),
            "isAvailable": .bool(destination.isAvailable),
            "isRunnable": .bool(destination.isRunnable),
            "arguments": .array([
                .string("-destination"),
                .string("id=\(destination.id)")
            ]),
        ])
    }
}
