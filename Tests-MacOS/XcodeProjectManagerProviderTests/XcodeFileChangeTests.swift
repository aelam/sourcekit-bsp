import BuildServerProtocol
import Foundation
import Testing
@testable import XcodeProjectManagerProvider

struct XcodeFileChangeTests {
    private let root = URL(fileURLWithPath: "/tmp/BSP Workspace")

    private var classifier: XcodeFileChangeClassifier {
        XcodeFileChangeClassifier(rootURL: root, buildRootURL: root.appendingPathComponent("DerivedData"))
    }

    private func event(_ path: String, kind: ProjectFileChange.Kind = .changed) -> ProjectFileChange {
        ProjectFileChange(uri: URI(root.appendingPathComponent(path)), kind: kind)
    }

    @Test(arguments: [ProjectFileChange.Kind.created, .changed, .deleted])
    func generatedSchemesDoNotInvalidateTheWorkspace(kind: ProjectFileChange.Kind) {
        let generated = event("App.xcodeproj/xcshareddata/xcschemes/sourcekit-bsp-App.xcscheme", kind: kind)
        #expect(!classifier.requiresReload(for: [generated]))
        #expect(!classifier.requiresReload(for: [
            event("Modules/Nested.xcodeproj/xcshareddata/xcschemes/sourcekit-bsp-Nested.xcscheme", kind: kind)
        ]))
        #expect(classifier.requiresReload(for: [
            generated, event("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme", kind: kind)
        ]))
        #expect(classifier.requiresReload(for: [generated, event("New.swift", kind: .created)]))
    }

    @Test(arguments: [
        "Configuration/sourcekit-bsp-App.xcscheme",
        "App.xcworkspace/xcshareddata/xcschemes/sourcekit-bsp-App.xcscheme",
        "App.xcodeproj/xcuserdata/xcschemes/sourcekit-bsp-App.xcscheme",
        "App.xcodeproj/xcshareddata/Other/sourcekit-bsp-App.xcscheme",
        "App.xcodeproj/xcshareddata/xcschemes/Nested/sourcekit-bsp-App.xcscheme",
        "App.xcodeproj/xcshareddata/xcschemes/sourcekit-bsp.xcscheme",
        "App.xcodeproj/xcshareddata/xcschemes/sourcekit-bsp-App.xcconfig"
    ])
    func onlyStrictHelperPathsAreIgnored(path: String) {
        #expect(classifier.requiresReload(for: [event(path)]))
    }

    @Test(arguments: [ProjectFileChange.Kind.created, .changed, .deleted])
    func buildArtifactsAreIgnored(kind: ProjectFileChange.Kind) {
        let paths = [
            "DerivedData", "DerivedData/Generated.swift", "DerivedData/Build/config.xcconfig",
            "DerivedData/Nested.xcodeproj/xcshareddata/xcschemes/App.xcscheme",
            ".build/Input.swift", "Module/.build/Package.resolved", "Sources/../DerivedData/Generated.swift"
        ]
        #expect(!classifier.requiresReload(for: paths.map { event($0, kind: kind) }))
    }

    @Test(arguments: ["swift", "c", "cc", "cpp", "cxx", "m", "mm", "h", "hpp", "hxx"])
    func sourceMembershipChangesReloadButEditsDoNot(fileExtension: String) {
        let path = "Sources/File.\(fileExtension)"
        #expect(classifier.requiresReload(for: [event(path, kind: .created)]))
        #expect(classifier.requiresReload(for: [event(path, kind: .deleted)]))
        #expect(!classifier.requiresReload(for: [event(path)]))
    }

    @Test(arguments: [
        "App.xcodeproj/project.pbxproj", "App.xcworkspace", "App.xcworkspace/contents.xcworkspacedata",
        "Config/Debug.xcconfig", "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme", "Config/Inputs.xcfilelist",
        "Package.resolved", ".sourcekit-bsp/project.json"
    ])
    func configurationChangesAlwaysReload(path: String) {
        for kind in [ProjectFileChange.Kind.created, .changed, .deleted] {
            #expect(classifier.requiresReload(for: [event(path, kind: kind)]))
        }
    }

    @Test
    func buildDirectoriesMatchPathComponents() {
        #expect(classifier.requiresReload(for: [event("DerivedData-other/File.swift", kind: .created)]))
        #expect(classifier.requiresReload(for: [event("Module/.build-other/File.swift", kind: .created)]))
        #expect(classifier.requiresReload(for: [event("DerivedData/../Sources/File.swift", kind: .deleted)]))
    }

    @Test
    func unrelatedFilesAndEmptyBatchesDoNotReload() throws {
        #expect(!classifier.requiresReload(for: []))
        #expect(try !classifier.requiresReload(for: [
            event("README.md", kind: .created), event("Assets/Icon.png", kind: .deleted),
            event("Module/.sourcekit-bsp/project.json"),
            .init(uri: URI(string: "https://example.com/Config.xcconfig"), kind: .changed)
        ]))
    }
}
