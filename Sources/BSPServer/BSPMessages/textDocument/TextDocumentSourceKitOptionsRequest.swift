//
//  TextDocumentSourceKitOptionsRequest.swift
//
//  Copyright © 2024 Wang Lun.
//

import Foundation
import JSONRPCConnection
import Logger

// Request compiler options for a specific source file in a build target.
//
// The `textDocument/sourceKitOptions` request is sent from the client to the server to query for the list of
// compiler options necessary to compile a specific file in the given target.
//
// ## Overview
//
// This request enables SourceKit-LSP to obtain the exact compiler arguments needed to analyze a source file
// within a specific build target context. The compiler arguments include module names, optimization levels,
// SDK paths, target architectures, and other compilation flags.
//
// ## Caching Behavior
//
// The build settings are considered up-to-date and can be cached by SourceKit-LSP until a
// `buildTarget/didChange` notification is sent for the requested target.
//
// ## Error Handling
//
// The request may return `nil` if no build settings are available for the file in the given target.
//
// ## Example Request
//
// ```json
// {
//   "jsonrpc": "2.0",
//   "method": "textDocument/sourceKitOptions",
//   "params": {
//     "textDocument": { "uri": "file:///path/to/source.swift" },
//     "target": { "uri": "xcode:///ProjectPath/SchemeName/TargetName" },
//     "language": "swift"
//   }
// }
// ```
//
// ## Example Response
//
// ```json
// {
//   "compilerArguments": [
//     "-module-name", "Hello",
//     "-Onone",
//     "-enforce-exclusivity=checked",
//     "/path/to/source.swift",
//     "-DDEBUG",
//     "-sdk", "/Applications/Xcode.app/.../iPhoneOS.sdk",
//     "-target", "arm64-apple-ios18.0",
//     "-index-store-path", "/path/to/IndexStore"
//   ],
//   "workingDirectory": "/path/to/project"
// }
// ```
//
import BuildServerProtocol

public struct TextDocumentSourceKitOptionsRequest: ContextualRequestType, Sendable {
    public typealias RequiredContext = BSPServerService

    public static func method() -> String {
        "textDocument/sourceKitOptions"
    }

    /// Parameters for the textDocument/sourceKitOptions request.
    ///
    /// Contains the necessary information to identify which source file and build target
    /// to retrieve compiler options for.
    public struct Params: Codable, Sendable {
        /// The URI of the document to get compiler options for.
        ///
        /// This should be a file URI pointing to the source file that needs compilation settings.
        ///
        /// - Note: The file must exist within the project structure and be associated with the specified target.
        public var textDocument: TextDocumentIdentifier

        /// The build target for which the build settings should be returned.
        ///
        /// A source file might be part of multiple targets and might have different compiler arguments
        /// in each target, thus the target specification is necessary for this request.
        ///
        /// - Important: The target URI should follow the format `xcode:///ProjectPath/TargetName`.
        public var target: BSPBuildTargetIdentifier

        /// The programming language of the document.
        ///
        /// This helps the server provide language-specific compiler options and optimizations.
        ///
        /// - SeeAlso: ``Language`` for supported language types.
        public var language: BuildServerProtocol.Language
    }

    public let id: JSONRPCID
    public let jsonrpc: String
    public let params: Params

    /// Handles the textDocument/sourceKitOptions request by retrieving compiler arguments.
    ///
    /// This method processes the request by:
    /// 1. Extracting compiler arguments for the specified file and target
    /// 2. Determining the appropriate working directory
    /// 3. Constructing a response with the compilation settings
    ///
    /// - Parameters:
    ///   - contextualHandler: The handler providing access to the build server context
    ///   - id: The request identifier for response correlation
    ///
    /// - Returns: A ``TextDocumentSourceKitOptionsResponse`` containing the compiler settings,
    ///           or `nil` result if settings cannot be determined
    ///
    /// - Note: Errors during processing are logged and result in a response with `nil` result
    ///         rather than throwing an exception.
    public func handle<Handler: ContextualMessageHandler>(
        contextualHandler: Handler,
        id: RequestID
    ) async -> ResponseType? where Handler.Context == BSPServerService {
        await contextualHandler.withContext { context in
            guard let fileURL = params.textDocument.uri.fileURL else {
                let errorMessage =
                    "Failed to get fileURL: \(params.textDocument.uri)"

                return JSONRPCErrorResponse(
                    id: id,
                    error: JSONRPCError(
                        code: -32002, // FIXME: LSP ServerNotInitialized error code
                        message: errorMessage
                    )
                )
            }
            do {
                // Get compile arguments for the specific file
                let compilerArguments = try await context.getCompileArguments(
                    targetIdentifier: params.target,
                    fileURL: fileURL
                )

                // Get working directory from context
                let workingDirectory = try await context.getWorkingDirectory() ?? ""

                // Create and return the response with the actual data
                let result = TextDocumentSourceKitOptionsResponse.Result(
                    compilerArguments: compilerArguments,
                    workingDirectory: workingDirectory
                )

                return TextDocumentSourceKitOptionsResponse(
                    id: id,
                    jsonrpc: "2.0",
                    result: result
                )
            } catch {
                logger.error("Failed to get sourceKit options: \(error)")

                // Return response with empty result on error
                return TextDocumentSourceKitOptionsResponse(
                    id: id,
                    jsonrpc: "2.0",
                    result: nil
                )
            }
        }
    }
}

/// Response structure for textDocument/sourceKitOptions requests.
///
/// Contains the compiler arguments and working directory needed to compile a specific source file.
public struct TextDocumentSourceKitOptionsResponse: ResponseType, Hashable {
    /// The result payload containing compilation information.
    ///
    /// This structure encapsulates all the necessary information for compiling a source file,
    /// including compiler flags, SDK paths, and the working directory context.
    public struct Result: Codable, Hashable, Sendable {
        /// The complete list of compiler arguments required for the requested file.
        ///
        /// These arguments include all necessary flags, paths, and options that would be passed
        /// to the compiler when building this specific source file within its target context.
        ///
        /// ## Typical Arguments Include:
        /// - Module name (`-module-name`)
        /// - Optimization level (`-Onone`, `-O`)
        /// - Source file paths
        /// - Preprocessor definitions (`-DDEBUG`)
        /// - SDK paths (`-sdk`)
        /// - Target architecture (`-target`)
        /// - Index store paths (`-index-store-path`)
        ///
        /// - Note: The arguments are ordered as they would appear in an actual compiler invocation.
        public let compilerArguments: [String]

        /// The working directory for the compile command.
        ///
        /// This is the directory from which the compiler command should be executed.
        /// Relative paths in the compiler arguments are resolved relative to this directory.
        ///
        /// - Returns: The absolute path to the working directory, or `nil` if not available.
        public let workingDirectory: String?
    }

    public let id: JSONRPCID?
    public let jsonrpc: String

    /// The compilation result, or `nil` if no build settings are available.
    ///
    /// When `nil`, it indicates that the server could not determine the appropriate
    /// compiler settings for the requested file and target combination.
    public let result: Result?
}
