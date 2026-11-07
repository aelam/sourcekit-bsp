import Foundation

public enum XcodeContainerDiscovery {
    public static func isSwiftPMPackageWorkspace(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        return path.pathExtension == "xcworkspace"
            && path.deletingLastPathComponent().lastPathComponent == "xcode"
            && path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".swiftpm"
    }

    public static func isBuildContainer(_ url: URL) -> Bool {
        guard !isSwiftPMPackageWorkspace(url) else { return false }
        let metadata: String
        switch url.pathExtension {
        case "xcodeproj": metadata = "project.pbxproj"
        case "xcworkspace": metadata = "contents.xcworkspacedata"
        default: return false
        }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent(metadata).path,
            isDirectory: &directory
        )
            && !directory.boolValue
    }
}
