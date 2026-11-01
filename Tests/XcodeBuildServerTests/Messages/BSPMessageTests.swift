//
//  BSPMessageTests.swift
//
//  Copyright © 2024 Wang Lun.
//

import XCTest
@testable import JSONRPCConnection
@testable import SourceKitBSP

final class BSPMessageTests: XCTestCase {
    func testBuildInitialize() throws {
        let message = """
        {
          "jsonrpc": "2.0",
          "method": "build/initialize",
          "params": {
            "rootUri": "file:///Users/test/project",
            "capabilities": {
              "languageIds": [
                "c",
                "cpp",
                "objective-c",
                "objective-cpp",
                "swift"
              ]
            },
            "displayName": "Test Client",
            "bspVersion": "2.2.0",
            "version": "1.0"
          },
          "id": 1
        }
        """

        let data = try XCTUnwrap(message.data(using: .utf8))
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(request.method, "build/initialize")
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertNotNil(request.id)

        // Test that we can decode the specific request type
        if let requestType: RequestType.Type = bspRegistry.requestType(for: request.method) {
            let typedRequest = try JSONDecoder().decode(requestType.self, from: data)
            // Verify it's the correct type
            XCTAssertTrue(typedRequest is BuildInitializeRequest)
            if let buildRequest = typedRequest as? BuildInitializeRequest {
                XCTAssertEqual(buildRequest.params.rootUri, "file:///Users/test/project")
                XCTAssertEqual(buildRequest.params.displayName, "Test Client")
                XCTAssertEqual(buildRequest.params.capabilities.languageIds.count, 5)
                XCTAssertTrue(buildRequest.params.capabilities.languageIds.contains(.swift))
                XCTAssertTrue(buildRequest.params.capabilities.languageIds.contains(.c))
            }
        } else {
            XCTFail("Should find request type for build/initialize")
        }
    }
}
