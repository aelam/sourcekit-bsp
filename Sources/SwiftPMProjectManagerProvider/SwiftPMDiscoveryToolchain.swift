import Foundation

enum SwiftPMDiscoveryToolchain {
    static func resolve(
        executable: URL,
        executor: any SwiftPMCommandExecuting,
        root: URL
    ) async throws -> URL? {
        let result: SwiftPMCommandResult
        do {
            result = try await executor.execute(
                executable: executable,
                arguments: ["-print-target-info"],
                workingDirectory: root
            )
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return nil
        }
        try Task.checkCancellation()
        guard result.exitCode == 0,
              let info = try? JSONDecoder().decode(TargetInfo.self, from: result.standardOutput),
              info.paths.runtimeResourcePath.hasPrefix("/")
        else { return nil }
        // Ask Swift for its runtime path because the executable can be a toolchain shim.
        let resources = URL(fileURLWithPath: info.paths.runtimeResourcePath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let toolchain = resources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let languageServer = toolchain.appendingPathComponent("usr/bin/sourcekit-lsp")
        guard resources.path == toolchain.appendingPathComponent("usr/lib/swift").path,
              FileManager.default.isExecutableFile(atPath: languageServer.path)
        else { return nil }
        return toolchain
    }

    private struct TargetInfo: Decodable {
        struct Paths: Decodable {
            let runtimeResourcePath: String
        }

        let paths: Paths
    }
}
