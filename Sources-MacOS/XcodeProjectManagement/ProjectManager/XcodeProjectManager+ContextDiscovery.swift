import Foundation
import SourceKitBSPProtocol
import XcodeProj

public extension XcodeProjectManager {
    func contextOptions(_ params: BuildContextOptionsParams) async throws -> BuildContextOptionsResult {
        try Task.checkCancellation()
        guard !destinationDiscoveryStopped else { throw CancellationError() }
        let graphVersion = buildGraphVersion
        guard let base = projectSnapshot else { throw BuildContextError.invalid("Project not initialized") }
        let requested = try contextRequestedTargets(params.scope)
        var selection = params.selection ?? [:]
        let keys: Set = ["xcode.scheme", "xcode.configuration", "xcode.destination", "xcode.debugMode"]
        guard Set(selection.keys).isSubset(of: keys)
        else { throw BuildContextError.invalid("Unknown Xcode selection key") }
        var related: [String: [XcodeTarget]] = [:]
        let schemes = base.schemes.sorted { $0.path.absoluteString < $1.path.absoluteString }
        let nameCounts = Dictionary(grouping: schemes, by: \.name).mapValues(\.count)
        var schemesByID: [String: XcodeScheme] = [:]
        var choices = schemes.map { scheme -> BuildContextOption in
            let id = scheme.path.resolvingSymlinksInPath().standardizedFileURL.absoluteString
            schemesByID[id] = scheme
            do {
                guard nameCounts[scheme.name] == 1 else {
                    throw BuildContextError.invalid("This scheme name has multiple definitions in the active container")
                }
                related[id] = try contextDiscoveryRelatedTargets(
                    scheme: scheme, requested: requested, selected: selection["xcode.scheme"] == id
                )
                return BuildContextOption(id: id, label: scheme.name, description: scheme.path.path, availability: true)
            } catch {
                return BuildContextOption(
                    id: id,
                    label: scheme.name,
                    description: scheme.path.path,
                    reason: error.localizedDescription,
                    availability: false
                )
            }
        }
        if let selected = selection["xcode.scheme"], !choices.contains(where: { $0.id == selected }) {
            choices.append(BuildContextOption(
                id: selected,
                label: selected,
                reason: "This scheme is no longer available",
                availability: false
            ))
        }
        if requested != nil, selection["xcode.scheme"] == nil {
            let available = choices.filter { $0.availability == true }
            let preferred = available.first { $0.label == preferredSchemeName }
            let matchingTarget = requested?.count == 1 ? available.first { $0.label == requested?.first?.name } : nil
            if let selected = preferred ?? matchingTarget ?? available.first { selection["xcode.scheme"] = selected.id }
        }
        let schemeDimension = BuildContextDimension(
            id: "xcode.scheme",
            label: "Scheme",
            options: choices,
            value: selection["xcode.scheme"]
        )
        var dimensions = [schemeDimension]
        guard let id = selection["xcode.scheme"], let targets = related[id],
              let scheme = schemesByID[id] else {
            dimensions += [
                BuildContextDimension(
                    id: "xcode.configuration",
                    label: "Configuration",
                    required: false,
                    options: [],
                    value: selection["xcode.configuration"],
                    enabled: false,
                    reason: "Select a scheme first"
                ),
                BuildContextDimension(
                    id: "xcode.destination",
                    label: "Destination",
                    required: false,
                    options: [],
                    value: selection["xcode.destination"],
                    enabled: false,
                    reason: "Select a scheme first"
                )
            ]
            return BuildContextOptionsResult(dimensions: dimensions, selection: selection, operations: [])
        }
        try await refreshContextDestinations(allowCached: true)
        guard graphVersion == buildGraphVersion else {
            throw BuildContextError.invalid("The project changed; request context options again")
        }
        dimensions += contextDiscoveryTargetDimensions(targets, scheme: scheme, selection: selection)
        let operations = contextDiscoveryOperations(scope: params.scope, selection: selection)
        return BuildContextOptionsResult(dimensions: dimensions, selection: selection, operations: operations)
    }
}

extension XcodeProjectManager {
    private func contextDiscoveryTargetDimensions(
        _ targets: [XcodeTarget],
        scheme: XcodeScheme,
        selection: [String: String]
    ) -> [BuildContextDimension] {
        var dimensions: [BuildContextDimension] = []
        let configurations = Set(targets.flatMap(\.buildConfigurations)).sorted()
        var configurationOptions = configurations.map { BuildContextOption(id: $0, label: $0, availability: true) }
        if let configuration = selection["xcode.configuration"], !configurations.contains(configuration) {
            configurationOptions.append(BuildContextOption(
                id: configuration,
                label: configuration,
                reason: "This configuration is not available in the selected scheme",
                availability: false
            ))
        }
        dimensions.append(BuildContextDimension(
            id: "xcode.configuration",
            label: "Configuration",
            required: false,
            options: configurationOptions,
            value: selection["xcode.configuration"]
        ))
        var inventory: [String: XcodeDestination] = [:]
        var destinationError: String?
        for target in targets {
            let configurations = selection["xcode.configuration"].map { [$0] } ?? target.buildConfigurations
            for configuration in configurations where target.buildConfigurations.contains(configuration) {
                let plan = XcodeContextScheme(
                    scheme: scheme,
                    targets: [target],
                    configuration: configuration,
                    buildsTests: false
                )
                do {
                    for destination in try contextDestinations(
                        plan: plan,
                        operation: .compile,
                        configuration: configuration
                    ) {
                        inventory[destination.id] = destination
                    }
                } catch {
                    destinationError = error.localizedDescription
                }
            }
        }
        let sortedDestinations = inventory.values.sorted {
            $0.fullDescription == $1.fullDescription ? $0.id < $1.id : $0.fullDescription < $1.fullDescription
        }
        var destinationOptions = sortedDestinations.map { destination in
            BuildContextOption(
                id: destination.id,
                label: destination.name,
                description: destination.isRunnable ? nil : "Build only",
                reason: destination.isAvailable ? nil : "This destination is offline or unavailable",
                availability: destination.isAvailable,
                dataKind: BuildContextDestination.dataKind,
                data: destination.buildContextMetadata.encodeToLSPAny()
            )
        }
        if let selected = selection["xcode.destination"], inventory[selected] == nil {
            destinationOptions.append(BuildContextOption(
                id: selected,
                label: selected,
                reason: destinationError ?? "This destination is not compatible with the selected configuration",
                availability: false
            ))
        }
        dimensions.append(BuildContextDimension(
            id: "xcode.destination",
            label: "Destination",
            required: false,
            options: destinationOptions,
            value: selection["xcode.destination"]
        ))
        return dimensions
    }

    private func contextDiscoveryRelatedTargets(
        scheme: XcodeScheme, requested: [XcodeTarget]?, selected: Bool
    ) throws -> [XcodeTarget]? {
        guard FileManager.default.fileExists(atPath: scheme.path.path) else {
            throw BuildContextError.invalid("This scheme is no longer available")
        }
        guard requested != nil || selected else { return nil }
        return try contextDiscoveryTargets(scheme: scheme, requested: requested)
    }

    private func contextDiscoveryTargets(scheme: XcodeScheme, requested: [XcodeTarget]?) throws -> [XcodeTarget] {
        let parsed = try XCScheme(pathString: scheme.path.path)
        let references = (parsed.buildAction?.buildActionEntries.map(\.buildableReference) ?? []) +
            [parsed.launchAction?.runnable?.buildableReference].compactMap(\.self)
        var seen = Set<XcodeTargetIdentifier>()
        let tests = parsed.testAction.flatMap { try? contextTestTargets($0, scheme: scheme) } ?? []
        let targets = (references.compactMap { try? contextTarget(for: $0, scheme: scheme) } + tests)
            .filter { seen.insert($0.targetIdentifier).inserted }
        if let requested {
            guard requested
                .allSatisfy({ target in targets.contains { $0.targetIdentifier == target.targetIdentifier } }) else {
                throw BuildContextError.invalid("This scheme does not include all requested targets")
            }
            return requested
        }
        return targets
    }

    private func contextDiscoveryOperations(
        scope: BuildContextScope?,
        selection: [String: String]
    ) -> [BuildContextOperation] {
        guard let id = selection["xcode.scheme"], let scheme = projectSnapshot?.schemes.first(where: {
            $0.path.resolvingSymlinksInPath().standardizedFileURL.absoluteString == id
        }) else { return [] }
        do {
            let requested = try contextRequestedTargets(scope)
            return BuildContextOperation.allCases.filter { operation in
                let debugMode = operation == .debug
                    ? selection["xcode.debugMode"] ?? (try? contextDefaultDebugMode(
                        scheme: scheme,
                        requested: requested
                    ))
                    : nil
                return (try? contextScheme(
                    scheme, operation: operation, debugMode: debugMode, requested: requested, validateExecution: false
                )) != nil
            }
        } catch {
            return []
        }
    }
}
