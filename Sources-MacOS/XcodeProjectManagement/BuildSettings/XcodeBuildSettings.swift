public typealias XcodeBuildSettingsMap = [String: XcodeBuildSettings]

public struct XcodeBuildSettings: Codable, Sendable {
    public let target: String
    public let action: String
    public let buildSettings: [String: String]

    public init(target: String, action: String, buildSettings: [String: String]) {
        self.target = target
        self.action = action
        self.buildSettings = buildSettings
    }

    /// Custom Codable to handle mixed buildSettings types
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try container.decode(String.self, forKey: .target)
        self.action = try container.decode(String.self, forKey: .action)
        // Handle mixed value types in buildSettings
        let rawBuildSettings = try container.decode([String: BuildSettingValue].self, forKey: .buildSettings)
        self.buildSettings = rawBuildSettings.mapValues { $0.stringValue }
    }

    private enum CodingKeys: String, CodingKey {
        case target, action, buildSettings
    }
}

public enum XcodeLanguageDialect: Codable, Sendable, Equatable {
    public var rawValue: String {
        switch self {
        case .c: "Xcode.SourceCodeLanguage.C"
        case .cpp: "Xcode.SourceCodeLanguage.C-Plus-Plus"
        case .swift: "Xcode.SourceCodeLanguage.Swift"
        case .objc: "Xcode.SourceCodeLanguage.Objective-C"
        case .objcCpp: "Xcode.SourceCodeLanguage.Objective-C-Plus-Plus"
        case .metal: "Xcode.SourceCodeLanguage.Metal"
        case .interfaceBuilder: "Xcode.SourceCodeLanguage.InterfaceBuilder"
        case let .other(languageName): languageName
        }
    }

    case c
    case cpp
    case swift
    case objc
    case objcCpp
    case metal
    case interfaceBuilder
    case other(languageName: String)

    public init?(rawValue: String) {
        switch rawValue {
        case "Xcode.SourceCodeLanguage.C":
            self = .c
        case "Xcode.SourceCodeLanguage.C-Plus-Plus":
            self = .cpp
        case "Xcode.SourceCodeLanguage.Swift":
            self = .swift
        case "Xcode.SourceCodeLanguage.Objective-C":
            self = .objc
        case "Xcode.SourceCodeLanguage.Objective-C-Plus-Plus":
            self = .objcCpp
        case "Xcode.SourceCodeLanguage.Metal":
            self = .metal
        case "Xcode.SourceCodeLanguage.InterfaceBuilder":
            self = .interfaceBuilder
        default:
            self = .other(languageName: rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stringValue = try container.decode(String.self)

        switch stringValue {
        case "Xcode.SourceCodeLanguage.C":
            self = .c
        case "Xcode.SourceCodeLanguage.C-Plus-Plus":
            self = .cpp
        case "Xcode.SourceCodeLanguage.Swift":
            self = .swift
        case "Xcode.SourceCodeLanguage.Objective-C":
            self = .objc
        case "Xcode.SourceCodeLanguage.Objective-C-Plus-Plus":
            self = .objcCpp
        case "Xcode.SourceCodeLanguage.Metal":
            self = .metal
        case "Xcode.SourceCodeLanguage.InterfaceBuilder":
            self = .interfaceBuilder
        default:
            self = .other(languageName: stringValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

public extension XcodeLanguageDialect {
    internal init(fileExtension: String) {
        switch fileExtension {
        case "swift":
            self = .swift
        case "c":
            self = .c
        case "cpp", "cc", "cxx", "C":
            self = .cpp
        case "m":
            self = .objc
        case "h":
            self = .objcCpp
        case "mm":
            self = .objcCpp
        case "metal":
            self = .metal
        case "storyboard", "xib":
            self = .interfaceBuilder
        default:
            self = .other(languageName: fileExtension)
        }
    }

    var isSwift: Bool {
        switch self {
        case .swift:
            true
        default:
            false
        }
    }

    var isClang: Bool {
        switch self {
        case .c, .cpp, .objc, .objcCpp:
            true
        default:
            false
        }
    }
}

public extension XcodeLanguageDialect {
    /// Clang-compatible language name suitable for use with `-x <language>`.
    var xflag: String? {
        switch self {
        case .swift: "swift"
        case .c: "c"
        case .cpp: "c++"
        case .objc: "objective-c"
        case .objcCpp: "objective-c++"
        default: nil
        }
    }
}
