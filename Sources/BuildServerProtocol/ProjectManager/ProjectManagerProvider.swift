//
//  ProjectManagerProvider.swift
//  Core Module
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger

public enum ProjectManagerProviderError: Error, Sendable {
    case notImplemented
}

public protocol ProjectManagerProvider: Sendable {
    var name: String { get }

    func canHandle(projectURL: URL) async -> Bool
    func canHandle(projectURL: URL, config: ProjectConfiguration?) async throws -> Bool

    func createProjectManager(rootURL: URL, config: ProjectConfiguration?) async throws -> any ProjectManager
}

public extension ProjectManagerProvider {
    func canHandle(projectURL: URL, config: ProjectConfiguration?) async throws -> Bool {
        await canHandle(projectURL: projectURL)
    }
}

public struct ProjectConfiguration: Sendable {
    public let customSettings: [String: String]
    public let workingDirectory: URL?

    public let preferredProvider: String?
    public let packagePath: String?

    public init(
        customSettings: [String: String] = [:],
        workingDirectory: URL? = nil,
        preferredProvider: String? = nil,
        packagePath: String? = nil
    ) {
        self.customSettings = customSettings
        self.workingDirectory = workingDirectory
        self.preferredProvider = preferredProvider
        self.packagePath = packagePath
    }
}

public actor ProjectManagerFactory {
    private var providers: [any ProjectManagerProvider] = []

    public init() {}

    public func registerProvider(_ provider: any ProjectManagerProvider) {
        providers.append(provider)
    }

    public func getRegisteredProviders() -> [any ProjectManagerProvider] {
        providers
    }

    public func createProjectManager(
        rootURL: URL,
        config: ProjectConfiguration? = nil
    ) async throws -> any ProjectManager {
        try await Task.detached {
            let providers = await self.providers
            logger.debug("Creating project manager for \(rootURL.path)")
            if let preferred = config?.preferredProvider {
                guard let provider = providers.first(where: { $0.name == preferred }) else {
                    throw ProjectManagerFactoryError
                        .noSuitableProvider("Configured provider is unavailable: \(preferred)")
                }
                return try await provider.createProjectManager(rootURL: rootURL, config: config)
            }
            for provider in providers where try await provider.canHandle(projectURL: rootURL, config: config) {
                return try await provider.createProjectManager(rootURL: rootURL, config: config)
            }

            throw ProjectManagerFactoryError.noSuitableProvider(
                "No provider found for project at: \(rootURL.path)"
            )
        }.value
    }
}

public enum ProjectManagerFactoryError: Error, LocalizedError {
    case noSuitableProvider(String)
    case providerCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .noSuitableProvider(message):
            "No suitable provider: \(message)"
        case let .providerCreationFailed(message):
            "Provider creation failed: \(message)"
        }
    }
}
