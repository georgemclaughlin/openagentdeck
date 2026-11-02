//
//  StalenessTests.swift · Tests/DeckCoreTests
//
//  Case P1.21, as amended for the context gauge: a
//  feed that stops feeding no longer empties the gauge, it MARKS it — the
//  LAST value stays on screen rather than reverting to an empty slot, which
//  is the half of this file that is still exactly true.
//
//  **No renderer draws a stale ctx reading any
//  differently from a fresh one, on any surface, deliberately.** The
//  ORIGINAL framing above ("the renderer draws a stale reading in the stale
//  ink… a decaying trend whose two-minute-old reading is still approximately
//  true") had the semantics backwards for context specifically: a context
//  percentage does not decay. An idle session's context is exactly what it
//  was: the last reading a statusline sent stays TRUE, not "approximately
//  true," until the next turn actually moves it. Sampled rates (the usage
//  dot) still DO keep moving off-screen between statuslines — the account
//  is still spending against its windows whether or not this deck happens to
//  be looking — but the deck no longer marks that in paint
//  either: "sometimes coloured, sometimes grey" read as
//  inconsistent, so the deck standardized on colour and `UsageIndicator`
//  dropped the field that dimmed it (`Frame.swift`'s own doc comment on the
//  type carries the account). Both readouts now share the one rule this
//  amendment states for ctx (`ContextBar.fill(for:)`'s own doc comment,
//  `SessionOverview.swift`, carries the full account there). The
//  frame still carries `contextStale` — the field this file exercises below
//  is real and still flips at the boundaries tested here — but its one
//  remaining production reader is the meters alarm gate (`Frame.swift`,
//  building `meters`): an old reading may still be shown, but an ALARM
//  raised on one is a red the deck can no longer vouch for, which is a fact
//  about the ALARM's own currency, not the number's.
//
// Every duration here is virtual. A test that waited 30 real seconds to
// prove a 30-second max age would be the behaviour the scheduled-clock rule
// exists to prevent, and it would be deleted within a month for being slow.
//

import Testing
import DeckCore

struct StalenessTests {

    private func hook(_ session: SessionID, at ms: Int64) -> DeckEvent {
        .hook(HookEvent(id: EventID("start-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                        kind: .sessionStart, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent))
    }

    /// The reading survives its max age and is MARKED, never silently
    /// fresh and never silently gone.
    @Test("a fed value past its max age stays on the gauge, marked stale")
    func staleValueIsMarkedNotEmptied() {
        let session = SessionID("s1")
        let feed = StatuslinePayload(session: session, contextPercent: .value(17),
                                     costUSD: .value(1.5), model: "Haiku 4.5", version: "2.1.220")
        let state = Reducer.run([hook(session, at: 0),
                                 .statusline(feed, at: Instant(sinceStart: Millis(1_000)),
                                             id: EventID("sl-1"))])

        let ages = MaxAges.proposed
        #expect(ages.contextPercent == Millis(30_000))

        func lane(atMillis ms: Int64) -> LaneView? {
            Projection.frame(from: state, at: Instant(sinceStart: Millis(ms)), maxAges: ages)
                .lanes.first
        }

        // Received at 1 s: fresh until 31 s inclusive, stale after — the
        // VALUE is identical on both sides of the boundary, which is what
        // "always visible" means; only the mark changes.
        #expect(lane(atMillis: 1_000)?.contextPercent == 17)
        #expect(lane(atMillis: 1_000)?.contextStale == false)
        #expect(lane(atMillis: 30_999)?.contextStale == false)
        #expect(lane(atMillis: 31_000)?.contextStale == false)   // exactly at the boundary
        #expect(lane(atMillis: 31_001)?.contextPercent == 17)
        #expect(lane(atMillis: 31_001)?.contextStale == true)
        #expect(lane(atMillis: 600_000)?.contextPercent == 17)
        #expect(lane(atMillis: 600_000)?.contextStale == true)

        // A shown value keeps its provenance however old it is — the frame is
        // still making the claim, so it still names the event behind it
        // (the provenance rule does not age out).
        let stale = Projection.frame(from: state, at: Instant(sinceStart: Millis(60_000)), maxAges: ages)
        #expect(stale.lanes.first?.sources["contextPercent"] == EventID("sl-1"))
        #expect(stale.unprovenancedFields.isEmpty)
    }

    /// A max age of zero would mark every reading stale immediately, which
    /// would satisfy the assertion above for the wrong reason. The policy is a
    /// value, so it is tested as one.
    @Test("the max-age policy decides the mark, not a constant")
    func maxAgeIsAPolicyValue() {
        let session = SessionID("s2")
        let feed = StatuslinePayload(session: session, contextPercent: .value(42),
                                     costUSD: .absent, model: nil, version: nil)
        let state = Reducer.run([hook(session, at: 0),
                                 .statusline(feed, at: Instant(sinceStart: .zero), id: EventID("sl-2"))])

        func stale(_ age: Int64, at ms: Int64) -> Bool? {
            Projection.frame(from: state, at: Instant(sinceStart: Millis(ms)),
                             maxAges: MaxAges(contextPercent: Millis(age)))
                .lanes.first?.contextStale
        }
        #expect(stale(30_000, at: 10_000) == false)
        #expect(stale(5_000, at: 10_000) == true)      // a shorter policy marks it sooner
        #expect(stale(60_000, at: 10_000) == false)    // a longer one keeps it fresh

        // And a lane that has NEVER been fed is not "stale" — it is empty
        // (the empty-slot rule's first clause, untouched), and the mark has
        // nothing to qualify.
        let unfed = Reducer.run([hook(SessionID("s3"), at: 0)])
        let lane = Projection.frame(from: unfed, at: Instant(sinceStart: Millis(10_000)),
                                    maxAges: .proposed).lanes.first
        #expect(lane?.contextPercent == nil)
        #expect(lane?.contextStale == false)
    }
}
