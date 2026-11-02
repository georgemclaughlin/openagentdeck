//
//  PrefsStoreTests.swift · Tests/DeckAdaptersTests
//
//  The adapter halves: prefs round-trip through a REAL
//  UserDefaults (hermetic throwaway suite — the standard seam), the themes
//  folder read through the real filesystem, and the watcher's inventory. No
//  waits, no timers: the watcher's event delivery is the live run's
//  to see; what a headless test can hold is what watching costs and what
//  reading returns.
//

import Testing
import Foundation
import DeckCore
@testable import DeckAdapters

struct PrefsStoreTests {

    /// The round trip `DeckCoreTests.PrefsTests` already proves at the
    /// `JSONValue` level, carried one layer further: through a REAL
    /// `UserDefaults` suite, the same `Data(forKey:)` boundary `PrefsStore
    /// .load`/`.save` actually cross. `JSONValue` equality cannot see a
    /// defect in `PrefsStore.data(from:)`'s own `JSONSerialization` call —
    /// this is the one test that can.
    @Test("prefs round-trip through a real, hermetic UserDefaults suite")
    func roundTripsThroughARealSuite() {
        let suite = PrefsStore.throwaway()
        var prefs = DeckPrefs()
        prefs.hidden = ["s1"]
        prefs.autoContinue = ["s2"]
        prefs.deleted = ["s3"]
        prefs.directoryColors = ["/w/s4": .slot(4), "/w/s5": .custom(red: 0.1, green: 0.2, blue: 0.3)]
        prefs.legacyCardColors = ["s6": .slot(7)]
        prefs.promptHistory = 5

        PrefsStore.save(prefs, to: suite)
        let loaded = PrefsStore.load(from: suite)

        #expect(loaded == prefs, "the round trip through a real UserDefaults suite changed the value")
    }

    /// The same total-decode posture `DeckPrefs.decode` documents at its own
    /// call site, exercised at the ADAPTER boundary: a prefs key holding
    /// bytes that are not JSON at all — hand-edited, truncated by a full
    /// disk, whatever produced it — must start the deck at first-run rather
    /// than crash `JSONSerialization` or throw out of `load`.
    @Test("corrupted bytes under the prefs key decode to first-run rather than crashing")
    func corruptedDataDecodesToFirstRun() {
        let suite = PrefsStore.throwaway()
        suite.set(Data("not json at all { [ } garbage".utf8), forKey: PrefsStore.key)

        #expect(PrefsStore.load(from: suite) == .firstRun)
    }
}
