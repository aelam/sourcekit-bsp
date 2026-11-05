public extension BSPServerService {
    func invalidateIndexInputs() async {
        await projectManager?.invalidateIndexInputs()
    }
}
