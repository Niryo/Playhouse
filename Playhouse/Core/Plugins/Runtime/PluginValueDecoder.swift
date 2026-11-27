import Foundation

/// Decodes a `Decodable` type straight from a `PluginValue` without encoding
/// it to JSON first. Atom props are decoded with it once per create/update op
/// (the node stores the result; rendering never decodes). For the types props use (String, Bool, Double, Int,
/// optionals, arrays, nested structs, and URL from its string) it behaves like
/// JSONDecoder; JSONDecoder's special handling of Data, Decimal and Date is
/// not reproduced.
///
/// Errors are `DecodingError`s whose coding path ends at the offending value
/// (including a missing key), with short messages such as
/// "expected a number, found a string" or "missing".
package enum PluginValueDecoder {
    package static func decode<T: Decodable>(_ type: T.Type, from value: PluginValue) throws -> T {
        try T(from: ValueDecoder(value: value, codingPath: []))
    }
}

private struct IndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String
    init(_ index: Int) { intValue = index; stringValue = String(index) }
    init?(intValue: Int) { self.init(intValue) }
    init?(stringValue: String) { return nil }
}

private func describe(_ value: PluginValue) -> String {
    switch value {
    case .null: "null"
    case .bool: "a boolean"
    case .number(let number): Int(exactly: number).map(String.init) ?? String(number)
    case .string: "a string"
    case .array: "an array"
    case .object: "an object"
    }
}

private func mismatch(_ type: Any.Type, expected: String, found value: PluginValue, at path: [CodingKey]) -> DecodingError {
    let context = DecodingError.Context(codingPath: path, debugDescription: "expected \(expected), found \(describe(value))")
    return value == .null ? .valueNotFound(type, context) : .typeMismatch(type, context)
}

private struct ValueDecoder: Decoder, SingleValueDecodingContainer {
    let value: PluginValue
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let fields) = value else {
            throw mismatch([String: Any].self, expected: "an object", found: value, at: codingPath)
        }
        return KeyedDecodingContainer(KeyedContainer<Key>(fields: fields, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let items) = value else {
            throw mismatch([Any].self, expected: "an array", found: value, at: codingPath)
        }
        return UnkeyedContainer(items: items, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer { self }

    // MARK: SingleValueDecodingContainer

    func decodeNil() -> Bool { value == .null }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let bool) = value else { throw mismatch(type, expected: "a boolean", found: value, at: codingPath) }
        return bool
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let string) = value else { throw mismatch(type, expected: "a string", found: value, at: codingPath) }
        return string
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard case .number(let number) = value else { throw mismatch(type, expected: "a number", found: value, at: codingPath) }
        return number
    }

    func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }

    private func integer<T: BinaryInteger>(_ type: T.Type) throws -> T {
        guard case .number(let number) = value, let integer = T(exactly: number) else {
            throw mismatch(type, expected: "a whole number", found: value, at: codingPath)
        }
        return integer
    }

    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if let value = value as? T { return value }  // PluginValue itself.
        if T.self == URL.self {
            // Like JSONDecoder, a URL is its string (URL's own Codable form is an object).
            guard let url = URL(string: try decode(String.self)) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "expected a URL, found \(describe(value))"))
            }
            return url as! T
        }
        return try T(from: self)
    }
}

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let fields: [String: PluginValue]
    let codingPath: [CodingKey]

    var allKeys: [Key] { fields.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { fields[key.stringValue] != nil }

    private func decoder(for key: Key) throws -> ValueDecoder {
        guard let value = fields[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: codingPath + [key], debugDescription: "missing"))
        }
        return ValueDecoder(value: value, codingPath: codingPath + [key])
    }

    func decodeNil(forKey key: Key) throws -> Bool { try decoder(for: key).decodeNil() }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try decoder(for: key).decode(type) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try decoder(for: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try decoder(for: key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        ValueDecoder(value: fields["super"] ?? .null, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        ValueDecoder(value: fields[key.stringValue] ?? .null, codingPath: codingPath + [key])
    }
}

private struct UnkeyedContainer: UnkeyedDecodingContainer {
    let items: [PluginValue]
    let codingPath: [CodingKey]
    private(set) var currentIndex = 0

    init(items: [PluginValue], codingPath: [CodingKey]) {
        self.items = items
        self.codingPath = codingPath
    }

    var count: Int? { items.count }
    var isAtEnd: Bool { currentIndex >= items.count }

    private mutating func next<T>(_ type: T.Type) throws -> ValueDecoder {
        let path = codingPath + [IndexKey(currentIndex)]
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: path, debugDescription: "missing"))
        }
        defer { currentIndex += 1 }
        return ValueDecoder(value: items[currentIndex], codingPath: path)
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd, items[currentIndex] == .null else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next(type).decode(type) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try next([String: Any].self).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try next([Any].self).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder { try next(Any.self) }
}
