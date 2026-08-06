//
//  BSPReactiveRefreshTests.swift
//  sourcekit-bsp
//
//  Verifies the reactive-refresh loop: when the client reports watched-file
//  changes via `workspace/didChangeWatchedFiles`, the server must emit a
//  `buildTarget/didChange` notification so the client re-queries sources and
//  compiler options.
//

import XCTest
@testable import BSPServer
@testable import JSONRPCConnection

final class BSPReactiveRefreshTests: XCTestCase {
    func testWatchedFileChangeEmitsBuildTargetDidChange() async throws {
        let harness = await BSPTestHarness.make()
        defer { Task { await harness.shutdown() } }

        // Start listening for the outbound notification, then report a change.
        async let notification = harness.nextNotification(method: "buildTarget/didChange", timeout: 3)

        try harness.notify(
            method: "workspace/didChangeWatchedFiles",
            params: #"{"changes":[{"uri":"file:///tmp/New.swift","type":1}]}"#
        )

        let data = await notification
        let payload = try XCTUnwrap(data, "expected a buildTarget/didChange notification")
        let json = try harness.json(payload)
        XCTAssertEqual(json["method"] as? String, "buildTarget/didChange")
    }
}
