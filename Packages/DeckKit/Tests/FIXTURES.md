# Fixture key

Fixture IDs cited in code and tests. `LVnn` are live captures (a real Claude Code / cmux session driven on a real Mac); `Sn` are earlier spike captures. All of them are synthetic probe sessions: nothing here is a real working session. Personal paths, host names, project names and terminal tab titles were replaced with neutral placeholders; structure, ordering, refs and UUIDs are as recorded.

Claude Code version where a fixture records it: 2.1.220 (`events`/statusline feed, LV19), 2.1.227 (LV38), 2.1.231 (LV39). Others do not record one.

| ID | Location | What was captured / what it proves |
|---|---|---|
| S1-S6, S5b, S6c, S6c2, S6d, S6e, S8, S10-S15, S12b, S17-S20, DEMO, FRESH, T1 | `DeckCoreTests/Fixtures/events.ndjson` | Spike scenarios: the hook event stream (one row per hook POST, tagged by `scenario`; S7, S9 and S16 have no rows here: S7/S9 are fleet snapshots, below). Corpus replay, ingest and state-machine tests. |
| statusline feed | `DeckCoreTests/Fixtures/statusline-feed.ndjson` | Recorded statusline payloads (carry `version`); `Corpus.statusline`, replay and relay tests. |
| S9 | `DeckCoreTests/Fixtures/S9-agents.json` | `claude agents --json` fleet snapshot from the S9 spike (`Corpus.fleetS9`). |
| S18 | `DeckCoreTests/Fixtures/S18-agents.json` | Later `claude agents --json` snapshot (`Corpus.fleetS18`); fleet ingest and conformance tests (rename/renamed-key variants). |
| LV14 | `DeckCoreTests/Fixtures/live/LV14-plan/payloads.ndjson` | Plan-mode / `AskUserQuestion` hook payloads; hold, subject and question-preview tests. |
| LV19 | `.../live/LV19-usage-limit/payloads.ndjson` | A turn killed by the usage limit: healthy turns at 96 %, then `rate_limits` and no `Stop`. Pins the usage dot (`UsageTests`, `StatuslineRelayTests`). |
| LV28 | `DeckAppTests/Fixtures/live/LV28-cmux-host/tree.txt` | `cmux tree` output: 11 workspaces, 15 surfaces, 4 multi-tab workspaces. Host-parsing structure tests (`CmuxHostTests`). Tab titles are replaced. |
| LV30 | `DeckCoreTests/` and `DeckAppTests/.../live/LV30-multitab/screen-{A,B}.txt` | `cmux read-screen` of a shell (A) and a live Claude composer (B), including the NO-BREAK SPACE after the prompt glyph. Panel classification and drain tests. |
| LV32 | `DeckAppTests/.../live/LV32-host-identity/tree-both.txt` | `cmux tree` with both UUIDs and short refs per node: the two spellings of a host surface. `CmuxHostTests`. |
| LV34 | `DeckCoreTests/Fixtures/live/LV34-discovery/agents.json` | `claude agents --json` discovery output; resilience tests for unknown fields/statuses. |
| LV36 | `.../live/LV36-dialog-open/agents.json` | `claude agents --json` while a permission dialog is open (`Corpus.fleetDialogOpen`); corroborating a dialog from a fleet row. |
| LV37 | `.../live/LV37-question-preview/` | `AskUserQuestion` with three previewed options: `payloads.ndjson`, `plan-mode-question.json`, and `DeckAppTests` `lv37-previews.json`; question-preview and render-fit tests. |
| LV38 | `.../live/LV38-question-mirror-*` (+ `-PROVENANCE.md`) | Question-mirror investigation: held/released, race, latency control, terminal-answered and digit-answered (multiselect, free-text) hook streams. `QuestionMirrorTests`. |
| LV39 | `.../live/LV39-queued-composer/` | Composer showing "Press up to edit queued messages" while a message is queued; pinned as empty-equivalent (`Composer.read`). See its `PROVENANCE.md`. |
| LVV | `.../live/LVV-permission/payloads.ndjson` | `PermissionRequest` payloads including `permission_suggestions`; permission wire, suggestion-label and subject tests. |
| LV27 | observed live; no fixture retained | Probe workspace only: it survives as a workspace titled "LV27 probe" in the LV28 `tree.txt`. Not cited by code. |
| S7 | not retained (see `docs/research/09-spike-results.md`, "S7 + S9") | Earliest `claude agents --json` fleet listing (7 rows); `status` in {busy, idle}, optional keys. Superseded in the corpus by S9 and S18. |
| LV21 | observed live; no fixture retained | A prompt sent mid-turn arrived 68 ms after the running turn's `Stop` (invisible until then); a routine turn took ~57 s; a slash command emits no `UserPromptSubmit`. Basis for wait-for-idle sends and the stall grace. |
| LV23 | observed live; no fixture retained | A send into a composer holding a draft splices onto it (`MYDRAFT reply with exactly LV23D` arrived as one prompt); slash commands again emit no `UserPromptSubmit`. Basis for read-before-write. |
| LV26 | observed live; no fixture retained | A tab title containing `" & (do shell script "echo PWNED") & "` was executed when interpolated into a script. Basis for passing text as an argv element, never through a shell or script. |
| LV29 | observed live; no fixture retained (`LV29-coexist`) | Live cmux host probe. Only its name survives; `CmuxHost.swift` and `Ports.swift` cite it with LV28-LV31 as evidence for the host adapter's three capabilities. |
| LV31 | observed live; no fixture retained (`LV31-userlayer`) | Live cmux host probe. Only its name survives; cited with LV28-LV30 as evidence for the host adapter's three capabilities. |
| LV33 | observed live; no fixture retained | Claude Code runs a statusline under `/bin/sh`: a probe statusline `echo "ARGV0=$0"` wrote `ARGV0=/bin/sh`, so bash process substitution (`tee >(...)`) fails at parse time. Basis for the POSIX statusline relay. |
| settings/, themes/ | `DeckCoreTests/Fixtures/settings`, `themes`, `DeckAdaptersTests/Fixtures/themes` | Recorded `settings.json` variants for the hook installer; a theme file. |
