import Foundation

/// One reconciler mutation inside a `commit` (spec §3.1). Fields are optional
/// because each op uses a different subset; validation enforces the required
/// combination per op.
public struct Mutation: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        case create
        case insert
        case update
        case remove
        case setRoot
    }

    public var op: Op
    public var id: Int?
    public var kind: String?
    public var props: [String: JSONValue]?
    public var parent: Int?
    public var before: Int?

    public init(
        op: Op,
        id: Int? = nil,
        kind: String? = nil,
        props: [String: JSONValue]? = nil,
        parent: Int? = nil,
        before: Int? = nil
    ) {
        self.op = op
        self.id = id
        self.kind = kind
        self.props = props
        self.parent = parent
        self.before = before
    }

    private enum CodingKeys: String, CodingKey {
        case op, id, kind, props, parent, before
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(Op.self, forKey: .op)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        props = try container.decodeIfPresent([String: JSONValue].self, forKey: .props)
        parent = try container.decodeIfPresent(Int.self, forKey: .parent)
        // `before` is explicitly null (= append) in fixtures; both null and
        // absent decode to nil, which the validator treats as append.
        before = try container.decodeIfPresent(Int.self, forKey: .before)
    }
}
