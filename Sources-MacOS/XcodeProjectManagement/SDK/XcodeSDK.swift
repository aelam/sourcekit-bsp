// TODO: update Platform/SDK to improve the relationship
public enum Platform: String, Sendable, Codable, Hashable {
    case macOS = "macosx"
    case iOS = "iphoneos"
    case iOSSimulator = "iphonesimulator"
    case watchOS = "watchos"
    case watchSimulator = "watchsimulator"
    case tvOS = "appletvos"
    case tvSimulator = "appletvsimulator"
    case visionOS = "xros"
    case visionSimulator = "xrsimulator"
}

public typealias XcodeSDK = Platform

extension Platform {
    /// "AVAILABLE_PLATFORMS" : "android appletvos appletvsimulator driverkit iphoneos iphonesimulator macosx qnx
    /// watchos watchsimulator xros xrsimulator",
    var isSimulator: Bool {
        switch self {
        case .iOSSimulator, .watchSimulator, .tvSimulator, .visionSimulator:
            true
        default:
            false
        }
    }

    var simulatorVariant: Platform {
        switch self {
        case .iOS: .iOSSimulator
        case .watchOS: .watchSimulator
        case .tvOS: .tvSimulator
        case .visionOS: .visionSimulator
        default: self
        }
    }

    var platformPathName: String {
        switch self {
        case .iOS: "iPhoneOS"
        case .iOSSimulator: "iPhoneSimulator"
        case .macOS: "MacOSX"
        case .watchOS: "WatchOS"
        case .watchSimulator: "WatchSimulator"
        case .tvOS: "AppleTVOS"
        case .tvSimulator: "AppleTVSimulator"
        case .visionOS: "XROS"
        case .visionSimulator: "XROS Simulator"
        }
    }

    var buildSettingsKey: String {
        switch self {
        case .iOS: "IPHONEOS_DEPLOYMENT_TARGET"
        case .iOSSimulator: "IPHONEOS_DEPLOYMENT_TARGET"
        case .macOS: "MACOSX_DEPLOYMENT_TARGET"
        case .watchOS: "WATCHOS_DEPLOYMENT_TARGET"
        case .watchSimulator: "WATCHOS_DEPLOYMENT_TARGET"
        case .tvOS: "TVOS_DEPLOYMENT_TARGET"
        case .tvSimulator: "TVOS_DEPLOYMENT_TARGET"
        case .visionOS: "XROS_DEPLOYMENT_TARGET"
        case .visionSimulator: "XROS_DEPLOYMENT_TARGET"
        }
    }

    /// EFFECTIVE_PLATFORM_NAME
    var effectiveSuffix: String {
        switch self {
        case .iOS: "-iphoneos"
        case .iOSSimulator: "-iphonesimulator"
        case .macOS: ""
        case .watchOS: "-watchos"
        case .watchSimulator: "-watchsimulator"
        case .tvOS: "-tvos"
        case .tvSimulator: "-tvossimulator"
        case .visionOS: "-xros"
        case .visionSimulator: "-xrsimulator"
        }
    }

    var osNameForTargetTriple: String {
        switch self {
        case .iOS: "ios"
        case .iOSSimulator: "ios"
        case .macOS: "macosx"
        case .watchOS: "watchos"
        case .watchSimulator: "watchos"
        case .tvOS: "tvos"
        case .tvSimulator: "tvos"
        case .visionOS: "xros"
        case .visionSimulator: "xros"
        }
    }
}

public struct SDK {
    let name: String
    let version: String
    let path: String
    let buildVersion: String
}
