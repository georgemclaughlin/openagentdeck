# Architecture

Open Agent Deck is a SwiftUI Mac app whose logic lives in one Swift package, `Packages/DeckKit`. The app target (`App/`) holds only the `@main`; everything else is a library so it can be tested without launching an app.

## Module layering

Dependencies point inward, and `Package.swift` enforces it: `DeckCore` declares no dependencies, so it cannot import anything above it.

| Module | Role |
|---|---|
| `DeckCore` | Pure model. The event types, the `DeckState` reducer, the `Frame` projection, layout rules, the settings merge. No I/O, no clock, no platform framework. |
| `DeckPorts` | Protocols the core is spoken to through: `HookServerPort`, `FleetPort`, `ConfigPort`, `SessionHostPort`, `TranscriptFilePort`, `WorktreePort`. |
| `DeckAdapters` | Implementations that touch the world: the loopback HTTP hook server (`HTTP/`), `~/.claude/settings.json` access (`Files/`), the `claude agents --json` fleet reader (`CLI/`), the cmux terminal host (`Host/`), preferences (`Prefs/`), bounded child processes (`Process/`). |
| `DeckApp` | `DeckRuntime`, which wires the above together, and every SwiftUI view and scene. |

## Main data flow

```
Claude Code hook ──curl──> HookServer ──> HookEvent ──┐
statusline relay ──curl──> /statusline ─> StatuslinePayload ─┼─> DeckEvent ─> DeckState reducer
claude agents --json (poll) ──────────> FleetRow ─────┘            │
                                                                   ├─> [Effect]  (data, performed by the runtime)
                                                                   └─> Projection.frame ─> Frame ─> SwiftUI views
```

1. **In.** Claude Code runs the hook commands that the deck installed in `~/.claude/settings.json`. Each is a `curl` posting the event JSON to the deck's loopback server (`HookServer`). The runtime decodes it into a `HookEvent` and hands it to the reducer as a `DeckEvent`. Statusline payloads and the polled fleet list (`FleetRow`s from `claude agents --json`) enter the same way.
2. **Reduce.** `DeckState` applies the event and returns a list of `Effect`s (resolve a hold, start or cancel a timer, and so on). The reducer never performs an action; the runtime does.
3. **Project.** `Projection.frame(from:at:)` turns state into a `Frame`, a complete, `Codable` description of what to show. SwiftUI views render the frame (`DeckRuntime.frame` is observable).
4. **Out.** Answers leave in one of two ways. For a held event (`PermissionRequest`, or `PreToolUse` for `AskUserQuestion`), the HTTP request from `curl` is left open while a human decides; the answer is the HTTP response body, in the JSON shape Claude Code expects for that event (`HookResponse`). Anything that does not need a human is answered immediately with an empty reply. Free text, quick actions and the composer go through the `SessionHostPort`, which the cmux host implements by running the `cmux` CLI (`read-screen`, `send`) against the session's terminal.

## Settings merge

`SettingsMerge` (`DeckCore/Config`) installs and removes the deck's hooks as a pure function over the decoded `settings.json`; `ConfigFile` (`DeckAdapters`) does the atomic write with a backup. Entries the deck owns carry the key `x-openagentdeck`; everything else in the file is copied through untouched.

## Glossary

Terms as used in the code and comments.

- **Lane** — the deck's record of one Claude Code session (`LaneRecord` in state, `LaneView` in the frame).
- **Lane state** — `idle`, `working`, `needsYou`, `errored` or `ended` (`LaneState`).
- **Fleet** — the set of all sessions, as reported by `claude agents --json` and by hook events.
- **Strip** — the 8.8" 1920x480 display the app is designed for, and by extension the wide, short window layout.
- **Overview** — the surface showing every lane at once as cards (`SessionOverview`).
- **Card** — one lane's tile in the overview.
- **Band** — the detail area for the selected lane, shown across the strip (`DetailBand`).
- **Well** — a content area inside the band, such as the command well (what a decision is about) or the transcript well (recent prompts and events, `TranscriptWell`).
- **Mast** — the always-visible summary row: counts of lanes needing a human and the usage gauge.
- **Rail** — the indicator for lanes scrolled off the strip that are asking for a human.
- **Hold** — a hook request the deck keeps open (blocks Claude Code's response) while a human decides (`Hold`).
- **Hold budget** — how long a hold waits before the deck releases it (`HoldPolicy`).
- **Release** — the deck stops holding and the terminal owns the call; deliberately distinct from deny.
- **Resolution** — how a hold ended: `allow`, `deny`, `updatedInput`, `release`, `expire`, `allowAndRemember`.
- **Subject** — what a decision is about: the tool and its command, path or URL, shown verbatim (`Subject`).
- **Takeover** — the lane expanding to a full-attention surface for a pending decision or question (`QuestionTakeover` for questions).
- **Decision bar** — the Allow / Deny (and "always allow") controls, built inside the band's act zone (`DecisionBar`, in `DetailBand`).
- **Question mirror** — a read-only card for an `AskUserQuestion` after it has left the deck's hands (answered in the terminal or released).
- **Quick action** — a canned message the deck types into a session on a tap (`QuickAction`).
- **Composer** — the session's own prompt input in the terminal; the deck only types into one it can see is empty (`Composer`).
- **Auto-continue** — a queued "Continue" the deck sends when a session stops for a usage limit.
- **Statusline** — Claude Code's configurable status command; the deck wraps it to receive context-percentage and rate-limit payloads.
- **Host** — the terminal that runs a session; today only cmux (`SessionHostPort`, `CmuxHost`).
- **Frame** — the complete, pure description of what to render, produced from state (`Frame`).
- **Effect** — something the reducer asks the world to do, returned as data (`Effect`).
- **Port / adapter** — a protocol in `DeckPorts` and its implementation in `DeckAdapters`.
- **Fixture / LVnn / Sn** — recorded real-session data used by tests; keyed in `Packages/DeckKit/Tests/FIXTURES.md`.
