import BuildServerProtocol
import Foundation

public extension XcodeProjectManager {
    internal func operationContextOptions(_ params: BuildContextParams) throws -> BuildContextOptionsResult {
        guard let base = projectSnapshot else { throw BuildContextError.invalid("Project not initialized") }
        let requested = try contextRequestedTargets(params.scope)
        var selection = params.selection ?? [:]
        let keys: Set<String> = params.operation == .debug
            ? ["xcode.scheme", "xcode.configuration", "xcode.destination", "xcode.debugMode"] : [
                "xcode.scheme",
                "xcode.configuration",
                "xcode.destination"
            ]
        guard Set(selection.keys).isSubset(of: keys) else {
            throw BuildContextError.invalid("Unknown Xcode selection key")
        }
        var dimensions: [BuildContextDimension] = []
        var plans: [String: [String: XcodeContextScheme]] = [:]
        var modeOptions: [String: [BuildContextOption]] = [:]
        let schemes = base.schemes.sorted { $0.path.absoluteString < $1.path.absoluteString }
        var options = schemes.map { scheme -> BuildContextOption in
            let id = scheme.path.resolvingSymlinksInPath().standardizedFileURL.absoluteString
            let modes = params.operation == .debug ? ["run", "test"] : [""]
            var supported: [String: XcodeContextScheme] = [:]
            let choices = modes.map { mode -> BuildContextOption in
                do {
                    supported[mode] = try contextScheme(
                        scheme,
                        operation: params.operation,
                        debugMode: mode,
                        requested: requested
                    )
                    return BuildContextOption(
                        id: mode,
                        label: mode == "test" ? "Tests" : "Application",
                        availability: true
                    )
                } catch {
                    return BuildContextOption(
                        id: mode,
                        label: mode == "test" ? "Tests" : "Application",
                        reason: error.localizedDescription,
                        availability: false
                    )
                }
            }
            plans[id] = supported
            modeOptions[id] = choices
            return BuildContextOption(
                id: id, label: scheme.name, description: scheme.path.path,
                reason: supported.isEmpty ? choices.compactMap(\.reason).joined(separator: "; ") : nil,
                availability: !supported.isEmpty
            )
        }
        if let id = selection["xcode.scheme"], !options.contains(where: { $0.id == id }) {
            options.append(BuildContextOption(
                id: id,
                label: id,
                reason: "This scheme is no longer available",
                availability: false
            ))
        }
        if selection["xcode.scheme"] == nil, requested != nil {
            let available = options.filter { $0.availability == true }
            let preferred = available.first { $0.label == preferredSchemeName }
            let matchingTarget = requested?.count == 1 ? available.first { $0.label == requested?.first?.name } : nil
            if let selected = preferred ?? matchingTarget ?? available.first {
                selection["xcode.scheme"] = selected.id
            }
        }
        dimensions.append(BuildContextDimension(
            id: "xcode.scheme",
            label: "Scheme",
            options: options,
            value: selection["xcode.scheme"]
        ))
        guard let id = selection["xcode.scheme"], let availablePlans = plans[id], !availablePlans.isEmpty else {
            return BuildContextOptionsResult(dimensions: dimensions, selection: selection)
        }
        var mode = ""
        if params.operation == .debug {
            if selection["xcode.debugMode"] == nil, let scheme = availablePlans.values.first?.scheme {
                selection["xcode.debugMode"] = try contextDefaultDebugMode(scheme: scheme, requested: requested)
            }
            guard let selected = selection["xcode.debugMode"], availablePlans[selected] != nil else {
                let reason = modeOptions[id]?.first { $0.id == selection["xcode.debugMode"] }?.reason
                throw BuildContextError.invalid(reason ?? "The selected debug mode is not supported by this scheme")
            }
            mode = selected
        }
        guard let plan = availablePlans[mode] else { return BuildContextOptionsResult(
            dimensions: dimensions,
            selection: selection
        ) }
        let configurations = plan.targets.dropFirst().reduce(Set(plan.targets[0].buildConfigurations)) {
            $0.intersection($1.buildConfigurations)
        }.sorted()
        let configuration = selection["xcode.configuration"] ?? plan.configuration
        selection["xcode.configuration"] = configuration
        var configurationOptions = configurations.map { BuildContextOption(id: $0, label: $0, availability: true) }
        if !configurations.contains(configuration) {
            configurationOptions.append(BuildContextOption(
                id: configuration, label: configuration,
                reason: "This configuration is not available for all selected targets", availability: false
            ))
        }
        dimensions.append(BuildContextDimension(
            id: "xcode.configuration", label: "Configuration",
            options: configurationOptions, value: configuration
        ))
        guard configurations.contains(configuration) else {
            return BuildContextOptionsResult(dimensions: dimensions, selection: selection)
        }
        let destinations: [XcodeDestination]
        do {
            destinations = try contextDestinations(
                plan: plan,
                operation: params.operation,
                configuration: configuration
            )
        } catch {
            let invalid = selection["xcode.destination"] ?? "unavailable"
            dimensions.append(BuildContextDimension(
                id: "xcode.destination", label: "Destination",
                options: [.init(
                    id: invalid,
                    label: "Unavailable",
                    reason: error.localizedDescription,
                    availability: false
                )],
                value: selection["xcode.destination"]
            ))
            return BuildContextOptionsResult(dimensions: dimensions, selection: selection)
        }
        var destinationOptions = destinations.map { destination in
            let reason = contextDestinationReason(destination, plan: plan, operation: params.operation)
            return BuildContextOption(
                id: destination.id, label: destination.fullDescription,
                description: "Device inventory; compatibility is inferred from build settings",
                reason: reason, availability: reason == nil,
                dataKind: BuildContextDestination.dataKind,
                data: destination.buildContextMetadata.encodeToLSPAny()
            )
        }
        if let id = selection["xcode.destination"] {
            if !destinationOptions.contains(where: { $0.id == id }) {
                destinationOptions.append(BuildContextOption(
                    id: id, label: id, reason: "This destination is not compatible with the selected configuration",
                    availability: false
                ))
            }
        } else {
            let available = destinations
                .filter { contextDestinationReason($0, plan: plan, operation: params.operation) == nil }
            let preferred = available.first { destination in
                destination.platform == .macOS ||
                    (destination.type == .simulator && (params.operation != .compile || !destination.isRunnable))
            }
            if let selected = preferred ?? available.first { selection["xcode.destination"] = selected.id }
        }
        dimensions.append(BuildContextDimension(
            id: "xcode.destination", label: "Destination", options: destinationOptions,
            value: selection["xcode.destination"]
        ))
        return BuildContextOptionsResult(dimensions: dimensions, selection: selection)
    }

    func resolveContext(_ params: BuildContextParams) async throws -> BuildContext {
        try await refreshContextDestinations()
        return try resolvedContext(params)
    }

    internal func resolvedContext(_ params: BuildContextParams) throws -> BuildContext {
        let result = try operationContextOptions(params)
        for dimension in result.dimensions {
            guard let value = dimension.value,
                  let option = dimension.options.first(where: { $0.id == value }), option.availability != false else {
                throw BuildContextError
                    .invalid(dimension.options.first(where: { $0.id == dimension.value })?
                        .reason ?? "Select an available \(dimension.label.lowercased())")
            }
        }
        guard let id = result.selection["xcode.scheme"], let scheme = projectSnapshot?.schemes.first(where: {
            $0.path.resolvingSymlinksInPath().standardizedFileURL.absoluteString == id
        }) else { throw BuildContextError.invalid("Select an available scheme") }
        guard result.selection["xcode.destination"] != nil
        else { throw BuildContextError.invalid("No usable destination is available") }
        let plan = try contextScheme(
            scheme, operation: params.operation, debugMode: result.selection["xcode.debugMode"],
            requested: contextRequestedTargets(params.scope)
        )
        return try BuildContext(
            operation: params.operation,
            targets: plan.targets.map { try BSPBuildTargetIdentifier(uri: URI(string: $0.targetIdentifier.rawValue)) },
            selection: result.selection
        )
    }
}

extension XcodeProjectManager {
    func contextRequestedTargets(_ scope: BuildContextScope?) throws -> [XcodeTarget]? {
        guard let base = projectSnapshot else { throw BuildContextError.invalid("Project not initialized") }
        if let uri = scope?.workspaceUri,
           uri.fileURL?.resolvingSymlinksInPath().standardizedFileURL != rootURL.resolvingSymlinksInPath()
           .standardizedFileURL {
            throw BuildContextError.invalid("The workspace URI does not match this project")
        }
        guard let identifiers = scope?.targets else { return nil }
        guard !identifiers.isEmpty else { throw BuildContextError.invalid("An explicit target scope cannot be empty") }
        guard Set(identifiers).count == identifiers.count
        else { throw BuildContextError.invalid("The target scope contains duplicate targets") }
        return try identifiers.map { identifier in
            guard let target = base.xcodeTargets
                .first(where: { $0.targetIdentifier.rawValue == identifier.uri.stringValue }) else {
                throw BuildContextError.invalid("Unknown target: \(identifier.uri.stringValue)")
            }
            return target
        }
    }

    func contextDestinations(
        plan: XcodeContextScheme, operation: BuildContextOperation, configuration: String
    ) throws -> [XcodeDestination] {
        guard let base = projectSnapshot else { throw BuildContextError.invalid("Project not initialized") }
        let settings = try plan.targets.map { target -> [String: String] in
            guard let project = loadXcodeProjCache(projectURL: target.projectURL) else {
                throw BuildContextError.invalid("Cannot load \(target.projectURL.path)")
            }
            return try BuildSettingResolver(
                xcodeInstallation: base.xcodeInstallation, xcodeGlobalSettings: base.xcodeGlobalSettings,
                xcodeProj: project, target: target.name, configuration: configuration, forceSimulator: false
            ).resolvedBuildSettings
        }
        if operation == .debug, plan.buildsTests {
            guard settings.count == 1, let host = settings[0]["TEST_HOST"], !host.isEmpty else {
                throw BuildContextError.invalid("Debug Tests requires an app-hosted unit test target")
            }
        }
        let inventory = destinationLoader.allDestinations
        var seen = Set<String>()
        return inventory.filter { destination in
            seen.insert(destination.id).inserted && settings.allSatisfy { contextDestination(destination, matches: $0) }
        }.sorted { $0.fullDescription == $1.fullDescription ? $0.id < $1.id : $0.fullDescription < $1.fullDescription }
    }

    private func contextDestination(_ destination: XcodeDestination, matches settings: [String: String]) -> Bool {
        guard let platform = settings["PLATFORM_NAME"].flatMap(Platform.init(rawValue:)) else { return false }
        let family: XcodeDestinationPlatform = switch platform {
        case .macOS: .macOS
        case .iOS, .iOSSimulator: .iOS
        case .watchOS, .watchSimulator: .watchOS
        case .tvOS, .tvSimulator: .tvOS
        case .visionOS, .visionSimulator: .visionOS
        }
        guard destination.platform == family else { return false }
        if let supported = settings["SUPPORTED_PLATFORMS"], !supported.isEmpty {
            let supportedPlatforms = supported.split(whereSeparator: \.isWhitespace).map(String.init)
            let devicePlatform: Platform = switch family {
            case .macOS: .macOS
            case .iOS: .iOS
            case .watchOS: .watchOS
            case .tvOS: .tvOS
            case .visionOS: .visionOS
            }
            let expected = destination.type == .simulator ? devicePlatform.simulatorVariant.rawValue : devicePlatform
                .rawValue
            return supportedPlatforms.contains(expected)
        }
        return true
    }

    private func contextDestinationReason(
        _ destination: XcodeDestination, plan: XcodeContextScheme, operation: BuildContextOperation
    ) -> String? {
        if !destination.isAvailable { return "This destination is offline or unavailable" }
        if operation != .compile,
           !destination.isRunnable { return "A concrete destination is required for this operation" }
        if operation == .debug, plan.buildsTests,
           destination.platform != .iOS || destination.type != .simulator {
            return "Test debugging supports app-hosted unit tests on iOS simulators"
        }
        if operation == .debug, !plan.buildsTests, destination.type == .device,
           destination.platform != .macOS, destination.platform != .iOS {
            return "Application debugging supports macOS, simulators, and physical iOS devices"
        }
        if operation == .run, destination.platform == .visionOS {
            return "Running visionOS applications is not supported by the current backend"
        }
        return nil
    }
}
