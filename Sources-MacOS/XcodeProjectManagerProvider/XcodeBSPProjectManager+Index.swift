import SourceKitBSPProtocol
import XcodeProjectManagement

public extension XcodeBSPProjectManager {
    func invalidateIndexInputs() async {
        await backend.invalidateIndexInputs()
        await indexing?.invalidateInputs()
    }

    func invalidateIndexInputs(for changes: [ProjectFileChange]) async {
        guard !changes.isEmpty else { return }
        guard let project else {
            await invalidateIndexInputs()
            return
        }
        let classifier = XcodeFileChangeClassifier(rootURL: project.rootURL, buildRootURL: project.buildRootURL)
        await backend.invalidateIndexInputs()
        await indexing?.invalidateInputs(preservingArguments: classifier.preservesCompilerArguments(for: changes))
    }
}
