//
//  HookServerStatusTests.swift · Tests/DeckCoreTests
//
//  Whether the deck can say it is alive.
//
//  This is a small type guarding a large claim. The product's whole promise is
//  that it will speak up when a session needs a human, and that promise rests
//  entirely on a socket being bound — so a deck that failed to bind and a deck
//  with nothing to report must never look alike. They did, for the whole life
//  of the previous shell, which dropped the status line and replaced it with
//  nothing.
//

import Testing
import DeckCore

struct HookServerStatusTests {

    private static let all: [HookServerStatus] = [
        .notStarted, .listening(port: 8765), .failed(reason: "address in use"), .stopped,
    ]

    /// Every state says something. A status line that can render empty is a
    /// status line that reads as "fine" while the deck is deaf.
    @Test("every state has something to say", arguments: HookServerStatusTests.all)
    func everyStateSpeaks(_ status: HookServerStatus) {
        #expect(!status.message.isEmpty)
        #expect(!status.spokenDescription.isEmpty)
        #expect(status.spokenDescription.count > status.message.count,
                Comment(rawValue: "\(status) is announced as a bare fragment — a screen "
                        + "reader gets the words without what they mean for the deck"))
    }

    /// **Only one state is normal.**
    ///
    /// Not started, stopped and failed all mean the same thing to a user
    /// standing in front of the deck: nothing arriving now will be shown. They
    /// differ in how alarming they are, and none of them is fine.
    @Test("only a listening deck is a healthy deck")
    func onlyListeningIsNormal() {
        for status in Self.all {
            if status.isListening {
                #expect(status.severity == .normal)
            } else {
                #expect(status.severity > .normal,
                        Comment(rawValue: "\(status) is drawn as healthy while nothing "
                                + "can reach the deck"))
            }
        }
    }

    /// A bind failure is the loudest of them, because it is the one that
    /// happens silently while somebody believes they are being supervised.
    @Test("a failure to bind outranks the quiet states")
    func failureIsTheLoudest() {
        let failed = HookServerStatus.failed(reason: "address in use")
        #expect(failed.severity == .alarm)
        #expect(failed.severity > HookServerStatus.notStarted.severity)
        #expect(failed.severity > HookServerStatus.stopped.severity)
    }

    /// The reason travels with the failure. "Could not bind" alone sends
    /// somebody to a console to find out what this type already knew.
    @Test("a failure carries what went wrong")
    func failuresCarryTheirReason() {
        let failed = HookServerStatus.failed(reason: "address already in use")
        #expect(failed.message.contains("address already in use"))
        #expect(failed.spokenDescription.contains("address already in use"))
    }

    /// The port is on the glass, because "which deck am I looking at" is a
    /// real question the moment somebody runs a second one on another port.
    @Test("a listening deck names its port")
    func listeningNamesThePort() {
        let listening = HookServerStatus.listening(port: 9999)
        #expect(listening.message.contains("9999"))
        #expect(listening.spokenDescription.contains("9999"))
        #expect(listening.isListening)
    }

    /// **Stopped is not the same fact as never-started.**
    ///
    /// Both are quiet and neither is listening, but only one of them means
    /// something changed while somebody was relying on it. Collapsing them
    /// would make a deck that died indistinguishable from one still booting.
    @Test("stopping is distinguishable from never having started")
    func stoppedIsItsOwnFact() {
        #expect(HookServerStatus.stopped != HookServerStatus.notStarted)
        #expect(HookServerStatus.stopped.message != HookServerStatus.notStarted.message)
        #expect(!HookServerStatus.stopped.isListening)
        #expect(!HookServerStatus.notStarted.isListening)
    }
}
