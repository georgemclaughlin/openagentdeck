//
//  Redacted.swift · DeckCore/Model
//
//  Text that may be **shown** and may never be **recorded**.
//
//  The deck must put payload content on screen: a decision surface has to
//  name its subject. But diagnostics exclude payload content *by
//  construction* (`Diagnostic` has no field a command, path or prompt could
//  travel in), and once a command enters the frame the frame becomes such a
//  field. `Frame` and `LaidOutFrame` are `Codable`, so logging, exporting or
//  attaching a frame to a crash report would cross that line unnoticed.
//
//  `Redacted` holds the real bytes and hands them out in-process, and there
//  is **no code path that writes them**:
//
//    - `encode(to:)` writes `placeholder`, never `value`. Any encoder — a
//      golden-frame diff, a JSON export, a crash reporter walking `Codable` —
//      gets the marker.
//    - `description` and `debugDescription` return `placeholder`, so
//      `"\(subject)"` in a log statement cannot leak.
//
//  `Equatable` compares the real values, because the byte-identical-command
//  rule (the approval command equals the payload's) needs tests to read them
//  back. Comparison happens in memory and writes nothing.
//
//  Deliberately **not generic**: the only thing to protect is text, and a
//  type that can only wrap that cannot be accidentally widened.
//

public struct Redacted: Equatable, Codable, Sendable,
                        CustomStringConvertible, CustomDebugStringConvertible {

    /// The real bytes. Readable in-process, unreachable from any encoder.
    public let value: String

    /// What every written form says instead. One constant, so a test asserting
    /// "the export contains no command" can assert what it *does* contain.
    public static let placeholder = "‹redacted›"

    public init(_ value: String) { self.value = value }

    /// Decoding yields the placeholder, not the original: an encoded frame no
    /// longer carries the text. That asymmetry is the invariant; if
    /// `decode(encode(x)) == x` held, the bytes would have survived the write.
    public init(from decoder: any Decoder) throws {
        self.value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.placeholder)
    }

    public var description: String { Self.placeholder }
    public var debugDescription: String { Self.placeholder }

    /// True when this carries nothing worth showing. Trimmed, because a command
    /// of three spaces is an empty well with a scrollbar.
    public var isEmpty: Bool { value.trimmed.isEmpty }
}

public extension Redacted {
    /// Present-or-nothing, for the many payload fields that are optional on
    /// the wire. An absent field and an empty string are the same thing to a
    /// reader, and both must render as no well rather than a blank one.
    init?(optional value: String?) {
        guard let value, !value.trimmed.isEmpty else { return nil }
        self.init(value)
    }
}
