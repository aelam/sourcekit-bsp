import Foundation
import SourceKitBSPProtocol
import SwiftPMProjectManagerProvider

public struct BSPServerLaunchOptions: Sendable {
    public let configuration: ProjectConfiguration?

    public init(arguments: [String]) throws {
        var selection: (option: String, path: String)?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            if option == "--debug" { continue }
            guard ["--package", "--project", "--workspace"].contains(option) else {
                throw BuildServerError.invalidConfiguration("Unknown server option: \(option). Use --help for usage.")
            }
            guard selection == nil else {
                throw BuildServerError.invalidConfiguration("Use only one of --package, --project, or --workspace.")
            }
            guard index < arguments.count, !arguments[index].hasPrefix("--"),
                  !arguments[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BuildServerError.invalidConfiguration("Missing path for \(option).")
            }
            selection = (option, arguments[index])
            index += 1
        }
        guard let selection else {
            configuration = nil
            return
        }
        if selection.option == "--package" {
            configuration = ProjectConfiguration(
                preferredProvider: SwiftPMProjectManagerProvider.providerName,
                packagePath: selection.path
            )
        } else {
            configuration = ProjectConfiguration(
                customSettings: [String(selection.option.dropFirst(2)): selection.path],
                preferredProvider: "XcodeProjectManagerProvider"
            )
        }
    }
}
