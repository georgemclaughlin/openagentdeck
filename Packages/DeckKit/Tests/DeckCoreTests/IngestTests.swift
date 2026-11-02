//
//  IngestTests.swift · Tests/DeckCoreTests
//
//  Ingest: the wire's bytes become events, and events become a deck.
//

import Testing
import DeckCore

struct IngestTests {

    /// Every recorded row decodes to a value; nothing throws.
    @Test("every recorded row decodes, including the five with no payload but `raw`")
    func everyRecordedRowDecodes() {
        let rows = Corpus.events
        #expect(rows.count == 158)

        let base = HookIngest.epochBase(rows: rows)
        #expect(base != nil)

        // The 5 `unknown` rows carry `{raw: …}` and no session, so they
        // decode to nil — which is a *value*, not a throw, and is the
        // no-synthesised-lane rule refusing to invent a lane rather than a
        // decoder giving up.
        let decoded = rows.compactMap { HookIngest.event(from: $0, epochBase: base!) }
        #expect(decoded.count == 153)
        #expect(rows.count - decoded.count == 5)
    }

    /// Unknown is not error, for arbitrary strings.
    ///
    /// Generative rather than an example list, because the whole point is the
    /// values nobody has seen. An example list tests the author's imagination.
    @Test("an unrecognised hook name is a value, never an error")
    func unknownHookKindIsNotAnError() {
        let known = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                     "Notification", "Stop", "SessionEnd"]
        for name in known { #expect(HookKind(name: name).isRecognised) }

        let unforeseen = ["", " ", "PreCompact", "SessionResume", "preToolUse", "PRETOOLUSE",
                          "Notification ", "🙂", "\u{0}", String(repeating: "x", count: 4096),
                          "SubagentStop", "PreToolUse\n"]
        for name in unforeseen {
            let kind = HookKind(name: name)
            #expect(kind == .unrecognised(name), "\(name.debugDescription) was not held as unrecognised")
            #expect(!kind.isRecognised)
        }
    }

    /// `notification_type` decodes off the payload's own field, and only
    /// means something where the wire actually sends it.
    @Test("notification_type decodes for Notification rows and nowhere else")
    func notificationTypeDecodes() {
        let rows = Corpus.events
        let base = HookIngest.epochBase(rows: rows)!
        let events = rows.compactMap { HookIngest.event(from: $0, epochBase: base) }

        let notifications = events.filter { $0.kind == .notification }
        #expect(!notifications.isEmpty, "the corpus lost its Notification rows")
        #expect(notifications.allSatisfy { $0.notificationType == "idle_prompt" },
                Comment(rawValue: "recorded types: \(notifications.map(\.notificationType))"))

        // Every other kind carries no notification_type — the corpus never
        // sends the key outside a Notification payload, so a decoder that
        // read it unconditionally would still show nothing for the rest.
        #expect(events.filter { $0.kind != .notification }
            .allSatisfy { $0.notificationType == nil })
    }

    /// `permission_suggestions` decodes VERBATIM — Claude Code's own option
    /// 2, "Yes, and don't ask again for: X", recorded on `LVV-permission`'s
    /// `PermissionRequest` row. `HookEvent.permissionSuggestions` carries a
    /// raw `JSONValue` rather than a typed array by design (see its own doc
    /// comment), so this checks only that the bytes arrive unchanged — no
    /// reader here picks them apart; that is `SuggestionLabel`'s job, tested
    /// separately.
    @Test("permission_suggestions decodes verbatim off the recorded PermissionRequest")
    func permissionSuggestionsDecodeVerbatim() {
        let events = Corpus.permissionRun()
        guard let request = events.first(where: { $0.kind == .permissionRequest }) else {
            Issue.record("the fixture lost its PermissionRequest row"); return
        }
        let expected = JSONValue.parse(
            #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"}]"#)
        #expect(request.permissionSuggestions == expected)

        // A row that never carried one decodes to nil, not an empty array —
        // absent and empty are different facts, the same distinction `Fed`
        // draws for every other field this ingest layer reads.
        let preToolUse = events.first { $0.kind == .preToolUse }
        #expect(preToolUse?.permissionSuggestions == nil)
    }

    /// `questions` decodes `preview`, and `rawQuestions` carries the
    /// untouched wire array beside it — the raw-passthrough doctrine
    /// `permission_suggestions` established (`permissionSuggestionsDecodeVerbatim`
    /// above), applied to `AskUserQuestion`'s own payload. No fixture in
    /// this corpus carries `preview` or `multiSelect: true` (all eight
    /// recorded calls predate both), so this is synthesised — the one place
    /// this reader is not exercised by a recording. `futureKey` on the
    /// option proves "verbatim" means the whole object survives, not just
    /// the one new key this reader happens to know about.
    @Test("an AskUserQuestion's raw questions array survives ingest verbatim, preview included")
    func rawQuestionsSurviveIngestVerbatim() {
        let rawOption = JSONValue.object([
            "label": .string("Rewrite"),
            "description": .string("Slower, cleaner"),
            "futureKey": .string("unclaimed"),
            "preview": .string("line one\nline two"),
        ])
        let rawQuestion = JSONValue.object([
            "question": .string("Which approach?"),
            "header": .string("Approach"),
            "options": .array([rawOption,
                               .object(["label": .string("Patch"), "description": .string("Faster")])]),
            "multiSelect": .bool(false),
        ])
        let row = JSONValue.object([
            "ts": .string("2026-07-29T10:00:00.000Z"),
            "payload": .object([
                "session_id": .string("s1"),
                "hook_event_name": .string("PreToolUse"),
                "tool_name": .string(SubjectReader.questionTool),
                "tool_input": .object(["questions": .array([rawQuestion])]),
            ]),
        ])

        let event = HookIngest.event(from: row, epochBase: 0)
        #expect(event?.questionsUnreadable == false)
        #expect(event?.questions.first?.options.first?.preview?.value == "line one\nline two")
        #expect(event?.rawQuestions == .array([rawQuestion]),
                "the raw questions array did not survive ingest byte-for-byte")
    }

    /// One bad row used to ship the good ones and silently drop the bad
    /// one — a 3-question call answered with the third question missing
    /// from the wire entirely. The all-or-nothing guard `QuestionReader
    /// .call` already stated is now enforced at ingest: any row this reader
    /// cannot decode empties the whole array and marks the call
    /// unreadable, so the surface can refuse honestly instead of opening a
    /// takeover it can only half populate.
    @Test("one undecodable row marks the whole AskUserQuestion call unreadable, not just that row")
    func partialDecodeMarksTheWholeCallUnreadable() {
        let good = JSONValue.object([
            "question": .string("Which colour?"),
            "options": .array([.object(["label": .string("Teal")]),
                               .object(["label": .string("Coral")])]),
        ])
        // No `options` key at all — undecodable per `QuestionReader
        // .question(from:)`'s own guard.
        let bad = JSONValue.object(["question": .string("Which font?")])

        func event(_ questions: [JSONValue]) -> HookEvent? {
            HookIngest.event(from: .object([
                "ts": .string("2026-07-29T10:00:00.000Z"),
                "payload": .object([
                    "session_id": .string("s1"),
                    "hook_event_name": .string("PreToolUse"),
                    "tool_name": .string(SubjectReader.questionTool),
                    "tool_input": .object(["questions": .array(questions)]),
                ]),
            ]), epochBase: 0)
        }

        let partial = event([good, bad])
        #expect(partial?.questions.isEmpty == true,
                "a bad row shipped the good ones instead of refusing the whole call")
        #expect(partial?.questionsUnreadable == true)

        let whole = event([good])
        #expect(whole?.questions.count == 1)
        #expect(whole?.questionsUnreadable == false)

        // A tool that is not AskUserQuestion never claims unreadable,
        // whatever its own input looks like — unreadable is a claim about
        // a call this deck TRIED to read, not about one it was never
        // asking.
        let other = HookIngest.event(from: .object([
            "ts": .string("2026-07-29T10:00:00.000Z"),
            "payload": .object([
                "session_id": .string("s1"),
                "hook_event_name": .string("PreToolUse"),
                "tool_name": .string("Bash"),
                "tool_input": .object(["command": .string("ls")]),
            ]),
        ]), epochBase: 0)
        #expect(other?.questionsUnreadable == false)
        #expect(other?.rawQuestions == nil)
    }

    /// At the fleet layer. One shape with optional keys.
    @Test("fleet rows decode with state only, status only, and both")
    func fleetRowShapesAllDecode() {
        let rows = FleetIngest.rows(from: Corpus.fleetS18)
        #expect(rows.count == 8)

        let stateOnly = rows.filter { $0.state.isPresent && !$0.status.isPresent }
        let statusOnly = rows.filter { !$0.state.isPresent && $0.status.isPresent }
        let both = rows.filter { $0.state.isPresent && $0.status.isPresent }
        #expect(stateOnly.count == 2)     // the two `done` background rows
        #expect(statusOnly.count == 5)
        #expect(both.count == 1)          // spike-fail: state blocked AND status idle

        // The induced failure, and the value the spec had guessed wrong.
        let failing = rows.filter(\.isFailing)
        #expect(failing.count == 1)
        #expect(failing.first?.state.value == "blocked")

        // A state nobody has seen is not a failure. This is the direction that
        // matters: reverse it and the next new enum value turns a lane red.
        let unforeseen = FleetRow(session: nil, name: nil, kind: "background",
                                  state: .value("hibernating"), status: .absent)
        #expect(!unforeseen.isFailing)
    }

    /// `Used_percentage: null` is absent, not zero.
    @Test("a null context percentage decodes as unset, never as 0")
    func nullPercentageIsNotZero() {
        let feed = Corpus.statusline.compactMap { StatuslineIngest.payload(from: $0) }
        #expect(feed.count == 54)

        let unset = feed.filter { $0.contextPercent == .unset }
        let valued = feed.filter { $0.contextPercent.isPresent }
        #expect(unset.count == 12)                   // the recorded nulls
        #expect(valued.count == 42)
        #expect(unset.allSatisfy { $0.contextPercent.value == nil })

        // 0 and null are different payloads and must stay different values.
        let zero = JSONValue.parse(#"{"session_id":"s","context_window":{"used_percentage":0}}"#)!
        let null = JSONValue.parse(#"{"session_id":"s","context_window":{"used_percentage":null}}"#)!
        let gone = JSONValue.parse(#"{"session_id":"s","context_window":{}}"#)!
        #expect(StatuslineIngest.payload(from: zero)?.contextPercent == .value(0))
        #expect(StatuslineIngest.payload(from: null)?.contextPercent == .unset)
        #expect(StatuslineIngest.payload(from: gone)?.contextPercent == .absent)
    }

    /// Absent, null and 0 are three decoding cases in the envelope too.
    @Test("held_ms absent, null and zero stay three distinct values")
    func heldMsAbsentNullZeroDistinct() {
        func held(_ json: String) -> Fed<Int> { JSONValue.parse(json)!.fedInt("held_ms") }
        #expect(held(#"{}"#) == .absent)
        #expect(held(#"{"held_ms":null}"#) == .unset)
        #expect(held(#"{"held_ms":0}"#) == .value(0))
        #expect(held(#"{"held_ms":8002}"#) == .value(8002))

        // Two of the three occur in the recording: `held_ms` is absent on 4
        // rows and 0 on 132, and an explicit null appears nowhere. So the null
        // branch is UNEVIDENCED TOLERANCE rather than a recorded observation —
        // exactly the status the register gives `status: null` after section I
        // opened the corpus and could not find it. Promoting it back to
        // evidence is the conformance job's business, not a test's.
        let rows = Corpus.events
        #expect(rows.filter { $0.fedInt("held_ms") == .absent }.count == 4)
        #expect(rows.filter { $0.fedInt("held_ms") == .value(0) }.count == 132)
        #expect(!rows.contains { $0.fedInt("held_ms") == .unset })
    }

    /// Timestamps become whole milliseconds without a host clock.
    @Test("ISO-8601 parses to epoch milliseconds by arithmetic")
    func timestampParsesToMillis() {
        #expect(Timestamp.epochMillis(iso: "1970-01-01T00:00:00.000Z") == 0)
        #expect(Timestamp.epochMillis(iso: "1970-01-01T00:00:00Z") == 0)
        #expect(Timestamp.epochMillis(iso: "1970-01-01T00:00:01.500Z") == 1500)
        #expect(Timestamp.epochMillis(iso: "2000-03-01T00:00:00.000Z") == 951_868_800_000)
        #expect(Timestamp.epochMillis(iso: "2026-07-25T06:51:37.207Z") == 1_784_962_297_207)

        // The fraction is truncated, not rounded, so ordering by the parsed
        // value never disagrees with ordering by the source string.
        #expect(Timestamp.epochMillis(iso: "2026-07-25T06:51:37.2079Z") == 1_784_962_297_207)

        // Refused rather than guessed.
        for bad in ["", "2026-07-25", "2026-07-25T06:51:37", "2026-07-25T06:51:37+02:00",
                    "2026-13-01T00:00:00Z", "2026-07-25T25:00:00Z", "not a timestamp"] {
            #expect(Timestamp.epochMillis(iso: bad) == nil, "\(bad) was accepted")
        }

        // Every recorded timestamp parses. A corpus row the deck cannot place on
        // its timeline is a row it cannot render.
        let unparseable = Corpus.events.filter { Timestamp.epochMillis(iso: $0["ts"]?.stringValue ?? "") == nil }
        #expect(unparseable.isEmpty)
    }
}
