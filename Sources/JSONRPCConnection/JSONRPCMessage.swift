//
//  JSONRPCMessage.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case int(Int)
    case string(String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(intValue):
            try container.encode(intValue)
        case let .string(stringValue):
            try container.encode(stringValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ID is not a valid type"
                )
            )
        }
    }
}

public struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: JSONValue?
}

public struct JSONRPCError: Codable, Sendable, Error {
    let code: Int
    let message: String
    let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Standard JSON-RPC error codes
    static func parseError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32700, message: "Parse error: \(message)")
    }

    static func invalidRequest(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32600, message: "Invalid request: \(message)")
    }

    static func methodNotFound(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(message)")
    }

    static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: "Invalid params: \(message)")
    }

    static func internalError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: "Internal error: \(message)")
    }
}

public enum JSONRPCResult: Codable, Sendable {
    case result(JSONValue)
    case error(JSONRPCError)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let result = try? container.decode(JSONValue.self, forKey: .result) {
            self = .result(result)
        } else if let error = try? container.decode(JSONRPCError.self, forKey: .error) {
            self = .error(error)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: "Response must have either result or error"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .result(result):
            try container.encode(result, forKey: .result)
        case let .error(error):
            try container.encode(error, forKey: .error)
        }
    }

    enum CodingKeys: String, CodingKey {
        case result
        case error
    }
}

public enum JSONValue: Codable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case array([JSONValue])
    case dictionary([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let dictionaryValue = try? container.decode([String: JSONValue].self) {
            self = .dictionary(dictionaryValue)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .int(intValue):
            try container.encode(intValue)
        case let .double(doubleValue):
            try container.encode(doubleValue)
        case let .string(stringValue):
            try container.encode(stringValue)
        case let .bool(boolValue):
            try container.encode(boolValue)
        case let .array(arrayValue):
            try container.encode(arrayValue)
        case let .dictionary(dictionaryValue):
            try container.encode(dictionaryValue)
        case .null:
            try container.encodeNil()
        }
    }
}
