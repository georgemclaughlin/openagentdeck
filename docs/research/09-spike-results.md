# Spike C Results — Hook Round-Trip Against Real Claude Code

> The spike harness this document cites (`spike/`, `bin/`) was a development scaffold and is not part of this repository; its file references are kept as the record of where each finding came from.


**Run 2026-07-25 · Claude Code v2.1.220 · macOS (Apple Silicon) · Agent SDK 0.3.220**
**Evidence discipline:** every load-bearing claim below names the file it comes from (60 of them are machine-asserted; see the coverage note in §Follow-ups), and each pointer is re-run against its file by **`bin/audit.sh` (part of the spike harness, not included in this repository)**, which also (a) enforces a structural invariant — every backticked identifier used in the derived sections (impact table, follow-ups) must also appear in the body, scoped to the derived text so a correct body line cannot mask a stale summary — and (b) asserts the corrections landed in the downstream docs the build reads. Crucially, each pointer is **two-sided** — it asserts both that the evidence still says X *and* that this document still claims X, because static fixtures make evidence-only checks near-tautologies while every defect found in review was prose drifting from unchanged evidence. Scenario verdict labels are pinned too, since they gate spec decisions. Run it after any edit; it exits non-zero on drift, and **`bin/mutate-test.sh` (likewise not included)** is its acceptance test — 21 reverted defect classes, all required to fail the audit (currently 21/21). A manual re-run of these pointers — now automated here — is what caught S8's scope error. Where an artifact no longer supports a claim, the claim is labeled testimony (see S6c).
The `spike/` and `bin/` paths below refer to the original spike harness, which is not included in this repository; the hook events it recorded live on as `Packages/DeckKit/Tests/DeckCoreTests/Fixtures/events.ndjson`.

All scenarios ran against the real `claude` CLI / SDK with project-scoped hook settings in `spike/fixtures/` (the user's global config was never modified). Raw evidence: `spike/results/events.ndjson` (158 hook events across 30 sessions and all scenarios, including later telemetry-harness runs S14–S20, DEMO, FRESH and T1 that post-date the numbered findings), per-scenario result JSONs, TTY logs. Server: `spike/server.mjs` (mode-switched per scenario via `spike/mode.json`).

**Environment caveats, stated up front:**

**(0) A wrapper on `PATH` injected a competing hook set — disclosed after review.** `which claude` resolves to `/Applications/cmux.app/Contents/Resources/bin/claude`, a bash wrapper that — when `CMUX_SURFACE_ID` is set and its socket is live, both true throughout the spike — execs the real binary (`~/.local/bin/claude`) with an injected `--session-id` **and a second full `--settings` hook set** of its own (PreToolUse `timeout:5, async:true`, plus SessionStart/Stop/SessionEnd/Notification/UserPromptSubmit). Consequences: the runs that also passed `--settings` (S6e, S10, S17) had **two `--settings` flags on one argv**, so the claim that confounds were "neutralised" via that flag was itself unverified. No conclusion changes — hooks are additive, our relay fired correctly across 158 events, and the decisive findings were re-confirmed with `CMUX_CLAUDE_HOOKS_DISABLED=1` (S18) — but a document whose thesis is evidence discipline cannot assert a controlled hook environment it did not have. `bin/env-capture.sh` now records `claude_is_wrapper`, `claude_real_binary`, `wrapper_hooks_active` and all `CMUX_*` state. **Product consequence:** "another tool has already injected hooks/`--settings`" is a real deployment condition for the deck's installer — added to the spec's open questions.

**(1)** All runs executed *nested inside another Claude Code session*. Headless (`-p`) and SDK runs were unaffected (hooks fired, transcripts written, results deterministic). Interactive TUI runs (S6c) were confounded by the host user's real interactive config — see S6c. Hook transport was **command-hook relay → local HTTP server** (the agentsd pattern); the native `type: "http"` hook was not exercised (see Follow-ups).

---

## Scenario verdicts

### S1 — Lifecycle telemetry · **VERIFIED**
`claude -p` with hooks fired `SessionStart` (`source: "startup"`), `UserPromptSubmit` (includes full `prompt`, `prompt_id`, `permission_mode`), `Stop`, `SessionEnd` (with `reason`) — all with `session_id`, `transcript_path`, `cwd`.
**Bonus finding:** `Stop.last_assistant_message` is present — the done-lane summary comes from hooks alone; no JSONL enrichment needed. `Stop` also carries `background_tasks` and `session_crons`.

**Headless result-JSON keys (from every `-p` result file in `results/`):** `result`, `session_id`, `uuid`, `type`, `subtype`, `is_error`, `stop_reason`, `terminal_reason`, `num_turns`, `usage{…}`, `modelUsage`, `total_cost_usd`, `duration_ms`, `duration_api_ms`, `ttft_ms`, `ttft_stream_ms`, `time_to_request_ms`, `permission_denials`, `api_error_status`, `fast_mode_state`. Note **`total_cost_usd`/`duration_ms`**, not the previously assumed `cost_usd`/`duration_seconds` — the deck's dispatch path reads these.

### S2 — Tool events · **VERIFIED**
`PreToolUse`: `tool_name`, `tool_input`, `tool_use_id`. `PostToolUse`: same + **`tool_response`** (not `tool_output` as our research doc guessed — field-name correction).

### S3 — Held approval → allow · **VERIFIED (the core mechanism works)**
Bash was not pre-approved; the server held the `PreToolUse` HTTP response **8.0 s** (measured 8002 ms, in `events.ndjson`) then returned `hookSpecificOutput.permissionDecision: "allow"`. The session blocked for exactly the hold, then executed (`spike-ok-42` in output; PostToolUse fired). Corroboration from `S3-result.json`: `duration_ms: 12570` total vs `duration_api_ms: 3745` — the ~8.8 s non-API remainder is the hold. (A shell `time` reading of 13.8 s included CLI startup; the JSON figures are the citable ones.) **The deck-as-permission-authority design is real.**

### S4 — Held approval → deny · **VERIFIED**
Held 5.0 s, returned `deny` + reason. Tool never ran (**zero** PostToolUse), Claude reported the denial gracefully and the session continued to Stop/SessionEnd. Empirically confirms the spec's ack rule: **deny produces no PostToolUse — the response write is the only valid ack.**
**Bonus finding:** headless result JSON carries a top-level **`permission_denials`** array with the full denied call (`{tool_name, tool_use_id, tool_input}`) — an independent audit trail the deck can reconcile against.

### S5/S5b — Hook timeout is a fall-through, not a deny · **VERIFIED, sharpens the spec**
Server held forever; the hook's own `timeout: 20` fired (~20 s measured), and the request **fell through to Claude Code's normal permission evaluation**: the safe command (`echo`) was auto-approved and ran; the write (`touch`) was **blocked, file not created** (headless, default mode, zero user allow-rules).
**Consequence for the spec (§4):** for interactive sessions, timeout → the frontend prompt appears, exactly as designed. For headless sessions, timeout ≠ deny — the engine's own policy decides. The spec's choice that the deck must **actively return deny** for headless expiry is validated and necessary; implementation note: return it *before* the hook budget (e.g. at 110 s of 120), never rely on the timeout.

### S6a — AskUserQuestion in headless · **REFUTED for `-p` (valuable negative)**
The tool **does not exist** in `claude -p` sessions ("flagged non-interactive"; the model confirmed it's absent from the session's tool registry; **no AskUserQuestion PreToolUse ever fired** — the scenario did log four ToolSearch Pre/PostToolUse pairs, proving the hook path itself was live while the tool was simply unavailable). Headless `-p` sessions can never produce question takeovers. Deck-dispatched *SDK* sessions are the headless path that can (S6b).

### S6b — Tier 1 answer injection via the SDK · **VERIFIED**
SDK `query()` with `canUseTool` returning `{behavior: "allow", updatedInput: {questions, answers}}` — the server-side logic deliberately picked the **second** option ("Teal"). Claude received it as the user's answer: final output `CHOSEN=Teal`. The callback received the exact documented schema (`questions[]`, `header`, `options[{label, description}]`, `multiSelect`). **Tier 1 is confirmed end-to-end for deck-dispatched sessions.**
**Engine quirk, verbatim:** the SDK warned `[CLAUDE_SDK_CAN_USE_TOOL_SHADOWED] canUseTool will not be invoked for: AskUserQuestion. Bare allowedTools entries auto-approve the whole tool before the callback is consulted` — yet the callback **was** invoked and injection worked (AskUserQuestion appears special-cased as requiring interaction). Implementation note: don't put AskUserQuestion in bare `allowedTools` anyway; the warning signals fragile semantics.

### S6c — Tier 1 for *interactive terminal* sessions · **UNVERIFIED (time-boxed out)**
**Three** TUI launches (per `events.ndjson`, sessions `04dec2e1`, `b10824a4`, `3ee9144b` — all three also present in `statusline-feed.ndjson`) failed to reach a clean tool call. **Evidence-handling defect, disclosed:** the retry script reused the same `log_file` path, so **run 1's capture was overwritten** — the surviving `S6c-tty.log` is a later run's. A first-run "Claude in Chrome" consent dialog *was* observed live during the first launch and is why it stalled; that artifact no longer exists, so treat the claim as operator testimony, not evidence. It does have a **surviving structural corroboration**: session `04dec2e1` logged SessionStart → SessionEnd with **no UserPromptSubmit** and exactly one statusline render — the signature of a session that opened, sat behind a blocking dialog, and died without a prompt ever being submitted. The other two (`b10824a4`, `3ee9144b`) each logged UserPromptSubmit but **no Stop** — prompts submitted, turns never completed. What the surviving logs (`S6c-tty.log`, `S6c2-tty.log`) show is the host user's real interactive config intruding — "⏸ manual mode on", `/rc connecting…`, "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker", onboarding banners — with the prompt sitting at the input line. TUI automation *from inside another Claude Code session* is confounded beyond signal. Harness fix for any re-run: unique log path per attempt.
**Status: needs a 5-minute manual test** (human at a real terminal: configure the relay hook with `answer-question` mode, ask Claude to use AskUserQuestion, observe whether the picker renders or the injected answer lands). **Until then the spec's tiering stands exactly as written: Tier 1 for deck-dispatched SDK sessions (proven), Tier 2 detect-and-route for interactive (guaranteed fallback).**
Incidental *product* finding: real user interactive configs (manual mode, remote-control autoconnect, onboarding dialogs) intrude unpredictably — reinforcing the spec's rule that the deck only ever *observes* interactive sessions via hooks and never scripts their UI.

### S6e — Tier 1 in an **interactive terminal** session · **VERIFIED — the gate is closed**
The scenario S6c could not reach: a real TTY session (`expect`-driven, prompt passed as a positional arg so no typing simulation is involved, confounds neutralised with `--settings {"remoteControlAtStartup":false}`), with the deck server in answer-question mode.

**Result: the hook's injected answer is honoured and the picker never renders.** From `results/events.ndjson`:

| clock | event |
|---|---|
| 19:41:00.067 | SessionStart |
| 19:41:00.159 | UserPromptSubmit |
| 19:41:03.099 | **PreToolUse · AskUserQuestion** → deck injects `{"Which color should the banner be?":"Teal"}` |
| 19:41:03.118 | **PostToolUse · AskUserQuestion** — **19 ms later** |
| 19:41:04.992 | Stop |

A 19 ms gap between request and completion excludes any human interaction. The TTY stream (`results/S6e-tty.log`) shows the terminal rendering **`⏺ User answered Claude's questions: ⎿ · Which color should the banner be? → Teal`** — the injected value presented as the user's answer, with **no option list anywhere in the stream** — and Claude's final reply is `GRAND_TEAL`, the deliberately-second option. Recorded twice: `results/video/S6e-interactive-tier1.mp4` (replay rendered from the captured pty stream) and **`results/video/S17-live.mp4` — a true screen recording** of the same test in a real Terminal window, made after screen-recording permission was granted, cropped to the test window only. S17's hooks reproduce S6e exactly: PreToolUse 23:05:51.177 → injected `Teal` → PostToolUse 23:05:51.195 (**18 ms**) → Stop; the terminal shows "User answered Claude's questions → Teal" and `GRAND_TEAL`, with no picker.

**Consequence:** **Tier 1 applies to interactive terminal sessions, not just deck-dispatched ones.** Spec §4.1's tiering stands as written but its likely branch is now the good one; Tier 2 remains the fallback for frontends that behave differently (desktop app still unverified, §10.6).

### S10 — Multi-question call (test-plan E6) · **VERIFIED — the stepper's premise holds**
Asked Claude to call AskUserQuestion **once with three questions**. It did: `results/events.ndjson` shows a single `PreToolUse` whose `tool_input.questions` has **length 3** (`Banner colour?`, `Font?`, `Density?`, all `multiSelect: false`), and **one** injected `answers` map keyed by question text resolved all three. Claude's reply: `GRAND_TEAL-SANS-ROOMY` — the second option of each. Confirms §4.1's two load-bearing rules: multi-question calls are real, and **all answers ship together in one response**, which is why releasing mid-stepper must abandon the whole call rather than submit partials.

### S11 — Questions from a **background** session (test-plan E13) · **VERIFIED — headless rules are live, not dead code**
`claude --bg --name spike-q` asking a Yes/No question. AskUserQuestion **is available in background sessions** (unlike headless `-p`, S6a): `PreToolUse` fired, the deck injected `{"Proceed with deploy?":"No"}`, `PostToolUse` followed, and `Stop.last_assistant_message` reads **`DONE_No`**. So §4.1's headless-question handling (Other suppressed, "unanswered becomes deny", auto-deny on expiry) governs a real code path — and the deck is the **only** answering authority for these sessions, since no frontend exists to fall back to.

### S12b — Ack timing under a slow foreground tool (test-plan D4) · **VERIFIED — the rule is empirically necessary**
Allowed a 15-second foreground `sleep`. `PreToolUse` at 22:55:41.789 held 3001 ms (deck responds ≈ :44.79); **`PostToolUse` at 22:55:56.932 — 15.1 s after the request, ≈12 s after the deck's response write.** Had the deck used PostToolUse as its acknowledgement (the design the first review round forced out), every long-running approved command would have shown a false "Confirming…" and then reverted the lane to needs-you. The response write is the only correct ack. (A first attempt, S12, is retained as a curiosity: asked to run `sleep 25`, Claude chose to background it, so PostToolUse returned in 223 ms.)

### S13 — Deck server dies mid-hold (test-plan D17/K2) · **VERIFIED — deck failure is non-fatal**
Server held a `PreToolUse` forever, then was killed at 22:56:22 while holding. The relay's curl failed, the hook errored, and Claude Code **fell through to its own permission evaluation** — the safe command was approved and the session completed normally (`is_error: false`, `permission_denials: []`). **A dead deck degrades to stock Claude Code behaviour; it never hangs or breaks the user's session.** This is the same fall-through as the timeout path (S5/S5b) and the reason §9's restart row can be honest by construction.

### S18 — Induced failure: the error-state enum · **VERIFIED — the last ungrounded rule is now grounded**
The spike's biggest remaining risk was that §3's error lane and §4's error rule rested on a value nobody had ever observed. Induced it directly: dispatched `claude --bg --name spike-fail` (with `CMUX_CLAUDE_HOOKS_DISABLED=1`, closing caveat 0) running a 120 s foreground `sleep`, then `kill -9`'d the session's own pid mid-run and polled `claude agents --json --all`.

| t | status | state |
|---|---|---|
| before kill | `busy` | `working` |
| +4 s | **`null`** | `working` |
| +12 s | `busy` | `working` |
| +20 s → stable at +38 s | `idle` | **`blocked`** |

**Two corrections to the spec's assumptions.** The failure value is **`state: "blocked"`, not the assumed `failed`** — a rule keyed on `failed` would never have fired. And **`status` is optional**, so any code that requires it is wrong. Full observed enums: `state` ∈ {`working`, `done`, `blocked`}; `status` ∈ {`busy`, `idle`}. Note the daemon also **respawned the session under a new pid** after the kill — the row persists rather than disappearing. The live row was captured to `S18-agents.json` while it was still listed: `{"name":"spike-fail","kind":"background","status":"idle","state":"blocked"}`.

> **Correction, 2026-07-26 (planning Phase 0).** This paragraph originally read "`status` can be `null` transiently", and listed `null` in the `status` enum. `bin/trace.sh` §I opened the artifact to verify it and **found no `null` anywhere in the corpus** — not in S18, S7, S9 or any other capture. The `null` now survives only in the timeline table above, transcribed from the harness's live polling output, where a missing property serialises through Node as `null`; every schema claim elsewhere in this file has been corrected, and `bin/audit.sh` asserts the corrected form so the retracted one cannot return. What the artifact does show is that keys are **optional**: the two `state: "done"` background rows omit `status`, while `spike-fail` carries both. Absent and null are different decoding cases, so the distinction is load-bearing rather than cosmetic. The timeline row is left as recorded — it is what was observed — but it is an observation whose evidence was not retained, and the schema claim has been corrected to match the file.

**This vindicates the defensive rule** §4 adopted on the reviewer's advice: treating any unrecognized `state`/`status` as *unknown* (hold prior state, log it) rather than as error meant the wrong-enum assumption degraded to "the lane never turns red" instead of "the lane lies". That rule is load-bearing and the spec now says so out loud. Closes follow-up 6 and test-plan cases H4/E14/K4.

### S7 + S9 — Fleet listing · **VERIFIED, schema corrected, better than documented**
`claude agents --json` returns the host's **live interactive sessions** (not just background ones). Two row shapes, both captured:
- **interactive:** `{pid, cwd, kind: "interactive", startedAt, sessionId, name, status}`
- **background** (S9: dispatched `claude --bg --name spike-bg`, polled to completion): adds **`id`** and **`state`** → `{pid, id, cwd, kind: "background", startedAt, sessionId, name, status: "idle", state: "done"}`

**Observed enums** (every value below appears in a named file):
- `status` ∈ {`busy`, `idle`} — across 23 rows total: `S7-agents.json` (7) + `S9-agents.json` (8) + `S9-agents-final.json` (8); `S9-agents-all.json` is an identical 8-row set, excluded from the count.
- `state` ∈ {**`working`**, **`done`**, **`blocked`**} — `working` in `S9-agents.json` (`{"status":"busy","state":"working"}`, mid-run poll), `done` in `S9-agents-final.json` (`{"status":"idle","state":"done"}`). **`state` appears on background rows only** and is how the fleet feed distinguishes working from finished — `status` alone does not (an idle interactive session and a finished background one are both `idle`). Note `done`, **not** the researched `completed`.
- The **failure value is `blocked`** (S18, induced) — *not* the assumed `failed`. `status` is **optional**, present on all interactive rows and on some background ones (corrected 2026-07-26; the earlier "`null`" claim is unsupported by any artifact). Enum still treated as open; unknown values are held, never rendered as error.

**No `model`/`effort`/`branch` on either shape** — those must come from hooks/statusline (see §Spec impact). `--all` ("also include completed background sessions") returned an identical set here, so completed rows appear in the default listing at least briefly.
Corrections to research/03 §4.1's assumed schema: it's a bare JSON array (not `{sessions: [...]}`), fields are `kind/status/startedAt/sessionId`, not `directory/created_at` — and `state` does exist, on background rows only.

**Session-control subcommands `claude attach|logs|stop <id>`: advertised but non-functional (v2.1.220).** `results/S9-dispatch.txt` prints a banner offering four affordances verbatim: `claude agents` (list sessions), `claude attach 6e4ef966` (open in this terminal), `claude logs 6e4ef966` (show recent output), `claude stop 6e4ef966` (stop this session). **None of `attach`/`logs`/`stop` exist as subcommands** — captured in `results/S9-cli-help.txt`: `claude --help`'s Commands list contains only agents, auth, auto-mode, doctor, gateway, install, mcp, plugin, project, setup-token, ultrareview, update, and `claude agents --help` reads `Usage: claude agents [options]` with no positional subcommands. Invoking the advertised command is captured in `results/S9-stop-attempt.txt`: `claude stop 6e4ef966` **started a new session with that text as the prompt** (replying conversationally, "Nothing was running — no scheduled jobs, background tasks, or active loops in this session"), with the row still present in `agents --json` immediately afterward — same behavior previously seen for `claude rm`. So the banner advertises a control surface the CLI does not implement at this version; the deck must not build Stop on it (spec §10.2).
*Cleanup note:* `spike-bg` therefore remains listed as `state: "done"`. Its PID resolved to a **shared `bg-spare` daemon process** (`ps` output), so it was deliberately not killed. Removal path in practice: the interactive agent view (Ctrl+X per its documented shortcuts) — not verified here.

### S8 — Statusline feed · **VERIFIED (not headless-only-interactive — see below), schema captured**
**Corrected during the final evidence audit:** the feed fires in **interactive *and* background (`--bg`) sessions**, and **not** in headless `-p`. Evidence: `statusline-feed.ndjson` (54 records / 12 sessions) includes the three S6c TUI launches (`04dec2e1`, `b10824a4`, `3ee9144b`) **and `6e4ef966`, the S9 background session** (`S9-dispatch.txt`: "backgrounded · 6e4ef966"); the S8 headless session (`cd8f53fb`, per `S8-result.json`) appears nowhere in the feed. The background session's records carry **live data**, not placeholders: `{model.display_name: "Haiku 4.5", context_window.used_percentage: 17, context_window.total_input_tokens: 33175, cost.total_cost_usd: 0.06706}`.
**Interactive sessions carry live values too — corrected after review.** An earlier draft claimed interactive values were unproven; `statusline-feed.ndjson` refutes it. The file holds **54 records across 12 sessions**, and every interactive session whose turn *completed* reports real numbers: **S6e** (`add8067e`) `used_percentage: 16, total_input_tokens: 31997, cost: 0.0283115`; **S17** (`0fd1603b`) `16 / 31973 / 0.0280056`; **S10** (`7fd3551d`) likewise. Only the three S6c launches — whose turns never completed — show `null`/`0`, which is correct behaviour, not a gap. So live context/cost is verified for **interactive, background, and SDK-driven sessions**; only headless `-p` never emits the feed at all.
**Product consequence:** BG lanes can carry real context/cost meters — the empty-slot rule applies to headless-`-p`-driven lanes, not to background sessions.
Schema (from the same records): `model{id, display_name}`, `cost{total_cost_usd, total_duration_ms, total_api_duration_ms, total_lines_added/removed}`, `context_window{context_window_size, current_usage, used_percentage, remaining_percentage, total_input/output_tokens}`, `workspace{current_dir, project_dir}`, `session_id`, `transcript_path`, `version`, plus `exceeds_200k_tokens`, `fast_mode`, `output_style`, `thinking`. Corrections to research/03 §1.3: field names are `cost.total_cost_usd` / `context_window.used_percentage` (not `session_cost` / `approximate_percent_filled`); **no git block** in this version's payload.

---

## Spec impact summary

| Spec claim (§) | Spike outcome |
|---|---|
| Held hook = deck is the permission authority; terminal prompt only after hook returns (§4) | **Verified** (S3/S4) — hold, allow, deny all behave exactly as designed |
| Synchronous ack; deny yields no PostToolUse (§4, §9) | **Verified** (S4) |
| Timeout → "falls back" honestly (§4) | **Verified + sharpened** (S5/S5b): fall-through to engine policy; headless deck must *actively* deny before budget |
| Tier 1 mechanics documented, behavior to verify (§4.1) | **Verified for SDK sessions** (S6b) **and for interactive terminal sessions** (S6e — 19 ms request-to-completion, picker never rendered); headless `-p` can't ask at all (S6a); desktop app still unverified |
| Done-lane copy needs a hook-only fallback (§3) | **Improved**: `Stop.last_assistant_message` gives the real summary from hooks alone |
| Multi-question stepper; answers ship together (§4.1) | **Verified** (S10): one call, three questions, one answers map, all resolved |
| Headless/background question rules (§4.1) | **Verified live** (S11): background sessions *can* ask; the deck is their only answering authority |
| Deck failure must not break the user (§9) | **Verified** (S13): server death mid-hold falls through to stock permission behaviour; session completes |
| Fleet poller `agents --json` (§2 brief, research/03) | **Verified**, schema corrected, includes interactive **and** background rows; background rows carry `state` ∈ {`working`, `done`, `blocked`} — and `state`, not `status`, is what distinguishes working from finished |
| Statusline relay feeds context %/cost (§5) | **Verified for interactive, background and SDK sessions; absent only in headless `-p`** (where the empty-slot rule applies). Live values confirmed on every completed turn (figures in S8); the S6c launches show zeros only because their turns never completed. Field names corrected |
| **Branch in the lane's name row (§3)** | **Data source lost.** `agents --json` has no `branch` (S7/S9) and the statusline payload has no `git` block (S8) — no surveyed surface supplies it in v2.1.220. The deck must derive branch itself from the session's `cwd` (hooks supply `cwd` on every event), or the element drops. **Spec action required.** |
| **Error lanes keyed on a failure state (§4 headless rule)** | **Grounded by S18.** `state` ∈ {`working`, `done`, `blocked`}; `status` ∈ {`busy`, `idle`}, and **both keys are optional**. A killed session reports **`blocked`** — not the assumed `failed`. Spec §4 treats any unrecognized value as unknown (holds prior state, logs it), which is why the wrong assumption degraded safely; that rule is now declared load-bearing. Evidence: `S18-agents.json` |

## Follow-ups (not blocking the spike's conclusions)

1. ~~Manual interactive test for S6c (Tier 1 vs Tier 2) and a statusline capture from a completed interactive turn.~~ **Both done** — S6e/S17 closed the tiering question and produced the interactive statusline values (see S8).
2. **`type: "http"` hooks untested** — the command-relay pattern is proven and sufficient (it's what agentsd ships), but native HTTP hooks would drop the curl hop; verify support in a later spike.
3. Desktop-app hook parity — not testable here (app not exercised); remains Spike-C-listed in spec §10.6.
4. Remote Control push timing — not testable locally; remains §10.6.
5. Research/03 corrections recorded above — **all applied**: (a) `tool_response` not `tool_output`; (b) `agents --json` schema (bare array; `kind/status/startedAt/sessionId`; `state` ∈ {`working`, `done`, `blocked`} and `id` on background rows only; no model/effort/branch); (c) statusline schema (`cost.total_cost_usd`, `context_window.used_percentage`, no git block) firing in **interactive + background, never headless `-p`**; (d) **headless result JSON** returns `duration_ms` / `duration_api_ms` / `total_cost_usd` / `modelUsage` / `permission_denials` — *not* the assumed `duration_seconds` / `cost_usd` (the dispatch feature reads these); (e) session-control subcommands advertised but unimplemented (S9).
6. ~~Induce a failure to capture the error `state`/`status` value.~~ **Done — S18: the value is `blocked`, and `status` is optional** (see the 2026-07-26 correction above). Enum asserted in `bin/audit.sh`.
7. **Spec §3 branch-source decision**: derive from `cwd` via git, or drop the branch element. *(Applied — §3 now derives it.)*
8. **Audit coverage is partial, by measurement.** 60 machine assertions cover the load-bearing claims; an adversarial reviewer's mutations showed rule *sentences* (as opposed to figures) were under-pinned, so negation guards were added for the rule statements that drove spec changes, and a growth rule (E) now fails the audit if any scenario lacks both a verdict pin and a pointer. Coverage is not total — treat `bin/audit.sh` as a regression net, not a proof.
9. **Re-test `claude attach|logs|stop <id>` on future versions.** The dispatch banner advertises them; they don't resolve at v2.1.220. If `stop` becomes real it is the v1.2 Stop mechanism (spec §10.2) and `logs` is a candidate feed for the BG transcript peek (§3) — both worth a smoke test that fails loudly if the banner and the CLI ever agree.
