//
//  BSPServerProtocolTests.swift
//  sourcekit-bsp
//
//  Protocol-behavior tests driven through the in-memory transport harness.
//  These exercise the real routing → handler → response path end-to-end.
//
//  This file also serves as the reference for how to write message-sequence
//  tests going forward (e.g. verifying that a `workspace/didChangeWatchedFiles`
//  notification triggers a cache refresh once that handler is implemented).
//

import XCTest
@testable import BSPServer
@testable import JSONRPCConnection

final class BSPServerProtocolTests: XCTestCase {
    /// An unregistered method must produce a JSON-RPC "method not found"
    /// (-32601) error response correlated to the request id.
    func testUnknownMethodReturnsMethodNotFound() async throws {
        let harness = await BSPTestHarness.make()
        defer { Task { await harness.shutdown() } }

        let data = try await harness.request(method: "does/notExist", id: 1)
        let json = try harness.json(data)

        XCTAssertEqual(json["id"] as? Int, 1)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    /// `build/shutdown` returns a response echoing the request id and no error.
    /// Proves request routing, contextual handler execution, and id
    /// correlation all work through the harness.
    func testBuildShutdownReturnsResponse() async throws {
        let harness = await BSPTestHarness.make()
        defer { Task { await harness.shutdown() } }

        let data = try await harness.request(method: "build/shutdown", id: 42)
        let json = try harness.json(data)

        XCTAssertEqual(json["id"] as? Int, 42)
        XCTAssertNil(json["error"])
    }

    /// Two concurrent requests both get responses correlated to their own ids,
    /// verifying the harness handles the connection's concurrent dispatch.
    func testConcurrentRequestsAreCorrelatedById() async throws {
        let harness = await BSPTestHarness.make()
        defer { Task { await harness.shutdown() } }

        async let first = harness.request(method: "build/shutdown", id: 100)
        async let second = harness.request(method: "build/shutdown", id: 200)

        let firstJSON = try await harness.json(first)
        let secondJSON = try await harness.json(second)

        XCTAssertEqual(firstJSON["id"] as? Int, 100)
        XCTAssertEqual(secondJSON["id"] as? Int, 200)
    }
}
