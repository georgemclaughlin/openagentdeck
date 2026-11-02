//
//  JSONValue.swift · DeckCore/Ingest
//
//  A lossless, unknown-tolerant JSON value.
//
//  Decoders must be total, lossless and unknown-tolerant, and a `Codable`
//  struct per payload is none of those: it throws on a renamed field,
//  silently drops everything it was not told about, and turns an unforeseen
//  enum value into an error. (An induced failure surfaced as `blocked`, not
//  the `failed` the spec assumed; a positive match on known values would have
//  called it fine.)
//
//  So the wire is decoded into this, and every payload decoder reads fields out
//  of it by hand and returns something for every input. Nothing here throws.
//

import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                          { self = .null }
        else if let b = try? c.decode(Bool.self)  { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
        }
    }

    /// Parse bytes. Returns nil only when the bytes are not JSON at all — which
    /// is the one failure a decoder cannot absorb, because there is nothing to
    /// be tolerant *of*.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    var intValue: Int?       { if case .number(let d) = self { return Int(d) }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var boolValue: Bool?     { if case .bool(let b) = self { return b }; return nil }
    var isNull: Bool { self == .null }
}

/// Absent, explicitly null, and present-with-a-value are **three** decoding
/// cases, not two.
///
/// A `status: null` once recorded as an observed value turned out to be a
/// Node serialisation of a *missing* property. A decoder that collapses the
/// two cannot tell which it saw, so it cannot notice when the wire changes
/// from one to the other.
///
/// The empty-slot rule needs the distinction on the display side too: an
/// absent feed and a feed that emitted `null` both render an empty slot, and
/// neither renders `0`.
public enum Fed<Value: Equatable & Sendable>: Equatable, Sendable {
    case absent
    case unset
    case value(Value)

    public var value: Value? { if case .value(let v) = self { return v }; return nil }
    public var isPresent: Bool { value != nil }
}

public extension JSONValue {
    /// Read a key as a fed integer, keeping absent and null apart.
    func fedInt(_ key: String) -> Fed<Int> {
        guard let v = self[key] else { return .absent }
        if v.isNull { return .unset }
        guard let i = v.intValue else { return .unset }
        return .value(i)
    }

    func fedString(_ key: String) -> Fed<String> {
        guard let v = self[key] else { return .absent }
        if v.isNull { return .unset }
        guard let s = v.stringValue else { return .unset }
        return .value(s)
    }

    func fedDouble(_ key: String) -> Fed<Double> {
        guard let v = self[key] else { return .absent }
        if v.isNull { return .unset }
        guard let d = v.doubleValue else { return .unset }
        return .value(d)
    }
}
