//
//  ConnectionTests.swift · Tests/DeckCoreTests
//
//  Whether Claude Code can reach this deck.
//
//  Two facts have to be true at once — a socket is bound, and the settings
//  file points at it — and every way they can disagree looks the same from the
//  outside: an empty deck. The whole value of this type is that it tells those
//  apart, so the tests are mostly about the states that were previously
//  indistinguishable from "nobody has started a session yet".
//

import Testing
import DeckCore

struct ConnectionTests {

    private func decide(document: ConfigReadout = .present,
                        listeningOn: Int? = 8765,
                        bindFailed: Bool = false,
                        installedPort: Int? = 8765,
                        attemptedPort: Int = 8765,
                        lanesSeen: Int = 0,
                        hooksHeard: Bool = false,
                        candidatesSeen: Int = 0) -> Connection {
        Connection.decide(document: document, listeningOn: listeningOn,
                          bindFailed: bindFailed, installedPort: installedPort,
                          attemptedPort: attemptedPort,
                          lanesSeen: lanesSeen, hooksHeard: hooksHeard,
                          candidatesSeen: candidatesSeen)
    }

    // ------------------------------------------------------- the silent ones

    /// **The dangerous state.**
    ///
    /// A deck that could not bind 8765 and took 8766 leaves the config aimed
    /// at a port nothing is listening on. Everything reads as installed and no
    /// session will ever appear — there is no error, no empty-looking failure,
    /// just a deck that is quiet forever. It has to be its own state or it is
    /// indistinguishable from a machine nobody has used yet.
    @Test("a port mismatch is its own state, not an empty deck")
    func portDriftIsNamed() {
        let drifted = decide(listeningOn: 8766, installedPort: 8765)
        #expect(drifted == .wrongPort(installed: 8765, listening: 8766))
        #expect(drifted.needsAttention)
        #expect(drifted.isConnectable, "the state that most needs repair cannot be repaired")
        #expect(drifted.detail.contains("8766"), "the fix does not name the port to move to")
    }

    /// No hook at all. Nothing will ever arrive, and the deck says so instead
    /// of inviting somebody to start a session that cannot reach it.
    @Test("an unconnected deck does not pretend to be waiting")
    func notConnectedIsNotWaiting() {
        let fresh = decide(document: .absent, installedPort: nil)
        #expect(fresh == .notConnected)
        #expect(fresh.needsAttention)
        #expect(fresh.isConnectable)
    }

    /// **A file the deck cannot read is never written to.** Merging into a
    /// document that failed to parse means merging into nothing, and writing
    /// that back replaces the user's configuration.
    @Test("an unreadable settings file refuses the connect button")
    func anUnreadableFileIsNotConnectable() {
        let broken = decide(document: .unreadable("is not valid JSON"))
        #expect(broken.needsAttention)
        #expect(!broken.isConnectable,
                "the deck offers to write over a settings file it could not read")
        #expect(broken.detail.contains("valid JSON"), "the reason is not passed through")
    }

    /// A second deck is not a broken deck. The sessions are connected; they
    /// are connected to the other window.
    @Test("a second deck says so and offers nothing to fix")
    func aSecondDeckIsNotAnError() {
        let second = decide(bindFailed: true, installedPort: 8765)
        #expect(second == .superseded(port: 8765))
        #expect(!second.isConnectable, "the second deck offers to rewrite hooks that are correct")

        // A fresh machine that never connected still names a real port — this
        // read "already owns 127.0.0.1:0", a number no deck has listened on.
        let fresh = decide(document: .absent, bindFailed: true,
                           installedPort: nil, attemptedPort: 8765)
        #expect(fresh == .superseded(port: 8765))
        #expect(!fresh.detail.contains(":0"),
                Comment(rawValue: "names a port nothing binds: \(fresh.detail)"))
    }

    // ------------------------------------------------------ proving it works

    /// **Writing the file proves a write happened, not that it worked.**
    ///
    /// Claude Code may need a session restart to read new hooks, so setup
    /// stays unfinished until something actually arrives.
    @Test("connected is claimed only once a hook has arrived")
    func connectionIsProvenByAHook() {
        #expect(decide(hooksHeard: false) != .connected)
        #expect(decide(hooksHeard: true) == .connected)
    }

    /// And the fleet feed turns "nothing here" into an instruction. It sees
    /// sessions that have never fired a hook, so the deck can name the three
    /// that need restarting rather than leaving somebody to guess.
    @Test("sessions that are running but silent are counted and explained")
    func runningButSilentSessionsAreNamed() {
        let quiet = decide(lanesSeen: 0)
        #expect(quiet == .waiting(running: 0))
        #expect(quiet.detail.contains("Start Claude Code"))

        let three = decide(lanesSeen: 3)
        #expect(three == .waiting(running: 3))
        #expect(three.title.contains("3"), "the count is not on the glass")
        #expect(three.detail.lowercased().contains("restart"),
                "the deck knows what to do about it and does not say")
        #expect(!three.needsAttention, "a deck that is working is asking to be fixed")
    }

    // ------------------------------------------------- the file lost the hook

    /// **A hook that arrived outranks a file that went quiet.**
    ///
    /// Observed live: Claude Code rewrote `settings.json` saving a model
    /// default and stripped the deck's marker, and the banner said "Not
    /// connected yet" above a session the deck was rendering at that moment.
    /// The file's silence means the deck cannot vouch for NEW sessions — it is
    /// never license to deny the ones it can see.
    @Test("an arrived hook is never reported as not connected")
    func anArrivedHookIsNeverDenied() {
        let live = decide(installedPort: nil, hooksHeard: true, candidatesSeen: 1)
        #expect(live == .unlisted(candidates: 1))
        #expect(live != .notConnected)
        #expect(live.title != Connection.notConnected.title,
                Comment(rawValue: "a working deck reads as unconnected: \(live.title)"))
        #expect(live.needsAttention, "the file still needs repairing, and nothing says so")
        #expect(live.isConnectable, "the state exists to be repaired and the button is gone")
    }

    /// The two ways the file can have lost the hook need different sentences,
    /// because they need different expectations: one says adopt, the other
    /// says new sessions will not appear.
    @Test("unlisted says whether there is a hook left to adopt")
    func unlistedNamesItsRepair() {
        let stripped = decide(installedPort: nil, hooksHeard: true, candidatesSeen: 1)
        #expect(stripped.detail.lowercased().contains("adopt"),
                Comment(rawValue: "the repair is not named: \(stripped.detail)"))

        let removed = decide(installedPort: nil, hooksHeard: true, candidatesSeen: 0)
        #expect(removed.detail.lowercased().contains("new sessions won't connect"),
                Comment(rawValue: "the consequence is not named: \(removed.detail)"))
    }

    /// And without the arrived hook, an empty file still reads as it always
    /// did — `unlisted` is proven by traffic, never inferred from the file.
    @Test("unlisted needs an arrived hook, not just a bare file")
    func unlistedNeedsProof() {
        #expect(decide(installedPort: nil, hooksHeard: false, candidatesSeen: 1)
                == .notConnected)
    }

    // -------------------------------------------------------- every state speaks

    @Test("every state has a title and a next move", arguments: [
        Connection.unreadable(reason: "is not valid JSON"), .notConnected,
        .wrongPort(installed: 1, listening: 2), .waiting(running: 0), .waiting(running: 2),
        .connected, .unlisted(candidates: 0), .unlisted(candidates: 1),
        .superseded(port: 8765),
    ])
    func everyStateSpeaks(_ state: Connection) {
        #expect(!state.title.isEmpty)
        #expect(state.detail.count > 20,
                Comment(rawValue: "\(state) says almost nothing: \(state.detail)"))
    }

    /// No two states read the same, or the value is finer than the words and
    /// the user cannot tell which one they are in.
    @Test("no two states say the same thing")
    func statesAreDistinguishable() {
        let all: [Connection] = [.unreadable(reason: "x"), .notConnected,
                                 .wrongPort(installed: 1, listening: 2),
                                 .waiting(running: 0), .waiting(running: 2),
                                 .connected, .unlisted(candidates: 0),
                                 .unlisted(candidates: 1), .superseded(port: 8765)]
        #expect(Set(all.map { $0.title + $0.detail }).count == all.count)
    }
}
