import Foundation

/// JSON content can be text or multimodal blocks. Reasoning fields are never projected.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
    /// A whole number as JSON holds it.
    static func int(_ value: some BinaryInteger) -> Self { .number(Double(value)) }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var int: Int? { if case .number(let v) = self { return Int(v) }; return nil }
    var double: Double? { if case .number(let v) = self { return v }; return nil }
    var formatted: String {
        if let string { return string }
        if self == .null { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? ""
    }
    subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
    var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var text: String {
        if let string { return string }
        return array.compactMap { block in
            let block = block.object
            guard ["text", "input_text", "output_text"].contains(block["type"]?.string ?? "") else { return nil }
            return block["text"]?.string
        }.joined(separator: "\n")
    }
    var identifier: String? {
        if let string { return string }
        if case .number(let number) = self { return String(format: "%.0f", number) }
        return nil
    }
}

/// Payloads are written as literals (`["type": "x", "id": .string(id)]`), so
/// a value JSON can't hold doesn't compile instead of becoming `null`.
extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringInterpolation,
                     ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements) { _, last in last }) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
}
