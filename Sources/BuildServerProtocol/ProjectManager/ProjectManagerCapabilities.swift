/// Operations that a project provider can execute.
public enum ProjectManagerCapability: String, CaseIterable, Sendable {
    case compile, test, run, debug
    case prepare, sourceKitOptions
    case outputPaths, cleanCache
}

public typealias ProjectManagerCapabilities = Set<ProjectManagerCapability>
