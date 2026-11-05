public extension XcodeBSPProjectManager {
    func invalidateIndexInputs() async {
        await backend.invalidateIndexInputs()
    }
}
