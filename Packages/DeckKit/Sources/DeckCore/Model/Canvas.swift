//
//  Canvas.swift · DeckCore
//
//  A size, in points. The window is the user's to size and SwiftUI does the
//  arranging; the only size the core has an opinion about is the one a fresh
//  launch opens to.
//

import Foundation

public struct Canvas: Equatable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

extension String {
    /// Whitespace-trimmed. Used wherever a recorded field arrives padded.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
