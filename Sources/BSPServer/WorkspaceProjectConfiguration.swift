import Foundation
import SourceKitBSPProtocol
import SwiftPMProjectManagerProvider

struct WorkspaceProjectConfiguration: Decodable {
    let package: String?
    let project: String?
    let workspace: String?

    static func load(at root: URL) throws -> ProjectConfiguration? {
        let file = root.appendingPathComponent(".sourcekit-bsp/project.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let selection: Self
        do {
            selection = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        } catch {
            throw BuildServerError.invalidConfiguration("Cannot read \(file.path): \(error.localizedDescription)")
        }
        guard let package = selection.package else {
            guard selection.project != nil || selection.workspace != nil else { return nil }
            return ProjectConfiguration(preferredProvider: "XcodeProjectManagerProvider")
        }
        guard !package.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.project == nil, selection.workspace == nil else {
            throw BuildServerError.invalidConfiguration(
                "The package path must be nonempty and cannot be combined with project or workspace in \(file.path)."
            )
        }
        return ProjectConfiguration(
            preferredProvider: SwiftPMProjectManagerProvider.providerName,
            packagePath: package
        )
    }
}
