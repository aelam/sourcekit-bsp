import BuildServerProtocol
import Foundation
import Support

extension XcodeProjectManager {
    public func test(
        xcodeTargetIdentifiers: [XcodeTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URL?,
        outputHandler: ProcessOutputHandler? = nil,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)? = nil
    ) async throws -> XcodeRunResult {
        let commands = try testInvocations(for: xcodeTargetIdentifiers, arguments: arguments)
        var failed = false
        // Xcode forwards TEST_RUNNER_ variables to the test runner.
        var environment = environmentVariables ?? [:]
        for (key, value) in environmentVariables ?? [:] where !key.hasPrefix("TEST_RUNNER_") {
            environment["TEST_RUNNER_" + key] = value
        }
        for invocation in commands {
            try Task.checkCancellation()
            var command = invocation.command
            let directory = workingDirectory ?? rootURL
            let bundle = try testResultBundle(command: &command, workingDirectory: directory)
            let target = try BSPBuildTargetIdentifier(uri: URI(string: invocation.target.rawValue))
            await testEventHandler?(.started(target))
            defer { invalidateSourceFileCache() }
            let exitCode = try await buildExecutor.execute(
                command: command,
                environment: environment,
                workingDirectory: directory,
                outputHandler: outputHandler
            )
            var report: TestExecutionReport?
            do {
                report = try await XcodeTestResultReader.read(bundle: bundle, toolchain: toolchain)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await testEventHandler?(
                    .warning("Cannot read test report at \(bundle.path): \(error.localizedDescription)")
                )
            }
            let missing = Self.missingSelectedTests(command: command, report: report)
            if !missing.isEmpty {
                await testEventHandler?(.warning("No result for selected tests: \(missing.joined(separator: ", "))"))
            }
            let succeeded = exitCode == 0 && missing.isEmpty
            await testEventHandler?(.finished(target, succeeded ? .ok : .error, report))
            failed = failed || !succeeded
        }
        return XcodeRunResult(
            statusCode: failed ? .error : .success,
            message: failed ? "Tests failed; see the Xcode output" : "Tests passed"
        )
    }

    nonisolated static func missingSelectedTests(command: [String], report: TestExecutionReport?) -> [String] {
        let selected = command.filter { $0.hasPrefix("-only-testing:") }.compactMap { filter -> String? in
            guard let slash = filter.firstIndex(of: "/") else { return nil }
            return String(filter[filter.index(after: slash)...])
        }
        let reported = (report?.tests ?? []).compactMap(\.testId)
        func normalized(_ id: String) -> String {
            id.hasSuffix("()") ? String(id.dropLast(2)) : id
        }
        return selected.filter { selection in
            !reported.contains { result in
                normalized(result) == normalized(selection) || result.hasPrefix(selection + "/")
            }
        }
    }

    func testCommands(for identifiers: [XcodeTargetIdentifier], arguments: [String]?) throws -> [[String]] {
        try testInvocations(for: identifiers, arguments: arguments).map(\.command)
    }

    private func testInvocations(
        for identifiers: [XcodeTargetIdentifier], arguments: [String]?
    ) throws -> [(target: XcodeTargetIdentifier, command: [String])] {
        guard let base = projectSnapshot, !identifiers.isEmpty else {
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
            let options = try XcodeBuildOptions(
                command: .build(
                    action: .test,
                    sdk: nil,
                    destination: nil,
                    configuration: nil,
                    derivedDataPath: nil,
                    resultBundlePath: nil
                ),
                flags: XcodeBuildFlags(),
                customFlags: argumentsWithoutScheme(flags)
            )
            return try (target.targetIdentifier, XcodeBuildCommandBuilder().buildCommand(
                project: buildConfiguration(for: target, arguments: arguments),
                options: options
            ))
        }
    }

    private func testResultBundle(command: inout [String], workingDirectory: URL) throws -> URL {
        let bundle: URL
        if let index = command.firstIndex(of: "-resultBundlePath") {
            guard index + 1 < command.count, !command[index + 1].hasPrefix("-") else {
                throw XcodeProjectError.invalidConfig("Missing -resultBundlePath value")
            }
            bundle = URL(fileURLWithPath: command[index + 1], relativeTo: workingDirectory).standardizedFileURL
        } else {
            let derivedData = command.firstIndex(of: "-derivedDataPath").flatMap { index in
                command.indices.contains(index + 1)
                    ? URL(fileURLWithPath: command[index + 1], relativeTo: workingDirectory).standardizedFileURL : nil
            } ?? projectSnapshot?.xcodeGlobalSettings.derivedDataPath
                ?? rootURL.appendingPathComponent(".sourcekit-bsp")
            bundle = derivedData.appendingPathComponent("Logs/Test/sourcekit-bsp-\(UUID().uuidString).xcresult")
            command += ["-resultBundlePath", bundle.path]
        }
        guard !FileManager.default.fileExists(atPath: bundle.path) else {
            throw XcodeProjectError.invalidConfig("Test result bundle already exists: \(bundle.path)")
        }
        try FileManager.default.createDirectory(
            at: bundle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return bundle
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
