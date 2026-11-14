//
//  CancelRequestNotification.swift
//
//  Copyright 2024 Wang Lun.
//

/// The connection handles cancellation before it dispatches queued notifications.
public struct CancelRequestNotification: MessageType {
    public static func method() -> String {
        "$/cancelRequest"
    }

    public struct Params: Codable, Sendable {
        public let id: RequestID
    }

    public let params: Params
}
