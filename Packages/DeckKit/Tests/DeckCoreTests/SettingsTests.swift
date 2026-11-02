//
//  SettingsTests.swift · Tests/DeckCoreTests
//
//  Cases P1.30–P1.34 — class C, over the highest blast-radius operation in the
//  app. All of it is arithmetic on a decoded document, so none of it needs a
//  real `~/.claude` and none of it can damage one.
//

import Testing
import DeckCore

struct SettingsTests {

    private func fixture(_ name: String) -> JSONValue {
        let v = JSONValue.parse(Corpus.text("settings/\(name)"))
        precondition(v != nil, "settings/\(name) did not parse")
        return v!
    }

    private var documents: [(String, JSONValue)] {
        ["bare.json", "foreign-hooks.json", "existing-statusline.json", "already-installed.json"]
            .map { ($0, fixture($0)) }
    }

    /// Every key the document had, as `path -> value`, so "preserved" can be
    /// asserted over the whole tree rather than over the keys someone thought of.
    private func leaves(_ v: JSONValue, at path: String = "") -> [String: JSONValue] {
        switch v {
        case .object(let o):
            return o.reduce(into: [:]) { acc, kv in
                acc.merge(leaves(kv.value, at: "\(path)/\(kv.key)")) { a, _ in a }
            }
        case .array(let a):
            return a.enumerated().reduce(into: [:]) { acc, kv in
                acc.merge(leaves(kv.element, at: "\(path)[\(kv.offset)]")) { a, _ in a }
            }
        default:
            return [path: v]
        }
    }

    /// Merge, never clobber.
    @Test("install preserves every pre-existing key, hook and statusline")
    func mergeNeverClobbers() {
        for (name, doc) in documents {
            let after = SettingsMerge.install(into: doc, port: 8765).after
            let before = leaves(doc), now = leaves(after)
            for (path, value) in before {
                // The one declared exception, and it is a spec gap rather
                // than a carve-out someone chose: the relay-wraps rule's
                // entire content is that this key is altered, and the
                // merge-never-clobber rule says no key is. The spec does not
                // order them. What install guarantees is that nothing is
                // *lost* — the original is kept verbatim beside the composed
                // command.
                if path == "/statusLine/command" {
                    #expect(SettingsMerge.originalStatusline(
                        SettingsMerge.uninstall(from: after).after) == value.stringValue,
                        "\(name): the original statusline was not recoverable")
                    continue
                }
                // The deck's OWN entry is the one thing install may rewrite —
                // that is what makes re-installing an upgrade rather than a
                // no-op, and it is how a deck whose hook command was wrong
                // gets fixed on the next install. (It was wrong: the command
                // shipped without `--data-binary @-` and posted an empty
                // body. A preservation rule that froze our own entry would
                // have preserved the defect.) the merge-never-clobber rule is
                // about OTHER people's keys.
                if path.hasPrefix("/hooks/PreToolUse"), path.hasSuffix("/command"),
                   value.stringValue?.contains("/hook") == true {
                    #expect(now[path]?.stringValue?.contains("--data-binary @-") == true,
                            "\(name): re-install did not upgrade the deck's own command")
                    continue
                }
                #expect(now[path] == value, "\(name): \(path) was altered or lost")
            }
            #expect(SettingsMerge.isInstalled(after), "\(name): the deck's own hook is missing")
        }

        // The case that is easy to get wrong and that the spike met for real:
        // a foreign PreToolUse hook must survive install as a sibling, not be
        // replaced by ours.
        let foreign = fixture("foreign-hooks.json")
        let after = SettingsMerge.install(into: foreign, port: 8765).after
        let entries = after["hooks"]?["PreToolUse"]?.arrayValue ?? []
        #expect(entries.count == 2)
        #expect(entries.contains { $0["matcher"] == JSONValue.string("Bash") })
        #expect(after["hooks"]?["SessionStart"] != nil)
        #expect(after["permissions"]?["allow"] != nil)
    }

    /// `install`'s own copy of the matcher-scoping rule — `reconcile` has
    /// its own loop and its own test (`ReconcileTests
    /// .postToolUseMatcherIsScopedToTheQuestionTool`), but `install` builds
    /// the SAME shape through a SEPARATE loop, and every test above this one
    /// exercises `install` rather than `reconcile` — so this is the one that
    /// would actually catch a regression in the function these tests use.
    @Test("install scopes PostToolUse to AskUserQuestion; every other event stays open")
    func installMatcherIsScopedToTheQuestionTool() {
        let after = SettingsMerge.install(into: .object([:]), port: 8765).after
        let postToolUse = after["hooks"]?["PostToolUse"]?.arrayValue ?? []
        #expect(postToolUse.count == 1)
        #expect(postToolUse.first?["matcher"] == .string("AskUserQuestion"))

        for event in ["PermissionRequest", "PreToolUse", "Notification",
                      "UserPromptSubmit", "SessionStart", "Stop", "SessionEnd"] {
            let entries = after["hooks"]?[event]?.arrayValue ?? []
            #expect(entries.first?["matcher"] == .string("*"),
                    Comment(rawValue: "\(event) installed with matcher \(entries.first?["matcher"] as Any)"))
        }
    }

    /// Install is idempotent.
    @Test("installing twice is byte-identical to installing once")
    func installIsIdempotent() {
        for (name, doc) in documents {
            let once = SettingsMerge.install(into: doc, port: 8765).after
            let twice = SettingsMerge.install(into: once, port: 8765).after
            #expect(once == twice, "\(name): install(install(x)) != install(x)")
        }
        // And re-installing on a different port updates in place rather than
        // appending a second deck hook — two hooks answering one call is the
        // exactly-once invariant broken one layer down.
        let doc = fixture("already-installed.json")
        let moved = SettingsMerge.install(into: doc, port: 9000).after
        #expect((moved["hooks"]?["PreToolUse"]?.arrayValue ?? []).count == 1)
    }

    /// Uninstall restores, and touches nothing it did not add.
    @Test("uninstall returns the document to its pre-install state exactly")
    func uninstallRestores() {
        for (name, doc) in documents where name != "already-installed.json" {
            let installed = SettingsMerge.install(into: doc, port: 8765).after
            let removed = SettingsMerge.uninstall(from: installed).after
            #expect(removed == doc, "\(name): uninstall did not restore the original")
        }
        // Including the container it created: a bare document must come back
        // bare, not as `{"hooks": {}}`.
        let bare = fixture("bare.json")
        #expect(SettingsMerge.uninstall(from: SettingsMerge.install(into: bare, port: 8765).after).after
                == JSONValue.object([:]))
        // And a foreign hook is never removed by our uninstall.
        let foreign = fixture("foreign-hooks.json")
        #expect(SettingsMerge.uninstall(from: foreign).after == foreign)
    }

    /// **The usage dot is unreachable without a statusline, and the deck
    /// does not install one.** A gap, pinned rather than closed.
    ///
    /// The dot and its percentage are fed ONLY by the statusline's `rate_limits`
    /// (measured, LV19: nothing speaks at a usage refusal, so no hook can drive
    /// it). P1.54 asserts that install invents no statusline for a document that
    /// has none — a rule about not writing keys into somebody's config that they
    /// never asked for. The consequence is that a user who has never configured a
    /// statusline cannot see the usage indicator at all, ever.
    ///
    /// Both halves are deliberate and they conflict, so this test states the
    /// conflict instead of leaving it to be rediscovered: the relay shape the
    /// deck WOULD need exists and is correct, and install does not use it.
    /// Closing the gap is a consent decision for the product owner, not a
    /// defect to fix quietly — the same treatment the the merge-never-clobber
    /// rule/the relay-wraps rule collision already gets.
    @Test("the usage dot needs a statusline the deck deliberately does not install")
    func usageNeedsAStatuslineTheDeckWillNotInvent() {
        // The gap, stated: no statusline in, none out.
        let bare = fixture("bare.json")
        #expect(SettingsMerge.originalStatusline(bare) == nil)
        #expect(SettingsMerge.install(into: bare, port: 8765).after["statusLine"] == nil,
                "install began inventing a statusline — P1.54 is the rule, and reversing it is a consent decision")

        // And the shape that WOULD close it is present and correct, so closing it
        // is one call rather than a design exercise.
        let relay = SettingsMerge.bareRelayCommand(port: 8765)
        #expect(relay.contains("/statusline"))
        #expect(relay.contains("--data-binary @-"),
                "the payload would arrive empty — the defect that made every deck-installed hook invisible")

        // The wrapping case, which is the one that works: an existing statusline
        // still runs verbatim with the relay only observing.
        let existing = fixture("existing-statusline.json")
        let after = SettingsMerge.install(into: existing, port: 8765).after
        #expect(SettingsMerge.wrapsOriginal(after, original: "npx ccusage statusline"),
                "an existing statusline stopped being invoked")
    }

    /// **The relay duplicates the statusline's INPUT, not its output**,
    /// and this is the assertion the usage feature always needed.
    ///
    /// The composed command was `original | tee >(curl …)`, which sends the deck
    /// the rendered LINE. `rate_limits` only ever arrives on stdin (LV19), so the
    /// deck received text it could not parse and the dot could never light. Every
    /// other part of task 35 was tested against the recorded payload; nothing
    /// tested that the payload would arrive.
    ///
    /// **"Asserted structurally rather than by running a shell" is what this test
    /// used to say, and that sentence is the whole story.** The structure it
    /// checked — tee first, original downstream, original verbatim at the end —
    /// was correct, and the command still did nothing, because `>(…)` is a bash
    /// extension and Claude Code runs a statusline under `/bin/sh` (LV33). It
    /// failed to PARSE, so neither half ran.
    ///
    /// The behavioural claims now live in `StatuslineRelayTests`
    /// (S17.1–S17.5), which gives the composed string to a real shell and
    /// reads back what the deck was posted and what the terminal was shown.
    /// What is left here is the part that is genuinely a property of the
    /// text: the user's own command is embedded verbatim and runs last, so
    /// nothing this function does can change what the statusline says. That
    /// is the relay-wraps rule, and it is the one claim a core test can make
    /// honestly.
    @Test("the statusline relay embeds the user's own command, verbatim and last")
    func relayForwardsThePayload() {
        // Something with a quote and a pipe of its own: a relay that had to
        // re-quote the original would mangle this, and the shipped shapes both
        // avoided that by construction rather than by luck.
        let original = #"npx ccusage statusline | sed 's/^/x/'"#
        let composed = SettingsMerge.relayCommand(wrapping: original, port: 8765)

        #expect(composed.contains(original), "the user's command was rewritten rather than invoked")
        #expect(composed.hasSuffix(original),
                "something is appended after the original, so its output is no longer the line")
        #expect(SettingsMerge.wrapsOriginal(
            .object(["statusLine": .object(["command": .string(composed)])]), original: original))
        // The deck's copy goes to the deck's own route, and it is the payload
        // that goes — a body-less POST is the defect that made every
        // deck-installed hook invisible, one command line over.
        #expect(composed.contains("http://127.0.0.1:8765/statusline"))
        #expect(composed.contains("--data-binary @"))
        // The spool is rooted at TMPDIR. Bare `mktemp` on macOS ignores it and
        // uses the confstr directory, which put the file somewhere neither the
        // user nor a test could name.
        #expect(composed.contains("${TMPDIR:-/tmp}"),
                "the spool ignores TMPDIR and lands wherever mktemp decides")
        // No bash-only syntax. A cheap, mechanical guard on the class of defect
        // rather than on the one instance of it: this function's output is
        // executed by `/bin/sh` and by nothing else.
        #expect(!composed.contains(">("),
                "process substitution is bash — /bin/sh rejects it before anything runs")
        #expect(!composed.contains("<("))
    }

    /// Preview then commit, of the same diff.
    @Test("no config write is committed without a confirmed preview of that diff")
    func previewThenCommit() {
        let diff = SettingsMerge.install(into: fixture("bare.json"), port: 8765)
        let other = SettingsMerge.install(into: fixture("foreign-hooks.json"), port: 8765)

        // A commit with no preview at all.
        let (_, unpreviewed) = Reducer.effects([.configConfirmed(diff)])
        #expect(!unpreviewed.contains { if case .commitConfigWrite = $0 { return true }; return false })

        // A confirmation naming a different diff than the one shown.
        let (_, mismatched) = Reducer.effects([.configRequested(.settingsWindow, diff),
                                               .configConfirmed(other)])
        #expect(!mismatched.contains { if case .commitConfigWrite = $0 { return true }; return false })

        // The legitimate path, or the assertions above are satisfied by a deck
        // that can never write anything at all.
        let (_, ok) = Reducer.effects([.configRequested(.settingsWindow, diff),
                                       .configConfirmed(diff)])
        #expect(ok.contains { if case .previewConfigWrite(let d) = $0 { return d == diff }; return false })
        #expect(ok.contains { if case .commitConfigWrite(let d) = $0 { return d == diff }; return false })

        // And the preview strictly precedes the commit.
        let previewIndex = ok.firstIndex { if case .previewConfigWrite = $0 { return true }; return false }
        let commitIndex = ok.firstIndex { if case .commitConfigWrite = $0 { return true }; return false }
        #expect(previewIndex != nil && commitIndex != nil && previewIndex! < commitIndex!)
    }

    /// The strip never writes to `~/.claude`.
    @Test("no config write can originate on the strip")
    func stripNeverWrites() {
        let diff = SettingsMerge.install(into: fixture("bare.json"), port: 8765)
        let (state, effects) = Reducer.effects([.configRequested(.strip, diff),
                                                .configConfirmed(diff)])
        #expect(!effects.contains { if case .commitConfigWrite = $0 { return true }; return false })
        #expect(!effects.contains { if case .previewConfigWrite = $0 { return true }; return false })
        #expect(state.pendingWrite == nil,
                "a strip gesture left a write pending, which a later confirmation could commit")
    }

    /// **The writer escapes.** It did not, and the file it writes is the
    /// user's real `~/.claude/settings.json`.
    ///
    /// `render` stapled quotes onto the bytes. It survived only because nothing the
    /// deck installed had ever contained a quote, and it surfaced the moment the
    /// hook command needed double quotes so its shell variables could expand. A
    /// Windows path, an apostrophe in a name, or somebody else's statusline command
    /// with a quoted argument would each have produced a file no tool could parse —
    /// including the deck, which reads it back.
    @Test("the config writer escapes every string it writes")
    func writerEscapesStrings() {
        let hostile: [String: JSONValue] = [
            "quoted": .string("say \"hello\""),
            "backslash": .string("C:\\Users\\deck"),
            "newline": .string("one\ntwo"),
            "tab": .string("a\tb"),
            "control": .string("bell\u{07}here"),
            "both": .string("mix \"\\ of\nthings"),
        ]
        let document = JSONValue.object(hostile)
        let text = WritePlan.render(document)
        guard let round = JSONValue.parse(text) else {
            Issue.record(Comment(rawValue: "the writer produced unparseable JSON: \(text)"))
            return
        }
        #expect(round == document, "the round trip changed the value")

        // A key needs it as much as a value — the same function, on both sides.
        let oddKey = JSONValue.object(["a \"key\" with quotes": .string("v")])
        #expect(JSONValue.parse(WritePlan.render(oddKey)) == oddKey,
                "a key containing a quote was written unescaped")

        // And the real case that exposed it: the hook command the deck installs.
        let installed = SettingsMerge.install(into: .object([:]), port: 8765).after
        let rendered = WritePlan.render(installed)
        #expect(JSONValue.parse(rendered) == installed,
                "the document the deck actually writes does not survive being read back")
    }

    /// **The writer does not trap.** `String(Int64(d))` — the old integer
    /// branch — aborts the process for any `d` past Int64's range, and 1e19
    /// is not an exotic input: an engine-owned `permission_suggestions`
    /// element can carry a number this deck never chose and never validated
    /// the shape of, and it is rendered by exactly this function
    /// (`HookServer.swift`'s `allowAndRemember` branch). A settings write
    /// that can crash the deck on a value the deck did not write is a data-
    /// loss bug wearing a permission feature's clothes.
    @Test("the writer renders a number past Int64's range instead of trapping")
    func writerDoesNotTrapOnAnOutOfRangeNumber() {
        let huge = JSONValue.number(1e19)
        // No crash getting here is the assertion; the exact text is
        // whatever `String(Double)` produces — this only pins that the
        // integer branch was skipped rather than trapped through.
        #expect(WritePlan.render(huge) == String(1e19))

        // And the ordinary case is unaffected: still a bare integer, no
        // trailing `.0`.
        #expect(WritePlan.render(.number(42)) == "42")
    }

    /// The deck installs all seven of its events, not just `PreToolUse`, and
    /// the held pair carries a budget the other five must not.
    ///
    /// `PermissionRequest` is "the event this product is actually about" —
    /// the engine announcing it is about to show a permission dialog — and a
    /// cleanly-installed deck never received it before this: only
    /// `PreToolUse` was registered, so Allow/Deny only ever worked on a
    /// machine carrying a leftover hand-rolled hook. `Notification`'s own
    /// `notification_type: idle_prompt` is the engine saying it has gone back
    /// to waiting for a human — the difference between a turn STALLED for
    /// budget (no `Stop` ever coming) and a long one still running, which
    /// look identical from a prompt with no `Stop` after it (LV19 rows
    /// 17–21). `Stop`, `SessionStart` and `UserPromptSubmit` are what let the
    /// deck's own idle/working transitions actually fire on a
    /// cleanly-installed machine; `SessionEnd` is the matching end-of-life
    /// fact.
    @Test("the deck installs all eight of its events, held and observed")
    func eightEventsAreInstalled() {
        let after = SettingsMerge.install(into: .object([:]), port: 8765).after
        let heldEvents = ["PermissionRequest", "PreToolUse"]
        let observerEvents = ["Notification", "UserPromptSubmit", "SessionStart", "Stop", "SessionEnd",
                              "PostToolUse"]

        for event in heldEvents + observerEvents {
            let entries = after["hooks"]?[event]?.arrayValue ?? []
            #expect(entries.count == 1, Comment(rawValue: "\(event): \(entries.count) entries"))
            let command = entries.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue
            #expect(command?.contains("127.0.0.1:8765/hook") == true,
                    Comment(rawValue: "\(event) does not post to the deck"))
        }
        // The budget lives on the COMMAND now, in `hooks`, not on the entry —
        // an entry-level `timeout` is outside Claude Code's own schema and is
        // silently stripped on its next save, which is the defect that meant
        // the intended budget was never actually in effect.
        for event in heldEvents + observerEvents {
            #expect(after["hooks"]?[event]?.arrayValue?.first?["timeout"] == nil,
                    Comment(rawValue: "\(event): an entry-level timeout is outside the schema"))
        }
        for event in heldEvents {
            let hook = after["hooks"]?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            #expect(hook?["timeout"]?.intValue != nil,
                    Comment(rawValue: "\(event): the held hook lost its per-command budget"))
        }
        for event in observerEvents {
            let hook = after["hooks"]?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            #expect(hook?["timeout"] == nil,
                    Comment(rawValue: "\(event): claims a hold budget it does not use"))
        }
    }

    /// And it all comes back out. A hook left behind by uninstall posts to a
    /// port nothing is listening on, forever.
    @Test("uninstall removes all eight events")
    func allEightEventsAreRemoved() {
        let installed = SettingsMerge.install(into: .object([:]), port: 8765).after
        let removed = SettingsMerge.uninstall(from: installed).after
        for event in ["PermissionRequest", "PreToolUse", "Notification",
                      "UserPromptSubmit", "SessionStart", "Stop", "SessionEnd", "PostToolUse"] {
            #expect(removed["hooks"]?[event] == nil,
                    Comment(rawValue: "uninstall left a \(event) hook posting into a closed port"))
        }
    }

    /// Still: a user's own Notification hook is kept.
    @Test("a pre-existing Notification hook survives installation")
    func theUsersOwnHookSurvives() {
        let theirs = JSONValue.object([
            "matcher": .string("*"),
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string("say something")])]),
        ])
        let document = JSONValue.object(["hooks": .object(["Notification": .array([theirs])])])
        let after = SettingsMerge.install(into: document, port: 8765).after
        let entries = after["hooks"]?["Notification"]?.arrayValue ?? []
        #expect(entries.count == 2, Comment(rawValue: "\(entries.count) entries — the user's was clobbered"))
        #expect(entries.contains(theirs), "the user's own Notification hook was replaced")
        // And uninstall gives them back exactly what they had.
        let removed = SettingsMerge.uninstall(from: after).after
        #expect(removed["hooks"]?["Notification"]?.arrayValue == [theirs])
    }

    /// **A marked entry can be bundling a user's hook too.** Claude Code's own
    /// `/hooks` UI appends a new command into an EXISTING matcher group
    /// rather than creating its own, so the entry the deck signed can end up
    /// carrying somebody else's command under the same matcher. Uninstall
    /// used to drop the WHOLE entry on sight of the marker — the user's hook
    /// went down with it, silently, the moment they had used that UI on the
    /// same matcher the deck was already in.
    @Test("uninstall keeps a user's hook that shares a marked entry with the deck's")
    func uninstallKeepsAForeignHookSharingAMarkedEntry() {
        let installed = SettingsMerge.install(into: .object([:]), port: 8765).after
        let deckHook = installed["hooks"]?["SessionEnd"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
        precondition(deckHook != nil, "install did not write a SessionEnd hook to build the fixture from")
        let auditCommand = "~/bin/audit.sh"
        let auditHook = JSONValue.object(["type": .string("command"), "command": .string(auditCommand)])
        let shared = JSONValue.object([
            SettingsMerge.marker: .bool(true),
            "matcher": .string("*"),
            "hooks": .array([deckHook!, auditHook]),
        ])
        let document = JSONValue.object(["hooks": .object(["SessionEnd": .array([shared])])])

        let after = SettingsMerge.uninstall(from: document).after
        let sessionEnd = after["hooks"]?["SessionEnd"]?.arrayValue ?? []
        #expect(sessionEnd.count == 1,
                Comment(rawValue: "the user's audit hook did not survive uninstall: \(sessionEnd)"))
        #expect(sessionEnd.first?["hooks"]?.arrayValue?
                    .contains { $0["command"]?.stringValue == auditCommand } == true,
                "the user's audit hook was dropped along with the deck's")
        #expect(sessionEnd.first?[SettingsMerge.marker] != .bool(true),
                "the surviving entry is still signed as the deck's, though none of it is")

        // Reconcile-then-uninstall lands the same place: the split already
        // unsigned the sibling (converge's own sibling-safety fix), and
        // uninstall then has only the deck's fully-owned entry left to drop.
        let reconciled = SettingsMerge.reconcile(document, port: 8765).diff.after
        let removedAfterReconcile = SettingsMerge.uninstall(from: reconciled).after
        let sessionEndAfterReconcile = removedAfterReconcile["hooks"]?["SessionEnd"]?.arrayValue ?? []
        #expect(sessionEndAfterReconcile.count == 1,
                Comment(rawValue: "reconcile-then-uninstall left \(sessionEndAfterReconcile)"))
        #expect(sessionEndAfterReconcile.first?["hooks"]?.arrayValue?
                    .contains { $0["command"]?.stringValue == auditCommand } == true)
        #expect(sessionEndAfterReconcile.first?[SettingsMerge.marker] != .bool(true))
    }
}

/// The installed hook must not make a session worse off when the deck is down.
///
/// Observed in a live session: with the deck closed, `curl` exited 7 silently
/// and Claude Code reported "PreToolUse:Bash hook error" on every single tool
/// call. The graceful-degradation rule says no session is ever worse off
/// because the deck exists — and it cannot be worse off for the deck being
/// absent either.
struct InstalledHookSafetyTests {

    private func commands(in document: JSONValue) -> [String] {
        guard case .object(let root) = document,
              case .object(let hooks)? = root["hooks"] else { return [] }
        return hooks.values.flatMap { entries -> [String] in
            (entries.arrayValue ?? []).flatMap { entry -> [String] in
                (entry["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
            }
        }
    }

    @Test("a hook the deck installs cannot fail the tool call it watched")
    func hooksNeverReportFailure() {
        let diff = SettingsMerge.install(into: .object([:]), port: 8765)
        let installed = commands(in: diff.after)

        #expect(!installed.isEmpty, "the install wrote no hook commands to inspect")
        for command in installed {
            #expect(command.hasSuffix("|| true"),
                    Comment(rawValue: "a dead deck makes this a reported hook error: \(command)"))
            #expect(command.contains("--max-time"),
                    Comment(rawValue: "a hung deck holds the tool call open: \(command)"))
        }
    }

    /// Still idempotent with the guard on it — installing twice must produce
    /// the same document, or an upgrade doubles every hook.
    @Test("installing twice is still byte-identical to installing once")
    func stillIdempotent() {
        let once = SettingsMerge.install(into: .object([:]), port: 8765).after
        let twice = SettingsMerge.install(into: once, port: 8765).after
        #expect(once == twice)
    }
}

/// The held command's own numbers, derived from `HoldPolicy.spec.budget`
/// rather than restated as free-standing literals.
///
/// `budgetSeconds` below is computed independently of `SettingsMerge`'s own
/// (internal, unreachable from this target) formula — the ceiling redone by
/// hand — so a genuine regression in the production arithmetic cannot pass by
/// having this test recompute the same wrong thing. Only the RESULT is then
/// also pinned to the literal today's 120 000 ms spec budget produces, so a
/// self-consistent-but-wrong formula change on the production side still
/// shows up as a changed literal here.
struct HeldTimeoutTests {
    /// `HoldPolicy.spec.budget` is 120 000 ms; a whole-seconds ceiling of
    /// that is 120 s exactly, but the arithmetic is written out rather than
    /// assumed, in case the budget ever becomes non-round.
    ///
    /// Force-unwrapped rather than threaded as `Int?`: `.spec` is pinned to
    /// `.seconds(120)` by its own definition and is never `.untilAnswered`,
    /// so this is a fact about a constant, not a possibility this suite has
    /// to handle.
    private static let budgetSeconds = Int((Double(HoldPolicy.spec.budget!.raw) / 1_000).rounded(.up))

    /// The engine's per-command `timeout` needs ten seconds above the budget
    /// so its own "proceed anyway" fallback is the LAST of three things to
    /// fire — after the deck's own prompt `{}` at expiry, after curl's own
    /// (wider) `--max-time`.
    @Test("PermissionRequest and PreToolUse hold past the deck's own budget")
    func heldEventsCarryTheWidenedBudget() {
        let after = SettingsMerge.install(into: .object([:]), port: 8765).after
        for event in ["PermissionRequest", "PreToolUse"] {
            let hook = after["hooks"]?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            let timeout = hook?["timeout"]?.intValue
            let command = hook?["command"]?.stringValue ?? ""

            #expect(timeout == Self.budgetSeconds + 10,
                    Comment(rawValue: "\(event): per-command timeout was \(String(describing: timeout))"))
            #expect(timeout == 130,
                    Comment(rawValue: "\(event): the 120 000 ms spec budget stopped producing 130 s"))
            #expect(command.contains("--max-time \(Self.budgetSeconds + 5) "),
                    Comment(rawValue: "\(event): curl's own cap did not widen: \(command)"))
            #expect(command.contains("--max-time 125 "),
                    Comment(rawValue: "\(event): the 120 000 ms spec budget stopped producing a 125 s cap"))
        }
    }

    @Test("observer events hold nothing and carry no timeout at all")
    func observersCarryNoTimeout() {
        let after = SettingsMerge.install(into: .object([:]), port: 8765).after
        for event in ["Notification", "UserPromptSubmit", "SessionStart", "Stop", "SessionEnd"] {
            let hook = after["hooks"]?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            #expect(hook?["timeout"] == nil,
                    Comment(rawValue: "\(event): an observer must not claim a hold budget"))
            #expect(hook?["command"]?.stringValue?.contains("--max-time 5 ") == true,
                    Comment(rawValue: "\(event): lost the floor that keeps a closed deck from stalling a call"))
            #expect(hook?["command"]?.stringValue?.contains("--max-time 125 ") == false,
                    Comment(rawValue: "\(event): widened to the held budget though nothing here is ever held"))
        }
    }
}

/// Refusing to send, and saying which refusal it was.
///
/// Both readings refuse — that part was always right. What was wrong is that
/// both reported `composerBusy`, so a deck pointed at a zsh prompt told the
/// user their composer was not empty. Observed on a live session: `/compact`
/// refused, and the reason on screen described something that had not happened.
struct ComposerRefusalTests {

    /// The recorded empty composer: the prompt glyph followed by U+00A0, a
    /// NO-BREAK SPACE. An ASCII-only trim reads that as text and refuses every
    /// send forever, which is why this is pinned to the real bytes.
    @Test("a live Claude prompt with nothing typed at it may be sent to")
    func anEmptyComposerAccepts() {
        let screen = "some output\n❯\u{00A0}\n  main | ~/project | ctx:3%"
        #expect(Composer.read(screen) == .empty)
        #expect(Composer.block(for: .empty) == nil)
    }

    @Test("a composer holding a draft refuses, and says it is a draft")
    func aDraftRefusesAsADraft() {
        #expect(Composer.read("❯\u{00A0}reply with something") == .holdingText)
        #expect(Composer.block(for: .holdingText) == .composerBusy)
        #expect(ActionBlock.composerBusy.message.contains("composer"))
    }

    /// **The bug, as a test.** A shell has no prompt glyph, and the deck used
    /// to report that as a full composer.
    @Test("a shell refuses, and does NOT claim the composer is full")
    func aShellRefusesAsAShell() {
        let shell = "** TEST EXECUTE FAILED **\ndev@devbox openagentdeck % \n"
        #expect(Composer.read(shell) == .notASession)
        #expect(Composer.block(for: .notASession) == .surfaceNotASession,
                "a shell is still reported as a busy composer")
        #expect(!ActionBlock.surfaceNotASession.message.contains("composer is not empty"),
                "the reason describes a draft that does not exist")
    }

    /// The two refusals must not read the same, or splitting them bought
    /// nothing.
    @Test("the two refusals give different advice")
    func theRefusalsDiffer() {
        #expect(ActionBlock.composerBusy.message != ActionBlock.surfaceNotASession.message)
    }
}

/// The user-configurable hold budget, at the file this app writes.
/// `HeldTimeoutTests` above pins `.spec`'s own 120 000 ms; these pin what a
/// DIFFERENT `HoldPolicy` — the shape `Reducer.reduce`'s `.prefsChanged` now
/// produces from `DeckPrefs.holdBudget` — writes instead, and that the
/// recognition machinery (`isDeckHook`) still finds its own writing
/// afterward. Every function called here is `public` (declared inside
/// `public extension SettingsMerge` in `Reconcile.swift`), so this needs no
/// `@testable` import, the same as `HeldTimeoutTests` beside it.
struct ConfigurableBudgetTests {

    private func heldEntry(_ document: JSONValue, event: String = "PermissionRequest") -> JSONValue? {
        document["hooks"]?[event]?.arrayValue?.first
    }
    private func heldCommand(_ document: JSONValue, event: String = "PermissionRequest") -> String {
        heldEntry(document, event: event)?["hooks"]?.arrayValue?.first?["command"]?.stringValue ?? ""
    }

    /// `seconds(300)`: five seconds wider for curl, ten for the engine — the
    /// same `+5`/`+10` arithmetic `HeldTimeoutTests` pins for the 120 s
    /// default, over a budget that is not it.
    @Test("a seconds(300) policy installs a 305 s curl ceiling and a 310 s engine timeout")
    func secondsPolicyInstallsItsOwnNumbers() {
        let policy = HoldPolicy(budget: HoldBudget.seconds(300).millis,
                                armDelay: Millis(250), reArmDelay: Millis(400))
        let after = SettingsMerge.install(into: .object([:]), port: 8765, policy: policy).after
        for event in ["PermissionRequest", "PreToolUse"] {
            let timeout = heldEntry(after, event: event)?["hooks"]?.arrayValue?.first?["timeout"]?.intValue
            #expect(timeout == 310, "\(event): expected a 310 s engine timeout, got \(String(describing: timeout))")
            #expect(heldCommand(after, event: event).contains("--max-time 305 "),
                    Comment(rawValue: "\(event): curl's own ceiling did not track the 300 s budget"))
        }
    }

    /// `.untilAnswered`: no deck-side ceiling on the connection at all — the
    /// `--max-time` flag is ABSENT, not merely large — and the engine's own
    /// per-command `timeout` is the fixed 24-hour safety net, because there
    /// is no documented "wait forever" value to ask it for instead.
    @Test("an untilAnswered policy installs no curl ceiling and the 24-hour engine fallback")
    func untilAnsweredPolicyInstallsNoCeiling() {
        let policy = HoldPolicy(budget: HoldBudget.untilAnswered.millis,
                                armDelay: Millis(250), reArmDelay: Millis(400))
        let after = SettingsMerge.install(into: .object([:]), port: 8765, policy: policy).after
        for event in ["PermissionRequest", "PreToolUse"] {
            let timeout = heldEntry(after, event: event)?["hooks"]?.arrayValue?.first?["timeout"]?.intValue
            #expect(timeout == 86_400,
                    Comment(rawValue: "\(event): expected the 24-hour engine fallback, got "
                            + "\(String(describing: timeout))"))
            let command = heldCommand(after, event: event)
            #expect(!command.contains("--max-time"),
                    Comment(rawValue: "\(event): a forever hold still carries a curl ceiling: \(command)"))
            #expect(command.contains("|| true"), "\(event): lost the graceful-degradation tail")
        }
        // Observer events are untouched by the policy either way — nothing
        // about them was ever held, and nothing here should start pretending
        // otherwise.
        let observerCommand = heldCommand(after, event: "Notification")
        #expect(observerCommand.contains("--max-time 5 "))
    }

    /// A file installed under one budget, read back against a DIFFERENT one:
    /// the drift is real, not rounding, and it is exactly the gap between
    /// what is on disk and what THIS policy would have written.
    @Test("a 130 s file reads as drifted against a policy that would install 310 s")
    func driftIsDetectedAgainstADifferentBudget() {
        let installedUnderSpec = SettingsMerge.install(into: .object([:]), port: 8765).after
        #expect(SettingsMerge.installedTimeoutMillis(installedUnderSpec) == 130_000,
                "the fixture for this test is not the 120 s spec budget it claims to be")

        let threeHundred = HoldPolicy(budget: HoldBudget.seconds(300).millis,
                                      armDelay: Millis(250), reArmDelay: Millis(400))
        let drift = SettingsMerge.timeoutDrift(installedUnderSpec, policy: threeHundred)
        #expect(drift?.installed == 130_000)
        #expect(drift?.expected == 310_000)

        // And reconciling that same file against that same 300 s policy
        // produces a real diff — the drift is fixable by the control that
        // already exists, not a second repair path.
        let repaired = SettingsMerge.reconcile(installedUnderSpec, port: 8765, policy: threeHundred)
        #expect(!repaired.isNoOp, "a genuine 130 s vs 310 s drift reconciled to nothing")
        #expect(SettingsMerge.timeoutDrift(repaired.diff.after, policy: threeHundred) == nil,
                "the repair did not actually converge to the new budget")

        // No drift at all when the file already agrees with the policy
        // asking about it.
        #expect(SettingsMerge.timeoutDrift(installedUnderSpec, policy: .spec) == nil)
    }

    /// **Both `HoldBudget` shapes survive a Claude Code save, under ANY
    /// currently-configured policy.** A save keeps every schema-valid key —
    /// the per-command `timeout`, in either shape — and drops only the
    /// marker, exactly the scenario `ReconcileTests.aStrippedFileIsStillTheDecks`
    /// pins for the 120 s default.
    ///
    /// This test used to assert the OPPOSITE for the cross-budget case: a
    /// stripped 300 s entry checked against `.spec` (120 s) was asserted
    /// `!isDeckHook`, which enshrined the defect rather than catching it. A
    /// budget change does not rewrite a saved file by itself — Connect/Repair
    /// does that — so the entry actually on disk is very often the shape a
    /// PAST policy wrote, not the current one, and it is still the deck's own
    /// hook either way. `Reconcile.swift`'s `canonicalPort` now derives the
    /// WRITING budget from the entry's own command instead of trusting
    /// whichever `policy` a caller happens to pass, so recognition is
    /// asserted here against every policy this test can name — the one that
    /// wrote the entry, `.spec`, and each other shape — not just one.
    @Test("a marker-stripped entry is recognised under both budget shapes, whatever policy is asked")
    func bothBudgetShapesSurviveAStrip() {
        let written: [HoldBudget] = [.seconds(300), .untilAnswered]
        let asked: [HoldBudget] = written + [.standard]
        for fileBudget in written {
            let filePolicy = HoldPolicy(budget: fileBudget.millis,
                                        armDelay: Millis(250), reArmDelay: Millis(400))
            let after = SettingsMerge.install(into: .object([:]), port: 8765, policy: filePolicy).after
            guard let entry = heldEntry(after) else {
                Issue.record("install wrote no PermissionRequest entry for \(fileBudget)")
                continue
            }
            guard case .object(var fields) = entry else {
                Issue.record("the entry is not an object")
                continue
            }
            fields.removeValue(forKey: SettingsMerge.marker)     // what a Claude Code save leaves
            let stripped = JSONValue.object(fields)

            for askedBudget in asked {
                let askedPolicy = HoldPolicy(budget: askedBudget.millis,
                                             armDelay: Millis(250), reArmDelay: Millis(400))
                #expect(SettingsMerge.isDeckHook(stripped, policy: askedPolicy),
                        Comment(rawValue: "a stripped entry written under \(fileBudget) was not "
                                + "recognised when asked against \(askedBudget)"))
            }
        }
    }

    /// **The three cross-budget probes a review found by hand.** Each pairs a
    /// file WRITTEN under one `HoldBudget` with a DIFFERENT one currently
    /// configured — exactly the shape of changing the Settings picker
    /// without pressing Connect afterward, which does not rewrite the file by
    /// itself. Before family recognition, every one of these left the deck's
    /// own hook reading as a candidate, `timeoutDrift` reading `(nil,
    /// expected)` — which is what hid the Settings drift notice exactly when
    /// it was needed — `reconcile` appending a permanent second hook beside
    /// the unrecognised one (every permission posting twice, the SECOND
    /// arrival tripping `handle`'s supersede-release), and `uninstall`
    /// leaving the stale entry behind.
    @Test("a stripped file survives a policy change: recognised, drift, one converged entry, removable",
          arguments: [
            (label: "300-file under 120-policy", file: HoldBudget.seconds(300), current: HoldBudget.standard),
            (label: "forever-file under seconds-policy", file: HoldBudget.untilAnswered, current: HoldBudget.standard),
            (label: "seconds-file under forever-policy", file: HoldBudget.seconds(300), current: HoldBudget.untilAnswered),
          ])
    func crossBudgetFileSurvivesAPolicyChange(
        _ probe: (label: String, file: HoldBudget, current: HoldBudget)
    ) {
        func policy(_ budget: HoldBudget) -> HoldPolicy {
            HoldPolicy(budget: budget.millis, armDelay: Millis(250), reArmDelay: Millis(400))
        }
        // The formula `heldTimeoutSeconds`/`budgetSeconds` compute internally
        // — reimplemented here, independently, the same discipline
        // `HeldTimeoutTests.budgetSeconds` already applies to the 120 s
        // default, so this cannot pass by calling the code under test to
        // check itself.
        func expectedTimeoutSeconds(_ budget: HoldBudget) -> Int {
            switch budget {
            case .seconds(let n): return n + 10
            case .untilAnswered: return 86_400
            }
        }

        let filePolicy = policy(probe.file)
        let currentPolicy = policy(probe.current)
        let installed = SettingsMerge.install(into: .object([:]), port: 8765, policy: filePolicy).after
        guard case .object(var root) = installed, case .object(var hooks)? = root["hooks"] else {
            Issue.record("\(probe.label): install produced no hooks object")
            return
        }
        for (event, list) in hooks {
            guard case .array(let entries) = list else { continue }
            hooks[event] = .array(entries.map { entry in
                guard case .object(var fields) = entry else { return entry }
                fields.removeValue(forKey: SettingsMerge.marker)    // what a Claude Code save leaves
                return .object(fields)
            })
        }
        root["hooks"] = .object(hooks)
        let stripped = JSONValue.object(root)

        // Recognised — never surfaced as a candidate needing the user's consent.
        #expect(SettingsMerge.isDeckHook(heldEntry(stripped) ?? .null, policy: currentPolicy),
                Comment(rawValue: "\(probe.label): the stripped entry was not recognised"))
        #expect(SettingsMerge.candidates(in: stripped, policy: currentPolicy).isEmpty,
                Comment(rawValue: "\(probe.label): the deck's own hook surfaced as a candidate: "
                        + "\(SettingsMerge.candidates(in: stripped, policy: currentPolicy))"))

        // Drift: the file's OWN installed number against what the CURRENT
        // policy expects — real when they differ, and never `(nil, ...)`.
        let installedMillis = SettingsMerge.installedTimeoutMillis(stripped)
        #expect(installedMillis == expectedTimeoutSeconds(probe.file) * 1_000,
                Comment(rawValue: "\(probe.label): installedTimeoutMillis read "
                        + "\(String(describing: installedMillis)), want the file's own "
                        + "\(expectedTimeoutSeconds(probe.file) * 1_000)"))
        let drift = SettingsMerge.timeoutDrift(stripped, policy: currentPolicy)
        if expectedTimeoutSeconds(probe.file) == expectedTimeoutSeconds(probe.current) {
            #expect(drift == nil, Comment(rawValue: "\(probe.label): the two policies agree; no drift"))
        } else {
            #expect(drift?.installed == installedMillis,
                    Comment(rawValue: "\(probe.label): drift.installed is not the file's own number"))
            #expect(drift?.expected == expectedTimeoutSeconds(probe.current) * 1_000,
                    Comment(rawValue: "\(probe.label): drift.expected does not match the current policy"))
        }

        // Reconcile converges to ONE current-shape entry, idempotently.
        let repaired = SettingsMerge.reconcile(stripped, port: 8765, policy: currentPolicy)
        for event in ["PermissionRequest", "PreToolUse"] {
            guard case .array(let list)? = repaired.diff.after["hooks"]?[event] else {
                Issue.record("\(probe.label): \(event) has no hooks array after reconcile")
                continue
            }
            #expect(list.count == 1,
                    Comment(rawValue: "\(probe.label): \(event) converged to \(list.count) entries, "
                            + "not 1 — the duplicate that is the steady state"))
        }
        #expect(SettingsMerge.timeoutDrift(repaired.diff.after, policy: currentPolicy) == nil,
                Comment(rawValue: "\(probe.label): reconcile did not converge to the current policy's own numbers"))
        #expect(SettingsMerge.reconcile(repaired.diff.after, port: 8765, policy: currentPolicy).isNoOp,
                Comment(rawValue: "\(probe.label): reconciling the repaired file again still wanted work"))

        // Uninstall removes it outright — no orphan left on disk.
        let uninstalled = SettingsMerge.uninstall(from: stripped, policy: currentPolicy)
        #expect(!SettingsMerge.isInstalled(uninstalled.after),
                Comment(rawValue: "\(probe.label): uninstall left the deck's hook behind"))
    }
}
