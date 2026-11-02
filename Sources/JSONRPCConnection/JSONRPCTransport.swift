//
//  JSONRPCTransport.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

public enum JSONRPCTransportError: Error, Sendable {
    case connectionFailed
    case disconnectionFailed
    case sendFailed
    case receiveFailed
    case listenFailed
    case acceptFailed

    case transportClosed
    case timeout
    case writeFailed(String)

    case invalidMessage
    case invalidHeader
    case missingContentLength
    case invalidContentLength
}

/// Represents a received JSON-RPC message with its raw data
public struct JSONRPCMessage: Sendable {
    public let request: JSONRPCRequest
    public let rawData: Data

    public init(request: JSONRPCRequest, rawData: Data) {
        self.request = request
        self.rawData = rawData
    }
}

/// Stream-based JSON-RPC transport protocol providing async streams for message handling
/// Implementers should typically be actors for thread safety
public protocol JSONRPCServerTransport: Sendable {
    /// Async stream of incoming JSON-RPC messages
    var messageStream: AsyncStream<JSONRPCMessage> { get }

    /// Async stream of transport errors
    var errorStream: AsyncStream<JSONRPCTransportError> { get }

    /// Start listening for incoming connections and messages
    func listen() async throws

    /// Close the transport and cleanup resources
    func close() async

    /// Send a response back to the client
    func send(response: ResponseType) async throws

    /// Send a notification to the client
    func send(notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws
}
