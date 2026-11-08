import Foundation
import XcodeProj

extension XcodeProjectManager {
    func findExistingScheme(
        for target: XcodeTarget,
        in schemes: [XcodeScheme],
        buildConfiguration: String = "Debug"
    ) throws -> XcodeScheme {
        let candidates = schemes.filter { scheme in
            if target.xcodeProductType.isTestBundle {
                return containsTestTarget(scheme: scheme, target: target)
            }
            return scheme.primaryBuildTargetProjectURL?.standardizedFileURL.path == target.projectURL
                .standardizedFileURL.path &&
                (scheme.primaryProductName == target.productNameWithExtension || scheme.primaryTarget == target.name) &&
                buildsForRunning(scheme: scheme, target: target)
        }
        let selected = candidates.first { $0.name == preferredSchemeName } ?? candidates.min { lhs, rhs in
            if (lhs.name == target.name) != (rhs.name == target.name) { return lhs.name == target.name }
            if (lhs.buildConfiguration == buildConfiguration) != (rhs.buildConfiguration == buildConfiguration) {
                return lhs.buildConfiguration == buildConfiguration
            }
            return lhs.name < rhs.name
        }
        guard let selected else {
            throw XcodeProjectError.invalidConfig(
                "No existing scheme supports target '\(target.name)'. Create or share a matching scheme in Xcode."
            )
        }
        guard schemes.count(where: { $0.name == selected.name }) == 1 else {
            throw XcodeProjectError.invalidConfig("Scheme '\(selected.name)' has multiple definitions")
        }
        return selected
    }

    private func buildsForRunning(scheme: XcodeScheme, target: XcodeTarget) -> Bool {
        guard let parsed = try? XCScheme(pathString: scheme.path.path) else { return false }
        return parsed.buildAction?.buildActionEntries.contains { entry in
            entry.buildFor.contains(.running) &&
                (try? contextTarget(for: entry.buildableReference, scheme: scheme).targetIdentifier) == target
                .targetIdentifier
        } == true
    }

    private func containsTestTarget(scheme: XcodeScheme, target: XcodeTarget) -> Bool {
        guard let parsed = try? XCScheme(pathString: scheme.path.path), let action = parsed.testAction,
              let targets = try? contextTestTargets(action, scheme: scheme) else { return false }
        return targets.contains { $0.targetIdentifier == target.targetIdentifier }
    }
}
