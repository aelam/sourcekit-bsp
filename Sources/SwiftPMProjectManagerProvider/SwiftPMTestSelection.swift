import Foundation
import SourceKitBSPProtocol

struct SwiftPMTestSelection: Codable, Sendable {
    static let dataKind = "sourcekit-test-selection"
    static let argumentPrefix = "--sourcekit-internal-test-selection="

    struct Test: Codable, Hashable, Sendable {
        let target: BSPBuildTargetIdentifier
        let id: String
        let style: String
    }

    let tests: [Test]

    func validate(requested: [BSPBuildTargetIdentifier]) throws {
        guard !tests.isEmpty, Set(tests.map(\.target)) == Set(requested) else {
            throw SwiftPMProjectError.invalidArguments("Test selection must cover exactly the requested targets.")
        }
        for test in tests {
            guard ["XCTest", "swift-testing"].contains(test.style),
                  !test.id.isEmpty, test.id.utf8.count <= 4096, test.id.hasSuffix(")"),
                  !test.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  test.id.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
                  test.style != "XCTest" || (test.id.hasSuffix("()") && test.id.contains("/")) else {
                throw SwiftPMProjectError.invalidArguments("Invalid test identifier: \(test.id)")
            }
        }
    }

    func encodedArgument() throws -> String {
        try Self.argumentPrefix + (JSONEncoder().encode(self)).base64EncodedString()
    }

    static func extract(from arguments: [String]?) throws -> (arguments: [String], selection: Self?) {
        var options = arguments ?? []
        guard let last = options.last, last.hasPrefix(argumentPrefix) else { return (options, nil) }
        options.removeLast()
        guard let data = Data(base64Encoded: String(last.dropFirst(argumentPrefix.count))) else {
            throw SwiftPMProjectError.invalidArguments("Invalid internal test selection.")
        }
        return try (options, JSONDecoder().decode(Self.self, from: data))
    }

    func tests(for target: BSPBuildTargetIdentifier) -> [Test] {
        Array(Set(tests.filter { $0.target == target })).sorted { $0.id < $1.id }
    }

    static func filter(module: String, tests: [Test]?) -> String {
        let prefix = "^" + NSRegularExpression.escapedPattern(for: module) + "\\."
        guard let tests else { return prefix }
        let patterns = tests.map { test in
            let identifier = test.style == "XCTest" ? String(test.id.dropLast(2)) : test.id
            let suffix = test.style == "XCTest" ? "$" : "(/|$)"
            return NSRegularExpression.escapedPattern(for: identifier) + suffix
        }
        return prefix + "(" + patterns.joined(separator: "|") + ")"
    }
}
