import Foundation
import Logger
import PathKit
import XcodeProj

public enum SourceFileLister {
    // MARK: - SourceFiles

    public typealias SourceMap = [String: [SourceItem]]

    public static func loadSourceFiles(
        for xcodeProj: XcodeProj,
        targets: Set<String>
    ) -> SourceMap {
        loadSourcesItems(for: xcodeProj, targets: targets).mapValues(\.sources)
    }

    static func loadSourcesItems(
        for xcodeProj: XcodeProj,
        targets: Set<String>
    ) -> [String: SourcesItem] {
        guard let xcodeProjPath = xcodeProj.path else {
            logger.warning(
                "Cannot open Xcode project at \(xcodeProj.path?.string ?? "unknown path")"
            )
            return [:]
        }
        let sourceRoot = xcodeProjPath.parent()
        var sourceMap: [String: SourcesItem] = [:]

        for target in xcodeProj.pbxproj.nativeTargets
            where targets.contains(target.name) {
            var files = sourceFilesFromBuildPhases(target, sourceRoot: sourceRoot)

            // Xcode15+：fileSystemSynchronizedGroups
            if let syncGroupIDs = target.fileSystemSynchronizedGroups {
                let synchronized = sourceFilesFromSynchronizedGroups(
                    syncGroupIDs,
                    target: target,
                    sourceRoot: sourceRoot
                )
                files.sources += synchronized.sources
                files.roots += synchronized.roots
            }

            // 去重
            let sourceItems = Array(Set(files.sources)).sorted { $0.path.path < $1.path.path }
            let roots = Array(Set(files.roots.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
            let targetIdentifier = XcodeTargetIdentifier(
                projectFilePath: xcodeProjPath.string,
                targetName: target.name
            )
            sourceMap[targetIdentifier.rawValue] = SourcesItem(
                target: targetIdentifier,
                sources: sourceItems,
                roots: roots
            )
        }
        return sourceMap
    }

    private struct SourceFiles {
        var sources: [SourceItem] = []
        var roots: [URL] = []
    }

    /// 辅助方法：从同步 group 获取源码文件
    private static func sourceFilesFromSynchronizedGroups(
        _ syncGroupIDs: [PBXFileSystemSynchronizedRootGroup],
        target: PBXNativeTarget,
        sourceRoot: Path
    ) -> SourceFiles {
        var result = SourceFiles()
        for group in syncGroupIDs {
            guard let folderPath = try? group.fullPath(sourceRoot: sourceRoot),
                  let enumerator = FileManager.default.enumerator(
                      at: URL(fileURLWithPath: folderPath.string),
                      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else {
                continue
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
            if !items.isEmpty {
                result.sources += items
                result.roots.append(URL(fileURLWithPath: folderPath.string, isDirectory: true))
            }
        }
        return result
    }

    /// 辅助方法：从 build phase 获取源码文件
    private static func sourceFilesFromBuildPhases(
        _ target: PBXNativeTarget,
        sourceRoot: Path
    ) -> SourceFiles {
        var result = SourceFiles()
        for phase in target.buildPhases.compactMap({ $0 as? PBXSourcesBuildPhase }) {
            for buildFile in phase.files ?? [] {
                guard let fileRef = buildFile.file else { continue }
                let fullPath: String
                if let full = try? fileRef.fullPath(sourceRoot: sourceRoot)?.string {
                    fullPath = full
                } else if let relative = fileRef.path {
                    fullPath = (sourceRoot + Path(relative)).string
                } else {
                    logger.warning("Cannot resolve path for \(fileRef)")
                    continue
                }
                let file = URL(filePath: fullPath)
                result.sources.append(SourceItem(path: file, itemKind: .file))
                result.roots.append(sourceFolder(for: fileRef, file: file, sourceRoot: sourceRoot))
            }
        }
        return result
    }

    private static func sourceFolder(for reference: PBXFileElement, file: URL, sourceRoot: Path) -> URL {
        let projectDirectory = URL(fileURLWithPath: sourceRoot.string, isDirectory: true).standardizedFileURL
        let file = file.standardizedFileURL
        var root = file.deletingLastPathComponent()
        var parent = reference.parent
        var visited: Set<ObjectIdentifier> = []
        while let group = parent, visited.insert(ObjectIdentifier(group)).inserted {
            // A named virtual group does not define a source directory.
            if let groupPath = group.path, !groupPath.isEmpty,
               let resolved = try? group.fullPath(sourceRoot: sourceRoot) {
                let directory = URL(fileURLWithPath: resolved.string, isDirectory: true).standardizedFileURL
                if directory != projectDirectory, file.path.hasPrefix(directory.path + "/") {
                    root = directory
                }
            }
            parent = group.parent
        }
        return root
    }
}
