// PBXProject (工程)
// │
// ├─ XCConfigurationList (配置列表)
// │   ├─ XCBuildConfiguration "Debug"
// │   │    └─ buildSettings { ... }   ← 工程 Debug 配置
// │   └─ XCBuildConfiguration "Release"
// │        └─ buildSettings { ... }   ← 工程 Release 配置
// │
// └─ PBXNativeTarget "AppTarget"
//     │
//     └─ XCConfigurationList (配置列表)
//         ├─ XCBuildConfiguration "Debug"
//         │    └─ buildSettings { ... }  ← Target Debug 配置（覆盖 Project Debug）
//         └─ XCBuildConfiguration "Release"
//              └─ buildSettings { ... }  ← Target Release 配置（覆盖 Project
// Release）

import Foundation
import PathKit
import XcodeProj

/// 通用 Xcode Build Setting 解析器。支持递归查找、$(inherited) 合并、自定义默认值。
public struct BuildSettingResolver: @unchecked Sendable {
    enum ResolverError: Error {
        case invalidXcodeProj
        case targetNotFound(String)
        case configurationNotFound(String)
    }

    let xcodeInstallation: XcodeInstallation
    let xcodeGlobalSettings: XcodeGlobalSettings
    let xcodeProj: XcodeProj
    let target: String
    let configuration: String
    let overrides: [String: String]
    let forceSimulator: Bool
    // private
    private let sourceRoot: Path
    private let project: PBXProject
    private let xcodeProjTarget: PBXNativeTarget
    public let resolvedBuildSettings: [String: String]

    public init(
        xcodeInstallation: XcodeInstallation,
        xcodeGlobalSettings: XcodeGlobalSettings,
        xcodeProj: XcodeProj,
        target: String,
        configuration: String = "Debug",
        overrides: [String: String] = [:],
        forceSimulator: Bool = true
    ) throws {
        self.xcodeInstallation = xcodeInstallation
        self.xcodeGlobalSettings = xcodeGlobalSettings
        self.xcodeProj = xcodeProj
        self.target = target
        self.configuration = configuration
        self.overrides = overrides
        self.forceSimulator = forceSimulator

        guard
            let sourceRoot = xcodeProj.path?.parent(),
            let project = xcodeProj.pbxproj.projects.first,
            let xcodeProjTarget = xcodeProj.pbxproj.nativeTargets
            .first(where: { $0.name == target })
        else {
            throw ResolverError.invalidXcodeProj
        }

        self.sourceRoot = sourceRoot
        self.project = project
        self.xcodeProjTarget = xcodeProjTarget
        self.resolvedBuildSettings = try Self.resolveBuildSettings(
            xcodeInstallation: xcodeInstallation,
            sourceRoot: sourceRoot,
            project: project,
            target: xcodeProjTarget,
            configuration: configuration,
            xcodeGlobalSettings: xcodeGlobalSettings,
            overrides: overrides,
            forceSimulator: forceSimulator
        )
    }

    func resolve(forKey key: String) -> String? {
        resolvedBuildSettings[key] ?? defaultFor(key: key)
    }

    private func getBuildSettingsFromConfigList(
        _ configList: XCConfigurationList?,
        configurationName: String,
        key: String
    ) -> String? {
        configList?.buildConfigurations.first { $0.name == configurationName }?
            .buildSettings[key] as? String
    }

    private func defaultFor(key: String) -> String? {
        switch key {
        case BuildSettingKey.toolchains.rawValue: "com.apple.dt.toolchain.XcodeDefault"
        case BuildSettingKey.buildVariants.rawValue: "normal"
        default: nil
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func resolveBuildSettings(
        xcodeInstallation: XcodeInstallation,
        sourceRoot: Path,
        project: PBXProject,
        target: PBXNativeTarget,
        configuration: String,
        xcodeGlobalSettings: XcodeGlobalSettings,
        overrides: [String: String],
        forceSimulator: Bool
    ) throws -> [String: String] {
        let projectBuildConfiguration = project.buildConfigurationList?
            .buildConfigurations
            .first { $0.name == configuration }
        let projectBuildSettings = projectBuildConfiguration?.buildSettings

        let targetBuildConfiguration = target.buildConfigurationList?
            .buildConfigurations
            .first { $0.name == configuration }

        var xcconfigSettings: [String: String] = [:]
        if
            let baseConfigRef = targetBuildConfiguration?.baseConfiguration,
            let xcconfigPath = try? baseConfigRef.fullPath(sourceRoot: sourceRoot) {
            xcconfigSettings = (try? XCConfigParser.parse(at: xcconfigPath.url.path)) ?? [:]
        }

        let targetBuildSettings = targetBuildConfiguration?.buildSettings

        // determine SDK
        let sdk: String = targetBuildSettings?["SDKROOT"] as? String
            ?? projectBuildSettings?["SDKROOT"] as? String
            ?? "iphonesimulator" // ,

        var defaultBuildSettings = try PlatformDefaults.settings(
            for: sdk,
            configuration: configuration,
            xcode: xcodeInstallation,
            forceSimulator: forceSimulator
        )

        let buildDir = xcodeGlobalSettings.derivedDataPath
            .appendingPathComponent("Build/Products")

        let moduleName: String = target.name.asC99ExtIdentifier()
        defaultBuildSettings["SRCROOT"] = sourceRoot.string
        defaultBuildSettings["CONFIGURATION"] = configuration
        defaultBuildSettings["BUILD_DIR"] = buildDir.path

        defaultBuildSettings["PROJECT_GUID"] = project.uuid
        defaultBuildSettings["PROJECT_DIR"] = sourceRoot.string
        if targetBuildSettings?["TARGET_NAME"] == nil || projectBuildSettings?["TARGET_NAME"] == nil {
            defaultBuildSettings["TARGET_NAME"] = target.name
        }
        if targetBuildSettings?["PRODUCT_NAME"] == nil || projectBuildSettings?["PRODUCT_NAME"] == nil {
            defaultBuildSettings["PRODUCT_NAME"] = target.name
        }
        if targetBuildSettings?["PRODUCT_MODULE_NAME"] == nil || projectBuildSettings?["PRODUCT_MODULE_NAME"] == nil {
            defaultBuildSettings["PRODUCT_MODULE_NAME"] = moduleName
        }
        defaultBuildSettings["PRODUCT_TYPE"] = target.productType?.rawValue

        if targetBuildSettings?["CONFIGURATION_BUILD_DIR"] == nil || projectBuildSettings?["CONFIGURATION_BUILD_DIR"] ==
            nil {
            let effectivePlatformName = defaultBuildSettings["EFFECTIVE_PLATFORM_NAME"] ?? ""
            defaultBuildSettings["CONFIGURATION_BUILD_DIR"] = buildDir
                .appendingPathComponent(configuration + effectivePlatformName)
                .path
        }

        if targetBuildSettings?["BUILT_PRODUCTS_DIR"] == nil || projectBuildSettings?["BUILT_PRODUCTS_DIR"] ==
            nil {
            let effectivePlatformName = defaultBuildSettings["EFFECTIVE_PLATFORM_NAME"] ?? ""
            defaultBuildSettings["BUILT_PRODUCTS_DIR"] = buildDir
                .appendingPathComponent(configuration + effectivePlatformName)
                .path
        }

        // let autoFix: [String: String] = [:]

        // 1. project-level
        // 2. target-level
        // 3. auto fix
        // 4. custom overrides

        var result = mergeSettings(
            layers: [
                defaultBuildSettings,
                normalizeSettings(projectBuildSettings ?? [:]),
                xcconfigSettings,
                normalizeSettings(targetBuildSettings ?? [:]),
                // autoFix,
                overrides
            ]
        )

        let effectivePlatformName = result["EFFECTIVE_PLATFORM_NAME"] ?? ""
        // result["SDKROOT"] = result["SDKROOT_PATH"]

        result["SYMROOT"] = xcodeGlobalSettings.symRoot.path
        result["CONFIGURATION_TEMP_DIR"] = xcodeGlobalSettings.derivedDataPath
            .appendingPathComponent("Build/Intermediates.noindex")
            .appendingPathComponent(project.name + ".build")
            .appendingPathComponent(configuration + effectivePlatformName)
            .appendingPathComponent(moduleName + ".build")
            .path

        result["TARGET_TRIPLE"] = getTargetTriple(settings: result)
        result["TOOLCHAIN_DIR"] = xcodeInstallation.toolchainDir.path
        result["TOOLCHAINS"] = "com.apple.dt.toolchain.XcodeDefault"

        return result
    }

    private static func getTargetTriple(settings: [String: String]) -> String {
        guard
            let nativeArch = settings["NATIVE_ARCH"],
            let versionKey = settings["DEPLOYMENT_TARGET_SETTING_NAME"],
            let deploymentVersion = settings[versionKey],
            let platformName = settings["PLATFORM_NAME"],
            let platform = Platform(rawValue: platformName)
        else {
            return "arm64-apple-ios18.5-simulator"
        }

        return [
            nativeArch,
            "apple",
            platform.osNameForTargetTriple + deploymentVersion,
            platform.isSimulator ? "simulator" : ""
        ].filter { !$0.isEmpty }.joined(separator: "-")
    }

    private static func normalizeSettings(_ settings: [String: Any])
        -> [String: String] {
        var dict: [String: String] = [:]
        for (key, value) in settings {
            if let str = value as? String {
                dict[key] = str
            } else if let arr = value as? [String] {
                dict[key] = arr.joined(separator: " ")
            }
        }
        return dict
    }

    /// 按层级合并 + 展开（先无 $ 的 key，后依赖项；无 globals）
    private static func mergeSettings(layers: [[String: String]]) -> [String: String] {
        // 1) 先做原始合并，只展开 $(inherited)
        var raw: [String: String] = [:]
        for overlay in layers {
            for (key, newVal) in overlay {
                let parent = raw[key]
                raw[key] = expandInheritedOnly(newVal, parent: parent)
            }
        }

        // 2) 再做变量展开：先无 $ 的 key，后依赖 key，直至收敛
        return resolveAllVariables(raw)
    }

    // MARK: - Phase 1: only $(inherited)

    /// 仅展开 $(inherited)，不展开 $(VAR)
    private static func expandInheritedOnly(_ value: String, parent: String?) -> String {
        guard value.contains("$(inherited)") else { return value }
        let replacement = parent ?? ""
        return value.replacingOccurrences(of: "$(inherited)", with: replacement)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Phase 2: expand $(VAR) with ordering

    /// 先落无 `$(` 的键，再迭代替换有依赖的键
    private static func resolveAllVariables(_ raw: [String: String], maxRounds: Int = 10) -> [String: String] {
        var resolved: [String: String] = [:]
        var pending: [String: String] = [:]

        // 2.1 seed：不含占位符的先放入 resolved，其余进 pending
        for (k, v) in raw {
            if hasVar(v) {
                pending[k] = v
            } else {
                resolved[k] = v
            }
        }

        // 2.2 多轮替换，直到没有进展或达到上限
        var round = 0
        while !pending.isEmpty, round < maxRounds {
            round += 1
            var stillPending: [String: String] = [:]
            var progressed = false

            for (k, v) in pending {
                // 使用你已经改好的 expandVarsFast，已支持 $(KEY) 与 ${KEY}
                let newV = expandVarsFast(v, using: resolved)
                if hasVar(newV) {
                    // 还有未解析的占位符，下轮再试
                    stillPending[k] = newV
                } else {
                    // 已解析完成，落入 resolved
                    resolved[k] = newV
                    progressed = true
                }
            }

            pending = stillPending
            if !progressed { break } // 无进展，避免死循环
        }

        // 2.3 兜底：仍含占位符的做最后一次替换（未知变量置空）
        for (k, v) in pending {
            resolved[k] = expandVarsFast(v, using: resolved, replaceUnknownWithEmpty: true)
        }

        return resolved
    }

    @inline(__always)
    private static func hasVar(_ s: String) -> Bool {
        // 同时支持 $(KEY) 与 ${KEY}
        s.contains("$(") || s.contains("${")
    }

    /// 快速展开 $(KEY) ${KEY}；仅使用 `known` 里的已解析值
    private static func expandVarsFast(
        _ value: String,
        using known: [String: String],
        replaceUnknownWithEmpty: Bool = false
    ) -> String {
        guard value.contains("$") else { return value }
        var out = ""
        var i = value.startIndex

        while i < value.endIndex {
            if value[i] == "$" {
                let nextIndex = value.index(after: i)
                if nextIndex < value.endIndex {
                    let delimiter = value[nextIndex]
                    var closing: Character?
                    var j = value.index(after: nextIndex)
                    if delimiter == "(" {
                        closing = ")"
                    } else if delimiter == "{" {
                        closing = "}"
                    }

                    if let closing {
                        var name = ""
                        while j < value.endIndex, value[j] != closing {
                            name.append(value[j])
                            j = value.index(after: j)
                        }

                        if j < value.endIndex { // 找到闭合符
                            let rep = known[name] ?? (replaceUnknownWithEmpty ? "" : "$\(delimiter)\(name)\(closing)")
                            out.append(rep)
                            i = value.index(after: j)
                            continue
                        }
                    }
                }
            }
            out.append(value[i])
            i = value.index(after: i)
        }

        return out.trimmingCharacters(in: .whitespaces)
    }
}

extension BuildSettingResolver {
    func resolveFileCompilerFlags(
        for fileURL: URL
    ) -> [String]? {
        // === Old: PBXBuildFile.settings.COMPILER_FLAGS ===
        let oldFlags = resolveOldFileFlags(for: fileURL, sourceRoot: sourceRoot)
        if !oldFlags.isEmpty {
            return oldFlags
        }

        // === New: PBXFileSystemSynchronizedRootGroup → exceptions →
        // BuildFileExceptionSet ===
        // === Xcode15+: PBXFileSystemSynchronizedBuildFileExceptionSet ===
        return resolveNewFileFlags(
            for: fileURL,
            target: xcodeProjTarget,
            sourceRoot: sourceRoot
        )
    }

    private func resolveOldFileFlags(
        for fileURL: URL,
        sourceRoot: Path
    ) -> [String] {
        var flags: [String] = []
        for buildFile in xcodeProj.pbxproj.buildFiles {
            guard let file = buildFile.file else { continue }
            if let absPath = try? file.fullPath(sourceRoot: sourceRoot),
               absPath.url == fileURL,
               let settings = buildFile.settings,
               let compilerFlags = settings["COMPILER_FLAGS"] as? String {
                flags += compilerFlags.split(separator: " ").map { String($0) }
            }
        }
        return flags
    }

    private func resolveNewFileFlags(
        for fileURL: URL,
        target: PBXNativeTarget,
        sourceRoot: Path
    ) -> [String] {
        var flags: [String] = []
        for rootGroup in target.fileSystemSynchronizedGroups ?? [] {
            for exception in rootGroup.exceptions ?? [] {
                guard
                    let exceptionSet =
                    exception as? PBXFileSystemSynchronizedBuildFileExceptionSet,
                    let groupPath = rootGroup.path
                else { continue }

                for (relativePath, compilerFlags) in exceptionSet
                    .additionalCompilerFlagsByRelativePath ?? [:] {
                    let absPath = sourceRoot + groupPath + relativePath
                    if absPath.url == fileURL {
                        flags += compilerFlags.split(separator: " ")
                            .map { String($0) }
                    }
                }
            }
        }
        return flags
    }
}
