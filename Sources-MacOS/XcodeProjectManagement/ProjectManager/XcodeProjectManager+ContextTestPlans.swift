import BuildServerProtocol
import Foundation
import XcodeProj

extension XcodeProjectManager {
    func contextTestTargets(_ action: XCScheme.TestAction, scheme: XcodeScheme) throws -> [XcodeTarget] {
        guard let plans = action.testPlans, !plans.isEmpty else {
            return try action.testables.filter { !$0.skipped }.map {
                try contextTarget(for: $0.buildableReference, scheme: scheme)
            }
        }
        let url = try contextDefaultTestPlan(plans, scheme: scheme)
        let plan: ContextTestPlan
        do {
            plan = try JSONDecoder().decode(ContextTestPlan.self, from: Data(contentsOf: url))
        } catch {
            throw BuildContextError
                .invalid("Cannot read test plan '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
        return try plan.testTargets.filter { $0.enabled != false }.map { item in
            try contextTarget(for: XCScheme.BuildableReference(
                referencedContainer: item.target.containerPath,
                blueprintIdentifier: item.target.identifier,
                buildableName: item.target.name + ".xctest",
                blueprintName: item.target.name
            ), scheme: scheme)
        }
    }

    func contextTestPlanName(scheme: XcodeScheme) throws -> String? {
        let parsed = try XCScheme(pathString: scheme.path.path)
        guard let plans = parsed.testAction?.testPlans, !plans.isEmpty else { return nil }
        return try contextDefaultTestPlan(plans, scheme: scheme).deletingPathExtension().lastPathComponent
    }

    private func contextDefaultTestPlan(_ plans: [XCScheme.TestPlanReference], scheme: XcodeScheme) throws -> URL {
        let defaults = plans.filter(\.default)
        guard let selected = defaults.count == 1 ? defaults.first : (plans.count == 1 ? plans.first : nil) else {
            throw BuildContextError.invalid("Scheme '\(scheme.name)' must have one default test plan")
        }
        let url: URL
        if selected.reference.hasPrefix("container:") {
            url = try contextSchemeContainer(scheme).deletingLastPathComponent()
                .appendingPathComponent(String(selected.reference.dropFirst("container:".count)))
        } else if selected.reference.hasPrefix("absolute:") {
            url = URL(fileURLWithPath: String(selected.reference.dropFirst("absolute:".count)))
        } else {
            throw BuildContextError.invalid("Unsupported test plan reference: \(selected.reference)")
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard plans.count(where: {
            let path = $0.reference.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last ?? ""
            return URL(fileURLWithPath: String(path)).deletingPathExtension().lastPathComponent == name
        }) == 1 else {
            throw BuildContextError.invalid("Test plan name '\(name)' is ambiguous in scheme '\(scheme.name)'")
        }
        return url
    }
}

private struct ContextTestPlan: Decodable {
    let testTargets: [TestTarget]

    struct TestTarget: Decodable {
        let enabled: Bool?
        let target: TargetReference
    }

    struct TargetReference: Decodable {
        let containerPath: String
        let identifier: String
        let name: String
    }
}
