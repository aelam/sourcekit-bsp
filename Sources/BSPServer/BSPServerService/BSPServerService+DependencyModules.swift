import BuildServerProtocol

extension BSPServerService {
    func getDependencyModules(targetIds: [BSPBuildTargetIdentifier]) async throws -> [DependencyModulesItem] {
        guard let projectManager else { throw DependencyModulesError.notInitialized }
        guard await projectManager.capabilities.contains(.dependencyModules) else {
            throw DependencyModulesError.unsupported
        }
        return try await projectManager.getDependencyModules(targetIdentifiers: targetIds)
    }
}
