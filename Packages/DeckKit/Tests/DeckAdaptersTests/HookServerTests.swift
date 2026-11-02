//
//  HookServerTests.swift · Tests/DeckAdaptersTests
//
//  The adapter's own parsing, tested without a socket. A test that binds a port
//  to check `Content-Length` handling is a test that fails on a busy machine for
//  a reason unrelated to what it asserts.
//

import Testing
import Foundation
@testable import DeckAdapters
import DeckCore

struct HookServerTests {

    /// The framing rule that matters: a request is complete when its body
    /// reaches the declared length. Waiting for the peer to close instead hangs
    /// on every keep-alive client, and curl is one.
    @Test("a request is complete only when the body reaches Content-Length")
    func completenessFollowsContentLength() {
        let head = "POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 12\r\n\r\n"
        #expect(!HookServer.isComplete(head))
        #expect(!HookServer.isComplete(head + "{\"a\":1"))
        #expect(HookServer.isComplete(head + "{\"a\":1234567"))
        #expect(HookServer.isComplete(head + "{\"a\":1234567890}"))
    }

    @Test("the body is everything after the header separator, byte for byte")
    func bodySurvivesIntact() {
        let payload = #"{"tool_input":{"command":"echo \"a\r\nb\""}}"#
        let request = "POST /hook HTTP/1.1\r\nContent-Length: \(payload.utf8.count)\r\n\r\n" + payload
        #expect(HookServer.body(of: request) == payload)
        #expect(JSONValue.parse(HookServer.body(of: request) ?? "") != nil)
    }

    /// The release-is-not-deny rule on the wire. Allow and deny carry a
    /// decision; a release carries an empty object, which is the deck
    /// declining to decide and letting the engine's own policy run. Two
    /// outcomes, two wire forms.
    @Test("release and deny are different bytes")
    func releaseIsNotDeny() {
        let deny = HookResponse.decision(.deny, reason: "deck")
        let release = HookResponse.decision(.release, reason: "deck timeout")
        #expect(deny.contains("\"permissionDecision\":\"deny\""))
        #expect(release == "{}")
        #expect(deny != release)
        #expect(HookResponse.decision(.allow, reason: "deck").contains("\"allow\""))
        // Every response is valid JSON, because it becomes the hook's stdout and
        // the engine parses it.
        for resolution in Resolution.allCases {
            #expect(JSONValue.parse(HookResponse.decision(resolution, reason: "r")) != nil)
        }
    }

    /// The timestamp the adapter stamps on arrival round-trips through the
    /// core's own parser — the two halves of the staleness rule's receipt
    /// clock agreeing. P1.70 — the answered-question wire form, against the
    /// published shape.
    ///
    /// Two things are asserted that a capture of the happy path could not have
    /// taught us. `updatedInput` sits **directly under `hookSpecificOutput`** —
    /// `PermissionRequest` puts the same field one level deeper inside a
    /// `decision` object, so guessing had even odds. And the decision is
    /// `allow`: returning it without `updatedInput` runs the tool with no answer
    /// in it, which looks like success and is not.
    /// The two events that can want a human answer in **different shapes**, and
    /// answering one in the other's form is not an error the engine reports — it
    /// is a field it does not recognise, so the call falls through to the normal
    /// permission flow and the deck looks like it was ignored.
    @Test("a permission request is answered with decision.behavior, not permissionDecision")
    func permissionRequestUsesItsOwnWireForm() throws {
        let asked = try #require(JSONValue.parse(
            HookResponse.decision(.deny, reason: "deck", event: .permissionRequest)))
        let out = try #require(asked["hookSpecificOutput"])
        #expect(out["hookEventName"]?.stringValue == "PermissionRequest")
        #expect(out["decision"]?["behavior"]?.stringValue == "deny")
        // The PreToolUse spelling must NOT appear, or a reader cannot tell which
        // shape was meant and the engine takes neither.
        #expect(out["permissionDecision"] == nil)

        let tool = try #require(JSONValue.parse(
            HookResponse.decision(.allow, reason: "deck", event: .preToolUse)))
        let toolOut = try #require(tool["hookSpecificOutput"])
        #expect(toolOut["hookEventName"]?.stringValue == "PreToolUse")
        #expect(toolOut["permissionDecision"]?.stringValue == "allow")
        #expect(toolOut["decision"] == nil)

        // The release-is-not-deny rule survives the second shape: release is still not deny.
        #expect(HookResponse.decision(.release, reason: "x", event: .permissionRequest) == "{}")
    }

    // ------------------------------------------------ chunk 3: the third answer

    /// The allow branch of `PermissionRequest`'s `decision` object accepts NO
    /// `message` member — extracted from the CLI 2.1.223 binary's own
    /// schema, not from a document. This line used to send one, which a
    /// schema that strict very plausibly rejected outright, silently, the
    /// same way an unrecognised field always falls through here rather than
    /// raising: the deck's Allow on a `PermissionRequest` may never have
    /// actually landed.
    ///
    /// **No prior assertion in this suite pinned this exact combination.**
    /// `permissionRequestUsesItsOwnWireForm` above uses `.deny` for the
    /// `PermissionRequest` shape and `.allow` for the `PreToolUse` one, and
    /// `releaseIsNotDeny`'s `.allow` check omits `event:` entirely, which
    /// defaults to `.preToolUse`. So this is new coverage of a shape the
    /// suite had never actually exercised, not an update to a byte it was
    /// already checking.
    @Test("a permission-request allow carries no message and no updatedPermissions")
    func permissionRequestAllowCarriesNoMessage() throws {
        let body = HookResponse.decision(.allow, reason: "deck", event: .permissionRequest)
        let parsed = try #require(JSONValue.parse(body))
        let decision = try #require(parsed["hookSpecificOutput"]?["decision"])
        #expect(decision["behavior"]?.stringValue == "allow")
        #expect(decision["message"] == nil, "the allow branch has no message member on the wire")
        #expect(decision["updatedPermissions"] == nil)
        guard case .object(let fields) = decision else {
            Issue.record("decision was not an object"); return
        }
        #expect(Set(fields.keys) == ["behavior"], "an allow decision carries fields beyond behavior")
    }

    /// The deny branch is untouched — it still carries its `message`, which is
    /// schema-valid there. Kept explicit rather than inferred from
    /// `permissionRequestUsesItsOwnWireForm`'s `behavior` check, since that
    /// test never reads the message key at all.
    @Test("a permission-request deny still carries its message")
    func permissionRequestDenyCarriesMessage() throws {
        let body = HookResponse.decision(.deny, reason: "the user said no", event: .permissionRequest)
        let parsed = try #require(JSONValue.parse(body))
        let decision = try #require(parsed["hookSpecificOutput"]?["decision"])
        #expect(decision["behavior"]?.stringValue == "deny")
        #expect(decision["message"]?.stringValue == "the user said no")
    }

    /// `allowAndRemember` is clicking Claude Code's own option 2, and the
    /// suggestion has to travel back VALUE-VERBATIM — not byte-verbatim;
    /// `WritePlan.render` sorts object keys, so the rendered bytes need not
    /// match the wire the suggestion arrived on, only the value. The literal
    /// below is `LVV-permission/payloads.ndjson` row 4's own
    /// `permission_suggestions` element, reconstructed by hand rather than
    /// read off `Corpus` — that helper lives in the `DeckCoreTests` target,
    /// and this suite has no dependency on it (see `Package.swift`'s
    /// per-target `Fixtures`). `IngestTests.permissionSuggestionsDecodeVerbatim`
    /// pins the same value from the decode side; this pins it from the
    /// encode side.
    @Test("allowAndRemember echoes the chosen suggestion back verbatim")
    func allowAndRememberEchoesTheChosenSuggestion() throws {
        let recorded = try #require(JSONValue.parse(
            #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"}]"#))
        let body = HookResponse.decision(.allowAndRemember(suggestionIndex: 0), reason: "deck",
                                         event: .permissionRequest, suggestions: recorded)
        let parsed = try #require(JSONValue.parse(body))
        let decision = try #require(parsed["hookSpecificOutput"]?["decision"])
        #expect(decision["behavior"]?.stringValue == "allow")
        #expect(decision["message"] == nil, "allowAndRemember carries no message either")
        let updated = try #require(decision["updatedPermissions"]?.arrayValue)
        #expect(updated.count == 1)
        #expect(updated.first == recorded.arrayValue?.first,
                "the echoed element's value differs from the one the engine sent")
    }

    /// A stale index — the hold's suggestions changed shape, or carried none
    /// at all — degrades to a plain allow rather than naming a rule the deck
    /// cannot back. The `mutedFloor` choice again: never claim more than what
    /// is known.
    @Test("allowAndRemember with no suggestion at that index degrades to a plain allow")
    func allowAndRememberWithNoSuggestionDegrades() throws {
        let outOfRange = try #require(JSONValue.parse(#"[{"type":"setMode","mode":"plan"}]"#))
        let cases: [(label: String, suggestions: JSONValue?)] = [
            ("nil", nil), ("out of range", outOfRange),
        ]
        for (label, suggestions) in cases {
            let body = HookResponse.decision(.allowAndRemember(suggestionIndex: 3), reason: "deck",
                                             event: .permissionRequest, suggestions: suggestions)
            let parsed = try #require(JSONValue.parse(body), Comment(rawValue: label))
            let decision = try #require(parsed["hookSpecificOutput"]?["decision"],
                                        Comment(rawValue: label))
            #expect(decision["behavior"]?.stringValue == "allow", Comment(rawValue: label))
            #expect(decision["updatedPermissions"] == nil, Comment(rawValue: label))
        }
    }

    /// A `PreToolUse` hold is an `AskUserQuestion` call and never carries
    /// suggestions, so `DecisionBar` never offers this button on one — but
    /// the encoder still has to answer SOMETHING if it is ever asked, and the
    /// honest answer is the same plain allow a bare Allow tap would send.
    @Test("allowAndRemember on a PreToolUse hold encodes as a plain allow")
    func allowAndRememberOnPreToolUseIsPlainAllow() throws {
        let body = HookResponse.decision(.allowAndRemember(suggestionIndex: 0), reason: "deck",
                                         event: .preToolUse)
        let parsed = try #require(JSONValue.parse(body))
        let out = try #require(parsed["hookSpecificOutput"])
        #expect(out["hookEventName"]?.stringValue == "PreToolUse")
        #expect(out["permissionDecision"]?.stringValue == "allow")
        #expect(out["decision"] == nil, "the PreToolUse shape must not borrow PermissionRequest's field")
    }

    @Test("an answered question carries allow, the questions, and labels keyed by question text")
    func answeredQuestionMatchesTheDocumentedShape() throws {
        let hold = HoldID(session: SessionID("s"), toolUseID: "u")
        // Quotes and an apostrophe on purpose: question text is Claude's prose,
        // and a hand-built JSON string that does not escape them produces a body
        // the engine rejects — a failure that would look like the deck ignoring
        // the answer rather than like malformed JSON.
        let question = Question(text: Redacted("Which \"store\" should I use? Don't guess."),
                                header: Redacted("Store"),
                                options: [QuestionOption(label: Redacted("Postgres"),
                                                         detail: Redacted("Relational")),
                                          QuestionOption(label: Redacted("Redis"),
                                                         detail: Redacted("In-memory"))],
                                multiSelect: true)
        let call = QuestionCall(hold: hold, questions: [question])
        let answers = [Answer(question: question.text,
                              labels: [Redacted("Postgres"), Redacted("Redis")])]

        let wire = HookResponse.answered(call, answers)
        let parsed = try #require(JSONValue.parse(wire), "the response is not valid JSON")

        let specific = try #require(parsed["hookSpecificOutput"])
        #expect(specific["hookEventName"]?.stringValue == "PreToolUse")
        #expect(specific["permissionDecision"]?.stringValue == "allow")

        let updated = try #require(specific["updatedInput"],
                                   "updatedInput is not directly under hookSpecificOutput")
        // The original questions travel back — the tool needs them to process
        // the answer at all.
        #expect(updated["questions"]?.arrayValue?.count == 1)
        #expect(updated["questions"]?.arrayValue?.first?["question"]?.stringValue
                == question.text.value)

        // A multi-select answer is an ARRAY of labels. Flattened into one
        // comma-joined string it would be a different answer, and the old
        // positional answer type could not express it at all.
        let value = try #require(updated["answers"]?[question.text.value])
        #expect(value.arrayValue?.compactMap(\.stringValue) == ["Postgres", "Redis"])

        // A single-select answer is a bare string, not a one-element array.
        let single = HookResponse.answered(
            QuestionCall(hold: hold, questions: [question]),
            [Answer(question: question.text, labels: [Redacted("Postgres")])])
        let one = try #require(JSONValue.parse(single))
        #expect(one["hookSpecificOutput"]?["updatedInput"]?["answers"]?[question.text.value]?
                    .stringValue == "Postgres")
    }

    /// A typed answer travels the same map a picked label does — no
    /// special-casing in the encoder, and the escaping the picked-label
    /// case already needed (quotes and an apostrophe, on purpose) is the
    /// same escaping a person's own typing needs.
    @Test("a typed (\"Other…\") answer reaches the wire verbatim, escaped like any label")
    func freeTextAnswerReachesTheWireVerbatim() throws {
        let hold = HoldID(session: SessionID("s"), toolUseID: "u")
        let question = Question(text: Redacted("Which approach?"), header: Redacted("Approach"),
                                options: [QuestionOption(label: Redacted("Rewrite"), detail: Redacted(""))],
                                multiSelect: false)
        let call = QuestionCall(hold: hold, questions: [question])
        let typed = #"Neither — use a "third" approach, don't ask again."#
        let answers = [Answer(question: question.text, labels: [Redacted(typed)])]

        let wire = HookResponse.answered(call, answers)
        let parsed = try #require(JSONValue.parse(wire), "the response is not valid JSON")
        let value = try #require(parsed["hookSpecificOutput"]?["updatedInput"]?["answers"]?[question.text.value])
        #expect(value.stringValue == typed,
                "the typed answer did not survive the wire byte for byte")
    }

    /// **The raw-passthrough doctrine, on `answered` specifically.** A
    /// `preview` key — or any key `QuestionOption` does not decode — used
    /// to be stripped from the tool's own input the moment the deck
    /// answered, because this encoder rebuilt `updatedInput.questions` from
    /// `call.questions`, its own lossy model. `rawQuestions` is the fix:
    /// when it is present, the ORIGINAL array goes back, value-verbatim
    /// (`WritePlan.render`, the same doctrine `allowAndRemember` already
    /// applies to `permission_suggestions`), keys unknown to this deck
    /// included.
    @Test("answered echoes the raw questions array verbatim when the hold carried one, preview included")
    func answeredEchoesRawQuestionsVerbatim() throws {
        let hold = HoldID(session: SessionID("s"), toolUseID: "u")
        let question = Question(text: Redacted("Which approach?"), header: Redacted("Approach"),
                                options: [QuestionOption(label: Redacted("Rewrite"), detail: Redacted(""),
                                                         preview: Redacted("$ diff --stat\n 3 files changed"))],
                                multiSelect: false)
        let raw = JSONValue.parse(
            #"[{"question":"Which approach?","header":"Approach","options":["#
            + #"{"label":"Rewrite","description":"","preview":"$ diff --stat\n 3 files changed","#
            + #""futureKey":"unclaimed"}],"multiSelect":false}]"#)!
        let call = QuestionCall(hold: hold, questions: [question], rawQuestions: raw)
        let answers = [Answer(question: question.text, labels: [Redacted("Rewrite")])]

        let wire = HookResponse.answered(call, answers)
        let parsed = try #require(JSONValue.parse(wire))
        let echoed = try #require(parsed["hookSpecificOutput"]?["updatedInput"]?["questions"])
        #expect(echoed == raw, "the echoed questions array is not the raw one the hold carried")
        #expect(echoed.arrayValue?.first?["options"]?.arrayValue?.first?["futureKey"]?.stringValue
                == "unclaimed", "a key this deck does not decode was dropped from the tool's own input")
        #expect(echoed.arrayValue?.first?["options"]?.arrayValue?.first?["preview"]?.stringValue
                == "$ diff --stat\n 3 files changed")

        // No `rawQuestions` (every test that predates this field, and no
        // call that reaches this function over the real wire once ingest
        // threads it through): the reconstruction fallback still runs, and
        // `answeredQuestionMatchesTheDocumentedShape` above is what pins
        // its exact shape.
        let noRaw = QuestionCall(hold: hold, questions: [question])
        let fallback = HookResponse.answered(noRaw, answers)
        let fallbackParsed = try #require(JSONValue.parse(fallback))
        #expect(fallbackParsed["hookSpecificOutput"]?["updatedInput"]?["questions"]?
                    .arrayValue?.first?["options"]?.arrayValue?.first?["futureKey"] == nil,
                "the fallback path invented a key nobody asked it to carry")
    }

    @Test("an arrival stamp is a timestamp DeckCore can read")
    func stampRoundTrips() {
        let text = HookServer.isoString(fromEpochMillis: 1_784_962_297_207)
        #expect(text == "2026-07-25T06:51:37.207Z")
        #expect(Timestamp.epochMillis(iso: text) == 1_784_962_297_207)
    }
}

extension HookServerTests {

    /// The server reads the host identity off the request line.
    ///
    /// The deck's own hook appends `?surface=…&workspace=…`, filled
    /// from the environment its parent session gave it. This is the one place
    /// those bytes become a value, so it is tested here rather than inferred
    /// from the fact that the ingest can decode them.
    @Test("the request line's query becomes the session's address")
    func hostIdentityFromTheQuery() {
        let request = "POST /hook?surface=SURF-ABC&workspace=WS-XYZ HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8765\r\nContent-Length: 2\r\n\r\n{}"
        let query = HookServer.query(of: request)
        #expect(query["surface"] == "SURF-ABC")
        #expect(query["workspace"] == "WS-XYZ")

        // A session in a terminal with no such notion sends the keys empty —
        // `${VAR:-}` expands to nothing — and empty must decode to NO address
        // rather than to an address of empty strings (the
        // unknown-is-not-error rule, unknown is not error, and a lane must
        // not claim reachability it does not have).
        let bare = HookServer.query(of: "POST /hook?surface=&workspace= HTTP/1.1\r\n\r\n{}")
        #expect(HostAddress(workspace: bare["workspace"], surface: bare["surface"]) == nil)

        // No query at all — an older install, or a different host.
        #expect(HookServer.query(of: "POST /hook HTTP/1.1\r\n\r\n{}").isEmpty)

        // Percent-encoding survives: cmux ids are UUIDs today, but a host that
        // used a path or a title would arrive encoded.
        let encoded = HookServer.query(of: "POST /hook?surface=a%20b&workspace=c%2Fd HTTP/1.1\r\n\r\n{}")
        #expect(encoded["surface"] == "a b")
        #expect(encoded["workspace"] == "c/d")
    }
}
