import Foundation
import XcodeProj

public struct XcodeScheme: Sendable, Codable {
    public let name: String
    public let path: URL
    public let isInWorkspace: Bool
    public let isUserScheme: Bool
    public var buildConfiguration: String = "Debug"
    public let primaryBuildTargetProjectURL: URL?
    public let primaryTarget: String?
    public var primaryProductName: String?
    public var orderHint: Int?
}

extension XcodeScheme: Comparable {
    enum ProductPriority: Int {
        case app = 10
        case framework = 9
        case library = 8
        case test = 7
        case other = 0

        init(productName: String) {
            if productName.hasSuffix(".app") {
                self = .app
            } else if productName.hasSuffix(".framework") {
                self = .framework
            } else if productName.hasSuffix(".a") || productName.hasSuffix(".dylib") {
                self = .library
            } else {
                self = .other
            }
        }
    }

    public static func < (lhs: XcodeScheme, rhs: XcodeScheme) -> Bool {
        let lhsOffset = lhs.path.relativePath.contains("Pods/") ? 0 : 100
        let rhsOffset = rhs.path.relativePath.contains("Pods/") ? 0 : 100

        let lhsPriority = lhsOffset + ProductPriority(productName: lhs.primaryProductName ?? "").rawValue
        let rhsPriority = rhsOffset + ProductPriority(productName: rhs.primaryProductName ?? "").rawValue
        return lhsPriority > rhsPriority
    }
}

public extension XcodeScheme {
    init(
        xcscheme: XCScheme,
        isInWorkspace: Bool,
        isUserScheme: Bool,
        projectURL: URL,
        path: URL
    ) {
        self.name = xcscheme.name
        self.isInWorkspace = isInWorkspace
        self.isUserScheme = isUserScheme
        self.path = path
        self.buildConfiguration = xcscheme.launchAction?.buildConfiguration ?? "Debug"
        let runnableReference = xcscheme.launchAction?.runnable?.buildableReference
            ?? xcscheme.launchAction?.macroExpansion
            ?? xcscheme.buildAction?.buildActionEntries.first?.buildableReference
            ?? xcscheme.testAction?.testables.first?.buildableReference
        if let referencedContainer = runnableReference?.referencedContainer {
            let relativePath = referencedContainer.replacingOccurrences(of: "container:", with: "")
            self.primaryBuildTargetProjectURL = projectURL.deletingLastPathComponent()
                .appendingPathComponent(relativePath)
        } else {
            self.primaryBuildTargetProjectURL = nil
        }
        self.primaryTarget = runnableReference?.blueprintName
        self.primaryProductName = runnableReference?.buildableName
        self.orderHint = nil
    }
}
