public struct BuildTargetOutputPathsResult: Codable, Hashable, Sendable {
    public let items: [OutputPathsItem]

    public init(items: [OutputPathsItem] = []) {
        self.items = items
    }

    public struct OutputPathsItem: Codable, Hashable, Sendable {
        public enum OutputPathItemKind: Int, Codable, Hashable, Sendable {
            case file = 1
            case directory = 2
        }

        public struct OutputPathItem: Codable, Hashable, Sendable {
            public let uri: URI
            public let kind: OutputPathItemKind

            public init(uri: URI, kind: OutputPathItemKind) {
                self.uri = uri
                self.kind = kind
            }
        }

        public let target: BSPBuildTargetIdentifier
        public let outputPaths: [OutputPathItem]

        public init(target: BSPBuildTargetIdentifier, outputPaths: [OutputPathItem]) {
            self.target = target
            self.outputPaths = outputPaths
        }
    }
}
