import Foundation
import SourceKitBSPProtocol

public struct PublishDiagnosticsParams: Codable, Sendable {
    public static let method = "build/publishDiagnostics"

    public let textDocument: TextDocumentIdentifier
    public let buildTarget: BSPBuildTargetIdentifier
    public let originId: String?
    public let diagnostics: [Diagnostic]
    public let reset: Bool?

    public init(
        textDocument: TextDocumentIdentifier,
        buildTarget: BSPBuildTargetIdentifier,
        originId: String? = nil,
        diagnostics: [Diagnostic],
        reset: Bool? = nil
    ) {
        self.textDocument = textDocument
        self.buildTarget = buildTarget
        self.originId = originId
        self.diagnostics = diagnostics
        self.reset = reset
    }
}
