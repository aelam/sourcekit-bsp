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
import XcodeProjectManagerProvider
#endif

public enum ProjectManagerProviderRegistry {
    public static func getAllProviders() -> [any ProjectManagerProvider] {
        var providers: [any ProjectManagerProvider] = []

        // 总是注册SwiftPM支持
        providers.append(SwiftPMProjectManagerProvider())

        #if os(macOS)
        // 只在macOS上注册Xcode支持
        providers.append(XcodeProjectManagerProvider())
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
