import Foundation
import SourceKitBSPProtocol

struct SwiftPMDebugLaunch: Sendable {
    let program: URL
    var arguments: [String]?
    var environment: [String: String]?
    var workingDirectory: String?
}

extension SwiftPMProjectManager {
    func testDebugLaunch(
        for identifier: BSPBuildTargetIdentifier,
        arguments: [String]?,
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> SwiftPMDebugLaunch {
        let target = try executionTarget(identifier)
        guard let module = testModules[identifier], let name = target.displayName else {
            throw SwiftPMProjectError.invalidArguments("Select a test target from the root package.")
        }
        let options = try buildOptions(arguments)
        let directory = try await binaryDirectory(arguments: options)
        let bundle = try SwiftPMTestBundle.resolve(target: name, root: rootURL, directory: directory)
        let listing = try await checkedCommand(
            executable: commandExecutable,
            arguments: ["test", "list", "--package-path", rootURL.path] + options + ["--skip-build"],
            logHandler: logHandler
        )
        let tests = try SwiftPMTestBundle.selectedTests(module: module, listing: listing)
        let xctest = try await xcodePath(["--sdk", "macosx", "--find", "xctest"])
        let platform = try await xcodePath(["--sdk", "macosx", "--show-sdk-platform-path"])
        let swift = try await xcodePath(["--find", "swift"])
        let libraries = swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib/swift/macosx", isDirectory: true)
        let frameworks = platform.appendingPathComponent("Developer/Library/Frameworks", isDirectory: true)
        return SwiftPMDebugLaunch(
            program: xctest,
            arguments: ["-XCTest", tests.joined(separator: ","), bundle.path],
            environment: [
                "DYLD_FRAMEWORK_PATH": [
                    directory.appendingPathComponent("PackageFrameworks").path, directory.path, frameworks.path
                ].joined(separator: ":"),
                "DYLD_LIBRARY_PATH": directory.path + ":" + libraries.path,
            ],
            workingDirectory: rootURL.path
        )
    }

    private func xcodePath(_ arguments: [String]) async throws -> URL {
        let value = try await checkedCommand(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments, logHandler: nil
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (value as NSString).isAbsolutePath, !value.contains("\n") else {
            throw SwiftPMProjectError.invalidMetadata(package: rootURL.path, details: "Xcode returned no tool path.")
        }
        return URL(fileURLWithPath: value)
    }

    private func checkedCommand(
        executable: URL,
        arguments: [String],
        logHandler: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let result = try await executeCommand(executable: executable, arguments: arguments, outputHandler: logHandler)
        guard result.exitCode == 0 else {
            throw SwiftPMProjectError.commandFailed(
                command: ([executable.path] + arguments).joined(separator: " "),
                status: result.exitCode,
                output: swiftPMOutputText(result.standardError)
            )
        }
        return swiftPMOutputText(result.standardOutput)
    }
}

enum SwiftPMTestBundle {
    private struct BuildDescription: Decodable {
        struct Product: Decodable {
            let binaryPath: String
            let packagePath: String
        }

        let builtTestProducts: [Product]
    }

    static func resolve(target: String, root: URL, directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent(target + ".xctest", isDirectory: true)
        let binary = bundle.appendingPathComponent("Contents/MacOS/" + target)
        if FileManager.default.isExecutableFile(atPath: binary.path) { return bundle }
        let description = directory.appendingPathComponent("description.json")
        guard let data = try? Data(contentsOf: description),
              let products = try? JSONDecoder().decode(BuildDescription.self, from: data).builtTestProducts else {
            throw SwiftPMProjectError.productNotBuilt(bundle.path)
        }
        let matching = products.filter {
            URL(fileURLWithPath: $0.packagePath).standardizedFileURL.resolvingSymlinksInPath().path == root.path
        }
        guard matching.count == 1, let product = matching.first else {
            throw SwiftPMProjectError.invalidMetadata(
                package: root.path, details: "SwiftPM did not return one test bundle for the root package."
            )
        }
        let executable = URL(fileURLWithPath: product.binaryPath).standardizedFileURL
        let testBundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard testBundle.pathExtension == "xctest", testBundle.deletingLastPathComponent().path == directory.path,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SwiftPMProjectError.productNotBuilt(product.binaryPath)
        }
        return testBundle
    }

    static func selectedTests(module: String, listing: String) throws -> [String] {
        let tests = Set(listing.split(whereSeparator: \.isNewline).map(String.init).filter {
            $0.hasPrefix(module + ".")
        }).sorted()
        guard !tests.isEmpty else {
            throw SwiftPMProjectError.invalidArguments("No tests were discovered in module '\(module)'.")
        }
        guard tests.allSatisfy({ !$0.contains(",") && !$0.contains("\r") }) else {
            throw SwiftPMProjectError.invalidArguments("XCTest cannot select test identifiers that contain commas.")
        }
        return tests
    }
}
