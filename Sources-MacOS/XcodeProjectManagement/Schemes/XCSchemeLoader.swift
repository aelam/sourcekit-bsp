import Foundation
import PathKit
import XcodeProj

public struct XCSchemeLoader {
    public init() {}

    public func listSchemes(
        projectLocation: XcodeProjectLocation,
        includeUserSchemes: Bool = true
    ) throws -> [XcodeScheme] {
        let result = try loadSchemesForLocation(projectLocation, includeUserSchemes: includeUserSchemes)
        return deduplicateAndSortSchemes(result)
    }

    private func loadSchemesForLocation(
        _ projectLocation: XcodeProjectLocation,
        includeUserSchemes: Bool
    ) throws -> [XcodeScheme] {
        switch projectLocation {
        case let .explicitWorkspace(workspaceURL):
            try loadExplicitWorkspaceSchemes(workspaceURL: workspaceURL, includeUserSchemes: includeUserSchemes)
        case let .implicitWorkspace(projectURL, workspaceURL):
            loadImplicitWorkspaceSchemes(
                projectURL: projectURL,
                workspaceURL: workspaceURL,
                includeUserSchemes: includeUserSchemes
            )
        case let .standaloneProject(projectURL):
            loadStandaloneProjectSchemes(projectURL: projectURL, includeUserSchemes: includeUserSchemes)
        }
    }

    private func loadExplicitWorkspaceSchemes(
        workspaceURL: URL,
        includeUserSchemes: Bool
    ) throws -> [XcodeScheme] {
        let wsPath = Path(workspaceURL.path)
        let ws = try XCWorkspace(path: wsPath)
        var result: [XcodeScheme] = []

        // A. workspace 自身的 schemes
        result += loadSchemes(
            at: wsPath,
            containerName: "workspace",
            isInWorkspace: true,
            includeUserSchemes: includeUserSchemes
        )

        // B. workspace 引用的每个 .xcodeproj 的 schemes
        let children = ws.data.children
        for child in children {
            guard case let .file(fileRef) = child,
                  fileRef.location.path.hasSuffix(".xcodeproj") else { continue }

            let projPath = resolveProjectPath(from: fileRef.location.path, workspacePath: wsPath)

            if projPath.exists {
                result += loadSchemes(
                    at: projPath,
                    containerName: projPath.lastComponentWithoutExtension,
                    isInWorkspace: false,
                    includeUserSchemes: includeUserSchemes
                )
            }
        }

        return result
    }

    private func loadImplicitWorkspaceSchemes(
        projectURL: URL,
        workspaceURL: URL,
        includeUserSchemes: Bool
    ) -> [XcodeScheme] {
        let projPath = Path(projectURL.path)
        let wsPath = Path(workspaceURL.path)
        var result: [XcodeScheme] = []

        // Load schemes from both project and its implicit workspace
        result += loadSchemes(
            at: projPath,
            containerName: projPath.lastComponentWithoutExtension,
            isInWorkspace: false,
            includeUserSchemes: includeUserSchemes
        )
        result += loadSchemes(
            at: wsPath,
            containerName: "workspace",
            isInWorkspace: true,
            includeUserSchemes: includeUserSchemes
        )

        return result
    }

    private func loadStandaloneProjectSchemes(
        projectURL: URL,
        includeUserSchemes: Bool
    ) -> [XcodeScheme] {
        let projPath = Path(projectURL.path)
        return loadSchemes(
            at: projPath,
            containerName: projPath.lastComponentWithoutExtension,
            isInWorkspace: false,
            includeUserSchemes: includeUserSchemes
        )
    }

    private func deduplicateAndSortSchemes(_ schemes: [XcodeScheme]) -> [XcodeScheme] {
        // Keep names from different containers so callers can detect ambiguous schemes.
        var seen = Set<String>()
        let deduped = schemes.filter { info in
            seen.insert(info.path.resolvingSymlinksInPath().standardizedFileURL.path).inserted
        }

        return deduped.sorted { lhs, rhs in
            // First sort by orderHint if available
            if let lhsOrder = lhs.orderHint, let rhsOrder = rhs.orderHint {
                return lhsOrder < rhsOrder
            } else if lhs.orderHint != nil {
                return true // Schemes with orderHint come first
            } else if rhs.orderHint != nil {
                return false
            }
            // Fall back to alphabetical sorting
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func loadSchemes(
        at containerDir: Path,
        containerName: String,
        isInWorkspace: Bool,
        includeUserSchemes: Bool
    ) -> [XcodeScheme] {
        let schemeOrderMap = includeUserSchemes ? loadSchemeOrderMapFromContainer(containerDir) : [:]
        var schemes: [XcodeScheme] = []

        // 1) shared schemes
        schemes += loadSharedSchemes(
            containerDir: containerDir,
            isInWorkspace: isInWorkspace,
            schemeOrderMap: schemeOrderMap
        )

        // 2) user schemes (optional)
        if includeUserSchemes {
            schemes += loadUserSchemes(
                containerDir: containerDir,
                isInWorkspace: isInWorkspace,
                schemeOrderMap: schemeOrderMap
            )
        }

        return schemes
    }

    private func loadSchemeOrderMapFromContainer(_ containerDir: Path) -> [String: Int] {
        let usersDir = containerDir + "xcuserdata"
        guard usersDir.exists else { return [:] }

        for managementFile in usersDir.glob("*.xcuserdatad/xcschemes/xcschememanagement.plist") {
            return loadSchemeOrderMap(from: managementFile)
        }
        return [:]
    }

    private func loadSharedSchemes(
        containerDir: Path,
        isInWorkspace: Bool,
        schemeOrderMap: [String: Int]
    ) -> [XcodeScheme] {
        let sharedDir = containerDir + "xcshareddata/xcschemes"
        guard sharedDir.exists else { return [] }

        var schemes: [XcodeScheme] = []
        for file in sharedDir.glob("*.xcscheme") {
            if let scheme = try? XCScheme(path: file) {
                var xcodeScheme = XcodeScheme(
                    xcscheme: scheme,
                    isInWorkspace: isInWorkspace,
                    isUserScheme: false,
                    projectURL: containerDir.url,
                    path: file.url
                )

                // Apply ordering from xcschememanagement.plist
                let sharedKey = "\(scheme.name).xcscheme_^#shared#^_"
                if let order = schemeOrderMap[sharedKey] {
                    xcodeScheme.orderHint = order
                }

                schemes.append(xcodeScheme)
            }
        }
        return schemes
    }

    private func loadUserSchemes(
        containerDir: Path,
        isInWorkspace: Bool,
        schemeOrderMap: [String: Int]
    ) -> [XcodeScheme] {
        let usersDir = containerDir + "xcuserdata"
        guard usersDir.exists else { return [] }

        var schemes: [XcodeScheme] = []
        for file in usersDir.glob("*.xcuserdatad/xcschemes/*.xcscheme") {
            if let scheme = try? XCScheme(path: file) {
                var xcodeScheme = XcodeScheme(
                    xcscheme: scheme,
                    isInWorkspace: isInWorkspace,
                    isUserScheme: true,
                    projectURL: containerDir.url,
                    path: file.url
                )

                // Apply ordering from xcschememanagement.plist
                let userKey = "\(scheme.name).xcscheme"
                if let order = schemeOrderMap[userKey] {
                    xcodeScheme.orderHint = order
                }

                schemes.append(xcodeScheme)
            }
        }
        return schemes
    }

    private func loadSchemeOrderMap(from plistPath: Path) -> [String: Int] {
        guard let plistData = try? Data(contentsOf: plistPath.url),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let schemeUserState = plist["SchemeUserState"] as? [String: Any] else {
            return [:]
        }

        var orderMap: [String: Int] = [:]
        for (schemeName, schemeInfo) in schemeUserState {
            if let info = schemeInfo as? [String: Any],
               let orderHint = info["orderHint"] as? Int {
                orderMap[schemeName] = orderHint
            }
        }
        return orderMap
    }

    private func resolveProjectPath(from location: String, workspacePath: Path) -> Path {
        if location.hasPrefix("absolute:") {
            let pathComponent = String(location.dropFirst(9)) // "absolute:".count = 9
            return Path(pathComponent)
        }

        // For group:, self:, container:, or plain relative paths
        let pathComponent = if location.contains(":") {
            String(location.split(separator: ":", maxSplits: 1).last ?? "")
        } else {
            location
        }

        return (workspacePath.parent() + Path(pathComponent)).normalize()
    }
}
