public struct TaskIdentifier: Codable, Sendable {
    public let id: String
    public let parents: [String]?

    public init(id: String, parents: [String]? = nil) {
        self.id = id
        self.parents = parents
    }
}
