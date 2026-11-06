import BuildServerProtocol
import Foundation

public extension SwiftPMProjectManager {
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusCode {
        try await test(
            targetIdentifiers: targetIdentifiers,
            arguments: arguments,
            environmentVariables: environmentVariables,
            workingDirectory: workingDirectory,
            logHandler: logHandler,
            testEventHandler: nil
        )
    }

    // swiftlint:disable:next function_parameter_count
    func test(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        environmentVariables: [String: String]?,
        workingDirectory: URI?,
        logHandler: (@Sendable (String) -> Void)?,
        testEventHandler: (@Sendable (TestExecutionEvent) async -> Void)?
    ) async throws -> StatusCode {
        let targets = try selectedTestTargets(targetIdentifiers)
        let request = try SwiftPMTestSelection.extract(from: arguments)
        var options = try SwiftPMTestOptions.validate(request.arguments)
        try request.selection?.validate(requested: targetIdentifiers)
        if let workingDirectory {
            guard let directory = workingDirectory.fileURL,
                  directory.standardizedFileURL.resolvingSymlinksInPath() == rootURL else {
                throw SwiftPMProjectError.invalidArguments("SwiftPM tests must run from the package root.")
            }
        }
        if options.last(where: { $0 == "--parallel" || $0 == "--no-parallel" }) == "--parallel" {
            options.removeAll { $0 == "--quiet" || $0 == "-q" }
            options.append("--verbose")
        }
        var status = StatusCode.ok
        for (target, module) in targets {
            try Task.checkCancellation()
            let selected = request.selection?.tests(for: target)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let events = directory.appendingPathComponent("events.jsonl")
            let output = SwiftPMTestOutput()
            let start = Date()
            await testEventHandler?(.started(target))
            let command = ["test", "--package-path", rootURL.path] + options + [
                "--filter", SwiftPMTestSelection.filter(module: module, tests: selected),
                "--event-stream-output-path", events.path, "--event-stream-version", "0"
            ]
            do {
                let result = try await executeCommand(
                    executable: commandExecutable,
                    arguments: command,
                    environment: environmentVariables ?? [:]
                ) {
                    output.append($0)
                    logHandler?($0)
                }
                let completedOutput = swiftPMOutputText(result.standardOutput) + "\n"
                    + swiftPMOutputText(result.standardError)
                let targetStatus = await finishTest(
                    target: target,
                    module: module,
                    selected: selected,
                    output: completedOutput,
                    events: events,
                    status: result.exitCode == 0 ? .ok : .error,
                    start: start,
                    handler: testEventHandler
                )
                if targetStatus != .ok { status = .error }
            } catch {
                _ = await finishTest(
                    target: target,
                    module: module,
                    selected: selected,
                    output: output.text,
                    events: events,
                    status: error is CancellationError ? .cancelled : .error,
                    start: start,
                    handler: testEventHandler
                )
                throw error
            }
        }
        return status
    }

    func testArguments(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        dataKind: String?,
        data: LSPAny?
    ) async throws -> [String]? {
        _ = try selectedTestTargets(targetIdentifiers)
        _ = try SwiftPMTestOptions.validate(arguments)
        guard dataKind != nil || data != nil else { return arguments }
        guard dataKind == SwiftPMTestSelection.dataKind, let data else { throw TestSelectionError.unsupported }
        let selection = try JSONDecoder().decode(SwiftPMTestSelection.self, from: JSONEncoder().encode(data))
        try selection.validate(requested: targetIdentifiers)
        return try (arguments ?? []) + [selection.encodedArgument()]
    }

    private func selectedTestTargets(
        _ identifiers: [BSPBuildTargetIdentifier]
    ) throws -> [(BSPBuildTargetIdentifier, String)] {
        guard !identifiers.isEmpty else {
            throw SwiftPMProjectError.invalidArguments("Select at least one root test target.")
        }
        let targets = try Set(identifiers).map { identifier in
            _ = try executionTarget(identifier)
            guard let module = testModules[identifier] else {
                throw SwiftPMProjectError.invalidArguments("Select a test target from the root package.")
            }
            return (identifier, module)
        }
        return targets.sorted { $0.1 < $1.1 }
    }

    // swiftlint:disable:next function_parameter_count
    private func finishTest(
        target: BSPBuildTargetIdentifier,
        module: String,
        selected: [SwiftPMTestSelection.Test]?,
        output: String,
        events: URL,
        status: StatusCode,
        start: Date,
        handler: (@Sendable (TestExecutionEvent) async -> Void)?
    ) async -> StatusCode {
        var report = SwiftPMTestReport(module: module)
        report.readXCTest(output)
        if let data = try? Data(contentsOf: events) { report.readSwiftTesting(data) }
        let tests = report.finish(selected: selected, cancelled: status == .cancelled)
        let result: StatusCode = if status == .cancelled {
            .cancelled
        } else if status != .ok || !report.problems.isEmpty || tests.contains(where: { $0.status == .failed }) {
            .error
        } else {
            .ok
        }
        for problem in report.problems {
            await handler?(.warning(problem))
        }
        await handler?(.finished(target, result, TestExecutionReport(
            tests: tests,
            time: Int64(max(0, Date().timeIntervalSince(start) * 1000))
        )))
        return result
    }
}

private enum SwiftPMTestOptions {
    static let flags: Set<String> = [
        "--skip-build", "--parallel", "--no-parallel", "--enable-code-coverage", "--disable-code-coverage",
        "--enable-xctest", "--enable-swift-testing", "--enable-testable-imports", "--disable-testable-imports",
        "--verbose", "-v", "--very-verbose", "--vv", "--quiet", "-q",
        "--color-diagnostics", "--no-color-diagnostics", "--disable-sandbox",
        "--enable-index-store", "--disable-index-store", "--auto-index-store",
        "--force-resolved-versions", "--disable-automatic-resolution", "--only-use-versions-from-resolved-file",
        "--skip-update", "--enable-all-traits", "--disable-default-traits",
    ]
    static let values: Set<String> = [
        "--configuration", "-c", "--scratch-path", "--cache-path", "--config-path", "--security-path",
        "--sdk", "--triple", "--swift-sdk", "--toolchain", "--arch", "--jobs", "-j",
        "-Xswiftc", "-Xcc", "-Xcxx", "-Xlinker", "-Xmanifest", "--build-system", "--sanitize",
        "--traits", "--num-workers", "--xunit-output", "--attachments-path",
    ]

    static func validate(_ arguments: [String]?) throws -> [String] {
        let arguments = arguments ?? []
        var index = 0
        while index < arguments.count {
            let parts = arguments[index].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let option = String(parts[0])
            if values.contains(option) {
                if parts.count == 1 {
                    index += 1
                    guard index < arguments.count else {
                        throw SwiftPMProjectError.invalidArguments("Missing value for SwiftPM test option \(option).")
                    }
                }
            } else if !flags.contains(option) || parts.count != 1 {
                throw SwiftPMProjectError.invalidArguments(
                    "Unsupported SwiftPM test option '\(option)'. "
                        + "Use the test selection data to select individual tests."
                )
            }
            index += 1
        }
        return arguments
    }
}
