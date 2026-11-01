import Darwin
import Foundation

// 你的类型：XcodeInstallation.defaultDeploymentTarget(for:) -> SDKInfo?
public struct SDKInfo {
    public let name: String; public let path: String; public let version: String
}

enum PlatformDefaults {
    // === Host arch 检测（封装成策略） ===
    enum SimulatorArchPolicy { case hostOnly, universal }
    private static func hostArch() -> String {
        var u = utsname()
        uname(&u)
        let mirror = Mirror(reflecting: u.machine)
        let bytes = mirror.children.compactMap { $0.value as? UInt8 }
        let validBytes = bytes.prefix { $0 != 0 } // to null
        if let s = String(data: Data(validBytes), encoding: .utf8) {
            return s.contains("x86") ? "x86_64" : "arm64"
        }
        return "arm64"
    }

    private static func simARCHS(policy: SimulatorArchPolicy) -> String {
        policy == .universal ? "arm64 x86_64" : hostArch()
    }

    /// === 规格表（消除分支重复） ===
    struct Spec {
        let family: String // "ios" / "macos" / "watchos" / "tvos"
        let deviceSDK: String // "iphoneos" / "macosx" / ...
        let simSDK: String? // "iphonesimulator" / ...
        let depKey: String // "IPHONEOS_DEPLOYMENT_TARGET" / ...
        let deviceARCHS: String // 默认真机 ARCHS
        let simARCHSDefault: String? // 模拟器 ARCHS（若为 nil 用策略计算）
        let codeSignIdentity: String // 默认签名标识（macOS 一般 "-"; 其它空串）
    }

    private static let specs: [String: Spec] = [
        "iphoneos": .init(
            family: "ios",
            deviceSDK: "iphoneos",
            simSDK: "iphonesimulator",
            depKey: "IPHONEOS_DEPLOYMENT_TARGET",
            deviceARCHS: "arm64",
            simARCHSDefault: nil,
            codeSignIdentity: ""
        ),
        "iphonesimulator": .init(
            family: "ios",
            deviceSDK: "iphoneos",
            simSDK: "iphonesimulator",
            depKey: "IPHONEOS_DEPLOYMENT_TARGET",
            deviceARCHS: "arm64",
            simARCHSDefault: nil,
            codeSignIdentity: ""
        ),
        "macosx": .init(
            family: "macos",
            deviceSDK: "macosx",
            simSDK: nil,
            depKey: "MACOSX_DEPLOYMENT_TARGET",
            deviceARCHS: "x86_64 arm64",
            simARCHSDefault: nil,
            codeSignIdentity: "-"
        ),
        "watchos": .init(
            family: "watchos",
            deviceSDK: "watchos",
            simSDK: "watchsimulator",
            depKey: "WATCHOS_DEPLOYMENT_TARGET",
            deviceARCHS: "armv7k arm64_32 arm64",
            simARCHSDefault: nil,
            codeSignIdentity: ""
        ),
        "watchsimulator": .init(
            family: "watchos",
            deviceSDK: "watchos",
            simSDK: "watchsimulator",
            depKey: "WATCHOS_DEPLOYMENT_TARGET",
            deviceARCHS: "armv7k arm64_32 arm64",
            simARCHSDefault: nil,
            codeSignIdentity: ""
        ),
        "tvos": .init(
            family: "tvos",
            deviceSDK: "tvos",
            simSDK: "tvossimulator",
            depKey: "TVOS_DEPLOYMENT_TARGET",
            deviceARCHS: "arm64",
            simARCHSDefault: nil,
            codeSignIdentity: ""
        ),
        "tvossimulator": .init(
            family: "tvos",
            deviceSDK: "tvos",
            simSDK: "tvossimulator",
            depKey: "TVOS_DEPLOYMENT_TARGET",
            deviceARCHS: "arm64",
            simARCHSDefault: nil,
            codeSignIdentity: ""
        )
    ]

    /// 映射 EFFECTIVE_PLATFORM_NAME
    private static func effectiveSuffix(for sdkName: String) -> String {
        switch sdkName {
        case "iphonesimulator": "-iphonesimulator"
        case "tvossimulator": "-appletvsimulator"
        case "watchsimulator": "-watchsimulator"
        default: ""
        }
    }

    static func settings(
        for requestedSDK: String,
        configuration: String,
        xcode: XcodeInstallation,
        forceSimulator: Bool = false,
        simulatorArchPolicy: SimulatorArchPolicy = .hostOnly,
        swiftVersion: String = "5.0"
    ) throws -> [String: String] {
        // 取规格
        guard let spec = specs[requestedSDK] ??
            specs[requestedSDK.replacingOccurrences(
                of: ".sdk",
                with: ""
            )] else {
            return [:]
        }

        // 如果强制模拟器，且此平台有模拟器对等 SDK，则切换
        let isSim = forceSimulator && spec.simSDK != nil || requestedSDK
            .hasSuffix("simulator")
        let sdkName = isSim ? (spec.simSDK ?? spec.deviceSDK) : spec.deviceSDK

        // 找 SDK 信息（用于 path + deployment target）
        // 设备/模拟器各自查询，没找到就回退到同家族 device
        let sdkInfo = (try? xcode.defaultDeploymentTarget(for: sdkName))
            ?? (try? xcode.defaultDeploymentTarget(for: spec.deviceSDK))
        guard let sdkInfo else {
            throw XcodeToolchainError.invalidSDK("Cannot find SDK info for \(sdkName)")
        }

        var m: [String: String] = [:]
        m["SDKROOT"] = sdkName // 平台名（语义型）
        m["SDKROOT_PATH"] = sdkInfo.path
        m["SDK_VERSION"] = sdkInfo.version
        m["SDK_BUILD_VERSION"] = sdkInfo.buildVersion

        m["PLATFORM_NAME"] = sdkName
        m["EFFECTIVE_PLATFORM_NAME"] = effectiveSuffix(for: sdkName)
        m["SWIFT_VERSION"] = swiftVersion
        m["ENABLE_TESTABILITY"] = configuration == "Debug" ? "YES" : "NO"
        m["CODE_SIGN_IDENTITY"] = spec.codeSignIdentity
        m["DEPLOYMENT_TARGET_SETTING_NAME"] = spec.depKey

        // ARCHS
        if isSim {
            // 优先使用规格默认，否则按策略/主机决定
            m["ARCHS"] = spec
                .simARCHSDefault ?? simARCHS(policy: simulatorArchPolicy)
        } else {
            m["ARCHS"] = spec.deviceARCHS
        }

        m["NATIVE_ARCH"] = hostArch()

        return m
    }
}
