import Foundation
import PathKit
import XcodeProj

public enum SourceFileLister {
    // MARK: - SourceFiles

    public typealias SourceMap = [String: [SourceItem]]

    public static func loadSourceFiles(
        for xcodeProj: XcodeProj,
        targets: Set<String>
    ) -> SourceMap {
        guard let xcodeProjPath = xcodeProj.path else {
            print(
                "Cannot open Xcode project at \(xcodeProj.path?.string ?? "unknown path")"
            )
            return SourceMap()
        }
        let sourceRoot = xcodeProjPath.parent()
        var sourceMap = SourceMap()

        for target in xcodeProj.pbxproj.nativeTargets
            where targets.contains(target.name) {
            var sourceItems = sourceFilesFromBuildPhases(target, sourceRoot: sourceRoot)

            // Xcode15+：fileSystemSynchronizedGroups
            if let syncGroupIDs = target.fileSystemSynchronizedGroups {
                sourceItems += sourceFilesFromSynchronizedGroups(
                    syncGroupIDs,
                    target: target,
                    sourceRoot: sourceRoot
                )
            }

            // 去重
            sourceItems = Array(Set(sourceItems)).sorted { $0.path.path < $1.path.path }
            let targetIdentifier = XcodeTargetIdentifier(
                projectFilePath: xcodeProjPath.string,
                targetName: target.name
            )
            sourceMap[targetIdentifier.rawValue] = sourceItems
        }
        return sourceMap
    }

    /// 辅助方法：从同步 group 获取源码文件
    private static func sourceFilesFromSynchronizedGroups(
        _ syncGroupIDs: [PBXFileSystemSynchronizedRootGroup],
        target: PBXNativeTarget,
        sourceRoot: Path
    ) -> [SourceItem] {
        syncGroupIDs.flatMap { group -> [SourceItem] in
            guard let folderPath = try? group.fullPath(sourceRoot: sourceRoot),
                  let enumerator = FileManager.default.enumerator(
                      at: URL(fileURLWithPath: folderPath.string),
                      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else {
                return []
            }
            let exceptions = (group.exceptions ?? []).flatMap { exception -> [String] in
                if let files = exception as? PBXFileSystemSynchronizedBuildFileExceptionSet,
                   files.target == target {
                    return files.membershipExceptions ?? []
                }
                if let phase = exception as? PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet,
                   phase.buildPhase is PBXSourcesBuildPhase,
                   target.buildPhases.contains(where: { $0 == phase.buildPhase }) {
                    return phase.membershipExceptions ?? []
                }
                return []
            }
            let excluded = exceptions + (group.explicitFolders ?? [])
            var items: [SourceItem] = []
            for case let file as URL in enumerator {
                let relative = file.pathComponents.suffix(enumerator.level).joined(separator: "/")
                if excluded.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                let isSource: Bool = if let type = group.explicitFileTypes?[relative] {
                    type.hasPrefix("sourcecode.")
                } else {
                    ["swift", "c", "m", "mm", "cc", "cpp", "cxx", "C", "h", "hh", "hpp", "hxx"]
                        .contains(file.pathExtension)
                }
                if isSource { items.append(SourceItem(path: file, itemKind: .file)) }
            }
            return items
        }
    }

    /// 辅助方法：从 build phase 获取源码文件
    private static func sourceFilesFromBuildPhases(
        _ target: PBXNativeTarget,
        sourceRoot: Path
    ) -> [SourceItem] {
        target.buildPhases.compactMap { $0 as? PBXSourcesBuildPhase }
            .flatMap { sourcesPhase in
                (sourcesPhase.files ?? []).compactMap { buildFile in
                    guard let fileRef = buildFile.file else { return nil }
                    if let full = try? fileRef.fullPath(sourceRoot: sourceRoot)?
                        .string {
                        return full
                    } else if let rel = fileRef.path {
                        return (sourceRoot + Path(rel)).string
                    } else {
                        print("Cannot resolve path for \(fileRef)")
                        return nil
                    }
                }
            }
            .map { fullPath in
                SourceItem(path: URL(filePath: fullPath), itemKind: .file)
            }
    }
}
