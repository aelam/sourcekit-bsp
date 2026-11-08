import Foundation
import XcodeProj

public struct XcodeLaunchSettings: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String? = nil
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    init(action: XCScheme.LaunchAction, buildSettings: [String: String]) throws {
        let enabled = action.commandlineArguments?.arguments.filter(\.enabled) ?? []
        arguments = try enabled.flatMap { argument in
            try Self.splitArguments(argument.name).map { try Self.expand($0, using: buildSettings) }
        }
        environment = [:]
        for variable in action.environmentVariables ?? [] where variable.enabled {
            environment[variable.variable] = try Self.expand(variable.value, using: buildSettings)
        }
        workingDirectory = try action.useCustomWorkingDirectory
            ? action.customWorkingDirectory.map { try Self.expand($0, using: buildSettings) } : nil
    }

    static func splitArguments(_ value: String) throws -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in value {
            if escaped {
                token.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                started = true
            } else if let current = quote {
                if character == current {
                    quote = nil
                } else {
                    token.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { result.append(token) }
                token = ""
                started = false
            } else {
                token.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else {
            throw XcodeRunError.failedToLaunchApp("The scheme contains an unterminated quoted argument or escape")
        }
        if started { result.append(token) }
        return result
    }

    static func expand(_ value: String, using settings: [String: String]) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\$\(([^)]+)\)|\$\{([^}]+)\}"#)
        var expanded = value
        for _ in 0 ..< 10 {
            let matches = expression.matches(in: expanded, range: NSRange(expanded.startIndex..., in: expanded))
            if matches.isEmpty { return expanded }
            for match in matches.reversed() {
                let keyRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
                guard let range = Range(match.range, in: expanded), let keyRange = Range(keyRange, in: expanded),
                      let replacement = settings[String(expanded[keyRange])] else {
                    throw XcodeRunError
                        .failedToLaunchApp("Cannot resolve a build setting in the scheme launch settings")
                }
                expanded.replaceSubrange(range, with: replacement)
            }
        }
        throw XcodeRunError.failedToLaunchApp("The scheme launch settings contain recursive build settings")
    }
}

extension XcodeProjectManager {
    func launchSettings(
        for target: XcodeTarget, arguments: [String]?, buildSettings: [String: String]
    ) throws -> XcodeLaunchSettings {
        guard let arguments, let index = arguments.firstIndex(of: "-scheme") else { return .init() }
        guard index + 1 < arguments.count, arguments.count(where: { $0 == "-scheme" }) == 1,
              let base = projectSnapshot else {
            throw XcodeRunError.failedToLaunchApp("Specify exactly one scheme name")
        }
        let matches = base.schemes.filter { $0.name == arguments[index + 1] }
        guard matches.count == 1, let scheme = matches.first else {
            throw XcodeRunError.failedToLaunchApp("The launch scheme is missing or ambiguous")
        }
        let parsed = try XCScheme(pathString: scheme.path.path)
        guard let action = parsed.launchAction, let reference = action.runnable?.buildableReference,
              try contextTarget(for: reference, scheme: scheme).targetIdentifier == target.targetIdentifier else {
            throw XcodeRunError.failedToLaunchApp("The selected scheme does not launch this target")
        }
        if let expansion = action.macroExpansion,
           try contextTarget(for: expansion, scheme: scheme).targetIdentifier != target.targetIdentifier {
            throw XcodeRunError.failedToLaunchApp("Launch settings that expand another target are not supported")
        }
        return try XcodeLaunchSettings(action: action, buildSettings: buildSettings)
    }
}
