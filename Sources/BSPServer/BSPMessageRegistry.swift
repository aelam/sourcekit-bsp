//
//  BSPMessageRegistry.swift
//
//  Copyright © 2024 Wang Lun.
//

import JSONRPCConnection

private let requestTypes: [any RequestType.Type] = [
    // build
    BuildInitializeRequest.self, // build/initialize
    BuildShutdownRequest.self, // build/shutdown

    // buildTarget
    BuildTargetPrepareRequest.self, // buildTarget/prepare
    BuiltTargetSourcesRequest.self, // buildTarget/sources
    BuildTargetCompileRequest.self, // buildTarget/compile
    BuildTargetRunRequest.self, // buildTarget/run
    BuildTargetTestRequest.self, // buildTarget/test
    BuildTargetOutputPathsRequest.self, // buildTarget/outputPaths

    // debugSession
    DebugSessionStartRequest.self, // debugSession/start

    // textDocument
    TextDocumentRegisterForChangeRequest.self, // textDocument/registerForChange
    TextDocumentSourceKitOptionsRequest.self, // textDocument/sourceKitOptions

    // window
    // ...

    // workspace
    WorkspaceBuildTargetsRequest.self,
    WorkspaceWaitForBuildSystemUpdatesRequest.self,
]

private let notificationTypes: [NotificationType.Type] = [
    OnBuildInitializedNotification.self, // build/initialized
    OnBuildExitNotification.self, // build/exit
    // workspace
    WorkspaceDidChangeWatchedFilesNotification.self, // workspace/didChangeWatchedFiles
    WorkspaceReloadNotification.self, // workspace/reload

    // build
    BuildSourceKitOptionsChangedNotification.self, // build/sourceKitOptionsChanged

    // $
    CancelRequestNotification.self, // $/cancelRequest
]

public let bspRegistry = MessageRegistry(
    requests: requestTypes,
    notifications: notificationTypes
)
