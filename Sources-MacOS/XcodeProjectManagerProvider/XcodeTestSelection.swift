import Foundation
import SourceKitBSPProtocol
import XcodeProjectManagement

struct XcodeTestSelection: Decodable {
    static let dataKind = "sourcekit-test-selection"

    struct Test: Decodable {
        let target: BSPBuildTargetIdentifier
        let id: String
        let style: String
    }

    let tests: [Test]

    static func arguments(
        targets: [XcodeTarget],
        requested: [BSPBuildTargetIdentifier],
        arguments: [String]?,
        dataKind: String?,
        data: LSPAny?
    ) throws -> [String]? {
        guard dataKind != nil || data != nil else { return arguments }
        guard dataKind == Self.dataKind, let data else {
            throw XcodeProjectError.invalidConfig("Unsupported test selection data")
        }
        let selection = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(data))
        guard !selection.tests.isEmpty else {
            throw XcodeProjectError.invalidConfig("Test selection must not be empty")
        }
        guard !(arguments ?? []).contains(where: {
            $0.hasPrefix("-only-testing") || $0.hasPrefix("-skip-testing") || $0.hasPrefix("-testPlan")
        }) else {
            throw XcodeProjectError.invalidConfig("Do not combine test selection data with test filters or a test plan")
        }
        let selectedTargets = Set(selection.tests.map(\.target))
        guard selectedTargets == Set(requested) else {
            throw XcodeProjectError.invalidConfig("Test selection must cover exactly the requested targets")
        }
        let filters = try selection.tests.map { test in
            guard let target = targets.first(where: { $0.targetIdentifier.bspIdentifier == test.target }),
                  target.xcodeProductType.isTestBundle else {
                throw XcodeProjectError.invalidConfig("Unknown test target: \(test.target.uri.stringValue)")
            }
            guard ["XCTest", "swift-testing"].contains(test.style),
                  !test.id.isEmpty, test.id.utf8.count <= 4096, test.id.hasSuffix(")"),
                  !test.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !test.id.contains("*"), !test.id.contains("?"),
                  test.id.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else {
                throw XcodeProjectError.invalidConfig("Invalid test identifier: \(test.id)")
            }
            let identifier = test.style == "XCTest" && test.id.hasSuffix("()")
                ? String(test.id.dropLast(2)) : test.id
            return "-only-testing:\(target.name)/\(identifier)"
        }
        return (arguments ?? []) + filters
    }
}

public extension XcodeBSPProjectManager {
    func testArguments(
        targetIdentifiers: [BSPBuildTargetIdentifier], arguments: [String]?, dataKind: String?, data: LSPAny?
    ) async throws -> [String]? {
        try await XcodeTestSelection.arguments(
            targets: backend.projectSnapshot?.xcodeTargets ?? [],
            requested: targetIdentifiers,
            arguments: arguments,
            dataKind: dataKind,
            data: data
        )
    }
}
