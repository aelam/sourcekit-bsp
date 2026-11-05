//
//  BSPServerService+SourceKitOptions.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/21.
//
import BuildServerProtocol
import Foundation

public extension BSPServerService {
    func getCompileArguments(
        targetIdentifier: BSPBuildTargetIdentifier,
        fileURL: URL
    ) async throws -> [String] {
        guard let projectManager else {
            throw BuildServerError.invalidConfiguration("Project not initialized")
        }

        return try await projectManager.getCompileArguments(
            targetIdentifier: targetIdentifier.uri.stringValue,
            sourceFileURL: fileURL
        )
    }
}
