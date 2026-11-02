//
//  Settings.swift · DeckCore/Config
//
//  Installing and uninstalling the deck's hooks, as a pure function on JSON.
//
//  This is the highest blast-radius operation in the app: it writes to a file
//  the user's other tools also write to. So the merge is a pure function over a
//  decoded document, and every claim about it is a unit test.
//
//  Nothing here touches a filesystem. `ConfigPort` does that, in an adapter,
//  and the config-adapter-owns-the-path rule keeps the path literal out of
//  every module but that one.
//
//  The governing rule: **merge, never clobber.** A wrapper on `PATH` was
//  observed injecting its own `--settings` hook set into every `claude`
//  invocation, so preserving every pre-existing key matches what real
//  machines look like.
//

/// A proposed change, carrying both endpoints.
///
/// Both, not just the result: the write is preview-then-commit, and a preview
/// must show what is being replaced. Carrying `before` also makes the
/// uninstall-restores rule ("restores the pre-install state byte-for-byte")
/// checkable without re-reading the disk.
public struct ConfigDiff: Equatable, Sendable {
    public let before: JSONValue
    public let after: JSONValue
    public let summary: String
    public init(before: JSONValue, after: JSONValue, summary: String) {
        self.before = before; self.after = after; self.summary = summary
    }
    public var isNoOp: Bool { before == after }
}

/// Where a change came from. The strip never writes to `~/.claude`.
public enum WriteOrigin: String, Equatable, Codable, Sendable {
    case settingsWindow
    case strip
}

/// One step of a write, as data.
///
/// Writes are atomic and backed up: write-temp-then-rename, with a timestamped
/// backup retained. `rename(2)` atomicity is the filesystem's to provide; what
/// is checkable here is the *plan*: the target is never opened for a truncating
/// write, and a backup exists before anything replaces it.
public enum WriteStep: Equatable, Sendable {
    case backup(from: String, to: String)
    case writeTemp(path: String, contents: String)
    case rename(from: String, to: String)
    /// The step that must never appear. It is in the enum so a plan containing
    /// it is a value a test can find.
    case truncateAndWrite(path: String, contents: String)
}

public enum WritePlan {
    public static func plan(_ diff: ConfigDiff, target: String, stamp: Int64) -> [WriteStep] {
        [.backup(from: target, to: "\(target).\(stamp).bak"),
         .writeTemp(path: "\(target).\(stamp).tmp", contents: render(diff.after)),
         .rename(from: "\(target).\(stamp).tmp", to: target)]
    }

    /// The atomic-write rule's falsifier, computed over the plan.
    public static func violations(_ steps: [WriteStep], target: String) -> [String] {
        var problems: [String] = []
        var backedUp = false
        for step in steps {
            switch step {
            case .backup(let from, _) where from == target: backedUp = true
            case .truncateAndWrite(let path, _) where path == target:
                problems.append("the target is opened for a truncating write")
            case .rename(_, let to) where to == target:
                if !backedUp { problems.append("the target is replaced before a backup exists") }
            default: break
            }
        }
        if !steps.contains(where: { if case .rename(_, let to) = $0 { return to == target }; return false }) {
            problems.append("nothing ever lands on the target")
        }
        return problems
    }

    /// A JSON string, **escaped**.
    ///
    /// Wrapping the raw bytes in quotes writes invalid JSON for any value
    /// containing a quote or backslash (a Windows-style path, another tool's
    /// statusline command with a quoted argument), and the target is the user's
    /// real `~/.claude/settings.json`. Control characters are escaped too: a raw
    /// newline inside a JSON string is a parse error.
    static func escaped(_ s: String) -> String {
        var out = "\""
        for character in s.unicodeScalars {
            switch character {
            case "\"":      out += "\\\""
            case "\\":     out += "\\\\"
            case "\n":      out += "\\n"
            case "\r":      out += "\\r"
            case "\t":      out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:       out.unicodeScalars.append(character)
            }
        }
        return out + "\""
    }

    /// Public so tests can exercise the writer directly; an escaping defect
    /// once shipped because nothing asked this function what it produced.
    public static func render(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            // `String(Int64(d))` traps outside Int64's range (1e19 aborted the
            // process), and an engine-owned `permission_suggestions` element can
            // reach here unvalidated (`HookServer.swift`, `allowAndRemember`).
            // `Int64(exactly:)` is nil for a fraction or an out-of-range
            // magnitude, which fall through to `String(d)`.
            if let i = Int64(exactly: d) { return String(i) }
            return String(d)
        case .string(let s): return escaped(s)
        case .array(let a): return "[" + a.map(render).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { escaped($0) + ":" + render(o[$0]!) }
                                              .joined(separator: ",") + "}"
        }
    }
}

/// A single deck instance owns the port.
///
/// The *detection* is an adapter's — something has to try to bind. The
/// **decision** is a rule, and it is the half where the falsifier lives: "two
/// instances bound, or hook events split across them" happens when a second
/// launch races instead of surrendering.
// Don't reintroduce a launch-decision type here: the surrender is emergent from
// the OS refusing the bind, and `Connection.superseded` renders it.

/// Schema drift fails **loudly**.
///
/// The live re-record (L4) needs the real CLI. What is a rule is the comparator:
/// any difference in shape or enum values between the recorded fixture and a
/// fresh capture must produce a finding, never a silent pass.
public enum Conformance {
    public struct Drift: Equatable, Sendable {
        public let path: String
        public let recorded: String
        public let live: String
    }

    public static func drift(recorded: JSONValue, live: JSONValue, at path: String = "") -> [Drift] {
        switch (recorded, live) {
        case (.object(let a), .object(let b)):
            var out: [Drift] = []
            for key in Set(a.keys).union(b.keys).sorted() {
                switch (a[key], b[key]) {
                case (let x?, let y?): out += drift(recorded: x, live: y, at: "\(path)/\(key)")
                case (_?, nil): out.append(Drift(path: "\(path)/\(key)", recorded: "present", live: "absent"))
                case (nil, _?): out.append(Drift(path: "\(path)/\(key)", recorded: "absent", live: "present"))
                case (nil, nil): break
                }
            }
            return out
        case (.array(let a), .array(let b)):
            // EVERY row, pairwise: comparing only `first` missed a renamed enum
            // in a later row (S18 is the later `claude agents --json` fixture, see
            // FIXTURES.md; its first row is a `done` background row).
            // Extra rows are not drift; a differently-shaped row is.
            return zip(a, b).enumerated().flatMap { i, pair in
                drift(recorded: pair.0, live: pair.1, at: "\(path)[\(i)]")
            }
        case (.string(let a), .string(let b)):
            // Enum VALUES matter: S18's real failure value was `blocked`, not `failed`.
            return a == b ? [] : [Drift(path: path, recorded: a, live: b)]
        default:
            let ra = kind(recorded), rb = kind(live)
            return ra == rb ? [] : [Drift(path: path, recorded: ra, live: rb)]
        }
    }

    static func kind(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"; case .bool: return "bool"; case .number: return "number"
        case .string: return "string"; case .array: return "array"; case .object: return "object"
        }
    }
}

public enum SettingsMerge {

    /// The keys the deck owns. Everything else in the document is somebody
    /// else's and is copied through untouched.
    public static let deckHookName = "OpenAgentDeck"
    public static let marker = "x-openagentdeck"
    public static let original = "x-openagentdeck-original"

    /// The events the deck registers, and how each is answered.
    ///
    /// **Held**: the deck may block Claude Code's response while a human
    /// decides. `PermissionRequest` is the event the product is about.
    /// `PreToolUse` joins it only because `AskUserQuestion` arrives there, never
    /// on `PermissionRequest`; curl's timeout cannot vary per tool within one
    /// installed command, so the whole entry takes the held shape.
    ///
    /// **Cost.** On a healthy deck this is free: `DeckRuntime.handle` answers
    /// anything `HoldPolicy.needsAHuman` refuses with `HookResponse.none` before
    /// the hold is reached, so curl completes in milliseconds. But a deck that
    /// ACCEPTS the connection and never ANSWERS (hung, deadlocked) stalls every
    /// `PreToolUse` and `PermissionRequest` call for up to 125 s
    /// (`heldMaxTimeSeconds` on the spec budget) rather than 5. A deck that is
    /// simply CLOSED stays instant: `curl` is refused immediately and `|| true`
    /// swallows the error. A hung deck is bounded by the engine's own
    /// per-command `timeout` (`heldTimeoutSeconds`).
    ///
    /// **Rejected alternative**: a second, `"AskUserQuestion"`-matched held
    /// `PreToolUse` entry beside the `"*"` observer. `converge` (`Reconcile.swift`)
    /// holds one entry per event as an invariant, and Claude Code fires every
    /// matching entry, so `AskUserQuestion` would be delivered TWICE (a
    /// duplicate post).
    static let heldEvents = ["PermissionRequest", "PreToolUse"]

    /// **Observed**, never held: answered immediately, so nothing here needs
    /// more than the floor that keeps a closed deck from stalling a call
    /// (`hookCommand`'s `--max-time 5`). `Notification`'s `idle_prompt` is the
    /// engine's own definition of idle; a turn stalled for budget looks
    /// identical otherwise (LV19 rows 17–21). `Stop`, `SessionStart` and
    /// `UserPromptSubmit` drive the idle/working transitions
    /// (`DeckState.transition(on:)`) without relying on the fleet poll alone;
    /// `SessionEnd` is the end-of-life fact. `PostToolUse` alone is not matched
    /// to `"*"`; see `matcher(for:)`. No observed event carries a `timeout`: it
    /// would be a number the deck wrote and does not mean (one-source countdown
    /// rule).
    static let observerEvents = ["Notification", "UserPromptSubmit",
                                 "SessionStart", "Stop", "SessionEnd", "PostToolUse"]

    /// Every event the deck registers, held first — `installedPort` and
    /// `uninstall` both want a stable order, and held is where the port is
    /// most likely to still be legible on a partially-stripped file.
    static let allEvents = heldEvents + observerEvents

    /// **The one matcher that is not `"*"`.** The `.postToolUse` reducer branch
    /// reads answers to retire a question hold and nothing else; every other
    /// tool's `PostToolUse` would be received, decoded and discarded on every
    /// completed tool call. `SubjectReader.questionTool` is the same string
    /// `HoldPolicy.needsAHuman`'s `.preToolUse` branch uses to scope a question
    /// hold's opening: the identical gate, at the wire's door.
    ///
    /// Every other registered event stays `"*"`.
    static func matcher(for event: String) -> String {
        event == "PostToolUse" ? SubjectReader.questionTool : "*"
    }

    /// The timeout written into the HELD entries and the one counted down on
    /// screen come from the SAME budget. The one-source countdown rule's
    /// falsifier is "installed config `timeout` ≠ the deck's configured hold
    /// budget, with no error surfaced", so there is one budget and a function
    /// that reads back what it produced.
    ///
    /// Read from `PermissionRequest`, not `PreToolUse`: it is the event the
    /// budget is FOR, and reading either would hide the other's drift.
    public static func installedTimeoutMillis(_ document: JSONValue,
                                              policy: HoldPolicy = .spec) -> Int? {
        let entries = arrayOf(document["hooks"]?["PermissionRequest"] ?? .array([]))
        // `policy` does not restrict WHICH entry this finds: `isDeckHook`
        // recognises a marker-stripped held entry against the whole `HoldBudget`
        // family (`Reconcile.swift`'s `canonicalPort`), parsed from the entry's
        // own command. A stripped entry left from a since-changed budget is
        // exactly what `timeoutDrift` must find. `policy` is threaded through
        // only because `isDeckHook` accepts one.
        guard let ours = entries.first(where: { isDeckHook($0, policy: policy) }) else { return nil }
        // The per-COMMAND `timeout`, in seconds, inside `hooks`. An entry-level
        // `timeout` is outside Claude Code's schema and is stripped on its next save.
        guard let seconds = arrayOf(ours["hooks"] ?? .array([])).first?["timeout"]?.intValue
        else { return nil }
        return seconds * 1_000
    }

    /// nil when they agree; the drift when they do not. An error state, never a
    /// rounding difference.
    ///
    /// `expected` is budget-DERIVED, not budget-identical: `installed` is
    /// seconds scaled back to millis, and a whole-seconds ceiling plus ten
    /// seconds of engine slack (`heldTimeoutSeconds`) is not the raw millisecond
    /// budget. Comparing against the raw budget would flag every correct install.
    public static func timeoutDrift(_ document: JSONValue,
                                    policy: HoldPolicy) -> (installed: Int?, expected: Int)? {
        let installed = installedTimeoutMillis(document, policy: policy)
        let expected = heldTimeoutSeconds(policy) * 1_000
        return installed == expected ? nil : (installed, expected)
    }

    /// Install: add the deck's hook entry to every event it manages,
    /// preserving every other key, hook and statusline already present.
    public static func install(into document: JSONValue, port: Int,
                               policy: HoldPolicy = .spec) -> ConfigDiff {
        var root = objectOf(document)
        var hooks = objectOf(root["hooks"] ?? .object([:]))

        // Pre-existing entries for the event are kept and appended to (replacing
        // the array is the clobber the merge-never-clobber rule forbids), and the
        // deck's own entry is updated in place rather than duplicated.
        //
        // `isDeckHook`, not `isOurs`: on a marker-stripped file the entry is
        // already the deck's, and keying on the marker alone appends a second
        // one, so every event posts twice.
        for event in allEvents {
            let ours = heldEvents.contains(event) ? deckEntry(port: port, policy: policy)
                                                  : observerEntry(port: port, matcher: matcher(for: event))
            var entries = arrayOf(hooks[event] ?? .array([]))
            if !entries.contains(where: { isDeckHook($0, policy: policy) }) { entries.append(ours) }
            else { entries = entries.map { isDeckHook($0, policy: policy) ? ours : $0 } }   // idempotent update
            hooks[event] = .array(entries)
        }

        root["hooks"] = .object(hooks)

        // The relay **wraps**: the pre-existing statusline command still renders
        // its own output unmodified and the relay only observes. The original is
        // embedded verbatim rather than parsed, since understanding somebody
        // else's command line will one day be wrong about quoting.
        //
        // This collides with merge-never-clobber on exactly one key: C2 says no
        // pre-existing key is altered, C6 says this one is. The spec does not
        // order them, so the implemented reading is the one that loses nothing:
        // the original is kept verbatim beside the composed command, so uninstall
        // restores it by copying rather than parsing.
        if let existing = originalStatusline(document) {
            root["statusLine"] = .object([
                "type": .string("command"),
                "command": .string(relayCommand(wrapping: existing, port: port)),
                marker: .bool(true),
                original: .string(existing),
            ])
        }
        // **A document with no statusline still gets none invented** (P1.54).
        // The usage dot is fed only by the statusline's `rate_limits`, so a user
        // with no statusline never sees it. That is a known gap: closing it would
        // mean writing a key into somebody's config they did not ask for, which is
        // a consent decision. See `relayCommand` for the relay's direction.
        let after = JSONValue.object(root)
        return ConfigDiff(before: document, after: after,
                          summary: "add \(deckHookName) hooks on 127.0.0.1:\(port)")
    }

    /// Uninstall: remove exactly what install added, and nothing else.
    ///
    /// The uninstall-restores rule's falsifier is "a post-uninstall document
    /// differing from the pre-install one", which is why this deletes the
    /// containers it created — an empty `hooks: {}` left behind is a
    /// difference, and the kind nobody notices until a diff is put in front
    /// of them.
    public static func uninstall(from document: JSONValue, policy: HoldPolicy = .spec) -> ConfigDiff {
        var root = objectOf(document)
        guard case .object(var hooks)? = root["hooks"] else {
            return ConfigDiff(before: document, after: document, summary: "nothing to remove")
        }
        // Uninstall gives the statusline back exactly as it was, and "as it was"
        // includes ABSENT: a deck-owned entry with no `original` was installed
        // where there was no statusline, so the key goes. `install` no longer
        // creates that shape (P1.54), but an earlier build's config can carry one.
        if let line = root["statusLine"], line[marker] == .bool(true) {
            if let kept = line[original]?.stringValue {
                // Unwind before restoring: a file damaged by the old relay-nesting
                // bug carries `relay(mine)` here, not `mine`.
                let inner = SettingsMerge.unwrapped(kept)
                if inner.isEmpty || SettingsMerge.bareRelay(inner) != nil {
                    root.removeValue(forKey: "statusLine")
                } else {
                    root["statusLine"] = .object([
                        "type": .string("command"),
                        "command": .string(inner),
                    ])
                }
            } else {
                root.removeValue(forKey: "statusLine")
            }
        } else if let command = root["statusLine"]?["command"]?.stringValue {
            // The deck's relay with its marker stripped (Claude Code saves do
            // that) is still the deck's to remove, recognised by equality with
            // what `relayCommand` writes. The wrap carries the original, so
            // restoring is a copy. Unwound for the same reason as above.
            if let (_, kept) = SettingsMerge.relayWrapped(command) {
                let inner = SettingsMerge.unwrapped(kept)
                if inner.isEmpty || SettingsMerge.bareRelay(inner) != nil {
                    root.removeValue(forKey: "statusLine")
                } else {
                    root["statusLine"] = .object([
                        "type": .string("command"),
                        "command": .string(inner),
                    ])
                }
            } else if SettingsMerge.bareRelay(command) != nil {
                root.removeValue(forKey: "statusLine")
            }
        }
        // `isDeckHook`, not `isOurs`: a marker-stripped hook left behind would
        // keep posting to a dead port. All eight events.
        //
        // A deck-recognised entry is stripped of the deck's OWN command, not
        // dropped whole: Claude Code's `/hooks` UI appends a command into an
        // EXISTING matcher group, so a marked entry can bundle a user's hook.
        // Whatever remains goes back to UNSIGNED, since none of it is the deck's
        // to sign (same sibling-safety rule as `converge`'s split).
        for event in allEvents {
            let kept = arrayOf(hooks[event] ?? .array([])).compactMap { entry -> JSONValue? in
                guard isDeckHook(entry, policy: policy) else { return entry }
                let foreign = arrayOf(entry["hooks"] ?? .array([])).filter { hook in
                    guard let command = hook["command"]?.stringValue else { return true }
                    return loopbackPort(in: command) == nil
                }
                guard !foreign.isEmpty else { return nil }
                var kept = objectOf(entry)
                kept["hooks"] = .array(foreign)
                kept.removeValue(forKey: marker)
                return .object(kept)
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = .array(kept) }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = .object(hooks) }
        return ConfigDiff(before: document, after: .object(root),
                          summary: "remove \(deckHookName) hooks")
    }

    /// The statusline command the deck did **not** write, if there is one.
    ///
    /// A relay that lost its marker — Claude Code strips unknown keys when it
    /// saves — must not read as the user's own command: treating the composed
    /// relay as an "original" wraps the wrap, and every reconnect after a
    /// Claude Code save would nest one more relay around the last. What the
    /// user actually owns in that shape is the command the relay carries, so
    /// that is what this answers.
    public static func originalStatusline(_ document: JSONValue) -> String? {
        guard let line = document["statusLine"], line[marker] != .bool(true),
              let command = line["command"]?.stringValue, !command.isEmpty
        else { return nil }
        if let (_, original) = relayWrapped(command) {
            let inner = unwrapped(original)
            return inner.isEmpty || bareRelay(inner) != nil ? nil : inner
        }
        if bareRelay(command) != nil { return nil }
        return command
    }

    /// The deck's own relay, recognised by **equality with its writer**: parse
    /// a candidate (port, original) leniently, then accept only if
    /// `relayCommand(wrapping:port:)` regenerates the exact command. Same move
    /// as `canonicalHookPort` — the acceptance test is `==`, so there is no
    /// string heuristic to be wrong.
    static func relayWrapped(_ command: String) -> (port: Int, original: String)? {
        guard let hostRange = command.range(of: "http://127.0.0.1:") else { return nil }
        let digits = command[hostRange.upperBound...].prefix { $0.isNumber }
        guard let port = Int(digits) else { return nil }
        guard let tail = command.range(of: "rm -f \"$d\"; ") else { return nil }
        let original = String(command[tail.upperBound...])
        guard relayCommand(wrapping: original, port: port) == command else { return nil }
        return (port, original)
    }

    /// The innermost command a chain of relays carries. One layer is the
    /// healthy shape; deeper nesting is the old bug's damage — the composed
    /// relay read as an "original" and was wrapped again — and unwinding it is
    /// a copy per layer, never a parse.
    static func unwrapped(_ command: String) -> String {
        var current = command
        while let (_, inner) = relayWrapped(current) { current = inner }
        return current
    }

    /// And the relay with nothing wrapped, by the same equality.
    static func bareRelay(_ command: String) -> Int? {
        guard let hostRange = command.range(of: "http://127.0.0.1:") else { return nil }
        let digits = command[hostRange.upperBound...].prefix { $0.isNumber }
        guard let port = Int(digits), bareRelayCommand(port: port) == command else { return nil }
        return port
    }

    /// `tee` rather than a re-implementation: stdout of the original reaches the
    /// terminal unchanged and a copy reaches the deck.
    /// The relay duplicates the statusline's **INPUT**, not its output.
    ///
    /// Claude Code hands the session JSON (the only place `rate_limits` appears,
    /// LV19) to the statusline command on **stdin** and takes the rendered line
    /// from stdout. Teeing the original's stdout would send the deck a rendered
    /// text line `StatuslineIngest` cannot parse.
    ///
    /// Claude Code runs a statusline under `/bin/sh` (LV33: a probe statusline
    /// `echo "ARGV0=$0"` wrote `ARGV0=/bin/sh`). Process substitution
    /// (`tee >(curl ...)`) is a bash extension that `sh` rejects at PARSE time,
    /// so nothing runs at all:
    ///
    ///     /bin/sh: -c: line 0: syntax error near unexpected token `('
    ///
    /// The POSIX shape spools stdin to a private temp file, posts the FILE, then
    /// points the shell's own stdin at it and runs the original last:
    ///
    ///   - `mktemp` for the spool, so the payload — which carries `cwd` and
    ///     `transcript_path` — lands mode 600 in the user's private temp
    ///     directory rather than somewhere world-readable;
    ///   - `exec < "$d"` before `rm`, so the file is unlinked while still open
    ///     and nothing survives the render;
    ///   - the original stays VERBATIM and LAST, inheriting exactly the bytes it
    ///     would have received and emitting exactly the line it would have
    ///     emitted, with no re-quoting to mangle a command containing
    ///     quotes of its own.
    public static func relayCommand(wrapping original: String, port: Int) -> String {
        // **An explicit template, and it is not cosmetic.** Bare `mktemp` on
        // macOS ignores `TMPDIR` and uses the confstr temp directory, so the
        // spool's location was neither controllable nor testable. A template
        // rooted at `${TMPDIR:-/tmp}` works with BSD and GNU `mktemp`, keeps the
        // 600 permissions and uniqueness, and puts the file somewhere nameable.
        "d=$(mktemp \"${TMPDIR:-/tmp}/openagentdeck-statusline.XXXXXX\"); cat > \"$d\"; "
            + "curl -s --max-time 3 -X POST --data-binary @\"$d\" "
            + "http://127.0.0.1:\(port)/statusline > /dev/null 2>&1; "
            + "exec < \"$d\"; rm -f \"$d\"; \(original)"
    }

    /// The relay with nothing to wrap: the payload goes to the deck and the
    /// deck's answer IS the line. Not installed by `install` (P1.54: the deck
    /// invents no statusline) but public because it is what a user who WANTS
    /// usage monitoring should be offered; the live hands-on harness (not included in this repo) uses this shape.
    public static func bareRelayCommand(port: Int) -> String {
        "curl -s --max-time 3 -X POST --data-binary @- http://127.0.0.1:\(port)/statusline"
    }

    /// The relay-wraps rule's falsifier, computed: the composed command does
    /// not invoke the original verbatim.
    public static func wrapsOriginal(_ installed: JSONValue, original: String) -> Bool {
        guard let composed = installed["statusLine"]?["command"]?.stringValue else { return false }
        return composed.contains(original)
    }

    /// `PreToolUse` alone, not all eight events. `install` always writes it with
    /// the rest, so on a deck-produced file its presence implies the others, and
    /// reading one event keeps this cheap enough for a render loop.
    /// `installedPort`, which must find a port on a file the deck did not
    /// necessarily write, scans all eight.
    public static func isInstalled(_ document: JSONValue, policy: HoldPolicy = .spec) -> Bool {
        arrayOf(document["hooks"]?["PreToolUse"] ?? .array([]))
            .contains { isDeckHook($0, policy: policy) }
    }

    // ------------------------------------------------------------------ pieces
    /// What the deck actually installs into somebody's settings.
    ///
    /// **`--data-binary @-` is load-bearing.** Without it curl posts an EMPTY
    /// BODY, the deck receives `{}`, finds no `session_id` and drops the event.
    ///
    /// The query carries the HOST's identity. A hook runs as a child of the
    /// session and inherits the host's environment; `${VAR:-}` yields an empty
    /// value outside cmux, which decodes to *no address* rather than an error
    /// (unknown is not error). The deck learns which surface a session lives in
    /// without inferring anything; every inference was measured and failed.
    static func hookCommand(port: Int) -> String { hookCommand(port: port, maxTime: 5) }

    /// The held event's own curl: everything `hookCommand` is, with
    /// `--max-time` widened past the deck's own hold budget instead of
    /// pinned at the observer floor.
    ///
    /// **Why 5 s is wrong for a held event.** The deck blocks the HTTP response
    /// while a human decides, so `--max-time 5` would kill the connection five
    /// seconds in, every time, and the answer channel would be dead before
    /// anyone could tap Allow.
    ///
    /// **Widening is not free.** A deck that ACCEPTS connections but never
    /// ANSWERS stalls every `PreToolUse` and `PermissionRequest` call for up to
    /// `heldMaxTimeSeconds` (125 s on the spec budget). A CLOSED deck stays
    /// instant: `curl` is refused and `|| true` swallows it. See `heldEvents`.
    ///
    /// The engine also lets the action proceed to the normal permission flow on
    /// a hook `timeout`, so three numbers must stay ordered, widest last, or a
    /// fallback becomes the one that decides:
    ///
    ///   1. the deck's own hold budget expires and it answers `{}` PROMPTLY
    ///      (`DeckRuntime.expire`); the common case, and everything below is
    ///      slack around it, never latency added to it;
    ///   2. curl's `--max-time` (`heldMaxTimeSeconds`, budget + 5 s) must
    ///      still be connected when that answer arrives;
    ///   3. the engine's per-command `timeout` (`heldTimeoutSeconds`,
    ///      budget + 10 s) must outlive curl, so the engine's "proceed anyway"
    ///      fallback is always the LAST to fire, never racing the deck for the
    ///      answer.
    static func heldHookCommand(port: Int, policy: HoldPolicy = .spec) -> String {
        hookCommand(port: port, maxTime: heldMaxTimeSeconds(policy))
    }

    /// What every hook command shares — the double-quoted URL, the query, the
    /// graceful-degradation tail — with only the ceiling curl waits under
    /// left open, since that is the one number a held command and an
    /// observed one may not share.
    ///
    /// `maxTime: nil` omits `--max-time` from the command entirely — curl's
    /// own default is to wait indefinitely, which is exactly what
    /// `.untilAnswered` asks for: no deck-side ceiling on this connection at
    /// all, with the engine's `foreverEngineTimeoutSeconds` fallback as the
    /// only net. Never `nil` for the observer shape — `hookCommand(port:)`
    /// above always passes a literal 5.
    private static func hookCommand(port: Int, maxTime: Int?) -> String {
        // **Double quotes are the point.** Single quotes protect the `&` from the
        // shell but also suppress `${...}` expansion, so the deck received the
        // literal `$CMUX_SURFACE_ID:-` as the surface and every session was
        // unroutable. Double quotes protect the `&` equally and let the variables
        // expand (`?surface=surface:18`).
        //
        // **`|| true` is the graceful-degradation rule in one operator.** `curl`
        // exits 7 when nothing is listening; Claude Code reads a non-zero hook as
        // a hook error and reports it on EVERY tool call ("PreToolUse:Bash hook
        // error / Failed with non-blocking status code"). A deck that is merely
        // closed must not turn every Bash command into a reported failure: no
        // session is ever worse off because the deck exists or is absent. The
        // hook observes; it has no opinion about the command it watched.
        //
        // `--max-time` is the same rule from the other side: a deck that accepts
        // the connection and then hangs must not hold the call open. 5 s for
        // everything not held (`hookCommand(port:)`); a budget-derived ceiling for
        // the two held events (`heldHookCommand`).
        let ceiling = maxTime.map { "--max-time \($0) " } ?? ""
        return "curl -s \(ceiling)-X POST --data-binary @- "
            + "\"http://127.0.0.1:\(port)/hook"
            + "?surface=${CMUX_SURFACE_ID:-}&workspace=${CMUX_WORKSPACE_ID:-}\""
            + " || true"
    }

    /// The budget, in whole seconds, rounded UP — or `nil` for
    /// `.untilAnswered`, which has no seconds to round. Claude Code's
    /// per-command `timeout` is stated in seconds; the deck's own budget
    /// (`HoldPolicy.budget`) is stated in milliseconds and is a round number
    /// of seconds today, but nothing enforces that — rounding toward MORE
    /// slack rather than less is what keeps a future non-round budget from
    /// quietly shaving a second off the engine's own fallback.
    static func budgetSeconds(_ policy: HoldPolicy) -> Int? {
        guard let budget = policy.budget else { return nil }
        return Int((Double(budget.raw) / 1_000).rounded(.up))
    }

    /// curl's own `--max-time` for a held event, in seconds — five seconds
    /// WIDER than the budget, so curl is still connected to hand back the
    /// deck's prompt `{}` at expiry rather than having already killed the
    /// connection itself. `nil` for `.untilAnswered`: curl gets no ceiling of
    /// its own at all, because there is no deck-side expiry for it to be
    /// wider than — see `heldHookCommand` for the full three-number ordering
    /// this is the middle of, and for what a `nil` here does to the command.
    static func heldMaxTimeSeconds(_ policy: HoldPolicy) -> Int? {
        budgetSeconds(policy).map { $0 + 5 }
    }

    /// There is no documented "wait forever" value for Claude Code's own
    /// per-command `timeout` — it is a number of seconds, full stop — so
    /// `.untilAnswered` cannot ask the engine to wait forever either. Twenty-
    /// four hours is the outermost safety net: long enough that no real hold
    /// will ever reach it, short enough that a session is not stuck for a
    /// week if the deck genuinely wedges mid-hold. Past this the engine hands
    /// the prompt to the terminal, which is "forever" being honest about its
    /// own ceiling rather than a number this deck can vouch for as infinite.
    static let foreverEngineTimeoutSeconds = 86_400

    /// The engine's own per-command `timeout` for a held event, in seconds —
    /// wider than curl's own cap, so the engine's "proceed to the normal
    /// permission flow" fallback is always the LAST of the three to fire.
    /// Never `nil`: an entry always needs SOME number in this field, and for
    /// `.untilAnswered` that number is `foreverEngineTimeoutSeconds`. See
    /// `heldHookCommand`.
    static func heldTimeoutSeconds(_ policy: HoldPolicy) -> Int {
        budgetSeconds(policy).map { $0 + 10 } ?? foreverEngineTimeoutSeconds
    }

    /// The two held events' entry: `PermissionRequest` — "the event this
    /// product is actually about" — and `PreToolUse`, which joins it only
    /// because `AskUserQuestion` arrives there and the deck cannot vary
    /// curl's ceiling per tool within one installed command. See
    /// `heldEvents`'s own comment for why sharing the shape costs an ordinary
    /// tool call nothing.
    ///
    /// The `timeout` lives on the COMMAND, inside `hooks`, in SECONDS. Claude
    /// Code reads `timeout` per command; an entry-level key is outside that
    /// schema and is silently dropped on the engine's next save.
    /// and never once in effect on a file Claude Code had touched.
    static func deckEntry(port: Int, policy: HoldPolicy = .spec) -> JSONValue {
        .object([
            marker: .bool(true),
            "matcher": .string("*"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(heldHookCommand(port: port, policy: policy)),
                // Written from the same budget the countdown renders. The
                // one-source countdown rule.
                "timeout": .number(Double(heldTimeoutSeconds(policy))),
            ])]),
        ])
    }

    /// A hook the deck only WATCHES. No `timeout`, because nothing is held: a
    /// budget on an entry that answers immediately would be a number the deck
    /// wrote and does not mean, and the one-source countdown rule is about
    /// exactly that.
    ///
    /// `matcher` defaults to `"*"`; only `PostToolUse` overrides it (via `matcher(for:)`).
    static func observerEntry(port: Int, matcher: String = "*") -> JSONValue {
        .object([
            marker: .bool(true),
            "matcher": .string(matcher),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(hookCommand(port: port)),
            ])]),
        ])
    }

    /// Ours is identified by an explicit marker, never by matching the command
    /// string. A user who edits the command still owns a hook the deck must be
    /// able to find and remove.
    static func isOurs(_ entry: JSONValue) -> Bool { entry[marker] == .bool(true) }

    static func objectOf(_ v: JSONValue) -> [String: JSONValue] {
        if case .object(let o) = v { return o }
        return [:]
    }
    static func arrayOf(_ v: JSONValue) -> [JSONValue] {
        if case .array(let a) = v { return a }
        return []
    }
}
