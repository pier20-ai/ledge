import Foundation

/// A faithful JSON value. Props over the wire are heterogeneous (`content` is a
/// string, `pad` is an int, `points` is a number array), so the shadow-tree
/// validator and the renderer both need to inspect values structurally rather
/// than through a fixed Codable shape. Integers and doubles are kept distinct so
/// checkpointed transducer state round-trips without gaining a spurious `.0`.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public extension JSONValue {
    var isNumber: Bool {
        switch self {
        case .int, .double: true
        default: false
        }
    }

    var asDouble: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }

    var asInt: Int? {
        switch self {
        case let .int(value): value
        case let .double(value): Int(value)
        default: nil
        }
    }

    var asString: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var asBool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var asArray: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var asObject: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
