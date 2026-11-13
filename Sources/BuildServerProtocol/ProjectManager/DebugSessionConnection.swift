//
//  DebugSessionConnection.swift
//  SourceKitBSPProtocol
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

/// A DAP endpoint. A nil request exposes only the standard BSP URI.
/// Native endpoints can retain their launch configuration for internal relays.
public struct DebugSessionConnection: Sendable, Equatable {
    public enum Request: String, Sendable, Equatable {
        case launch
        case attach
    }

    public let uri: String // e.g. "tcp://127.0.0.1:52345"
    public let request: Request?
    public let program: String? // macOS launch: built binary path
    public let pid: Int? // attach: PID on the platform configured by the server
    public let bundleId: String?
    public let args: [String]?
    public let env: [String: String]?
    public let cwd: String?

    public init(
        uri: String,
        request: Request? = nil,
        program: String? = nil,
        pid: Int? = nil,
        bundleId: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        cwd: String? = nil
    ) {
        self.uri = uri
        self.request = request
        self.program = program
        self.pid = pid
        self.bundleId = bundleId
        self.args = args
        self.env = env
        self.cwd = cwd
    }
}
