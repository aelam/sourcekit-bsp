import Foundation
import PathKit
import Testing
import XcodeProj // @tuist ~> 8.8.0

struct XcodeProjTests {
    @Test
    func workspaceInitialization() throws {
        let projectFolder = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("DemoProjects")
            .appendingPathComponent("HelloWorkspace")
            .appendingPathComponent("Hello.xcworkspace"))
        let workspacePath = Path(projectFolder.path)
        let workspace = try XCWorkspace(path: workspacePath)
        for child in workspace.data.children {
            if case let .file(fileElement) = child {
                let xcodeprojPath = resolveFileRefPath(workspacePath: workspacePath, fileRef: fileElement.location.path)
                print("Project path: \(xcodeprojPath.string)")
                if xcodeprojPath.extension == "xcodeproj" {
                    let xcodeproj = try XcodeProj(path: xcodeprojPath)
                    for target in xcodeproj.pbxproj.nativeTargets {
                        print("Target: \(target.name)")
                        let files = try target.sourceFiles()
                        for file in files {
                            print("  \(file.path ?? "No path")")
                        }
                    }
                }
            }
        }
    }

    func resolveFileRefPath(workspacePath: Path, fileRef: String) -> Path {
        if fileRef.hasPrefix("group:") {
            let relativePath = fileRef.replacingOccurrences(of: "group:", with: "")
            return workspacePath.parent() + Path(relativePath)
        } else if fileRef.hasPrefix("container:") {
            let relativePath = fileRef.replacingOccurrences(of: "container:", with: "")
            return workspacePath.parent() + Path(relativePath)
        } else if fileRef.hasPrefix("absolute:") {
            let absolutePath = fileRef.replacingOccurrences(of: "absolute:", with: "")
            return Path(absolutePath)
        } else {
            // fallback, treat as relative to workspace parent
            return workspacePath.parent() + Path(fileRef)
        }
    }
}
