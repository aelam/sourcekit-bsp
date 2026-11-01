//
//  TextDocumentSourceKitOptionsRequestTests.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import Testing
@testable import sourcekit - bsp

struct TextDocumentSourceKitOptionsRequestTests {
    // MARK: - Test Data

    static let swiftJSONWithIntID = """
    {
        "id": 123,
        "jsonrpc": "2.0",
        "method": "textDocument/sourceKitOptions",
        "params": {
            "textDocument": {
                "uri": "file:///Users/user/project/Hello/Hello.swift"
            },
            "target": {
                "uri": "xcode:///Hello/HelloScheme/Hello"
            },
            "language": "swift"
        }
    }
    """

    static let objectiveCJSONWithStringID = """
    {
        "id": "test-request",
        "jsonrpc": "2.0",
        "method": "textDocument/sourceKitOptions",
        "params": {
            "textDocument": {
                "uri": "file:///Users/user/project/Hello/AppDelegate.m"
            },
            "target": {
                "uri": "xcode:///Hello/HelloScheme/HelloTarget"
            },
            "language": "objective-c"
        }
    }
    """

    // MARK: - JSON Decoding Tests

    @Test(arguments: [swiftJSONWithIntID, objectiveCJSONWithStringID])
    func jSONDecoding(json: String) throws {
        let data = Data(json.utf8)
        let request = try JSONDecoder().decode(TextDocumentSourceKitOptionsRequest.self, from: data)

        #expect(request.jsonrpc == "2.0")

        // Validate based on the JSON content
        if json.contains("\"language\": \"swift\"") {
            // Swift test case
            if case let .int(idValue) = request.id {
                #expect(idValue == 123)
            } else {
                #expect(Bool(false), "Expected int ID for Swift test")
            }
            #expect(request.params.textDocument.uri.stringValue == "file:///Users/user/project/Hello/Hello.swift")
            #expect(request.params.target.uri.stringValue == "xcode:///Hello/HelloScheme/Hello")
            #expect(request.params.language == .swift)
        } else {
            // Objective-C test case
            if case let .string(idValue) = request.id {
                #expect(idValue == "test-request")
            } else {
                #expect(Bool(false), "Expected string ID for Objective-C test")
            }
            #expect(request.params.textDocument.uri.stringValue == "file:///Users/user/project/Hello/AppDelegate.m")
            #expect(request.params.target.uri.stringValue == "xcode:///Hello/HelloScheme/HelloTarget")
            #expect(request.params.language == .objective_c)
        }
    }

    // MARK: - Method Tests

    @Test
    func testMethod() {
        #expect(TextDocumentSourceKitOptionsRequest.method() == "textDocument/sourceKitOptions")
    }

    // MARK: - Response Tests

    @Test
    func responseWithCompilerArguments() {
        let arguments = [
            "-module-name", "Hello",
            "-Onone",
            "-enforce-exclusivity=checked",
            "/Users/user/project/Hello/Hello.swift",
            "-DDEBUG",
            "-sdk", "/Applications/Xcode.app/.../iPhoneOS.sdk",
            "-target", "arm64-apple-ios18.0",
            "-index-store-path", "/Users/user/Library/.../Index.noindex/DataStore"
        ]

        let result = TextDocumentSourceKitOptionsResponse.Result(
            compilerArguments: arguments,
            workingDirectory: "/Users/user/project/Hello"
        )

        let response = TextDocumentSourceKitOptionsResponse(
            id: .string("123"),
            jsonrpc: "2.0",
            result: result
        )

        #expect(response.result?.compilerArguments.count == arguments.count)
        #expect(response.result?.compilerArguments.first == "-module-name")
        #expect(response.result?.workingDirectory == "/Users/user/project/Hello")
    }

    @Test
    func responseWithNilResult() {
        let response = TextDocumentSourceKitOptionsResponse(
            id: .int(456),
            jsonrpc: "2.0",
            result: nil
        )

        #expect(response.result == nil)
        if let id = response.id, case let .int(idValue) = id {
            #expect(idValue == 456)
        } else {
            #expect(Bool(false), "Expected int ID")
        }
        #expect(response.jsonrpc == "2.0")
    }

    @Test
    func responseJSONEncoding() throws {
        let arguments = ["-module-name", "TestModule", "-swift-version", "5"]

        let result = TextDocumentSourceKitOptionsResponse.Result(
            compilerArguments: arguments,
            workingDirectory: "/test/path"
        )

        let response = TextDocumentSourceKitOptionsResponse(
            id: .string("test-id"),
            jsonrpc: "2.0",
            result: result
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(response)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(jsonString.contains("\"compilerArguments\""))
        #expect(jsonString.contains("\"workingDirectory\""))
        #expect(jsonString.contains("\"-module-name\""))
        #expect(jsonString.contains("\"TestModule\""))
        #expect(jsonString.contains("\"\\/test\\/path\"")) // JSON escapes forward slashes
    }

    // MARK: - Params Tests

    @Test
    func paramsCreation() throws {
        let textDocument = try TextDocumentIdentifier(URI(string: "file:///test.swift"))
        let target = try BSPBuildTargetIdentifier(uri: URI(string: "xcode:///Project/Scheme/Target"))

        let params = TextDocumentSourceKitOptionsRequest.Params(
            textDocument: textDocument,
            target: target,
            language: .swift
        )

        #expect(params.textDocument.uri.stringValue == "file:///test.swift")
        #expect(params.target.uri.stringValue == "xcode:///Project/Scheme/Target")
        #expect(params.language == .swift)
    }

    @Test
    func paramsJSONRoundTrip() throws {
        let textDocument = try TextDocumentIdentifier(FileURL(string: "file:///MyApp/ViewController.swift"))
        let target = try BuildTargetIdentifier(uri: FileURL(string: "xcode:///MyApp/MyScheme/MyTarget"))

        let originalParams = TextDocumentSourceKitOptionsRequest.Params(
            textDocument: textDocument,
            target: target,
            language: .swift
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalParams)

        // Decode back
        let decoder = JSONDecoder()
        let decodedParams = try decoder.decode(TextDocumentSourceKitOptionsRequest.Params.self, from: data)

        #expect(decodedParams.textDocument.uri.stringValue == originalParams.textDocument.uri.stringValue)
        #expect(decodedParams.target.uri.stringValue == originalParams.target.uri.stringValue)
        #expect(decodedParams.language == originalParams.language)
    }

    // MARK: - Integration Test Helper

    @Test
    func testCreateMockRequest() throws {
        let request = try createMockRequest()

        #expect(request.params.textDocument.uri.stringValue.hasSuffix(".swift"))
        #expect(request.params.target.uri.stringValue.hasPrefix("xcode:///"))
        #expect(request.params.language == .swift)
        #expect(TextDocumentSourceKitOptionsRequest.method() == "textDocument/sourceKitOptions")
    }

    // MARK: - Helper Methods

    private func createMockRequest() throws -> TextDocumentSourceKitOptionsRequest {
        let textDocument = TextDocumentIdentifier(
            URI(URL(fileURLWithPath: "/Users/test/project/MyApp/ViewController.swift"))
        )
        let target = try BuildTargetIdentifier(
            uri: URI(string: "xcode:///MyApp/MyScheme/MyTarget")
        )

        let params = TextDocumentSourceKitOptionsRequest.Params(
            textDocument: textDocument,
            target: target,
            language: .swift
        )

        return TextDocumentSourceKitOptionsRequest(
            id: .string("test-request"),
            jsonrpc: "2.0",
            params: params
        )
    }
}
