# LV38 — the never-hold-questions investigation (2026-08-11)

Recorded live, `claude --version` 2.1.227, in support of the investigation
into whether `AskUserQuestion` calls can be released instantly instead of
held (the goal: the deck should mirror a question, never hold it,
if the evidence allows).

**Status: committed fixtures.** These directories follow the existing
corpus's `payloads.ndjson` shape (`{"ts","event","tool","workspace",
"surface","payload"}`, one row per hook POST, chronological by arrival),
and `Corpus.swift` exposes them through the same `JSONValue.parse` /
`HookIngest.event(from:epochBase:)` path as every other `live/*` directory.

## How these were recorded

A scratch Claude Code session (`--dangerously-skip-permissions`, cwd under
this investigation's own scratchpad, never this repo) was driven through a
real `cmux` terminal surface — the same automation the LV corpus's own prior
live runs used (`cmux new-workspace --command`, `cmux send`/`send-key` to
type into it, `cmux read-screen` to observe it) — the scratch project's own
`.claude/settings.local.json` pointed every hook at a local Python recorder
(`127.0.0.1:8901`, never the real deck port 8765) that logged every hook
POST verbatim with a high-resolution arrival timestamp, and answered per a
runtime-configurable mode (instant `{}`, an artificial N-second hold then
`{}`, or a transparent proxy to the real deck at 8765 that logs both legs).

**A field, not a footnote: every one of these sessions ALSO reached the real,
live OpenAgentDeck app**, because Claude Code merges the scratch project's
own hooks with the machine's global `~/.claude/settings.json` hooks rather than
one replacing the other — the global `PreToolUse` entry posts to `:8765`
unconditionally, for every session on the machine, scratch or not. This was
not the original plan (the intent was full isolation via the project-local
hook alone) and is recorded here as a safety-relevant finding in its own
right, not swept under the rug: the real deck opened a genuine, briefly-held
`AskUserQuestion` hold for several of these probe sessions and let it run to
its own natural 120 s expiry, unanswered, exactly as `HoldPolicy.spec` and
the graceful-degradation rule say it should. No card was ever tapped, no
deck UI was ever touched, and `Library/Logs/OpenAgentDeck.log` was checked
after every run to confirm each opened hold reached `holdExpired` before
moving on — verified clean at the end of the whole investigation (see the
investigation's final report for the exact log lines). This is *also* how
`LV38-question-mirror-latency-control`'s central finding was discovered: see
that directory's own note below.

## The five directories

- **`LV38-question-mirror-held-released/`** — `SessionStart` through
  `Notification`, cut off before the answer. Session `eb096a00-…`. The
  recorder held this call's `PreToolUse` for 8 s (an artificial stand-in for
  a deck's own hold) before answering `{}`. Demonstrates the hold/release
  mechanics in isolation: nothing about the question reaches the terminal
  screen for the entire held span (confirmed by a parallel `cmux read-screen`
  poll, not itself part of this ndjson — raw screen not retained).

- **`LV38-question-mirror-terminal-answered/`** — the same session,
  continued through the terminal answer (a digit `"1"` keystroke sent via
  `cmux send`, the identical mechanism `CmuxHost.send`/`.dialogKey` uses —
  see `DeckRuntime.swift`'s own comment on why `send` and not `send-key`),
  `PostToolUse`, and `Stop`. `PostToolUse.tool_input.answers` reads
  `{"Pick": "Option A"}` — the question's own text, keyed to the CHOSEN
  option's label, arriving **directly on `tool_input`**, not nested under an
  `updatedInput` the way a deck-authored `hookSpecificOutput` response is
  shaped (`HookResponse.answered`'s own doc comment). `duration_ms: 0` on
  the `PostToolUse` row — answering completes fast enough that Claude Code's
  own millisecond counter rounds it to nothing.

- **`LV38-question-mirror-digit-answered/`** — three complete sessions
  mapping the terminal's own keystroke grammar for the two response shapes
  besides a plain single-select digit:
  - `multiselect-one-pick.ndjson` (session `a0aed9d6-…`) — a multiSelect
    question where a digit **toggles** a checkbox rather than answering
    (`[ ] Option A` → `[✔] Option A`), and pressing `enter` on an
    already-focused row toggles it again rather than submitting (documented
    the hard way — a stray `enter` here re-toggled `Option A` back off mid
    recording, which is exactly why the final answer is one label, not two).
    Reaching the actual submit control needs `↓`/`send-key down` navigation
    PAST the options and the built-in "Type something" row to a dedicated
    "Submit" row, `enter` on THAT opens a "Review your answers" confirmation
    screen, and only a further `1` ("Submit answers") on that screen
    actually answers. `tool_input.answers` reads `{"Which?": "Option C"}` —
    a bare string, same shape as single-select.
  - `multiselect-two-picks.ndjson` (session `10c3951c-…`) — the same flow
    with two boxes checked before Submit. `tool_input.answers` reads
    `{"Pick": "Option A, Option B"}` — **a comma-joined STRING, not a JSON
    array.** This contradicts `HookResponse.answered`'s own doc comment
    ("…an array of labels when multiSelect is set"), which describes the
    shape a DECK sends when it answers on the wire — a real terminal-side
    multi-select answer is encoded differently. Any reader of
    `PostToolUse.tool_input.answers` (a no-hold mirror included) needs to
    split on `", "` for the multi-value case, not expect an array.
  - `other-freetext.ndjson` (session `5f5e5353-…`) — the "Other" flow:
    the numbered "Type something" row is first FOCUSED with its own digit
    (`cmux send -- "3"`, text bytes, not `send-key`) — this alone does not
    submit — then the free text is typed directly into that same focused row
    as ordinary text bytes (no separate "activate edit mode" keystroke), then
    `enter` submits. `tool_input.answers` reads `{"Other": "Hello free text
    answer"}` — the typed text becomes the answer value directly; nothing in
    the wire payload marks it as "the free-text branch" versus an ordinary
    label match. **A caution recorded alongside this file, not folded into
    it because it recorded no payload worth keeping**: pressing `enter`
    directly on the unfocused "Type something" row with NO subsequent typed
    text does not open an editable field — it submits an empty answer, which
    Claude Code reports as "User declined to answer questions" (a distinct
    outcome from a real answer, with no `PostToolUse` at all).

- **`LV38-question-mirror-race/`** (session `4aaca1c7-…`) — the late-tap
  simulation: a digit `"1"` answer immediately followed (next `cmux send`
  call, ~400 ms wall-clock apart including process spawn overhead) by a
  second, unrelated digit `"2"`. `PostToolUse` shows the FIRST digit landed
  correctly (`answers: {"Race": "Skip this question"}`, matching whatever
  option 1 actually was — the model wrote its own option labels rather than
  the ones asked for, a content quirk unrelated to the mechanism). The
  SECOND digit did **not** reach the (already-closed) dialog and did **not**
  vanish — `cmux read-screen`, captured moments later (not itself part of
  this ndjson; raw screen not retained for the raw screen), shows a
  bare `2` sitting unsent in the terminal's now-empty prompt composer. This
  is the composer-leak hazard named in the investigation brief, reproduced:
  a late second answer becomes stray, unsent, splice-hazard text in the
  NEXT prompt's own composer, exactly the failure mode `DeckRuntime.drain`'s
  own `.prompt` case comment (LV23) already names for a different path.

- **`LV38-question-mirror-latency-control/`** (session `99ef5bf0-…`,
  supplementary — not one of the four named fixtures, kept because the
  finding is load-bearing for question 7) — a session with **no
  project-level hooks at all** (no `.claude/settings.local.json` in its cwd;
  only the global hook fired). `PreToolUse` arrived at `12:05:45.374Z`;
  `PermissionRequest` did not arrive until `12:07:47.101Z` — **a 120.8 s
  gap**, timed independently against `Library/Logs/OpenAgentDeck.log`'s own
  `holdOpened`/`holdExpired` pair for this session (opened +2.9 s after
  `PreToolUse`, expired 120.8 s after THAT). Two other sessions recorded
  outside this directory (not fixture-worthy on their own, cited in the
  raw capture not retained) reproduced the identical ~120 s gap with the
  project-level recorder set to *instant* release and to an *8 s* artificial
  hold respectively — proving the gap tracks the REAL deck's own
  `HoldPolicy.spec.budget` (120 000 ms), not any hook's response latency.
  **The practical reading:** on a machine with the deck's global hook
  installed, there is no such thing as an unheld `AskUserQuestion` call
  today — every one is held by the real deck for up to its full budget
  unless a human answers it there, REGARDLESS of what any other hook
  (a project-level one, a mirror's own) does or how fast it answers.
