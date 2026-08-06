import Foundation
import PathKit
import XcodeProj

extension String {
    func droppingExtension() -> String {
        (self as NSString).deletingPathExtension
    }
}

func normalizeTargetOrProductName(_ raw: String) -> String {
    raw.droppingExtension().asC99ExtIdentifier()
}

public final class XcodeBuildGraphResolver {
    public enum DependencyResolutionMode {
        case full
        case topLevel
    }

    private let primary: XcodeProj
    private let extras: [XcodeProj]
    private var productToTarget: [String: (proj: XcodeProj, target: PBXNativeTarget)] = [:]
    private var nameToTarget: [String: (proj: XcodeProj, target: PBXNativeTarget)] = [:]
    private let mode: DependencyResolutionMode

    public init(
        primaryXcodeProj: XcodeProj,
        additionalXcodeProjs: [XcodeProj] = [],
        mode: DependencyResolutionMode = .topLevel
    ) {
        self.primary = primaryXcodeProj
        self.extras = additionalXcodeProjs
        self.mode = mode

        // 注册所有 target
        for t in primaryXcodeProj.pbxproj.nativeTargets {
            registerTarget(proj: primaryXcodeProj, target: t)
        }
        for proj in additionalXcodeProjs {
            for t in proj.pbxproj.nativeTargets {
                registerTarget(proj: proj, target: t)
            }
        }
    }

    /// 统一 target/product 名，去掉扩展名 + 转合法 C99
    private func normalizeTargetOrProductName(_ raw: String) -> String {
        let noExt = (raw as NSString).deletingPathExtension
        let invalidChars = CharacterSet.alphanumerics.inverted
        return noExt.unicodeScalars.map { invalidChars.contains($0) ? "_" : Character($0) }
            .map { String($0) }
            .joined()
    }

    private func registerTarget(proj: XcodeProj, target: PBXNativeTarget) {
        if let productName = target.productName {
            productToTarget[normalizeTargetOrProductName(productName)] = (proj, target)
        }
        productToTarget[normalizeTargetOrProductName(target.name)] = (proj, target)
        nameToTarget[target.name] = (proj, target)
    }

    /// 查找目标 target
    private func findTarget(by identifier: XcodeTargetIdentifier)
        -> (proj: XcodeProj, target: PBXNativeTarget)? {
        let allProjects = [primary] + extras
        for proj in allProjects where proj.path?.string == identifier.projectFilePath {
            if let t = proj.pbxproj.nativeTargets.first(where: { $0.name == identifier.targetName }) {
                return (proj, t)
            }
        }
        return nil
    }

    /// 计算构建顺序
    public func buildOrder(for target: XcodeTargetIdentifier) -> [XcodeTargetIdentifier] {
        guard let start = findTarget(by: target) else {
            print("❌ Target '\(target.rawValue)' not found")
            return []
        }

        var visited = Set<String>()
        var result: [XcodeTargetIdentifier] = []
        var tempMark = Set<String>()

        visit(start, result: &result, visited: &visited, tempMark: &tempMark)
        return result
    }

    /// The *direct* (immediate, non-transitive) upstream dependencies of a
    /// target — both explicit target dependencies and implicit framework links.
    /// This is what BSP's `BSPBuildTarget.dependencies` expects (unlike
    /// `buildOrder`, which returns the full transitive order).
    public func directDependencies(for target: XcodeTargetIdentifier) -> [XcodeTargetIdentifier] {
        guard let entry = findTarget(by: target) ?? nameToTarget[target.targetName] else {
            return []
        }

        var seen = Set<String>()
        var deps: [XcodeTargetIdentifier] = []

        func append(_ e: (proj: XcodeProj, target: PBXNativeTarget)) {
            // Don't list the target as its own dependency, and de-dupe.
            guard e.target.uuid != entry.target.uuid, seen.insert(e.target.uuid).inserted else {
                return
            }
            deps.append(XcodeTargetIdentifier(
                projectFilePath: e.proj.path?.string ?? "<unknown>",
                targetName: e.target.name
            ))
        }

        // Explicit target dependencies.
        for dep in entry.target.dependencies {
            if let depTarget = dep.target as? PBXNativeTarget, let depEntry = nameToTarget[depTarget.name] {
                append(depEntry)
            } else if let depName = dep.name, let depEntry = nameToTarget[depName] {
                append(depEntry)
            }
        }

        // Implicit dependencies via linked frameworks/libraries.
        if let linkPhase = entry.target.buildPhases.compactMap({ $0 as? PBXFrameworksBuildPhase }).first {
            for file in linkPhase.files ?? [] {
                if let rawName = file.file?.name ?? file.file?.path {
                    let key = normalizeTargetOrProductName(rawName)
                    if let depEntry = productToTarget[key] {
                        append(depEntry)
                    }
                }
            }
        }

        return deps
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func visit(
        _ entry: (proj: XcodeProj, target: PBXNativeTarget),
        result: inout [XcodeTargetIdentifier],
        visited: inout Set<String>,
        tempMark: inout Set<String>
    ) {
        let uuid = entry.target.uuid
        if visited.contains(uuid) { return }
        if tempMark.contains(uuid) {
            print("⚠️ Cycle at \(entry.target.name)")
            return
        }
        tempMark.insert(uuid)

        let isAggregateLike = entry.target.name.hasPrefix("Pods-")

        if mode == .full || !isAggregateLike {
            // 显式依赖
            for dep in entry.target.dependencies {
                if let depTarget = dep.target as? PBXNativeTarget {
                    if let depEntry = nameToTarget[depTarget.name] {
                        visit(depEntry, result: &result, visited: &visited, tempMark: &tempMark)
                    }
                } else if let depName = dep.name,
                          let depEntry = nameToTarget[depName] {
                    visit(depEntry, result: &result, visited: &visited, tempMark: &tempMark)
                }
            }

            // 隐式依赖
            if let linkPhase = entry.target.buildPhases.compactMap({ $0 as? PBXFrameworksBuildPhase }).first {
                for file in linkPhase.files ?? [] {
                    if let rawName = file.file?.name ?? file.file?.path {
                        let key = normalizeTargetOrProductName(rawName)
                        if let depEntry = productToTarget[key] {
                            visit(depEntry, result: &result, visited: &visited, tempMark: &tempMark)
                        }
                    }
                }
            }
        }

        tempMark.remove(uuid)
        visited.insert(uuid)

        let id = XcodeTargetIdentifier(
            projectFilePath: entry.proj.path?.string ?? "<unknown>",
            targetName: entry.target.name
        )
        result.append(id)
    }
}
