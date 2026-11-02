//
//  OpenAgentDeckApp.swift · OpenAgentDeck
//
//  The application target, entire. Everything the deck does lives in
//  `DeckKit`, where it is testable without launching an app; what is left here
//  is the one declaration a library cannot make.
//

import SwiftUI
import DeckApp

@main
struct OpenAgentDeckApp: App {
    var body: some Scene {
        DeckScene()
    }
}
