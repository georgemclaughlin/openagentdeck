//
//  SuggestionLabelTests.swift · Tests/DeckCoreTests
//
//  `permission_suggestions[]` -> a sentence a person can read on a button —
//  the one place chunk 3 decodes the engine's shape at all. `HookEvent` and
//  `Hold` both keep the array raw (see `HookEvent.permissionSuggestions`'s
//  own doc comment for why); this is what turns one element into a label,
//  tested against the shapes the LVV-permission fixture and the CLI
//  2.1.223 binary's own extracted schema name.
//

import Testing
import DeckCore

struct SuggestionLabelTests {

    private func json(_ text: String) -> JSONValue { JSONValue.parse(text)! }

    /// The exact shape `LVV-permission/payloads.ndjson` row 4 recorded.
    @Test("addRules with one rule reads its ruleContent")
    func addRulesSingleRule() {
        let suggestion = json(
            #"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"}"#)
        #expect(SuggestionLabel.label(for: suggestion) == "Don't ask again for: git push *")
    }

    @Test("addRules with several rules joins them with a comma")
    func addRulesMultipleRules() {
        let suggestion = json(
            #"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"},{"toolName":"Write","ruleContent":"*.md"}],"behavior":"allow","destination":"localSettings"}"#)
        #expect(SuggestionLabel.label(for: suggestion) == "Don't ask again for: git push *, *.md")
    }

    /// A rule with no `ruleContent` falls back to the tool's own name — still
    /// a label, never a blank.
    @Test("addRules falls back to toolName when a rule has no ruleContent")
    func addRulesFallsBackToToolName() {
        let suggestion = json(#"{"type":"addRules","rules":[{"toolName":"Bash"}]}"#)
        #expect(SuggestionLabel.label(for: suggestion) == "Don't ask again for: Bash")
    }

    /// Not fixture-verified — no `setMode` row exists in this corpus — so
    /// `mode` is read off the task's own prose rather than a captured
    /// payload. `label(for:)`'s doc comment says so; this test pins the
    /// same field name so a live capture can be diffed against it later.
    @Test("setMode names the mode it switches to")
    func setModeNamesTheMode() {
        let suggestion = json(#"{"type":"setMode","mode":"acceptEdits"}"#)
        #expect(SuggestionLabel.label(for: suggestion) == "Switch mode to acceptEdits")
    }

    /// Unknown is not error: a type this deck has never seen still gets a
    /// label — its own name — because dropping it would desynchronise
    /// `Decision.suggestionLabels` from the raw array
    /// `HookResponse.decision` indexes by position.
    @Test("an unrecognised suggestion type renders its own name rather than being dropped")
    func unrecognisedTypeRendersItsOwnName() {
        let suggestion = json(#"{"type":"removeRules","rules":[]}"#)
        #expect(SuggestionLabel.label(for: suggestion) == "Apply: removeRules")
    }

    /// And a suggestion with no `type` field at all — not even a string to
    /// name — still yields a label rather than nothing.
    @Test("a suggestion missing type entirely still yields a label")
    func missingTypeStillYieldsALabel() {
        let suggestion = json(#"{"behavior":"allow"}"#)
        #expect(SuggestionLabel.label(for: suggestion) == "Apply: unknown")
    }

    /// `labels(from:)` is the whole-array form `Frame.swift`'s projection
    /// calls: nil becomes empty (a `PermissionRequest` with none), and every
    /// element keeps its position — the alignment `Decision.suggestionLabels`
    /// documents as the response encoder's contract.
    @Test("labels(from:) is index-aligned with the raw array; nil becomes empty")
    func labelsIndexAligned() {
        #expect(SuggestionLabel.labels(from: nil) == [])
        let array = json(
            #"[{"type":"setMode","mode":"plan"},{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"**/*.md"}],"behavior":"allow","destination":"localSettings"}]"#)
        #expect(SuggestionLabel.labels(from: array) == [
            "Switch mode to plan",
            "Don't ask again for: **/*.md",
        ])
    }
}
