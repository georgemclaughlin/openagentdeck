//
//  Signal.swift · DeckCore
//
//  What a reading MEANS, not what colour it is painted.
//
//  The core hands out a severity, not a colour, so no palette lives in the
//  model. The view turns it into `.secondary`, `.orange` or `.red`: system
//  colours, which already honour Increase Contrast, Reduce Transparency and
//  the user's appearance.
//

/// How much attention a reading is asking for.
public enum Severity: String, Equatable, Codable, Sendable, CaseIterable, Comparable {
    /// Nothing is wrong. The reading is informational.
    case normal
    /// Worth noticing before it becomes a problem — a gauge running down, a
    /// usage window filling.
    case caution
    /// Acting now, or being told why you cannot.
    case alarm

    private var rank: Int {
        switch self {
        case .normal: 0
        case .caution: 1
        case .alarm: 2
        }
    }

    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}
