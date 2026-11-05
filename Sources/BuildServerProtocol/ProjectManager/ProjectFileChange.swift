/// A file event passed from the server to a project provider.
public struct ProjectFileChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case created
        case changed
        case deleted
    }

    public let uri: URI
    public let kind: Kind

    public init(uri: URI, kind: Kind) {
        self.uri = uri
        self.kind = kind
    }
}
