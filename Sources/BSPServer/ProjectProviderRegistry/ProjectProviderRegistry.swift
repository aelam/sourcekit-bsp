//
//  ProjectProviderRegistry.swift
//  BSPServer Module
//
//  Copyright © 2024 Wang Lun.
//

import BuildServerProtocol
import Foundation
import Logger
import SwiftPMProjectManagerProvider

#if os(macOS)
import XcodeProjectManagement
import XcodeProjectManagerProvider
#endif

public enum ProjectManagerProviderRegistry {
    public static func getAllProviders() -> [any ProjectManagerProvider] {
        var providers: [any ProjectManagerProvider] = []

        #if os(macOS)
        // 只在macOS上注册Xcode支持
        providers.append(XcodeProjectManagerProvider())
        #endif

        // Prefer an existing Xcode project when the folder also contains a package.
        #if os(macOS)
        providers.append(SwiftPMProjectManagerProvider(debugAdapter: SwiftPMLLDBAdapter()))
        #else
        providers.append(SwiftPMProjectManagerProvider())
        #endif
        return providers
    }

    /// 创建配置好的ProjectManagerFactory
    public static func createFactory() async -> ProjectManagerFactory {
        let factory = ProjectManagerFactory()

        for provider in getAllProviders() {
            await factory.registerProvider(provider)
        }

        return factory
    }
}

#if os(macOS)
private struct SwiftPMLLDBAdapter: SwiftPMDebugAdapterServing {
    func start() async throws -> SwiftPMDebugEndpoint {
        let endpoint = try await LLDBDAPServer().start()
        return SwiftPMDebugEndpoint(uri: endpoint.uri, terminate: endpoint.terminate)
    }
}
#endif
