//
//  ProjectProviderRegistry.swift
//  BSPServer Module
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger
import SourceKitBSPProtocol
import SwiftPMProjectManagerProvider

#if os(macOS)
import XcodeProjectManagement
import XcodeProjectManagerProvider
#endif

public enum ProjectManagerProviderRegistry {
    public static func getAllProviders(enableBuildTargetPrepare: Bool = false) -> [any ProjectManagerProvider] {
        var providers: [any ProjectManagerProvider] = []

        #if os(macOS)
        // 只在macOS上注册Xcode支持
        providers.append(XcodeProjectManagerProvider(enableBuildTargetPrepare: enableBuildTargetPrepare))
        #endif

        // Probe Xcode containers before scanning for nested packages.
        #if os(macOS)
        providers.append(SwiftPMProjectManagerProvider(debugAdapter: SwiftPMLLDBAdapter()))
        #else
        providers.append(SwiftPMProjectManagerProvider())
        #endif
        return providers
    }

    /// 创建配置好的ProjectManagerFactory
    public static func createFactory(enableBuildTargetPrepare: Bool = false) async -> ProjectManagerFactory {
        let factory = ProjectManagerFactory()

        for provider in getAllProviders(enableBuildTargetPrepare: enableBuildTargetPrepare) {
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
