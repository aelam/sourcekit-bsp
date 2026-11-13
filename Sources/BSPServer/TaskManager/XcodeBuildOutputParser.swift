import Foundation
import SourceKitBSPProtocol

struct BuildOutputDiagnostic: Sendable {
    let file: URL
    let target: BSPBuildTargetIdentifier
    let diagnostic: Diagnostic
}

struct ParsedBuildLine {
    var message: String?
    var type: Int = 4
    var progress: String?
    var diagnostic: BuildOutputDiagnostic?
}

struct XcodeBuildOutputParser {
    let context: BuildOutputContext
    private let targetIndex: BuildOutputTargetIndex
    private(set) var steps = 0
    private var sourceLines: [URL: [String]] = [:]

    init(context: BuildOutputContext) {
        self.context = context
        self.targetIndex = BuildOutputTargetIndex(context: context)
    }

    mutating func parse(_ raw: String) -> ParsedBuildLine {
        let line = raw.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedBuildLine() }
        let location = captures(
            #"^(.+?):([0-9]+):(?:([0-9]+):)?\s+(fatal error|error|warning|note):\s*(.*)$"#,
            in: trimmed
        )
        if let location { return diagnostic(location, original: line) }
        if let stage = stageMessage(trimmed) {
            steps += 1
            return ParsedBuildLine(message: stage, type: 3, progress: stage)
        }
        if isTestEvent(trimmed) {
            return ParsedBuildLine(message: trimmed, type: 3, progress: trimmed)
        }
        // Suppress only known command echoes. Keep unfamiliar output and diagnostic context.
        if isCommandEcho(line) { return ParsedBuildLine() }
        let type = if trimmed.range(of: #"(^|\s)(fatal error|error):"#, options: .regularExpression) != nil {
            1
        } else if trimmed.range(of: #"(^|\s)warning:"#, options: .regularExpression) != nil {
            2
        } else {
            4
        }
        return ParsedBuildLine(message: line, type: type)
    }

    private mutating func diagnostic(_ fields: [String], original: String) -> ParsedBuildLine {
        let severity: Diagnostic.DiagnosticSeverity = switch fields[3] {
        case "warning": .warning
        case "note": .information
        default: .error
        }
        var result = ParsedBuildLine(message: original, type: severity.rawValue)
        let path = fields[0]
        let file: URL = if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            url.standardizedFileURL
        } else {
            (path.hasPrefix("/") ? URL(fileURLWithPath: path) : context.rootURL.appendingPathComponent(path))
                .standardizedFileURL
        }
        let targetFields = captures(#"\s+\(in target '(.+)' from project '(.+)'\)$"#, in: fields[4])
        guard let target = targetIndex.target(for: file, named: targetFields?.first, project: targetFields?.last) else {
            return result
        }
        let line = max(0, (Int(fields[1]) ?? 1) - 1)
        let column = max(0, (Int(fields[2]) ?? 1) - 1)
        let position = Diagnostic.Position(
            line: line,
            character: utf16Column(file: file, line: line, byteColumn: column)
        )
        let message = fields[4].replacingOccurrences(
            of: #"\s+\(in target '.+' from project '.+'\)$"#, with: "", options: .regularExpression
        )
        result.diagnostic = BuildOutputDiagnostic(file: file, target: target, diagnostic: Diagnostic(
            range: .init(start: position, end: position), severity: severity, source: "xcodebuild", message: message
        ))
        return result
    }

    private mutating func utf16Column(file: URL, line: Int, byteColumn: Int) -> Int {
        if sourceLines[file] == nil {
            sourceLines[file] = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        }
        guard let lines = sourceLines[file], lines.indices.contains(line) else { return byteColumn }
        var bytes = 0
        var units = 0
        for scalar in lines[line].unicodeScalars {
            let length = String(scalar).utf8.count
            if bytes + length > byteColumn { break }
            bytes += length
            units += scalar.value > 0xFFFF ? 2 : 1
        }
        return units
    }

    private func stageMessage(_ line: String) -> String? {
        let phases: [String: String] = [
            "ComputeTargetDependencyGraph": "Resolve build dependencies",
            "Resolve Package Graph": "Resolve packages",
            "Prepare packages": "Prepare packages",
            "CreateBuildDescription": "Prepare build",
            "SwiftCompile": "Compile Swift", "SwiftEmitModule": "Emit Swift module",
            "CompileC": "Compile C/Objective-C", "Ld": "Link",
            "CompileAssetCatalog": "Compile assets", "CompileAssetCatalogVariant": "Compile assets",
            "CompileStoryboard": "Compile storyboard", "CompileXIB": "Compile interface",
            "CodeSign": "Sign product", "ProcessInfoPlistFile": "Process Info.plist",
            "PhaseScriptExecution": "Run build script", "Copy": "Copy files",
            "Touch": "Finish product", "GenerateDSYMFile": "Generate debug symbols"
        ]
        guard let entry = phases.first(where: { line == $0.key || line.hasPrefix($0.key + " ") }) else { return nil }
        let target = captures(#"\(in target '(.+)' from project '(.+)'\)$"#, in: line)?.first
        return target.map { "\(entry.value) — \($0)" } ?? entry.value
    }

    private func isTestEvent(_ line: String) -> Bool {
        line.hasPrefix("Test Suite ") || line.hasPrefix("Test Case ") || line.hasPrefix("Test case ")
            || line.hasPrefix("Testing started") || line.hasPrefix("Executed ")
            || line.hasPrefix("◇ Test ") || line.hasPrefix("✔ Test ") || line.hasPrefix("✘ Test ")
            || line.hasPrefix("** TEST ") || line.hasPrefix("** BUILD ")
    }

    private func isCommandEcho(_ line: String) -> Bool {
        guard line.hasPrefix("    ") else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("cd ") || trimmed.hasPrefix("export ")
            || trimmed.hasPrefix("/Applications/") || trimmed.hasPrefix("/usr/bin/")
            || trimmed.hasPrefix("builtin-") || trimmed.hasPrefix("/bin/sh -c ")
            || trimmed.hasPrefix("/Library/Developer/Toolchains/")
    }

    private func captures(_ pattern: String, in string: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
        else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: string).map { String(string[$0]) } ?? ""
        }
    }
}
