//
//  DebugSessionConnection.swift
//  BuildServerProtocol
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

/// Everything the client needs to attach a DAP debugger for a target.
/// `uri` is the DAP TCP endpoint; the remaining fields are the DAP
/// launch/attach configuration the client should send once connected.
public struct DebugSessionConnection: Sendable, Equatable {
    public enum Request: String, Sendable, Equatable {
        case launch
        case attach
    }

    public let uri: String // e.g. "tcp://127.0.0.1:52345"
    public let request: Request
    public let program: String? // macOS launch: built binary path
    public let pid: Int? // attach: PID on the platform configured by the server
    public let bundleId: String?

    public init(uri: String, request: Request, program: String? = nil, pid: Int? = nil, bundleId: String? = nil) {
        self.uri = uri
        self.request = request
        self.program = program
        self.pid = pid
        self.bundleId = bundleId
    }
}
