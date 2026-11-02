//
//  TranscriptBackfillTests.swift · Tests/DeckAppTests
//
//  The transcript-well backfill's own runtime-adapter laws — trigger-once,
//  never-block, deleted-session refusal, unreadable-file silence, and the
//  legitimate re-seed on delete-then-recreate — held against a SCRIPTED
//  `TranscriptFilePort`, the same "this file never touches the real
//  filesystem" discipline `FleetDiscoveryTests`'s own file doc states for
//  `RecordingWorktree`.
//
//  **Every wait in this file is deterministic — no `Task.sleep`,
//  anywhere.** Sleeping against a real clock is the
//  anti-pattern: `DeckRuntime.testClockMS`'s own doc
//  comment calls sleeping against a real clock "a race the test usually
//  wins, which is the worst kind", and every assertion here that depends
//  on the backfill's own fire-and-forget `Task` having finished now
//  `await`s `DeckRuntime.pendingTranscriptSeedTask[session]` directly —
//  that property's own doc comment states why it exists and that
//  production never reads it. `GatedTranscriptFile.waitForEntry()` is the
//  same discipline one level earlier, for the ONE test that needs to
//  observe the read having STARTED before it has finished.
//

import Testing
import Foundation
import SwiftUI
import AppKit
import DeckCore
import DeckPorts
@testable import DeckApp

/// **Every `tail(of:maxBytes:)` call, in order, against a genuinely
/// SIZE-AWARE virtual file — `RecordingWorktree`'s own shape, one door
/// over, upgraded for the backfill ladder.** `content` stands in for the
/// WHOLE file, not a canned answer handed back unconditionally: `size(of:)`
/// reports its own UTF8 byte count, and `tail(of:maxBytes:)` slices the
/// LAST `maxBytes` bytes of it, the real adapter's own exact contract
/// (`TranscriptFile.tail(of:maxBytes:)`'s own doc comment). **The earlier
/// version of this fake ignored `maxBytes` entirely and always returned
/// the same string — a real gap, found writing the ladder's own escalation
/// tests: a fake blind to the depth it was asked for cannot tell a test
/// whether a SHALLOWER rung genuinely saw fewer prompts than a deeper
/// one, which is the exact property the ladder exists to prove.** Every
/// existing caller that only ever needed one canned answer still gets
/// exactly that — a `content` shorter than every rung in the ladder
/// slices down to itself regardless of `maxBytes`, the same one-read
/// behaviour those tests already depended on.
actor RecordingTranscriptFile: TranscriptFilePort {
    struct Call: Equatable { let path: String; let maxBytes: Int }
    private(set) var calls: [Call] = []
    /// The virtual file's own content — `nil` is the SAME "could not be
    /// read at all" `TranscriptFilePort`'s own doc comment collapses
    /// every failure mode to, honoured by BOTH methods below (a file that
    /// cannot be read has no size to report either).
    private let content: String?
    /// `false` simulates `size(of:)` itself failing while `tail(of:
    /// maxBytes:)` still succeeds — a real, narrower failure mode
    /// `TranscriptFilePort`'s own doc comment names independently for the
    /// two methods (a `stat` denied while a `read` still succeeds is a
    /// real POSIX possibility, not a fabricated test case).
    private let reportsSize: Bool
    /// `nil` never fails; an `Int` fails every `tail(of:maxBytes:)` call
    /// PAST the given count — `1` means the first call succeeds and every
    /// call after it fails, simulating a file that goes unreadable
    /// MID-LADDER (a permissions change, a disk error) rather than one
    /// that was never readable at all.
    private let failTailAfterCalls: Int?

    init(content: String?, reportsSize: Bool = true, failTailAfterCalls: Int? = nil) {
        self.content = content
        self.reportsSize = reportsSize
        self.failTailAfterCalls = failTailAfterCalls
    }

    func tail(of path: String, maxBytes: Int) async -> String? {
        calls.append(Call(path: path, maxBytes: maxBytes))
        if let failTailAfterCalls, calls.count > failTailAfterCalls { return nil }
        guard let content else { return nil }
        let bytes = Array(content.utf8)
        let bound = max(0, maxBytes)
        let start = bytes.count > bound ? bytes.count - bound : 0
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    func size(of path: String) async -> Int? {
        guard reportsSize else { return nil }
        return content.map { $0.utf8.count }
    }
}

/// A read that does not finish until the test releases it — proves
/// `handle(_:)` never waits on this port, rather than merely running fast
/// enough in practice that a race never shows it.
actor GatedTranscriptFile: TranscriptFilePort {
    private(set) var askedCount = 0
    private var releaseContinuation: CheckedContinuation<String?, Never>?
    /// Resumed the instant `tail(of:maxBytes:)` is entered — what
    /// `waitForEntry()` suspends on, so a caller can know the read has
    /// STARTED without sleeping and hoping enough scheduler turns have
    /// passed.
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private let answer: String?

    init(answer: String?) { self.answer = answer }

    func tail(of path: String, maxBytes: Int) async -> String? {
        askedCount += 1
        entryContinuation?.resume()
        entryContinuation = nil
        return await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    /// **Answered promptly, never gated — `size(of:)` is not what this
    /// fake exists to test.** `neverBlocksAndUpgradesLater`'s own point is
    /// that `handle(_:)` returns before a SLOW `tail(of:maxBytes:)` ever
    /// resolves; gating `size(of:)` too would only add a second
    /// suspension point that test has no assertion for. Reporting
    /// `answer`'s own byte length keeps the ladder this fake's one caller
    /// walks down to exactly the single rung that test already expects —
    /// `answer` is short, well under the floor, so `TranscriptTail
    /// .backfillWindows(fileSize:)` clamps to one window regardless of
    /// how many rungs the raw ladder offers.
    func size(of path: String) async -> Int? {
        answer.map { $0.utf8.count }
    }

    /// Suspends until `tail(of:maxBytes:)` has been entered strictly MORE
    /// than `afterCount` times — returns immediately if it already has.
    /// The deterministic replacement for "sleep a while, then check
    /// `askedCount`". Defaulted to 0 — the ONLY value every pre-existing
    /// caller needs ("has it been entered at least once yet") — so this
    /// stays source-compatible with every call site that predates the
    /// parameter. `onePeekInFlightPerSession`'s own SECOND wait is why the
    /// parameter exists at all: `askedCount > 0` alone cannot tell a
    /// second entry apart from the first, so a caller synchronizing on the
    /// second read has to say which count it is waiting to exceed.
    func waitForEntry(afterCount: Int = 0) async {
        if askedCount > afterCount { return }
        await withCheckedContinuation { self.entryContinuation = $0 }
    }

    /// Let the pending read return. A no-op if nothing is waiting.
    func release() {
        releaseContinuation?.resume(returning: answer)
        releaseContinuation = nil
    }
}

@MainActor
struct TranscriptBackfillTests {

    private let session = SessionID("s-backfill")
    private let path = "/Users/redacted/.claude/projects/-fake/session.jsonl"

    private func hook(_ kind: HookKind, _ id: String, transcriptPath: String? = nil,
                      prompt: String? = nil) -> HookEvent {
        HookEvent(id: EventID(id), at: .start, kind: kind, session: session,
                  cwd: Redacted("/work/project"), transcriptPath: Redacted(optional: transcriptPath),
                  tool: nil, toolUseID: nil, held: .absent, prompt: Redacted(optional: prompt))
    }

    /// A real-shaped tail — one genuine human prompt, one tool-result row
    /// that must never surface — the same fixture discipline
    /// `TranscriptTailTests`'s own file doc states (authored to the
    /// verified real shape, invented content).
    private static let realShapedTail = """
        {"type":"user","message":{"role":"user","content":"fix the flaky retry test"}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}}
        """

    // ------------------------------------------------------------- trigger-once

    @Test("the file is read exactly once per session per launch, even across several hooks that all carry the path")
    func triggersExactlyOnce() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.realShapedTail)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        _ = await runtime.handle(hook(.userPromptSubmit, "p1", transcriptPath: path, prompt: "hello"))
        _ = await runtime.handle(hook(.stop, "stop1", transcriptPath: path))
        // Deterministic: only the FIRST hook ever creates a Task (the
        // second and third are already gated out by `seededTranscriptSessions`
        // BEFORE either one could create one), so awaiting the one entry
        // this session ever gets is enough to know every read that will
        // ever happen for it already has.
        await runtime.pendingTranscriptSeedTask[session]?.value

        let calls = await file.calls
        #expect(calls.count == 1,
                "expected exactly one read across three hooks that all carried the same transcriptPath, got \(calls.count)")
        #expect(calls.first?.path == path)
        // **Clamped to the FIXTURE's own size, not the floor constant
        // unconditionally — the ladder's own behaviour for a file smaller
        // than the floor, held to the SAME rule the "backfill ladder"
        // section below drives through this same seam at larger sizes.**
        // `realShapedTail` is a few hundred bytes; `TranscriptTail
        // .backfillWindows(fileSize:)` answers a SINGLE rung equal to
        // that size, so this is still exactly one read — the pre-ladder
        // assertion this test always made — at a bound the fixture's own
        // size decides, not a second, independently-drifting literal
        // restated here.
        #expect(calls.first?.maxBytes == Self.realShapedTail.utf8.count,
                Comment(rawValue: "expected the single rung clamped to the fixture's own \(Self.realShapedTail.utf8.count) "
                        + "byte size, got \(String(describing: calls.first?.maxBytes))"))
    }

    // ------------------------------------------------------------------ no-block

    @Test("handle(_:) never blocks on the file read — the well upgrades from empty to populated only once the read completes")
    func neverBlocksAndUpgradesLater() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let gate = GatedTranscriptFile(answer: Self.realShapedTail)
        runtime.transcriptFile = gate

        let start = Date()
        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0,
                "handle(_:) took \(elapsed)s to return while the file read was gated open — it must not be waiting on it")

        // Deterministic: suspends only until `tail(of:maxBytes:)` has
        // actually been ENTERED — not a guess at how long that takes.
        // The read has started but not finished, so the well must still
        // show nothing seeded yet.
        await gate.waitForEntry()
        #expect(await gate.askedCount == 1)
        #expect(runtime.frame.lanes.first { $0.session == session }?.transcript.isEmpty != false,
                "the transcript should not be populated before the gated read is released")

        await gate.release()
        // Deterministic: the seed Task's own completion, not a nap long
        // enough to (usually) cover apply(_:)/refresh() too.
        await runtime.pendingTranscriptSeedTask[session]?.value
        let texts = runtime.frame.lanes.first { $0.session == session }?.transcript.map { $0.text.value } ?? []
        #expect(texts == ["fix the flaky retry test"],
                "the well should upgrade to the seeded prompt once the read completes, tool_result excluded")
    }

    // ------------------------------------------------------------ deleted-session

    @Test("a session already deleted from the deck is never read at all")
    func deletedSessionIsNeverRead() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.realShapedTail)
        runtime.transcriptFile = file
        runtime.delete(session)   // deleted BEFORE any hook ever arrives for it

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        // No wait needed at all, deterministically: the deleted-session
        // guard in `handle(_:)` sits BEFORE the `Task {}` is ever
        // constructed, so if the guard held, nothing was scheduled and
        // there is nothing for a later moment to complete.
        #expect(runtime.pendingTranscriptSeedTask[session] == nil,
                "the fixture's own premise: no Task should ever have been created for a deleted session")

        #expect(await file.calls.isEmpty,
                "a deleted session's own transcript file must never be opened")
        #expect(runtime.frame.lanes.first { $0.session == session } == nil,
                "the fixture's own premise: DeckCore's own no-trace-for-a-deleted-session rule keeps the lane from existing at all")
    }

    // -------------------------------------------------------- unreadable file

    @Test("a missing or unreadable file seeds nothing, silently — no crash, no partial state")
    func unreadableFileSeedsNothingSilently() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: nil)   // TranscriptFilePort's own "could not read at all" case
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value

        #expect(await file.calls.count == 1, "the read should still have been ATTEMPTED")
        #expect(runtime.frame.lanes.first { $0.session == session }?.transcript.isEmpty != false,
                "an unreadable file must seed nothing — the well's own empty state already says the honest thing")
    }

    // ---------------------------------------------------- delete, then re-created

    @Test("a session deleted mid-launch does not walk back in through the very next hook")
    func deletedSessionDoesNotWalkBackInImmediately() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.realShapedTail)
        runtime.transcriptFile = file

        // First life: seeded once.
        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value
        #expect(await file.calls.count == 1)
        #expect(runtime.frame.lanes.first { $0.session == session }?.transcript.isEmpty == false)

        // The person removes it from the deck.
        runtime.delete(session)
        #expect(runtime.frame.lanes.first { $0.session == session } == nil)

        // **The SAME still-running session speaking again, RIGHT AWAY, does
        // NOT come back — verified, not assumed.** `collectTombstones`'s
        // own doc comment states the design in full: "a deleted id is
        // remembered so the session cannot walk back in through the next
        // hook" — `DeckState.apply(_:HookEvent)`'s own `prefs.deleted`
        // guard refuses EVERY hook for this exact id until the tombstone
        // is pruned (`tombstoneMisses` consecutive fleet polls confirming
        // it is truly gone). This is the anti-leak protection working as
        // designed, not a bug this test is proving around. No wait is
        // needed here either: the guard that refuses this hook is
        // `DeckState.apply(_:HookEvent)`'s own, which runs SYNCHRONOUSLY
        // inside `handle(_:)` before this adapter's own trigger is even
        // reached — nothing async is in flight to wait for.
        _ = await runtime.handle(hook(.sessionStart, "start-again", transcriptPath: path))
        // `file.calls.count == 1` (not 2) is itself the proof no second
        // `Task` ever ran `seedTranscript` — a stronger, more direct
        // check than inspecting `pendingTranscriptSeedTask` for a
        // same-or-different `Task` reference would be, and it needs no
        // wait either: the guard that refuses this hook is `DeckState
        // .apply(_:HookEvent)`'s own, running SYNCHRONOUSLY inside
        // `handle(_:)` before this adapter's own trigger is even
        // reached, so there is nothing async in flight to wait for.
        #expect(await file.calls.count == 1,
                "a session's tombstone must still block it immediately after delete — it must not walk back in through the next hook")
        #expect(runtime.frame.lanes.first { $0.session == session } == nil)
    }

    /// **The scenario `delete(_:)`'s own doc comment on `seededTranscriptSessions`
    /// actually describes — reached the way production reaches it, through
    /// the real tombstone lifecycle, not skipped past it.** A session's
    /// tombstone is pruned once the fleet has confirmed it missing for
    /// `DeckRuntime.tombstoneMisses` consecutive polls — the SAME
    /// `resolvedCwd`/`unplaceable` cleanup `delete(_:)` already does for
    /// the identical reason (`resolvedCwd`'s own doc comment: "a session
    /// that comes BACK... would otherwise find its directory already
    /// marked resolved"). Once pruned, `prefs.deleted` no longer refuses
    /// this id, and a fresh hook opens a genuinely NEW `LaneRecord` with
    /// `transcriptSeeded == false` — this is where the adapter-level set
    /// forgetting the session at delete time actually matters: without
    /// it, THIS lane would go on showing an empty well forever even
    /// though its own transcript file never stopped being exactly as
    /// readable as it was the first time.
    @Test("once a session's tombstone is pruned by the real fleet lifecycle, it is legitimately re-seedable")
    func reSeedableAfterTombstonePruning() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.realShapedTail)
        runtime.transcriptFile = file
        let other = SessionID("s-other")
        runtime.fleet = ScriptedFleet([[FleetRow(session: other, name: "other", kind: "interactive",
                                                  state: .absent, status: .value("idle"),
                                                  pid: nil, cwd: "/w/other")]])

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value
        #expect(await file.calls.count == 1)
        runtime.delete(session)

        // `tombstoneMisses` consecutive polls, NONE of which list `session`
        // — a non-empty roster missing this one id each time, the exact
        // shape `collectTombstones`'s own doc comment requires ("only
        // after the id has been missing for several consecutive polls").
        // `pollFleet()` is already a real `await`, no sleep involved.
        for _ in 0..<DeckRuntime.tombstoneMisses {
            await runtime.pollFleet()
        }

        _ = await runtime.handle(hook(.sessionStart, "start-again", transcriptPath: path))
        // Deterministic: the SAME dictionary key now holds the SECOND
        // Task (the trigger reassigns it) — awaiting it directly proves
        // the re-seed completed, no matter how long the scheduler took.
        await runtime.pendingTranscriptSeedTask[session]?.value
        #expect(await file.calls.count == 2,
                "once the tombstone is genuinely pruned, the re-created lane should be re-seeded")
        #expect(runtime.frame.lanes.first { $0.session == session }?.transcript.isEmpty == false)
    }

    // --------------------------------------------------- no transcriptPath at all

    @Test("a hook carrying no transcriptPath triggers no read")
    func noTranscriptPathTriggersNoRead() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.realShapedTail)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: nil))
        // No wait needed: `transcriptPath == nil` fails the trigger's own
        // `if let` before any `Task` is constructed.
        #expect(runtime.pendingTranscriptSeedTask[session] == nil)

        #expect(await file.calls.isEmpty)
    }

    // ------------------------------------------------------------ backfill ladder
    //
    // **The regression, driven through the real `handle(_:)`/`seedTranscript`
    // seam, not just the pure `TranscriptTail.backfillWindows(fileSize:)`
    // table (`TranscriptTailTests` holds that half accountable on its
    // own).** Every fixture below is built so a SHALLOWER rung's own tail
    // genuinely contains fewer prompts than a deeper one — `RecordingTranscriptFile`'s
    // own doc comment states why that depends on the fake actually slicing
    // by `maxBytes`, not merely accepting one regardless of depth.

    /// An inert padding row — a `tool_result` turn, never counted as a
    /// prompt (`TranscriptTail`'s own file doc: 7,018 of 7,700+ real rows
    /// took exactly this shape) — used here purely to push a fixture's own
    /// TOTAL byte size past a rung boundary, the same real shape a busy
    /// session's own subagent output takes.
    private static let paddingRow =
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok","is_error":false}]}}"# + "\n"

    /// A genuine, tiny human prompt row, parameterised so a fixture can
    /// place several distinct ones without hand-typing each.
    private static func promptRow(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":""# + text + #""}}"# + "\n"
    }

    /// `paddingRow`, repeated enough times to reach AT LEAST `minBytes` —
    /// a cheap way to build a fixture whose own byte size crosses a
    /// specific rung boundary without hand-typing kilobytes of JSON. May
    /// overshoot by up to one row's own width; every test below reads the
    /// fixture's OWN `.utf8.count` back rather than assuming an exact
    /// total, so the overshoot never has to be accounted for by hand.
    private static func padding(minBytes: Int) -> String {
        guard minBytes > 0 else { return "" }
        let rowBytes = paddingRow.utf8.count
        let rows = (minBytes / rowBytes) + 1
        return String(repeating: paddingRow, count: rows)
    }

    @Test("the floor rung alone finds the cap's worth of prompts — exactly ONE read")
    func floorRungAloneSatisfiesTheCapInOneRead() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let prompts = (0..<LaneRecord.historyCap).map { Self.promptRow("prompt \($0)") }.joined()
        // Padding BEFORE the prompts pushes the file's own TOTAL size past
        // the floor, so the ladder genuinely offers a second, deeper rung
        // — proving the loop stopped at the floor by CHOICE (the cap was
        // already met there), not because a second rung was never on offer.
        let content = Self.padding(minBytes: DeckRuntime.transcriptTailFloorBytes + 50_000) + prompts
        let file = RecordingTranscriptFile(content: content)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value

        let calls = await file.calls
        #expect(calls.map(\.maxBytes) == [DeckRuntime.transcriptTailFloorBytes],
                Comment(rawValue: "expected exactly one read at the floor rung, got \(calls.map(\.maxBytes))"))
        let texts = runtime.frame.lanes.first { $0.session == session }?.transcript.map { $0.text.value } ?? []
        #expect(texts.count == LaneRecord.historyCap,
                Comment(rawValue: "expected the cap's worth seeded from the floor rung alone, got \(texts.count)"))
    }

    @Test("the floor rung finds nothing, the second rung finds enough — exactly TWO reads, ascending bounds")
    func floorRungEmptySecondRungFindsPrompts() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let prompts = (0..<3).map { Self.promptRow("prompt \($0)") }.joined()
        // Prompts sit at the FRONT; padding AFTER them pushes the file
        // past the floor, so the LAST floor-bytes are padding alone —
        // zero prompts — and only a deeper rung reaches back far enough
        // to see them.
        let content = prompts + Self.padding(minBytes: DeckRuntime.transcriptTailFloorBytes + 50_000)
        let file = RecordingTranscriptFile(content: content)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value

        let calls = await file.calls
        let totalSize = content.utf8.count
        #expect(calls.map(\.maxBytes) == [DeckRuntime.transcriptTailFloorBytes, totalSize],
                Comment(rawValue: "expected the floor rung then the whole-file rung, ascending, got \(calls.map(\.maxBytes))"))
        let texts = runtime.frame.lanes.first { $0.session == session }?.transcript.map { $0.text.value } ?? []
        #expect(texts.count == 3,
                Comment(rawValue: "expected the 3 prompts seeded from the second rung, got \(texts.count)"))
    }

    @Test("a file smaller than the floor, with fewer prompts than the cap — one read, clamped, seeds honestly fewer than the cap")
    func tinyFileSeedsFewerThanCapHonestly() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let content = (0..<3).map { Self.promptRow("prompt \($0)") }.joined()
        #expect(content.utf8.count < DeckRuntime.transcriptTailFloorBytes,
                "the fixture's own premise: smaller than the floor")
        let file = RecordingTranscriptFile(content: content)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value

        let calls = await file.calls
        #expect(calls.map(\.maxBytes) == [content.utf8.count],
                Comment(rawValue: "expected one read clamped to the file's own size, got \(calls.map(\.maxBytes))"))
        let texts = runtime.frame.lanes.first { $0.session == session }?.transcript.map { $0.text.value } ?? []
        #expect(texts.count == 3,
                "fewer than the cap is the honest answer for a file this small — seeding 3 rather than padding to 8")
    }

    @Test("prompts surface only once the ladder reaches the whole-file rung — it walks there and stops")
    func promptsSurfaceOnlyAtTheWholeFileRung() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let prompts = (0..<2).map { Self.promptRow("deep prompt \($0)") }.joined()
        // A THIRD rung, past the floor AND the second rung (2MB) — proving
        // the ladder walks MULTIPLE empty rungs, not just one, before it
        // ever finds anything, and stops exactly at the rung that
        // finally covers the whole file rather than continuing past it.
        let targetSize = 2_150_000
        let content = prompts + Self.padding(minBytes: targetSize - prompts.utf8.count)
        #expect(content.utf8.count > DeckRuntime.transcriptTailFloorBytes * 8,
                "the fixture's own premise: past the second rung (2MB), needing a third")
        let file = RecordingTranscriptFile(content: content)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value

        let calls = await file.calls
        let totalSize = content.utf8.count
        let expectedRungs = [DeckRuntime.transcriptTailFloorBytes, DeckRuntime.transcriptTailFloorBytes * 8, totalSize]
        #expect(calls.map(\.maxBytes) == expectedRungs,
                Comment(rawValue: "expected the ladder to walk the floor, the second rung, then stop AT the "
                        + "whole file, got \(calls.map(\.maxBytes)), expected \(expectedRungs)"))
        let texts = runtime.frame.lanes.first { $0.session == session }?.transcript.map { $0.text.value } ?? []
        #expect(texts.count == 2,
                "the deep prompts should surface only once the whole file was read")
    }

    @Test("an unreadable read partway down the ladder notes the failure and seeds nothing — no partial seed from an earlier rung")
    func unreadableMidLadderNotesAndSeedsNothing() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        // The floor rung SUCCEEDS and finds something — fewer than the
        // cap, so the ladder escalates — proving the earlier round's own
        // few prompts are genuinely DISCARDED, not merely never reached,
        // once the deeper read fails.
        let prompts = (0..<2).map { Self.promptRow("prompt \($0)") }.joined()
        let content = Self.padding(minBytes: DeckRuntime.transcriptTailFloorBytes + 50_000) + prompts
        let file = RecordingTranscriptFile(content: content, failTailAfterCalls: 1)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value

        let calls = await file.calls
        #expect(calls.count == 2,
                "expected the floor rung to succeed (and find too few), then the second rung to be attempted and fail")
        #expect(runtime.frame.lanes.first { $0.session == session }?.transcript.isEmpty != false,
                "a failed deeper read must seed NOTHING, not the shallower round's own few prompts")

        let logged = (try? String(contentsOfFile: runtime.logPathForTesting, encoding: .utf8)) ?? ""
        #expect(logged.contains("transcript backfill: file unreadable for \(session.raw)"),
                "the failure should still be noted, the same line unreadableFileSeedsNothingSilently already holds accountable")
    }

    @Test("size(of:) returning nil still seeds — the un-clamped ladder, tail(of:maxBytes:) alone carries the read")
    func unknownSizeStillSeedsViaTheUnclampedLadder() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let content = (0..<LaneRecord.historyCap).map { Self.promptRow("prompt \($0)") }.joined()
        let file = RecordingTranscriptFile(content: content, reportsSize: false)
        runtime.transcriptFile = file

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value

        let calls = await file.calls
        // The RAW floor value, not a size-derived clamp — proof the
        // un-clamped ladder was used (a known, small size would have
        // clamped this to `content.utf8.count` instead, the exact shape
        // `tinyFileSeedsFewerThanCapHonestly` above holds accountable).
        #expect(calls.map(\.maxBytes) == [DeckRuntime.transcriptTailFloorBytes],
                Comment(rawValue: "expected the raw, un-clamped floor rung with an unknown size, got \(calls.map(\.maxBytes))"))
        let texts = runtime.frame.lanes.first { $0.session == session }?.transcript.map { $0.text.value } ?? []
        #expect(texts.count == LaneRecord.historyCap,
                "the cap's worth should still seed with no known file size, off the un-clamped floor rung alone")
    }

    // ------------------------------------------------------------ end to end

    /// `measured(_:width:)`'s own twin in `RenderSweepTests.swift` — that
    /// one is `private` to its own suite, so this file carries its own
    /// copy rather than widen that file's own surface for one caller
    /// outside it. Identical technique: a plain `fittingSize` read, not
    /// the enforced-minimum one `measuredMinimum(_:)` there uses.
    private func measured(_ view: some View, width: Double) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// **The full path, end to end — a mocked file seam standing in for a
    /// real disk, everything else exactly as the live deck runs it.** A
    /// hook arrives carrying a `transcriptPath`, the adapter reads it
    /// (through the port, never the real filesystem), the reducer seeds
    /// the lane, the session is selected, and `TranscriptWell` — the same
    /// component a real strip renders — draws the result. This is the
    /// "fresh launch shows real history" contract
    /// `detailBandNeverDemandsHeight`'s own sibling tests in
    /// `RenderSweepTests.swift` hold `DetailBand` to for a LIVE transcript;
    /// this is its backfill-sourced twin.
    @Test("a fresh launch, a rich-history session: the well renders the seeded prompts, tool_result excluded")
    func endToEndBackfillRendersInTheWell() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let richTail = """
            {"type":"user","message":{"role":"user","content":"set up the project's own CI config"}}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done","is_error":false}]}}
            {"type":"user","message":{"role":"user","content":"now add a release workflow too"}}
            """
        runtime.transcriptFile = RecordingTranscriptFile(content: richTail)

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        // Deterministic: the seed Task's own completion — the SAME
        // property `neverBlocksAndUpgradesLater` above awaits directly,
        // not a nap sized to (usually) outlast it.
        await runtime.pendingTranscriptSeedTask[session]?.value

        runtime.select(session)
        #expect(runtime.frame.selection == session)
        guard let lane = runtime.frame.lanes.first(where: { $0.session == session }) else {
            Issue.record("the fixture's own premise: a selected lane to build the well for")
            return
        }

        // `LaneView.transcript` (the PROJECTED ledger `TranscriptWell`
        // actually renders from) is OLDEST first — `Frame.swift`'s own
        // doc comment on the field states the projection reverses the
        // stored, newest-first `LaneRecord.transcript` for exactly this
        // reason. Do not confuse the two: `TranscriptSeedTests`'s own
        // reducer-level assertions read the STORED order deliberately;
        // this is the rendered one.
        #expect(lane.transcript.map { $0.text.value } == ["set up the project's own CI config",
                                                           "now add a release workflow too"],
                "the well should show both seeded prompts, oldest first, the tool_result row excluded")
        #expect(lane.transcript.allSatisfy { $0.origin == .terminal && $0.deckStatus == nil },
                "seeded rows are .terminal with no deckStatus — a deck send in the file is indistinguishable from typed bytes")

        let size = measured(TranscriptWell(lane: lane, runtime: runtime, maxHeight: 200), width: 380)
        #expect(size.height > 0, "the well renders as nothing for a real, non-empty seeded transcript")
    }

    // -------------------------------------------------------- api-error peek
    //
    // **`DeckRuntime`'s own trigger for `TranscriptTail.apiErrorLastWord
    // (fromJSONL:)` — riding the SAME five hook kinds the backfill's own
    // doc comment on the scheduling site names, never a watcher or a
    // timer.** Every fixture below shares `session`/`path` with the
    // suite above; the transcript-SEED trigger above has NO kind
    // restriction at all (it fires on the FIRST hook carrying a
    // `transcriptPath`, whichever kind that happens to be), so it also
    // fires alongside the api-error peek in most of these fixtures —
    // `warmUpTheSeed()` below consumes that one-shot gate FIRST, on a
    // hook kind the peek itself never triggers on, so every assertion
    // that follows reads `file.calls` free of the seed's own, unrelated
    // reads.

    /// The 529 specimen, the identical string `TranscriptTailTests`/
    /// `ApiErrorTests` already pin — Claude Code's own product copy, fine
    /// to carry verbatim.
    private static let overloadedText =
        "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. "
        + "If it persists, check https://status.claude.com."

    /// A transcript tail whose own last word IS an API error — the same
    /// hand-authored-to-shape discipline `TranscriptTailTests`'s own file
    /// doc states, modeled on the probe's own recorded row.
    private static let errorShapedTail = """
        {"type":"assistant","isSidechain":false,"message":{"role":"assistant","model":"<synthetic>",\
        "content":[{"type":"text","text":"\(overloadedText)"}]},"error":"server_error",\
        "isApiErrorMessage":true,"timestamp":"2026-08-13T16:00:00.000Z"}
        """

    /// Consumes the transcript-seed's own one-shot-per-session gate on a
    /// hook kind the api-error peek never triggers on (`.preToolUse`), so
    /// every test below can read `file.calls` afterward and see ONLY the
    /// peek's own reads — never the seed's unrelated one, riding the same
    /// port. Returns the `calls` count at the moment this returns, so a
    /// caller can assert against the DELTA rather than an absolute count.
    private func warmUpTheSeed(_ runtime: DeckRuntime, file: RecordingTranscriptFile) async -> Int {
        runtime.transcriptFile = file
        _ = await runtime.handle(hook(.preToolUse, "warmup", transcriptPath: path))
        await runtime.pendingTranscriptSeedTask[session]?.value
        return await file.calls.count
    }

    @Test("each of the five trigger kinds spawns exactly one peek read at backfillFloorBytes; the three mid-turn hooks spawn none",
          arguments: [(HookKind.sessionStart, true), (.userPromptSubmit, true), (.notification, true),
                      (.stop, true), (.sessionEnd, true),
                      (.preToolUse, false), (.postToolUse, false), (.permissionRequest, false)])
    func triggerKindsMatchTheDesignedSet(_ kind: HookKind, _ expectsAPeek: Bool) async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.errorShapedTail)
        // Both properties point at the SAME double — `apiErrorTranscriptFile`'s
        // own doc comment (`DeckRuntime.swift`) states why the two are
        // separate properties in the first place (so every OTHER fixture
        // in this file, which sets only `transcriptFile`, never sees an
        // uninvited second reader); this fixture wants to see both.
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        let baseline = await warmUpTheSeed(runtime, file: file)

        _ = await runtime.handle(hook(kind, "trigger", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value

        let newCalls = Array((await file.calls).dropFirst(baseline))
        #expect(newCalls.count == (expectsAPeek ? 1 : 0),
                Comment(rawValue: "\(kind) expected \(expectsAPeek ? 1 : 0) peek read(s), got \(newCalls.count)"))
        if expectsAPeek {
            #expect(newCalls.first?.maxBytes == DeckRuntime.transcriptTailFloorBytes,
                    Comment(rawValue: "expected the single floor-rung read, got \(String(describing: newCalls.first?.maxBytes))"))
        }
    }

    @Test("one peek in flight per session — a second trigger arriving mid-read spawns no second one")
    func onePeekInFlightPerSession() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        // The seed's own gate is a SEPARATE double from the peek's —
        // `apiErrorTranscriptFile`'s own doc comment states why sharing
        // one here would leak the seed's warmup call into `gate`'s single
        // continuation slot, unresumed, since nothing in this fixture
        // ever calls `release()` for a call the seed itself made.
        _ = await warmUpTheSeed(runtime, file: RecordingTranscriptFile(content: Self.errorShapedTail))
        let gate = GatedTranscriptFile(answer: Self.errorShapedTail)
        runtime.apiErrorTranscriptFile = gate

        _ = await runtime.handle(hook(.sessionStart, "first", transcriptPath: path))
        await gate.waitForEntry()
        #expect(await gate.askedCount == 1)

        // A second trigger kind, arriving while the first peek is still
        // gated open — the in-flight guard must refuse to schedule a
        // second read for the SAME session.
        _ = await runtime.handle(hook(.stop, "second", transcriptPath: path))
        #expect(await gate.askedCount == 1,
                "a peek already in flight for this session must not be joined by a second one")

        await gate.release()
        await runtime.pendingApiErrorPeekTask[session]?.value

        // Now that the first has completed (and removed itself), a THIRD
        // trigger legitimately schedules a fresh one — the guard is
        // "one in flight," never "once ever" the way the seed's own is.
        // `GatedTranscriptFile` gates EVERY `tail(of:maxBytes:)` call, not
        // only its first — this second read needs its own
        // `waitForEntry(afterCount:)`/`release()` cycle, or its own
        // `tail()` suspends forever on a continuation nothing ever resumes.
        _ = await runtime.handle(hook(.sessionEnd, "third", transcriptPath: path))
        await gate.waitForEntry(afterCount: 1)
        #expect(await gate.askedCount == 2,
                "once the first peek finished, a later trigger must be free to schedule its own")
        await gate.release()
        await runtime.pendingApiErrorPeekTask[session]?.value
    }

    /// **HISTORY, kept as the evidence rather than deleted now that it is
    /// resolved.** The provenance rule stamps a peek with its OWN trigger
    /// hook's `(at, id)` — and that SAME hook's own synchronous `apply
    /// (.hook(arrived))` (which runs FIRST, before the async peek ever
    /// resolves) already writes `lane.stateDecidedAt`/`stateSource` to
    /// that IDENTICAL pair whenever `transition(on:)` returns non-nil for
    /// it. Writing this feature, that made `SessionStart`'s own peek tie
    /// its own `.idle` write and LOSE, deterministically, every time —
    /// the identical shape held for `UserPromptSubmit`, `Stop` and
    /// `SessionEnd` (all four ALWAYS write non-nil) and for `Notification`
    /// whenever its own type was `idle_prompt` or `permission_prompt` —
    /// which directly contradicted the design's own stated latency claim
    /// ("Worst-case latency is the 60s `idle_prompt` notification"): an
    /// `idle_prompt` Notification's `transition(on:)` returns `.idle`
    /// (non-nil), so by the SAME mechanism its own peek tied and lost
    /// too, and the error never reached the lane through the one hook
    /// the design names as the usual bearer.
    ///
    /// **RESOLVED — `DeckState`'s own `.apiError` case handler now carries
    /// a refined guard, argued in full there:** a tie against the SAME
    /// hook that triggered the peek still loses UNLESS that hook's own
    /// anchor is `.idle` — a verdict reached out of silence, which is
    /// exactly what the transcript peek exists to supply the WHY of.
    /// `SessionStart`'s own peek below now WINS the tie it used to lose;
    /// `ApiErrorTests.tiedPeekLosesToItsOwnTriggeringHook` (UserPromptSubmit,
    /// `.working`) and `.tiedPeekAgainstOwnEndedTriggerLoses` (SessionEnd,
    /// `.ended`) are the reducer-level receipts that the OTHER three
    /// trigger kinds' own ties still lose, unchanged — only `.idle` was
    /// ever the gap.
    @Test("a SessionStart's own peek REFINES the idle it wrote — the historical gap, now resolved")
    func sessionStartsOwnPeekRefinesTheIdleItWrote() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.errorShapedTail)
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        _ = await warmUpTheSeed(runtime, file: file)

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value

        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane?.state == .errored,
                "SessionStart's own transition anchor is .idle — a guess out of silence — and its own peek must refine it, not tie-and-lose against it")
        #expect(lane?.apiError?.value == Self.overloadedText)
    }

    /// **The exact fact-2 shape, end to end through the real runtime —
    /// the design's own worst-case-latency bearer, not the simplest
    /// possible trigger.** `SessionStart` opens the lane; nothing else
    /// ever happens (the live probe's own recorded silence); a
    /// `Notification` carrying `idle_prompt` arrives 60 seconds later —
    /// the SAME shape `ApiErrorTests.idlePromptsOwnPeekRefinesTheIdleItWrote`
    /// holds at the reducer level, exercised here through the WHOLE path:
    /// the trigger-set gate, the scheduled `Task`, the port read, the
    /// parse, and the projected `LaneView` a real strip would draw from.
    @Test("a found error applies .apiError through the idle_prompt bearer, end to end — the lane goes errored, the view carries the text")
    func foundErrorAppliesApiErrorEvent() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        // Silence first — the fixture's own premise, matching fact 2's
        // live probe: `SessionStart` opens the lane and its OWN peek
        // (the SAME error-content double is not yet handed to it) finds
        // no error at all, exactly as a real, healthy session start
        // would. `apiErrorTranscriptFile` is reassigned BELOW, between
        // the two hooks — the port a real disk read would see the error
        // land on only once the turn actually dies, seconds later.
        let cleanFile = RecordingTranscriptFile(content: Self.realShapedTail)
        runtime.transcriptFile = cleanFile
        runtime.apiErrorTranscriptFile = cleanFile
        _ = await warmUpTheSeed(runtime, file: cleanFile)

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value
        #expect(runtime.frame.lanes.first { $0.session == session }?.state == .idle,
                "the fixture's own premise: SessionStart's own peek finds nothing yet — silence, per fact 2")

        // The turn dies; the file now carries the synthetic error row.
        // A `Notification` carrying `idle_prompt` — fact 2's own recorded
        // bearer, 60 real seconds later — is the next hook this session
        // ever sends.
        runtime.apiErrorTranscriptFile = RecordingTranscriptFile(content: Self.errorShapedTail)
        let notification = HookEvent(id: EventID("notif1"), at: .start, kind: .notification, session: session,
                                     cwd: Redacted("/work/project"), transcriptPath: Redacted(path),
                                     tool: nil, toolUseID: nil, held: .absent,
                                     notificationType: "idle_prompt")
        _ = await runtime.handle(notification)
        await runtime.pendingApiErrorPeekTask[session]?.value

        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane?.state == .errored,
                "idle_prompt's own transition write (.idle, a guess out of silence) must be refined by its own peek")
        #expect(lane?.apiError?.value == Self.overloadedText,
                Comment(rawValue: "expected the verbatim 529 specimen, got \(String(describing: lane?.apiError?.value))"))
    }

    @Test("a tail with no error applies nothing — the lane keeps whatever the hook itself decided")
    func nilParseAppliesNothing() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.realShapedTail)
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        _ = await warmUpTheSeed(runtime, file: file)

        _ = await runtime.handle(hook(.sessionStart, "start", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value

        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane?.state == .idle, "SessionStart's own transition, undisturbed by a peek that found nothing")
        #expect(lane?.apiError == nil)
    }

    // ------------------------------------------------- the recap, same read
    //
    // The peek's SECOND product (`DeckRuntime.peekTranscript`'s own doc
    // comment states why one read serves both). These hold the wiring
    // accountable — that a recap in the window reaches the ledger, that
    // it does so without a second file read, and that neither product
    // can suppress the other.

    /// A recap row at the shape counted out of the real corpus
    /// (`TranscriptTail.swift`'s own recap section carries the count and
    /// the versions); the summary wording is invented, per this file's
    /// own fixture doctrine.
    private static let recapText = "Goal was wiring the session recap into the transcript well; the parser and the peek are both green."
    private static let recapShapedTail = """
        {"type":"system","subtype":"away_summary","content":"\(recapText)",\
        "timestamp":"2026-08-18T02:10:22.343Z","isSidechain":false,"version":"2.1.251"}
        """

    @Test("a recap in the peek's own window reaches the ledger, as its own origin")
    func recapReachesTheLedger() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.recapShapedTail)
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        _ = await warmUpTheSeed(runtime, file: file)

        _ = await runtime.handle(hook(.stop, "done", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value

        let transcript = runtime.frame.lanes.first { $0.session == session }?.transcript ?? []
        let recaps = transcript.filter { $0.origin == .recap }
        #expect(recaps.count == 1)
        #expect(recaps.first?.text.value == Self.recapText)
        #expect(recaps.first?.deckStatus == nil, "a recap is nobody's send — it carries no send ledger")
    }

    @Test("the SAME recap re-found on a second peek is not a second row")
    func recapIsIdempotentAcrossPeeks() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.recapShapedTail)
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        _ = await warmUpTheSeed(runtime, file: file)

        // Three separate triggers over an unchanged file — the ORDINARY
        // shape, since the peek fires on five hook kinds and a recap
        // stays in the window until the conversation moves past it.
        for kind in [HookKind.stop, .sessionStart, .userPromptSubmit] {
            _ = await runtime.handle(hook(kind, "trigger", transcriptPath: path))
            await runtime.pendingApiErrorPeekTask[session]?.value
        }

        let transcript = runtime.frame.lanes.first { $0.session == session }?.transcript ?? []
        #expect(transcript.filter { $0.origin == .recap }.count == 1,
                "the recap's own timestamp-derived (at, id) is what makes re-finding it a no-op rather than a duplicate row")
    }

    @Test("the recap costs no second file read — one tail serves both products")
    func recapAddsNoSecondRead() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        // A tail carrying BOTH an error row and a recap row, so both
        // parsers have something to find off the one read.
        let file = RecordingTranscriptFile(content: Self.errorShapedTail + "\n" + Self.recapShapedTail)
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        let baseline = await warmUpTheSeed(runtime, file: file)

        _ = await runtime.handle(hook(.stop, "done", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value

        let newCalls = Array((await file.calls).dropFirst(baseline))
        #expect(newCalls.count == 1,
                Comment(rawValue: "two products must ride ONE read; got \(newCalls.count) reads"))

        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane?.apiError?.value == Self.overloadedText, "the error still lands")
        #expect(lane?.transcript.contains { $0.origin == .recap } == true, "and so does the recap")
    }

    @Test("a tail with a recap but no error still yields the recap — the ordinary case, where nothing has gone wrong")
    func recapSurvivesTheAbsenceOfAnError() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: Self.recapShapedTail)
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        _ = await warmUpTheSeed(runtime, file: file)

        _ = await runtime.handle(hook(.stop, "done", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value

        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane?.apiError == nil)
        #expect(lane?.transcript.contains { $0.origin == .recap } == true,
                "an early return on the error parse would have made the recap unreachable in every healthy session")
    }

    @Test("a recap whose timestamp cannot be placed is dropped, never dated to now")
    func unplaceableRecapIsDropped() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let file = RecordingTranscriptFile(content: """
            {"type":"system","subtype":"away_summary","content":"a summary with an unparseable moment",\
            "timestamp":"last Tuesday","isSidechain":false}
            """)
        runtime.transcriptFile = file
        runtime.apiErrorTranscriptFile = file
        _ = await warmUpTheSeed(runtime, file: file)

        _ = await runtime.handle(hook(.stop, "done", transcriptPath: path))
        await runtime.pendingApiErrorPeekTask[session]?.value

        let transcript = runtime.frame.lanes.first { $0.session == session }?.transcript ?? []
        #expect(transcript.contains { $0.origin == .recap } == false,
                "dating an undateable summary to now would make an arbitrarily old one read as current")
    }
}
