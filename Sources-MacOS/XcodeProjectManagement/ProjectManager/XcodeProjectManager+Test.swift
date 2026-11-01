import Foundation

extension XcodeProjectManager {
    public func test(
        xcodeTargetIdentifiers: [XcodeTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URL?,
        outputHandler: ProcessOutputHandler? = nil
    ) async throws -> XcodeRunResult {
        let commands = try testCommands(for: xcodeTargetIdentifiers, arguments: arguments)
        var failed = false
        // Xcode forwards TEST_RUNNER_ variables to the test runner.
        var environment = environmentVariables ?? [:]
        for (key, value) in environmentVariables ?? [:] where !key.hasPrefix("TEST_RUNNER_") {
            environment["TEST_RUNNER_" + key] = value
        }
        for command in commands {
            try Task.checkCancellation()
            let exitCode = try await executeXcodeProcess(
                command: command,
                environment: environment,
                workingDirectory: workingDirectory,
                outputHandler: outputHandler
            )
            failed = failed || exitCode != 0
        }
        return XcodeRunResult(
            statusCode: failed ? .error : .success,
            message: failed ? "Tests failed; see the Xcode output" : "Tests passed"
        )
    }

    func testCommands(for identifiers: [XcodeTargetIdentifier], arguments: [String]?) throws -> [[String]] {
        guard let base = xcodeProjectBaseInfo, !identifiers.isEmpty else {
            throw XcodeProjectError.invalidConfig("Testing requires at least one test target in an initialized project")
        }
        var seen: Set<XcodeTargetIdentifier> = []
        // Validate the full request before creating schemes or starting a build.
        let targets = try identifiers.filter { seen.insert($0).inserted }.map { identifier in
            guard let target = base.xcodeTargets.first(where: { $0.targetIdentifier == identifier }),
                  target.xcodeProductType.isTestBundle else {
                throw XcodeProjectError.invalidConfig("Not a test target: \(identifier.rawValue)")
            }
            return target
        }
        let filters = (arguments ?? []).filter { $0.hasPrefix("-only-testing:") }
        for filter in filters {
            guard targets.contains(where: { matchesTestFilter(filter, target: $0) }) else {
                throw XcodeProjectError.invalidConfig("Test filter does not match a requested target: \(filter)")
            }
        }
        let selected = targets.filter { target in
            filters.isEmpty || filters.contains { matchesTestFilter($0, target: target) }
        }
        if selected.count > 1, arguments?.contains("-resultBundlePath") == true {
            throw XcodeProjectError.invalidConfig("Use a separate result bundle path for each test target")
        }
        let flags = try selected.map { try testArguments(for: $0, arguments: arguments) }
        return try zip(selected, flags).map { target, flags in
            let options = XcodeBuildOptions(
                command: .build(
                    action: .test,
                    sdk: nil,
                    destination: nil,
                    configuration: nil,
                    derivedDataPath: nil,
                    resultBundlePath: nil
                ),
                flags: XcodeBuildFlags(),
                customFlags: flags
            )
            return try XcodeBuildCommandBuilder().buildCommand(
                project: buildConfiguration(for: target),
                options: options
            )
        }
    }

    private func matchesTestFilter(_ filter: String, target: XcodeTarget) -> Bool {
        filter == "-only-testing:\(target.name)" || filter.hasPrefix("-only-testing:\(target.name)/")
    }

    func testArguments(for target: XcodeTarget, arguments: [String]?) throws -> [String] {
        var arguments = arguments ?? []
        if let index = arguments.firstIndex(of: "-destination") {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"),
                  !arguments[index + 1].hasPrefix("generic/") else {
                throw XcodeProjectError.invalidConfig("Tests require a concrete simulator or device destination")
            }
        } else if target.xcodeTargetPlatform == .macOS {
            arguments += ["-destination", "platform=macOS"]
        } else {
            guard let destination = target.destinations.first(where: {
                $0.type == .simulator && $0.isAvailable && $0.isRunnable
            }) else {
                throw XcodeProjectError
                    .invalidConfig("No simulator is available for \(target.name); specify -destination")
            }
            arguments += ["-destination", "id=\(destination.id)"]
        }
        arguments.removeAll { $0.hasPrefix("-only-testing:") && !matchesTestFilter($0, target: target) }
        if !arguments.contains(where: { $0.hasPrefix("-only-testing:") }) {
            arguments.append("-only-testing:\(target.name)")
        }
        return buildArguments(for: target, configuration: nil, arguments: arguments)
    }
}
