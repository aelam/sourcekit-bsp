import BuildServerProtocol
import Foundation

public extension SwiftPMProjectManager {
    var supportsBuildContexts: Bool {
        true
    }

    var supportedBuildPolicies: [BuildContextBuildPolicy] {
        BuildContextBuildPolicy.allCases
    }

    func contextOptions(_ params: BuildContextOptionsParams) async throws -> BuildContextOptionsResult {
        try await contextOptionsForQuery(.init(scope: params.scope, operation: nil, selection: params.selection))
    }

    func resolveContext(_ params: BuildContextParams) async throws -> BuildContext {
        try params.buildPolicy.validate(for: params.operation)
        let options = try await contextOptionsForQuery(.init(
            scope: params.scope,
            operation: params.operation,
            selection: params.selection
        ))
        let targets: [BSPBuildTargetIdentifier]
        if let scoped = params.scope?.targets, !scoped.isEmpty {
            targets = scoped
        } else if let identifier = options.selection["swiftpm.target"] {
            targets = try [BSPBuildTargetIdentifier(uri: URI(string: identifier))]
        } else {
            throw BuildContextError.invalid("Select a target.")
        }
        return .init(
            operation: params.operation, targets: targets, selection: options.selection, buildPolicy: params.buildPolicy
        )
    }

    func startBuild(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        try await validateContext(context, operation: .compile, targets: targetIdentifiers)
        return try await startBuild(
            targetIdentifiers: targetIdentifiers,
            arguments: contextBuildArguments(arguments, context: context),
            logHandler: logHandler
        )
    }

    // swiftlint:disable:next function_parameter_count
    func run(
        targetIdentifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        try await validateContext(context, operation: .run, targets: [targetIdentifier])
        let options = try contextBuildArguments(nil, context: context)
        if context.buildPolicy == .build {
            await progressHandler?("Building the selected configuration")
            let status = try await startBuild(
                targetIdentifiers: [targetIdentifier],
                arguments: options,
                logHandler: nil
            )
            guard status == .ok else { return status }
        }
        let program = try await builtExecutable(for: targetIdentifier, arguments: options)
        return try await runExecutable(
            program,
            arguments: arguments ?? [],
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            progressHandler: progressHandler
        )
    }

    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?,
        context: BuildContext
    ) async throws -> StatusCode {
        try await validateContext(context, operation: .test, targets: targetIdentifiers)
        let options = try contextBuildArguments(arguments, context: context)
        let policyArguments = context.buildPolicy == .reuse ? ["--skip-build"] : []
        return try await test(
            targetIdentifiers: targetIdentifiers,
            arguments: policyArguments + options,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            logHandler: logHandler,
            testEventHandler: testEventHandler
        )
    }

    func startDebugSession(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (String) async -> Void)?,
        context: BuildContext
    ) async throws -> DebugSessionConnection {
        try await validateContext(context, operation: .debug, targets: targetIdentifiers)
        guard let target = targetIdentifiers.first, targetIdentifiers.count == 1 else {
            throw BuildContextError.invalid("Select one target to debug.")
        }
        let options = try contextBuildArguments(nil, context: context)
        if testModules[target] != nil, !(arguments ?? []).isEmpty {
            throw BuildContextError.invalid("Test debugging does not support additional runtime arguments.")
        }
        if context.buildPolicy == .build {
            let status = try await startBuild(
                targetIdentifiers: targetIdentifiers,
                arguments: options,
                logHandler: logHandler
            )
            guard status == .ok else { throw BuildContextError.invalid("The selected configuration failed to build.") }
        }
        let launch: SwiftPMDebugLaunch = if testModules[target] != nil {
            try await testDebugLaunch(for: target, arguments: options, logHandler: logHandler)
        } else {
            try await SwiftPMDebugLaunch(
                program: builtExecutable(for: target, arguments: options),
                arguments: arguments
            )
        }
        return try await startDebugLaunch(launch, progressHandler: progressHandler)
    }
}

private struct SwiftPMContextQuery {
    let scope: BuildContextScope?
    let operation: BuildContextOperation?
    let selection: [String: String]?
}

extension SwiftPMProjectManager {
    private func contextOptionsForQuery(_ params: SwiftPMContextQuery) async throws -> BuildContextOptionsResult {
        let targets = try availableContextTargets(params)
        let allowed: Set = ["swiftpm.target", "swiftpm.configuration", "swiftpm.destination"]
        var selection = params.selection ?? [:]
        guard Set(selection.keys).isSubset(of: allowed) else {
            throw BuildContextError.invalid("The selection contains an unknown SwiftPM option.")
        }
        selection["swiftpm.target"] = try contextTargetSelection(params, available: targets)
        let configuration = selection["swiftpm.configuration"] ?? (params.operation == nil ? nil : "debug")
        if let configuration, !["debug", "release"].contains(configuration) {
            throw BuildContextError.invalid("The configuration must be debug or release.")
        }
        let host = try await contextHost()
        if let destination = selection["swiftpm.destination"], destination != host.id {
            throw BuildContextError.invalid("Only the current Swift toolchain's host destination is supported.")
        }
        selection["swiftpm.configuration"] = configuration
        selection["swiftpm.destination"] = host.id
        var dimensions: [BuildContextDimension] = []
        if params.scope?.targets == nil {
            let options = targets.map {
                BuildContextOption(id: $0.id.uri.stringValue, label: $0.displayName ?? $0.id.uri.stringValue)
            }
            dimensions.append(.init(
                id: "swiftpm.target",
                label: "Target",
                options: options,
                value: selection["swiftpm.target"]
            ))
        }
        let configurations: [BuildContextOption] = [
            .init(id: "debug", label: "Debug"),
            .init(id: "release", label: "Release")
        ]
        dimensions += [
            .init(
                id: "swiftpm.configuration",
                label: "Configuration",
                required: params.operation != nil,
                options: configurations,
                value: configuration
            ),
            .init(id: "swiftpm.destination", label: "Destination", options: [host], value: host.id),
        ]
        let operations = contextOperations(params, targets: targets, selection: selection)
        return .init(dimensions: dimensions, selection: selection, operations: operations)
    }

    private func availableContextTargets(_ params: SwiftPMContextQuery) throws -> [BSPBuildTarget] {
        guard !isShutDown else { throw BuildContextError.invalid("The project is shut down.") }
        guard let project else { throw BuildContextError.invalid("The project is not initialized.") }
        if let workspace = params.scope?.workspaceUri {
            guard workspace.fileURL?.standardizedFileURL.resolvingSymlinksInPath().path == workspaceRootURL.path else {
                throw BuildContextError.invalid("The workspace does not belong to this package.")
            }
        }
        if let operation = params.operation,
           !capabilities.contains(ProjectManagerCapability(rawValue: operation.rawValue)!) {
            throw BuildContextError.invalid("The operation is unavailable for this provider.")
        }
        let targets = project.targets.filter { target in
            if let operation = params.operation { return contextSupports(target, operation: operation) }
            return BuildContextOperation.allCases.contains { contextSupports(target, operation: $0) }
        }
        guard !targets.isEmpty else { throw BuildContextError.invalid("No target supports this operation.") }
        return targets.sorted { ($0.displayName ?? $0.id.uri.stringValue) < ($1.displayName ?? $1.id.uri.stringValue) }
    }

    private func contextTargetSelection(
        _ params: SwiftPMContextQuery,
        available: [BSPBuildTarget]
    ) throws -> String? {
        let scoped = params.scope?.targets ?? []
        if params.scope?.targets != nil, scoped.isEmpty || Set(scoped).count != scoped.count {
            throw BuildContextError.invalid("The scope must contain a nonempty set of distinct targets.")
        }
        guard Set(scoped).isSubset(of: Set(available.map(\.id))) else {
            throw BuildContextError.invalid("A target is unknown or unavailable for this operation.")
        }
        if let operation = params.operation, [.run, .debug].contains(operation), scoped.count > 1 {
            throw BuildContextError.invalid("Select exactly one target for run or debug.")
        }
        if let selected = params.selection?["swiftpm.target"] {
            guard available.contains(where: { $0.id.uri.stringValue == selected }),
                  scoped.isEmpty || (scoped.count == 1 && scoped[0].uri.stringValue == selected) else {
                throw BuildContextError.invalid("The selected target conflicts with the request scope.")
            }
            return selected
        }
        return scoped.count <= 1 ? (scoped.first?.uri.stringValue ?? available[0].id.uri.stringValue) : nil
    }

    private func contextSupports(_ target: BSPBuildTarget, operation: BuildContextOperation) -> Bool {
        guard capabilities.contains(ProjectManagerCapability(rawValue: operation.rawValue)!) else { return false }
        switch operation {
        case .compile: return target.capabilities.canCompile == true
        case .run: return target.capabilities.canRun == true
        case .test: return target.capabilities.canTest == true
        case .debug: return target.capabilities.canDebug == true
        }
    }

    private func contextOperations(
        _ params: SwiftPMContextQuery,
        targets: [BSPBuildTarget],
        selection: [String: String]
    ) -> [BuildContextOperation] {
        let selected: [BSPBuildTarget] = if let scoped = params.scope?.targets {
            targets.filter { scoped.contains($0.id) }
        } else {
            targets.filter { $0.id.uri.stringValue == selection["swiftpm.target"] }
        }
        return BuildContextOperation.allCases.filter { operation in
            guard !selected.isEmpty else { return false }
            if [.run, .debug].contains(operation), selected.count != 1 { return false }
            return selected.allSatisfy { contextSupports($0, operation: operation) }
        }
    }

    private func contextHost() async throws -> BuildContextOption {
        if let buildContextHost { return buildContextHost }
        struct TargetInfo: Decodable {
            struct Target: Decodable {
                let triple: String
                let platform: String?
                let arch: String?
            }

            let target: Target
        }
        let result = try await executeCommand(executable: commandExecutable, arguments: ["-print-target-info"])
        guard result.exitCode == 0,
              let info = try? JSONDecoder().decode(TargetInfo.self, from: result.standardOutput),
              !info.target.triple.isEmpty else {
            throw BuildContextError.invalid("The Swift toolchain did not report its host target.")
        }
        let platform = hostPlatform(triple: info.target.triple, reported: info.target.platform)
        let architecture = info.target.arch ?? info.target.triple.split(separator: "-").first.map(String.init)
        let metadata = platform.map {
            BuildContextDestination(kind: "host", platform: $0, architecture: architecture)
        }
        let host = BuildContextOption(
            id: info.target.triple,
            label: platform?.id == "macos" ? "My Mac" : "Host",
            description: info.target.triple,
            dataKind: metadata.map { _ in BuildContextDestination.dataKind },
            data: metadata?.encodeToLSPAny()
        )
        buildContextHost = host
        return host
    }

    private func hostPlatform(triple: String, reported: String?) -> BuildContextPlatform? {
        let parts = triple.split(separator: "-")
        let candidate = reported ?? (parts.count > 2 ? String(parts[2]) : "")
        if triple.contains("-android") { return .init(id: "android", label: "Android") }
        let platforms: [(String, BuildContextPlatform)] = [
            ("macos", .init(id: "macos", label: "macOS")),
            ("darwin", .init(id: "macos", label: "macOS")),
            ("ios", .init(id: "ios", label: "iOS")),
            ("tvos", .init(id: "tvos", label: "tvOS")),
            ("watchos", .init(id: "watchos", label: "watchOS")),
            ("xros", .init(id: "visionos", label: "visionOS")),
            ("visionos", .init(id: "visionos", label: "visionOS")),
            ("linux", .init(id: "linux", label: "Linux")),
            ("windows", .init(id: "windows", label: "Windows")),
            ("win32", .init(id: "windows", label: "Windows")),
            ("wasi", .init(id: "wasi", label: "WASI")),
            ("freebsd", .init(id: "freebsd", label: "FreeBSD")),
            ("openbsd", .init(id: "openbsd", label: "OpenBSD"))
        ]
        if let match = platforms.first(where: { candidate.lowercased().hasPrefix($0.0) }) {
            return match.1
        }
        guard let reported, !reported.isEmpty else { return nil }
        return .init(id: reported, label: reported)
    }

    private func validateContext(
        _ context: BuildContext,
        operation: BuildContextOperation,
        targets: [BSPBuildTargetIdentifier]
    ) async throws {
        guard context.operation == operation, Set(context.targets) == Set(targets) else {
            throw BuildContextError.invalid("The operation or targets do not match the resolved context.")
        }
        let current = try await resolveContext(.init(
            scope: .init(targets: targets),
            operation: operation,
            selection: context.selection,
            buildPolicy: context.buildPolicy
        ))
        guard current.selection == context.selection, current.buildPolicy == context.buildPolicy else {
            throw BuildContextError.invalid("The selection is no longer available.")
        }
    }

    private func isContextTestPolicyArgument(
        _ option: String, hasValue: Bool, context: BuildContext
    ) throws -> Bool {
        guard context.operation == .test, option == "--skip-build" else { return false }
        guard context.buildPolicy == .reuse, !hasValue else {
            throw BuildContextError.invalid("The test arguments conflict with the resolved build policy.")
        }
        return true
    }

    func contextBuildArguments(_ arguments: [String]?, context: BuildContext) throws -> [String] {
        guard let configuration = context.selection["swiftpm.configuration"] else {
            throw BuildContextError.invalid("The context has no configuration.")
        }
        let arguments = arguments ?? []
        let destination: Set = ["--sdk", "--triple", "--swift-sdk", "--toolchain", "--arch"]
        let operands: Set = [
            "--scratch-path",
            "--cache-path",
            "--config-path",
            "--security-path",
            "--jobs",
            "-j",
            "-Xswiftc",
            "-Xcc",
            "-Xcxx",
            "-Xlinker",
            "-Xmanifest",
            "--build-system"
        ]
        var output = ["--configuration", configuration]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let option = String(parts[0])
            if try isContextTestPolicyArgument(option, hasValue: parts.count > 1, context: context) {
                index += 1
                continue
            }
            guard !destination.contains(option) else {
                throw BuildContextError.invalid("The resolved destination controls \(option).")
            }
            if option == "--configuration" || option == "-c" {
                let value: String
                if parts.count == 2 {
                    value = String(parts[1])
                } else {
                    index += 1
                    guard index < arguments.count
                    else { throw BuildContextError.invalid("Missing value for \(option).") }
                    value = arguments[index]
                }
                guard value == configuration else {
                    throw BuildContextError.invalid("The argument configuration conflicts with the resolved context.")
                }
            } else {
                output.append(token)
                if operands.contains(option), parts.count == 1 {
                    index += 1
                    guard index < arguments.count
                    else { throw BuildContextError.invalid("Missing value for \(option).") }
                    output.append(arguments[index])
                }
            }
            index += 1
        }
        return output
    }
}
