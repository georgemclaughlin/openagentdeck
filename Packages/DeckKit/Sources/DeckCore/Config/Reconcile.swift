//
//  Reconcile.swift · DeckCore/Config
//
//  Connecting the deck is a convergence, not a write.
//
//  The question asked of each hook entry is "is this a deck hook?", judged by
//  what the entry does, so connecting can converge from any starting state:
//  adopt what is already there, repair what is wrong with it, leave what is
//  right alone, and touch nothing that belongs to somebody else.
//
//  Consequences:
//  - There is no separate repair flow. Port drift, hold-budget drift, a
//    duplicate hook, or a hook missing the `|| true` (which keeps a closed deck
//    from turning every Bash call into a reported error) are all fixed by the
//    same operation, from any state, any number of times.
//  - It can answer without writing. A reconciliation whose diff is a no-op
//    means "already connected", computed from the file rather than from a
//    remembered preference.
//
//  The hook command line has carried three defects that adoption repairs:
//  single quotes that suppressed `${CMUX_SURFACE_ID}` expansion, a missing
//  `--data-binary @-` (empty bodies), and a missing `|| true`.
//

import Foundation

/// What connecting would do, in a form a person can read before agreeing to it.
public struct Reconciliation: Equatable, Sendable {
    public let diff: ConfigDiff
    /// One line per thing that changes, in plain words. The JSON diff is the
    /// proof; this is the explanation, and a person deciding whether to agree
    /// deserves the explanation first.
    public let steps: [String]

    /// Unsigned hooks that mention a loopback `/hook`. The deck will not touch
    /// one without being told to; see `isDeckHook`.
    public let candidates: [String]

    public var isNoOp: Bool { diff.isNoOp }

    public init(diff: ConfigDiff, steps: [String], candidates: [String] = []) {
        self.diff = diff; self.steps = steps; self.candidates = candidates
    }
}

public extension SettingsMerge {

    // ------------------------------------------------------ recognising ours

    /// **The deck converges hooks it SIGNED. It asks about everything else.**
    ///
    /// Recognising a deck hook by parsing its command was tried and was always
    /// too broad. Each of these defeated a successive attempt:
    ///
    ///     whole command      -d "surface=prod" ... /hook
    ///     whole query        /hook?resurface=true
    ///     past the '#'       /hook?id=1#surface=prod
    ///     one URL only       -d "u=http://…/hook?surface=x" attacker.test/collect
    ///
    /// `curl` accepts a destination with no scheme, so counting URLs cannot
    /// separate the request target from a URL that is merely DATA. Even without an
    /// adversary, a hook that backs up `settings.json` starts matching once the
    /// deck is connected, because that file then contains the deck's hook line.
    /// Parsing sh and curl's argument grammar to decide would risk deleting
    /// somebody's hook, to gain only not duplicating a hand-written one.
    ///
    /// So an entry the deck SIGNED is the deck's and is converged freely. An
    /// unsigned entry that might be the deck's is a CANDIDATE: surfaced with its
    /// command and adopted only if a person says so.
    ///
    /// **One exception, and it is equality, not recognition.** Claude Code
    /// rewrites `settings.json` on its own saves and drops keys outside its
    /// schema, the deck's marker among them. An entry whose every command is
    /// BYTE-IDENTICAL to what `hookCommand(port:)` emits is the deck's by
    /// construction; none of the four commands above can pass that gate.
    ///
    /// `policy` is kept for caller-signature stability. A signed entry is
    /// recognised whatever its budget says, and a marker-stripped entry's budget
    /// is read from its own command (`impliedHeldBudget`), not from `policy`.
    static func isDeckHook(_ entry: JSONValue, policy: HoldPolicy = .spec) -> Bool {
        isOurs(entry) || canonicalPort(of: entry, policy: policy) != nil
    }

    /// The port this command posts to, **if and only if the command is the
    /// deck's own, verbatim** — in either shape. A lenient parse finds a candidate
    /// port and exact regeneration accepts it, so acceptance is `==` against a
    /// writer and no string-matcher hole can get through.
    ///
    /// Two writers are checked: `hookCommand` for the five observed events and
    /// `heldHookCommand` for the two held ones, which differ only in
    /// `--max-time`. Both are needed because an older installer wrote the
    /// observer-shaped 5 s command into `PreToolUse`; that must still be
    /// recognised as the deck's while `converge` repairs it to the held shape.
    ///
    /// **The held check covers the whole `HoldBudget` family, not just
    /// `policy`.** A budget change does not rewrite a saved file by itself, so a
    /// marker-stripped held entry on disk was often written under a different
    /// budget than the current one. Comparing against only the current budget made
    /// the deck's own hook read as a candidate, `reconcile` appended a duplicate
    /// (as the steady state), and `uninstall` left the orphan. `impliedHeldBudget`
    /// parses the command's own `--max-time` to nominate the budget,
    /// `derivedHeldPolicy` builds a `HoldPolicy` from it, and `heldHookCommand`
    /// regenerates against it. `==` still decides.
    static func canonicalHookPort(_ command: String, policy: HoldPolicy = .spec) -> Int? {
        guard let port = loopbackPort(in: command) else { return nil }
        if hookCommand(port: port) == command { return port }
        let derived = derivedHeldPolicy(from: command, policy: policy)
        return heldHookCommand(port: port, policy: derived) == command ? port : nil
    }

    /// The `HoldBudget` a held command's own `--max-time` implies — leniently
    /// PARSED, never used to accept anything by itself. `heldHookCommand` writes
    /// `--max-time (budgetSeconds + 5)` for a `.seconds` budget and omits the flag
    /// for `.untilAnswered`; this undoes that arithmetic so the caller can
    /// regenerate the one command (and, via `derivedHeldPolicy`, the one stripped
    /// entry) that budget would produce and compare with `==`. This is the same
    /// "lenient parse to nominate, exact regeneration to accept" rule `relayWrapped`
    /// (`Settings.swift`) uses.
    ///
    /// A missing or malformed flag nominates `.untilAnswered`: right when the flag
    /// is genuinely absent, and harmless otherwise since a nomination that does
    /// not round-trip is rejected downstream.
    ///
    /// Sub-floor values (`N - 5 < HoldBudget.floorSeconds`) return nil: a shape the
    /// deck can never write is not the deck's, so a hand-crafted `--max-time 0`
    /// must stay a candidate.
    static func impliedHeldBudget(in command: String) -> HoldBudget? {
        guard let range = command.range(of: "--max-time "),
              let n = Int(command[range.upperBound...].prefix { $0.isNumber })
        else { return nil }
        let budget = n - 5
        return budget >= HoldBudget.floorSeconds ? .seconds(budget) : nil
    }

    /// `policy`, with its budget replaced by whatever `command`'s own
    /// `--max-time` implies. Only the budget matters: `armDelay`, `reArmDelay` and
    /// `longPress` play no part in `heldHookCommand`, `heldTimeoutSeconds` or
    /// `strippedHeldEntry`, so they are carried over unexamined.
    private static func derivedHeldPolicy(from command: String, policy: HoldPolicy) -> HoldPolicy {
        let budget = impliedHeldBudget(in: command) ?? .untilAnswered
        return HoldPolicy(budget: budget.millis, armDelay: policy.armDelay,
                         reArmDelay: policy.reArmDelay, longPress: policy.longPress)
    }

    /// The port of an UNSIGNED entry that is nonetheless the deck's own
    /// writing — the shape a Claude Code save leaves behind: marker dropped,
    /// matcher and command list intact, and for a held event the per-command
    /// `timeout` intact too (it lives inside `hooks`, is schema-valid, and so is
    /// not touched by a save).
    ///
    /// Equality is against the WHOLE stripped entry, not the command alone: the
    /// deck's command pasted into an entry with somebody's own matcher or extra
    /// `timeout` stays theirs, and stays a question. Held shape is tried first,
    /// then observer; an entry matching neither is somebody else's.
    ///
    /// The held comparison uses `derivedHeldPolicy(from: first, policy:)`, the same
    /// budget `canonicalHookPort` matched the command against, so the two checks
    /// cannot disagree about which budget wrote the entry.
    static func canonicalPort(of entry: JSONValue, policy: HoldPolicy = .spec) -> Int? {
        let commands = arrayOf(entry["hooks"] ?? .array([]))
            .compactMap { $0["command"]?.stringValue }
        guard let first = commands.first, let port = canonicalHookPort(first, policy: policy)
        else { return nil }
        let derived = derivedHeldPolicy(from: first, policy: policy)
        if entry == strippedHeldEntry(port: port, policy: derived) { return port }
        if entry == strippedObserverEntry(port: port) { return port }
        // The `PostToolUse` shape: the same command as an observer entry, under the
        // one matcher that is not `"*"`. This reads an ENTRY with no event name, so it
        // is tried unconditionally rather than threading `event` through every caller.
        // A `"*"` entry never collides; `==` on the whole entry tells them apart.
        if entry == strippedObserverEntry(port: port, matcher: SettingsMerge.matcher(for: "PostToolUse")) {
            return port
        }
        return nil
    }

    /// What `deckEntry` looks like after a Claude Code save: marker gone, the
    /// per-command `timeout` still there (it is schema-valid and lives inside
    /// `hooks`, so a save has no reason to strip it).
    static func strippedHeldEntry(port: Int, policy: HoldPolicy = .spec) -> JSONValue {
        .object([
            "matcher": .string("*"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(heldHookCommand(port: port, policy: policy)),
                "timeout": .number(Double(heldTimeoutSeconds(policy))),
            ])]),
        ])
    }

    /// What `observerEntry` looks like after a Claude Code save. An observer never
    /// carried a `timeout`, so a save strips only the marker. `matcher` defaults to
    /// `"*"`; only `PostToolUse` recognition (`canonicalPort`) passes another.
    static func strippedObserverEntry(port: Int, matcher: String = "*") -> JSONValue {
        .object([
            "matcher": .string(matcher),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(hookCommand(port: port)),
            ])]),
        ])
    }

    /// Every spelling of "this machine" a person might reasonably type.
    static let loopbackHosts = ["127.0.0.1", "localhost", "[::1]", "0.0.0.0"]

    /// The port of a loopback `/hook` in this command.
    ///
    /// Used on entries the deck signed, where ownership is settled and only the
    /// port is in question. Don't demand the deck's query keys here: the recorded
    /// fixture `already-installed.json` carries the marker and a bare
    /// `curl -s -X POST http://127.0.0.1:8765/hook`, and a stricter rule made the
    /// deck report "Not connected yet" over a working installation.
    static func loopbackPort(in command: String) -> Int? {
        var search = command[...]
        while let scheme = search.range(of: "://") {
            let after = search[scheme.upperBound...]
            for host in loopbackHosts where after.hasPrefix("\(host):") {
                let rest = after.dropFirst(host.count + 1)
                let digits = rest.prefix { $0.isNumber }
                if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix("/hook") {
                    return Int(digits)
                }
            }
            search = after
        }
        return nil
    }

    /// Unsigned entries that mention a loopback `/hook`, with the command a
    /// person needs in order to decide.
    ///
    /// **Deliberately loose.** Surfacing a hook that turns out not to be the
    /// deck's costs one question nobody has to answer twice. Missing one produces
    /// the duplicate this mechanism exists to prevent, so every event in
    /// `SettingsMerge.allEvents` is scanned, not just `PreToolUse`.
    ///
    /// Results are unioned and deduplicated in event order: the same command
    /// pasted under two events is one question. `event` narrows to a single event,
    /// chiefly for tests.
    static func candidates(in document: JSONValue, event: String? = nil,
                           policy: HoldPolicy = .spec) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for event in event.map({ [$0] }) ?? allEvents {
            for entry in arrayOf(document["hooks"]?[event] ?? .array([]))
                where !isDeckHook(entry, policy: policy) {
                for hook in arrayOf(entry["hooks"] ?? .array([])) {
                    guard let command = hook["command"]?.stringValue,
                          loopbackPort(in: command) != nil,
                          seen.insert(command).inserted
                    else { continue }
                    out.append(command)
                }
            }
        }
        return out
    }

    /// The port the installed hooks point at, or nil. `isDeckHook`, not
    /// `isOurs`: a marker-stripped installation still names its port, and the
    /// whole connection state hangs on this reading.
    ///
    /// Scans all `allEvents` (held pair first). On a converged file any event gives
    /// the same answer; the scan matters for a partially stripped or hand-edited
    /// file, which should read as connected if any managed event still names a
    /// port.
    static func installedPort(_ document: JSONValue, policy: HoldPolicy = .spec) -> Int? {
        for event in allEvents {
            for entry in arrayOf(document["hooks"]?[event] ?? .array([]))
                where isDeckHook(entry, policy: policy) {
                for hook in arrayOf(entry["hooks"] ?? .array([])) {
                    if let command = hook["command"]?.stringValue,
                       let port = loopbackPort(in: command) { return port }
                }
            }
        }
        return nil
    }

    /// **Whether the document is shaped the way the deck expects**, or a reason
    /// it is not.
    ///
    /// `objectOf` and `arrayOf` coerce anything unexpected to an empty container,
    /// so `"hooks": "please"` or an object where `PreToolUse` should be an array
    /// would be silently replaced rather than merged into. That is the overwrite
    /// `ConfigDocument.unreadable` refuses, one level down. Claude Code's schema
    /// requires these shapes, so this is rarely hit, but a coercion is a touch of
    /// something the deck does not understand.
    static func misshapen(_ document: JSONValue) -> String? {
        guard let hooks = document["hooks"] else { return nil }
        guard case .object(let events) = hooks else {
            return "its \"hooks\" is not an object"
        }
        for event in allEvents {
            guard let list = events[event] else { continue }
            guard case .array(let entries) = list else {
                return "its \"hooks.\(event)\" is not an array"
            }
            for entry in entries where entry["hooks"] != nil {
                guard case .array = entry["hooks"]! else {
                    return "an entry in \"hooks.\(event)\" has a non-array \"hooks\""
                }
            }
        }
        return nil
    }

    /// Adopting a candidate: mark it as the deck's, so the next reconcile
    /// converges it like any other signed entry.
    ///
    /// Scans every event `candidates` can surface one from. Signing only
    /// `PreToolUse` would leave a candidate adopted from another event unsigned,
    /// and `converge` would read it as a fresh candidate again. `event` narrows to
    /// a single event, as in `candidates`.
    ///
    /// Only touches an event's array when that event already has one; an absent
    /// event is not a reason to write `[]` into it.
    static func adopt(_ document: JSONValue, commands: Set<String>,
                      event: String? = nil) -> JSONValue {
        guard !commands.isEmpty else { return document }
        var root = objectOf(document)
        var hooks = objectOf(root["hooks"] ?? .object([:]))
        for event in event.map({ [$0] }) ?? allEvents {
            guard let existing = hooks[event] else { continue }
            hooks[event] = .array(arrayOf(existing).map { entry in
                guard !isOurs(entry) else { return entry }
                let mine = arrayOf(entry["hooks"] ?? .array([]))
                    .contains { commands.contains($0["command"]?.stringValue ?? "") }
                guard mine else { return entry }
                var marked = objectOf(entry)
                marked[marker] = .bool(true)
                return .object(marked)
            })
        }
        root["hooks"] = .object(hooks)
        return .object(root)
    }

    /// What connecting to `port` would change, and why.
    ///
    /// `addStatusline` creates a statusline where the user has none. It is off by
    /// default because that is a consent decision rather than a layout fix.
    static func reconcile(_ document: JSONValue, port: Int,
                          policy: HoldPolicy = .spec,
                          addStatusline: Bool = false,
                          adopting: Set<String> = []) -> Reconciliation {
        let before = document
        // Whatever the person agreed to adopt is signed FIRST, and from there
        // it is an ordinary signed entry with no special case anywhere below.
        let document = adopt(document, commands: adopting)
        var root = objectOf(document)
        var hooks = objectOf(root["hooks"] ?? .object([:]))
        var steps: [String] = []

        // All managed events, converged the same way from any starting state.
        // `PermissionRequest` and `PostToolUse` carry their own sentence when they are
        // being ADDED, so an upgrade from an older install explains itself instead of
        // adding the hook silently.
        let addedSentences: [String: String] = [
            "PermissionRequest": "Register the PermissionRequest hook — the event that opens "
                                 + "a decision on the deck; without it Allow and Deny never appear.",
            "PostToolUse": "Register the PostToolUse hook, scoped to AskUserQuestion — the event "
                          + "that tells the deck a question was answered at the terminal; without "
                          + "it, a released question's mirror never learns what was chosen.",
        ]
        for event in allEvents {
            let canonical = heldEvents.contains(event) ? deckEntry(port: port, policy: policy)
                                                        : observerEntry(port: port, matcher: matcher(for: event))
            let existing = arrayOf(hooks[event] ?? .array([]))
            let (converged, note) = converge(existing, to: canonical, event: event,
                                             policy: policy, added: addedSentences[event])
            hooks[event] = .array(converged)
            steps.append(contentsOf: note)
        }
        root["hooks"] = .object(hooks)

        // The relay WRAPS. A pre-existing statusline keeps rendering its own
        // output unmodified and is kept verbatim beside the composed command,
        // so disconnecting restores it by copying rather than by parsing a
        // string back apart.
        if let existing = originalStatusline(document) {
            let wrapped = relayCommand(wrapping: existing, port: port)
            if root["statusLine"]?["command"]?.stringValue != wrapped {
                root["statusLine"] = .object([
                    "type": .string("command"),
                    "command": .string(wrapped),
                    marker: .bool(true),
                    original: .string(existing),
                ])
                steps.append("Wrap your statusline so the deck can read context and usage. "
                             + "Yours keeps rendering exactly as it does now.")
            }
        } else if document["statusLine"] == nil, addStatusline {
            root["statusLine"] = .object([
                "type": .string("command"),
                "command": .string(bareRelayCommand(port: port)),
                marker: .bool(true),
            ])
            steps.append("Add a statusline. It is what feeds the context gauge and the "
                         + "usage windows; you do not have one today.")
        } else if let line = root["statusLine"], line[marker] == .bool(true),
                  let storedOriginal = line[Self.original]?.stringValue {
            // Already ours and already wrapping; only the port can drift. The stored
            // original is unwound first: a file damaged by an old relay-nesting bug reads
            // `relay(mine)` back as the "original", and wrapping that verbatim would add
            // another layer on every reconcile.
            //
            // Don't rename this local to `original`: that is also this type's static key
            // constant, and a local would shadow it in the dictionary literal below,
            // keying the entry by the command string instead of by
            // `"x-openagentdeck-original"`.
            let restoredOriginal = unwrapped(storedOriginal)
            let wrapped = relayCommand(wrapping: restoredOriginal, port: port)
            if line["command"]?.stringValue != wrapped {
                root["statusLine"] = .object([
                    "type": .string("command"), "command": .string(wrapped),
                    marker: .bool(true), original: .string(restoredOriginal),
                ])
                steps.append("Point your statusline relay at port \(port).")
            }
        }

        let after = JSONValue.object(root)
        let diff = ConfigDiff(before: before, after: after,
                              summary: steps.isEmpty ? "already connected"
                                                     : "connect the deck on 127.0.0.1:\(port)")
        return Reconciliation(diff: diff, steps: steps,
                              candidates: candidates(in: document, policy: policy))
    }

    /// One event's array of hooks, converged.
    ///
    /// Position is preserved: a deck hook that was third stays third. Hook order
    /// is the user's, and reordering it to tidy a diff is not our call.
    ///
    /// `added` overrides the generic "Add the deck's `event` hook." sentence for an
    /// event whose absence needs more explaining (`PermissionRequest`,
    /// `PostToolUse`).
    private static func converge(_ existing: [JSONValue], to canonical: JSONValue,
                                 event: String, policy: HoldPolicy = .spec,
                                 added: String? = nil) -> ([JSONValue], [String]) {
        // **A matched entry may not be the deck's alone.** Claude Code lets one entry
        // bundle several commands under a single matcher, so replacing the whole entry
        // would silently delete anybody else's hook sharing it.
        //
        // An entry is only REPLACED when every command in it is the deck's. A shared
        // one is stripped of the deck's command and kept, and the deck takes an entry
        // of its own; a held event's `timeout` lives on the deck's own command and
        // must not be imposed on somebody else's hook.
        //
        // The kept sibling also loses the deck's MARKER. Keeping it left an entry
        // signed by the deck but holding nothing of the deck's, which every later
        // reconcile rediscovered as "shared" and reported phantom
        // Move/Update/Remove-duplicate steps against an unchanged file. An unmarked
        // sibling is an ordinary foreign entry and is left alone.
        var out: [JSONValue] = []
        var steps: [String] = []
        var placed = false
        var adopted = false
        var duplicates = 0
        var strippedSiblings = 0

        for entry in existing {
            guard isDeckHook(entry, policy: policy) else { out.append(entry); continue }

            let wasMarked = isOurs(entry)
            let commands = arrayOf(entry["hooks"] ?? .array([]))
            // Within an entry the deck signed, its own command is the one
            // posting to a loopback `/hook`; anything else bundled under the
            // same matcher belongs to the user and is kept.
            let foreign = commands.filter { hook in
                guard let command = hook["command"]?.stringValue else { return true }
                return loopbackPort(in: command) == nil
            }

            if !foreign.isEmpty {
                // Shared. Keep it minus the deck's command and minus the deck's marker:
                // what is left is not the deck's to sign, and a signed entry holding nothing
                // of the deck's reads as "shared" again on every later reconcile (phantom
                // steps on an unchanged file).
                var kept = objectOf(entry)
                kept["hooks"] = .array(foreign)
                kept.removeValue(forKey: marker)
                out.append(.object(kept))
                strippedSiblings += 1
            }

            if placed {
                duplicates += 1
            } else {
                out.append(canonical)
                placed = true
                if !wasMarked { adopted = true }
                else if entry != canonical { steps.append("Update the deck's \(event) hook.") }
            }
        }

        if !placed { return (out + [canonical], [added ?? "Add the deck's \(event) hook."]) }
        if adopted {
            // Only a marker-stripped entry can reach here unmarked: a hook the person
            // agreed to adopt was signed by `adopt` before converge ran, and anything
            // else unsigned was left alone.
            steps.append("Re-sign the deck's \(event) hook — another tool rewrote the "
                         + "settings file and dropped the deck's marker.")
        }
        if strippedSiblings > 0 {
            steps.append("Move the deck's \(event) hook out of an entry it shares with "
                         + "\(strippedSiblings == 1 ? "another command" : "other commands"), "
                         + "which stay exactly as they are — the entry itself goes back to "
                         + "being unsigned, since nothing left in it is the deck's to sign.")
        }
        if duplicates > 0 {
            steps.append("Remove \(duplicates) duplicate \(event) "
                         + "hook\(duplicates == 1 ? "" : "s") posting to this deck.")
        }
        return (out, steps)
    }
}
