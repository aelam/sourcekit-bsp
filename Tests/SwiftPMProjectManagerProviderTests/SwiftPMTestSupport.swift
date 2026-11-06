import Foundation
@testable import SwiftPMProjectManagerProvider

final class TemporarySwiftPMPackage: Sendable {
    let directory: URL
    let root: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftpm-tests-\(UUID())",
            isDirectory: true
        )
        .resolvingSymlinksInPath()
        root = directory.appendingPathComponent("Root 空 格", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("// Fixture manifest", to: "Package.swift")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func write(_ text: String, to path: String, in base: URL? = nil) throws {
        let file = (base ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func describe(
        name: String = "Root",
        at root: URL? = nil,
        targets: [[String: Any]] = [],
        products: [[String: Any]] = [],
        dependencies: [[String: Any]] = []
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "name": name, "path": (root ?? self.root).path, "targets": targets,
            "products": products, "dependencies": dependencies,
        ])
    }

    func manager(executor: any SwiftPMCommandExecuting) -> SwiftPMProjectManager {
        SwiftPMProjectManager(rootURL: root, executable: root.appendingPathComponent("swift"), executor: executor)
    }
}

func describedTarget(
    _ name: String,
    type: String = "library",
    path: String? = nil,
    sources: [String] = ["File.swift"],
    dependencies: [String] = [],
    products: [String] = []
) -> [String: Any] {
    [
        "name": name, "c99name": name.replacingOccurrences(of: "-", with: "_"), "type": type,
        "path": path ?? "Sources/\(name)",
        "sources": sources,
        "module_type": (sources.contains { $0.hasSuffix(".swift") }) ? "SwiftTarget" : "ClangTarget",
        "target_dependencies": dependencies, "product_dependencies": products,
    ]
}

actor FixtureCommandExecutor: SwiftPMCommandExecuting {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let root: URL
    }

    var outputs: [String: SwiftPMCommandResult]
    private(set) var calls: [Call] = []
    let delay: Duration?

    init(_ data: Data, stderr: String = "", code: Int32 = 0, delay: Duration? = nil) {
        outputs = ["default": .init(standardOutput: data, standardError: Data(stderr.utf8), exitCode: code)]
        self.delay = delay
    }

    func set(_ data: Data, key: String = "default", stderr: String = "", code: Int32 = 0) {
        outputs[key] = .init(standardOutput: data, standardError: Data(stderr.utf8), exitCode: code)
    }

    func execute(executable: URL, arguments: [String], workingDirectory: URL) async throws -> SwiftPMCommandResult {
        calls.append(.init(executable: executable, arguments: arguments, root: workingDirectory))
        if let delay { try await Task.sleep(for: delay) }
        let operation =
            arguments.contains("dump-package")
                ? "dump" : (arguments.contains("show-dependencies") ? "resolve" : "describe")
        let key = workingDirectory.path + ":" + operation
        guard let result = outputs[key] ?? outputs["default"] else { throw SwiftPMProjectError.notInitialized }
        return result
    }
}

func swiftExecutable(root: URL) throws -> URL {
    try SwiftPMExecutableResolver.resolve(configured: nil, environment: ProcessInfo.processInfo.environment, root: root)
}
