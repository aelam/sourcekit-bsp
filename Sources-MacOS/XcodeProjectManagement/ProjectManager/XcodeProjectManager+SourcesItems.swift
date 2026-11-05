public extension XcodeProjectManager {
    func getSourcesItems(targetIdentifiers: [XcodeTargetIdentifier]) -> [SourcesItem] {
        guard projectSnapshot != nil else {
            fatalError("XcodeProjectSnapshot cannot be resolved before initialize()")
        }
        return projectStore.sources(for: targetIdentifiers)
    }
}
