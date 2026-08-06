import BuildServerProtocol
import Foundation
import Logger
import Support
import XcodeProjectManagement

extension XcodeProjectManager: @preconcurrency ProjectManager {
    public func getProjectState() async -> BuildServerProtocol.ProjectState {
        .init()
    }

    public func addStateObserver(_ observer: any BuildServerProtocol.ProjectStateObserver) async {}

    public func removeStateObserver(_ observer: any BuildServerProtocol.ProjectStateObserver) async {}

    public var projectType: String {
        "xcodeproj"
    }

    public func updateBuildGraph() async {
        // Invalidate cached project data so the next source / compiler-argument
        // query re-reads the (possibly changed) project from disk.
        clearCaches()
    }

    public func buildIndex(for targets: [BSPBuildTargetIdentifier]) async {
        // TODO: await startBuild(targetIdentifiers: targets)
    }

    public var projectInfo: ProjectInfo? {
        xcodeProjectBaseInfo?.asProjectInfo()
    }

    public func getTargetList(
        resolveSourceFiles: Bool,
        resolveDependencies: Bool
    ) async -> [BSPBuildTarget] {
        guard let xcodeProjectBaseInfo else {
            return []
        }

        return xcodeProjectBaseInfo.xcodeTargets.compactMap { $0.asBSPBuildTarget() }
    }

    public func getSourceFileList(targetIdentifiers: [BSPBuildTargetIdentifier]) async throws
        -> [BuildServerProtocol.SourcesItem] {
        let xcodeTargetIdentifiers = targetIdentifiers.map { identifier in
            XcodeTargetIdentifier(rawValue: identifier.uri.stringValue)
        }
        let xcodeSourceItems = getSourcesItems(targetIdentifiers: xcodeTargetIdentifiers)
        return try xcodeSourceItems.compactMap {
            try $0.asBSPSourcesItems()
        }
    }

    public func getCompileArguments(targetIdentifier: String, sourceFileURL: URL) async throws -> [String] {
        let xcodeTargetIdentifier = XcodeTargetIdentifier(rawValue: targetIdentifier)
        return try await getCompileArguments(targetIdentifier: xcodeTargetIdentifier, sourceFileURL: sourceFileURL)
    }
}

extension XcodeTarget {
    func asBSPBuildTarget() -> BSPBuildTarget? {
        let capabilities = BuildTargetCapabilities(
            canCompile: true,
            canTest: self.xcodeProductType.isTestBundle,
            canRun: self.xcodeProductType.isApplication,
            canDebug: self.xcodeProductType.isApplication || self.xcodeProductType.isTestBundle
        )

        return try? BSPBuildTarget(
            id: BSPBuildTargetIdentifier(uri: URI(string: self.targetIdentifier)),
            displayName: self.targetName,
            baseDirectory: URI(self.projectURL.deletingLastPathComponent()),
            tags: [],
            languageIds: [.swift, .objective_c, .cpp, .c],
            dependencies: [],
            capabilities: capabilities,
            dataKind: BuildTargetDataKind(rawValue: "sourceKit"),
            data: createXcodeData()
        )
    }

    private func createXcodeData() -> LSPAny {
        LSPAny.dictionary([
            "selectors": createSelectorsArray()
        ])
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

        let destinationArgument = if destination.id.contains("generic") {
            "platform=\(destination.platform.rawValue)"
        } else if destination.id.contains("platform=") {
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
