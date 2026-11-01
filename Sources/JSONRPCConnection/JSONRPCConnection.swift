//
//  JSONRPCConnection.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Logger

/// Stream-based JSON-RPC connection that processes messages using async streams
public final actor JSONRPCConnection {
    private let transport: JSONRPCServerTransport
    private let messageRegistry: MessageRegistry
    private let messageHandler: MessageHandler
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    // Task handles for stream processing
    private var messageProcessingTask: Task<Void, Never>?
    private var errorProcessingTask: Task<Void, Never>?
    private var requests: [RequestID: Task<Void, Never>] = [:]
    private var notificationTail: Task<Void, Never>?
    private var notifications: [UUID: Task<Void, Never>] = [:]

    public init(
        transport: JSONRPCServerTransport,
        messageRegistry: MessageRegistry,
        messageHandler: MessageHandler
    ) {
        self.transport = transport
        self.messageRegistry = messageRegistry
        self.messageHandler = messageHandler
    }

    /// Start the connection and begin processing messages from streams
    public func listen() async throws {
        // Start the transport
        let transportTask = Task {
            try await transport.listen()
        }

        // Start processing message stream
        messageProcessingTask = Task { [weak self] in
            guard let self else { return }

            for await message in transport.messageStream {
                await self.enqueueMessage(message)
            }
        }

        // Start processing error stream
        errorProcessingTask = Task { [weak self] in
            guard let self else { return }

            for await error in transport.errorStream {
                Task { [weak self] in
                    await self?.handleTransportError(error)
                }
            }
        }

        // Wait for transport to complete
        try await transportTask.value
    }

    /// Close the connection and cleanup resources
    public func close() async {
        // Cancel processing tasks
        messageProcessingTask?.cancel()
        errorProcessingTask?.cancel()
        for task in requests.values {
            task.cancel()
        }
        for task in notifications.values {
            task.cancel()
        }

        // Close transport
        await transport.close()

        // Wait for tasks to complete
        _ = await messageProcessingTask?.result
        _ = await errorProcessingTask?.result

        messageProcessingTask = nil
        errorProcessingTask = nil
    }

    private struct Cancellation: Decodable {
        struct Params: Decodable { let id: RequestID }
        let params: Params
    }

    /// Preserve notification order without blocking cancellation behind a build.
    private func enqueueMessage(_ message: JSONRPCMessage) {
        if message.request.method == "$/cancelRequest", message.request.id == nil {
            if let cancellation = try? jsonDecoder.decode(Cancellation.self, from: message.rawData) {
                requests[cancellation.params.id]?.cancel()
            }
            return
        }
        let precedingNotifications = notificationTail
        if let id = message.request.id {
            guard requests[id] == nil else {
                logger.warning("Ignoring duplicate active request ID: \(id)")
                return
            }
            requests[id] = Task {
                defer { requests[id] = nil }
                await precedingNotifications?.value
                if Task.isCancelled {
                    await sendErrorResponse(id: id, error: JSONRPCError(code: -32800, message: "Request cancelled"))
                    return
                }
                await processMessage(message)
            }
        } else {
            let token = UUID()
            let task = Task {
                defer {
                    notifications[token] = nil
                    if notifications.isEmpty { notificationTail = nil }
                }
                await precedingNotifications?.value
                guard !Task.isCancelled else { return }
                await processMessage(message)
            }
            notifications[token] = task
            notificationTail = task
        }
    }

    /// Process a single message from the message stream
    private func processMessage(_ message: JSONRPCMessage) async {
        if let requestType = messageRegistry.requestType(for: message.request.method) {
            logger.debug("Found request type for method: \(message.request.method)")
            await handleRequest(message: message, requestType: requestType)
        } else if let notificationType = messageRegistry.notificationType(for: message.request.method) {
            logger.debug("Found notification type for method: \(message.request.method)")
            await handleNotification(message: message, notificationType: notificationType)
        } else {
            logger.warning("No handler found for method: \(message.request.method)")
            if let requestID = message.request.id {
                await sendErrorResponse(
                    id: requestID,
                    error: .methodNotFound("Method not found: \(message.request.method)")
                )
            }
        }
    }

    /// Handle transport errors from the error stream
    private func handleTransportError(_ error: JSONRPCTransportError) async {
        // Log transport errors but don't propagate them
        logger.error("Transport error: \(error)")
    }

    /// Handle a JSON-RPC request
    private func handleRequest(message: JSONRPCMessage, requestType: any RequestType.Type) async {
        guard let requestID = message.request.id else {
            logger.warning("Request without ID for method: \(message.request.method)")
            return
        }

        logger.debug("Handling request ID: \(requestID) method: \(message.request.method)")

        do {
            let typedRequest = try jsonDecoder.decode(requestType, from: message.rawData)
            logger.debug("Successfully decoded request for method: \(message.request.method)")

            let prettyJSON: String = if let jsonObject = try? JSONSerialization.jsonObject(
                with: message.rawData,
                options: []
            ),
                let prettyData = try? JSONSerialization.data(
                    withJSONObject: jsonObject,
                    options: [.prettyPrinted, .sortedKeys]
                ),
                let prettyString = String(data: prettyData, encoding: .utf8) {
                prettyString
            } else {
                "<invalid JSON>"
            }
            logger.debug("requestBody: \n\(prettyJSON)")

            if let response = await typedRequest.handle(handler: messageHandler, id: requestID) {
                if Task.isCancelled {
                    await sendErrorResponse(
                        id: requestID, error: JSONRPCError(code: -32800, message: "Request cancelled")
                    )
                    return
                }
                do {
                    logger.debug(
                        "Request handler returned response for method: \(message.request.method), " +
                            "response type: \(type(of: response))"
                    )
                    try await send(response: response)
                    logger.debug("Successfully sent response for request ID: \(requestID)")
                } catch {
                    logger.error("Failed to send response for request ID: \(requestID), error: \(error)")
                }
            } else {
                logger.error("Handler returned nil response for method: \(message.request.method)")
                await sendErrorResponse(
                    id: requestID,
                    error: .internalError("Handler failed to process request")
                )
            }
        } catch {
            logger.error("Failed to decode request for method: \(message.request.method), error: \(error)")
            await sendErrorResponse(id: requestID, error: .parseError("Invalid request format"))
        }
    }

    /// Handle a JSON-RPC notification
    private func handleNotification(message: JSONRPCMessage, notificationType: any NotificationType.Type) async {
        logger.debug("Handling notification for method: \(message.request.method)")

        do {
            let typedNotification = try jsonDecoder.decode(notificationType, from: message.rawData)
            logger.debug("Successfully decoded notification for method: \(message.request.method)")

            try await typedNotification.handle(handler: messageHandler)
            logger.debug("Successfully handled notification for method: \(message.request.method)")
        } catch {
            // Notifications don't have responses, so we can only log the error
            logger.error("Notification processing error for method: \(message.request.method), error: \(error)")
        }
    }

    /// Send an error response back to the client
    private func sendErrorResponse(id: RequestID, error: JSONRPCError) async {
        let errorResponse = JSONRPCErrorResponse(
            jsonrpc: "2.0",
            id: id,
            error: error
        )

        // A cancelled request must still deliver its final error response.
        let sending = Task { try await send(response: errorResponse) }
        do {
            try await sending.value
        } catch {
            // Failed to send error response
            logger.error("Failed to send error response: \(error)")
        }
    }

    /// Send a response using the transport
    private func send(response: ResponseType) async throws {
        try await transport.send(response: response)
    }

    /// Send a notification proactively to the client
    public func send(notification: ServerJSONRPCNotification<some Codable & Sendable>) async throws {
        try await transport.send(notification: notification)
    }
}
