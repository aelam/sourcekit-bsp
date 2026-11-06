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
        let modules = try selectedTestModules(targetIdentifiers)
        let options = try SwiftPMTestOptions.validate(arguments)
        if let workingDirectory {
            guard let directory = workingDirectory.fileURL,
                  directory.standardizedFileURL.resolvingSymlinksInPath() == rootURL else {
                throw SwiftPMProjectError.invalidArguments("SwiftPM tests must run from the package root.")
            }
        }
        let pattern = "^(" + modules.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\."
        let result = try await executeCommand(
            executable: commandExecutable,
            arguments: ["test", "--package-path", rootURL.path] + options + ["--filter", pattern],
            environment: environmentVariables ?? [:],
            outputHandler: logHandler
        )
        return result.exitCode == 0 ? .ok : .error
    }

    func testArguments(
        targetIdentifiers: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        dataKind: String?,
        data: LSPAny?
    ) async throws -> [String]? {
        guard dataKind == nil, data == nil else { throw TestSelectionError.unsupported }
        _ = try selectedTestModules(targetIdentifiers)
        _ = try SwiftPMTestOptions.validate(arguments)
        return arguments
    }

    private func selectedTestModules(_ identifiers: [BSPBuildTargetIdentifier]) throws -> [String] {
        guard !identifiers.isEmpty else {
            throw SwiftPMProjectError.invalidArguments("Select at least one root test target.")
        }
        return try Set(identifiers.map { identifier in
            _ = try executionTarget(identifier)
            guard let module = testModules[identifier] else {
                throw SwiftPMProjectError.invalidArguments("Select a test target from the root package.")
            }
            return module
        }).sorted()
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
                    "Unsupported SwiftPM test option '\(option)'. Select whole test targets without test filters."
                )
            }
            index += 1
        }
        return arguments
    }
}
