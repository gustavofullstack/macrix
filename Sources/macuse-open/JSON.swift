import Foundation

/// Minimal Sendable JSON value so tool handlers stay dependency-free.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }; return nil
    }
}

public func jsonError(code: Int, message: String, id: JSONValue?) -> JSONValue {
    .object(["jsonrpc": .string("2.0"),
             "id": id ?? .null,
             "error": .object(["code": .number(Double(code)),
                               "message": .string(message)])])
}

public func jsonResult(_ result: JSONValue, id: JSONValue?) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
}
