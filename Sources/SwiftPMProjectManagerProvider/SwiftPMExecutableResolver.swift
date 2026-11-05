import Foundation

enum SwiftPMExecutableResolver {
    #if os(Windows)
    static let usesWindowsPaths = true
    #else
    static let usesWindowsPaths = false
    #endif

    static func resolve(
        configured: String?,
        environment: [String: String],
        root: URL,
        windows: Bool = usesWindowsPaths
    ) throws -> URL {
        func variable(_ key: String) -> String? {
            if windows {
                return environment.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            }
            return environment[key]
        }
        let override = configured ?? variable("SWIFT_EXEC")
        var name = override ?? "swift"
        if configured == nil, let compiler = variable("SWIFT_EXEC") {
            let basename = compiler.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? compiler
            if basename == "swiftc" || (windows && basename.lowercased() == "swiftc.exe") {
                name = String(compiler.dropLast(basename.count)) + (windows ? "swift.exe" : "swift")
            }
        }
        guard !name.isEmpty else {
            throw SwiftPMProjectError.executableNotFound("swiftExecutable or SWIFT_EXEC is empty.")
        }
        let names = windows && (name as NSString).pathExtension.isEmpty ? [name + ".exe", name] : [name]
        let candidates: [URL] = if name.contains("/") || name.contains("\\") {
            names.map { URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
        } else {
            (variable("PATH") ?? "").split(
                separator: windows ? ";" : ":",
                omittingEmptySubsequences: false
            )
            .flatMap { entry -> [URL] in
                let directory = String(entry).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let base =
                    directory.isEmpty ? root : URL(fileURLWithPath: directory, isDirectory: true, relativeTo: root)
                return names.map { base.appendingPathComponent($0).standardizedFileURL }
            }
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path) {
                // Preserve the executable name because Swift uses argv[0] to select its mode.
                return candidate
            }
        }
        let source = override == nil ? "PATH" : "swiftExecutable/SWIFT_EXEC"
        throw SwiftPMProjectError.executableNotFound("Checked \(source) for '\(name)'.")
    }
}
