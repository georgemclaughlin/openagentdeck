# Claude Code Integration Surface — Complete Survey for Open Agent Deck

**Compiled 2026-07-24** from official Claude Code and Claude Agent SDK documentation (code.claude.com/docs, platform.claude.com/docs), verified against v2.1.211+ docs.

---

## 1. Observing running Claude Code sessions

### 1.1 Hooks (primary telemetry feed)

Deterministic event handlers firing at lifecycle points, receiving JSON on stdin and returning JSON on stdout. Hook handler types include **HTTP hooks that POST directly to a local server** — no shell scripts required.

**Hook events:** `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `StopFailure`, `FileChanged`, `ConfigChange`, `Notification`, `Setup` (experimental), plus agent-team events (`TaskCreated`, `TaskCompleted`, `TeammateIdle`).

**Common payload (stdin):**
```json
{
  "session_id": "abc123",
  "prompt_id": "550e8400-...",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/working/directory",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "effort": { "level": "medium" }
}
```
`PreToolUse`/`PostToolUse` add `tool_name`, `tool_input`, `tool_use_id`, and (Post only) `tool_response` **(spike-verified field name, v2.1.220 — not `tool_output`)**. Also spike-verified: `Stop` carries `last_assistant_message` (plus `background_tasks`, `session_crons`), and `SessionEnd` carries `reason`. See 09-spike-results.md.

**Handler types:**
1. `command` — shell command with timeout/async options
2. `http` — **POST to a URL** (e.g. `http://localhost:8080/hooks/telemetry`), headers with env-var expansion via `allowedEnvVars`
3. `mcp_tool` — call a tool on a connected MCP server
4. `prompt` — send to Claude for yes/no decisions
5. `agent` — spawn subagents for complex validation

**Return JSON fields:** `continue`, `suppressOutput`, `systemMessage`, `terminalSequence`, `additionalContext`, `hookSpecificOutput` (includes permission decisions for PreToolUse). Exit code 0 = success; exit 2 = blocking error (PreToolUse: blocks the tool).

**Config locations:** `~/.claude/settings.json` (global), `.claude/settings.json` (project), `.claude/settings.local.json` (project, gitignored), plugin `hooks/hooks.json`, skill/agent frontmatter.

**Stability: fully documented, stable API.** This is the ideal deck telemetry feed: SessionStart/PreToolUse/PostToolUse/Notification/Stop/SessionEnd hooks POSTing to the deck's local server.

### 1.1b AskUserQuestion & modified-input surfaces (verified against official docs, 2026-07-24)

**AskUserQuestion input schema — DOCUMENTED** ([agent-sdk/user-input](https://code.claude.com/docs/en/agent-sdk/user-input.md)):
```json
{ "questions": [ {
    "question": "How should I format the output?",
    "header": "Format",
    "options": [ {"label": "Summary", "description": "Brief overview"}, ... ],
    "multiSelect": false
} ] }
```
- `questions` is an **array** (no hard per-call cap documented; examples show up to 4); options are **2–4 per question**, each `label` + `description` (+ optional `preview`); `multiSelect` boolean per question.
- **"Other" is NOT built-in** — docs instruct hosts: "Display an additional 'Other' choice after Claude's options that accepts text input. Use the user's custom text as the answer value." It is a host convention.
- There is **no `answers` field in the input**; answers are supplied by the host **in the response**, via modified input.

**Programmatic answering — DOCUMENTED** (same page + [agent-sdk/hooks](https://code.claude.com/docs/en/agent-sdk/hooks.md)):
- SDK `canUseTool`: return `{ behavior: "allow", updatedInput: { questions, answers: {"<question text>": "Label" | ["Labels"]} } }` (Python: `updated_input`). The docs show this exact AskUserQuestion example.
- **PreToolUse hooks**: `hookSpecificOutput` documents `permissionDecision: "allow"|"deny"|"ask"|"defer"`, `permissionDecisionReason`, `additionalContext`, and **`updatedInput`** — "directly replaces tool arguments before the tool runs."
- Remaining behavioral question (not a documentation question): does an *interactive* frontend skip its native picker when a hook allows with injected answers → Spike C.

**Desktop app + hooks — PARTIALLY DOCUMENTED** ([settings](https://code.claude.com/docs/en/settings.md), [desktop](https://code.claude.com/docs/en/desktop.md)): settings files are documented as shared "across both frontends" with universal precedence, but no explicit statement that desktop sessions fire the same hook set; statusline-in-desktop is undocumented. Treat hook parity as expected-but-unverified → Spike C.

**Remote Control push timing vs hooks — NOT DOCUMENTED** ([remote-control](https://code.claude.com/docs/en/remote-control.md)): pushes fire "when Claude needs a decision," with no documented ordering relative to PreToolUse hook evaluation. Whether a held hook delays the push → Spike C.

### 1.2 Session transcripts (JSONL)

- Location: `~/.claude/projects/<project-slug>/<session-id>.jsonl` (slug = cwd with non-alphanumerics → `-`)
- **Format is internal and changes between versions — do not parse for production.**
- Stable access instead: `/export` command; Agent SDK `getSessionMessages(sessionId)`; `claude -p --resume <session-id> --output-format json`
- Config: `CLAUDE_CONFIG_DIR` env moves storage; `{"cleanupPeriodDays": 30}`; `--no-session-persistence`

### 1.3 Statusline API

Custom script receives session-state JSON on stdin per render; outputs text. **Spike-verified actual fields (v2.1.220):** `session_id`, `transcript_path`, `version`, `model{id, display_name}`, `cost{total_cost_usd, total_duration_ms, total_api_duration_ms, total_lines_added/removed}`, `context_window{context_window_size, current_usage, used_percentage, remaining_percentage, total_input/output_tokens}`, `workspace{current_dir, project_dir, added_dirs}`, `exceeds_200k_tokens`, `fast_mode`, `output_style`, `thinking`. **Fires in interactive *and* background (`--bg`) sessions — never in headless `-p`** (spike-verified: the feed captured the `--bg` session's live `used_percentage: 17`, `total_input_tokens: 33175`, `total_cost_usd: 0.06706`; the `-p` session is absent). No git block observed in this version. (Earlier assumed names — `session_cost`, `context_usage.approximate_percent_filled`, `git{}` — did not match; see 09-spike-results.md S8.) A statusline script can also POST to an external server — a second telemetry channel with per-render context/cost data.

### 1.4 OpenTelemetry

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```
Metrics: `claude_code.cost.usage`, `token.usage`, `session.count`, `lines_of_code.count`, `active_time.total`, `commit.count`, `pull_request.count`. Events: `api_request` (cost_usd, tokens, duration), `api_error`, `tool_result`, `tool_decision` (accept/reject). Attributes: `model`, `query_source`, `effort`, `agent.name`, `session.id`, `user.*`; correlate by `prompt.id`. Documented; schema extensible.

---

## 2. Controlling / driving Claude Code programmatically

### 2.1 Headless mode (`claude -p`)

Key flags (all documented/stable):

```bash
# Session: --continue/-c, --resume/-r <id|name>, --name/-n, --background/--bg, --fork-session
# Model: --model, --effort low|medium|high|xhigh|max, --fallback-model
# Permissions: --permission-mode default|acceptEdits|plan|auto|dontAsk|bypassPermissions
#              --allowedTools "Read,Edit,Bash", --disallowedTools "Bash(rm *)"
#              --permission-prompt-tool (experimental)
# System prompt: --system-prompt, --system-prompt-file, --append-system-prompt
# Output: --output-format text|json|stream-json, --json-schema, --verbose, --include-partial-messages
# Extensions: --bare, --mcp-config, --plugin-dir, --plugin-url, --add-dir, --settings
# Limits: --max-turns, --max-budget-usd, --no-session-persistence, --safe-mode
```

Output formats: `json` — **spike-verified actual top-level keys (v2.1.220)**: `result`, `session_id`, `uuid`, `type`, `subtype`, `is_error`, `stop_reason`, `terminal_reason`, `num_turns`, `usage{…}`, `modelUsage`, **`total_cost_usd`**, **`duration_ms`**, `duration_api_ms`, `ttft_ms`, `ttft_stream_ms`, `time_to_request_ms`, **`permission_denials[{tool_name, tool_use_id, tool_input}]`**, `api_error_status`, `fast_mode_state`. (Not `cost_usd`/`duration_seconds` as previously assumed. `permission_denials` gives the deck an audit trail of denied calls.); `stream-json` emits newline-delimited events (`system/init`, `stream_event` deltas, `assistant`, `result`). Stdin piped input ≤10MB. Exit codes: 0 success, 1 error/permission denied, 143 SIGTERM.

### 2.2 Claude Agent SDK (TypeScript & Python)

- `npm install @anthropic-ai/claude-agent-sdk` / `pip install claude-agent-sdk` (ships bundled Claude Code binary)
- TS `query()` async iterator with `includePartialMessages` for token-level streaming; `startup()` pre-warms the subprocess
- Python `query()` one-shot and `ClaudeSDKClient` continuous sessions
- Options: model, allowedTools, permissionMode, maxTurns, systemPrompt, resume (session id), mcpServers, agents (subagent definitions), custom tools (in-process MCP), hooks (in-process)
- **Permission callback:** `canUseTool` (TS documented; Python support less clear) — programmatic allow/deny
- **Control requests (TS):** `q.interrupt()`, `q.setModel()`, `q.setPermissionMode()`, `q.applyFlagSettings()`, `q.close()`
- Session utilities: `listSessions()`, `getSessionMessages()`, `renameSession()`
- The SDK can **resume sessions by id** (including ones started elsewhere), but cannot inject input into a *live* interactive terminal session

### 2.3 Remote Control — not an IPC mechanism

`claude remote-control` serves existing local sessions to claude.ai/code / mobile. Human-facing only; **no documented way for an external process to send input to a running interactive terminal session.** (Focus-the-terminal-window via Accessibility APIs is the practical workaround used by existing deck tools.)

### 2.4 Session resume

`claude --continue`, `claude --resume <name|id> ["prompt"]`. Lookup scoped to current worktree/repo, expandable to all projects.

---

## 3. Extending Claude Code

- **Skills:** `.claude/skills/<name>/SKILL.md` with frontmatter; invoked as `/name` or auto. No programmatic install API — filesystem placement works.
- **Agents:** `.claude/agents/<name>/AGENT.md` (frontmatter: model, tools). Invoke `claude --agent <name> -p "..."`.
- **Plugins:** full extension packages (skills/agents/hooks/MCP/LSP/settings); load via `/plugin install`, `--plugin-dir`, `--plugin-url`. **An Open Agent Deck plugin could ship the hook config that wires sessions to the deck** — one-command install.
- **MCP client:** `claude mcp add`, project `.mcp.json`; tools named `mcp__<server>__<tool>`; stdio/HTTP/SSE/in-process transports.
- **MCP server:** `claude mcp serve` exposes Claude Code's built-in tools to other MCP clients.

---

## 4. Multi-session / fleet awareness

### 4.1 Agent view — the fleet API

```bash
claude agents --json
```
**Spike-verified actual schema (v2.1.220)** — a bare JSON array (not `{sessions:[…]}`), including **live interactive terminal sessions**, not just background ones. Two row shapes:
```json
[
  { "pid": 97277, "cwd": "/path", "kind": "interactive",
    "startedAt": 1784400222548, "sessionId": "0472f8ff-…",
    "name": "project-0e", "status": "idle" },

  { "pid": 36966, "id": "6e4ef966", "cwd": "/path", "kind": "background",
    "startedAt": 1784963611053, "sessionId": "6e4ef966-…",
    "name": "spike-bg", "status": "idle", "state": "done" }
]
```
Observed enums: `status` ∈ {`busy`, `idle`, **`null`**}; `state` ∈ {`working`, `done`, **`blocked`**} — **`state` and `id` appear on background rows only**, and `state` is what distinguishes working from finished (`status` is `idle` for both an idle interactive session and a completed background one). Note `done`, not the previously assumed `completed`. **A killed session reports `state: "blocked"` — not `failed` — and `status` goes transiently `null` (spike S18, induced).** Treat the enum as open and unknown values as unknown: never light an error state on an unrecognized value. **No `model`/`effort`/`branch` fields on either shape** — those come from hooks/statusline, and branch from nowhere (derive it from `cwd`). `--all` ("include completed background sessions") returned an identical set in testing. Dispatch: `claude --bg --name <name> "<prompt>"`.

**Session-control subcommands are advertised but not implemented (v2.1.220):** the dispatch banner offers `claude attach|logs|stop <id>`, but none appear in `claude --help`'s command list, `claude agents` accepts options only (no positionals), and invoking `claude stop <id>` starts a *new session with that text as the prompt* (same for `rm`). **Do not build Stop or transcript-peek on these.** Re-test on future versions. See 09-spike-results.md S7+S9.
Dispatch: `claude --bg "prompt"`, `--bg --name`, `--agent <name> --bg`, `--bg --exec "cmd"`. Interactive agent view: attach (Enter), detach (Ctrl/Cmd+K), `/bg`, stop (Ctrl+X), rename (Ctrl+R). CLI flags stable; agent view itself is research preview.

### 4.2 Worktrees

Background sessions get isolated git worktrees under `.claude/worktrees/` automatically; `claude --worktree` for manual. Documented.

### 4.3 Agent teams (experimental)

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`; shared task lists in `~/.claude/tasks/`, mailboxes in `~/.claude/teams/`. File formats unstable — do not parse in production.

---

## 5. Notifications

`Notification` hook fires when Claude needs attention (permission prompt, input needed). Payload: `notification_type` ("action_required" etc.), `title`, `message`. HTTP hook → deck server → pulse the lane. Also: `terminalSequence` escape for terminal notifications; Remote Control mobile pushes (first-party).

---

## 6. Usage & cost data

- `/usage`, `/cost` — interactive-only display
- Headless `--output-format json` → `usage{input_tokens, output_tokens, cache_*}`, **`total_cost_usd`**, `modelUsage` (spike-verified names; see §2.1)
- Statusline JSON → per-render **`context_window.used_percentage`** and **`cost.total_cost_usd`** — **the easiest live per-session feed**, in interactive *and* background sessions; absent in headless `-p` (spike-verified; see §1.3)
- OTel metrics → cost/token counters with model/effort attributes
- ccusage-style JSONL parsing works today but rides an unstable format

---

## 7. Recommended integration tiers

**Tier 1 (stable, build on these):**
1. HTTP hooks → deck local server (telemetry + permission decisions)
2. Statusline script → per-render context/cost data
3. `claude agents --json` → fleet state polling
4. `claude -p` headless + `--output-format stream-json` → dispatch work
5. TS Agent SDK → embedded control if the deck ships a Node sidecar

**Tier 2:** OTel export; `/export` + SDK `getSessionMessages` for history; MCP for external integrations.

**Tier 3 (avoid/monitor):** raw JSONL parsing (unstable), agent-teams files (experimental), Remote Control (human-only).

## 8. Uncertainty register

| Feature | Status |
|---|---|
| Session JSONL format | Unstable — use /export or SDK instead |
| Agent teams file format | Experimental |
| Programmatic plugin install | Not exposed — filesystem/CLI only |
| Hook async edge cases | Partially documented |
| Statusline field additions | Extensible between versions |
| Python SDK permission callback | Less documented than TS |

## 9. Security & permissions notes

- Hooks use `allowedEnvVars` for secrets; HTTP hooks support Authorization headers
- Headless runs inherit user settings; `--allowedTools` pre-approves; nothing lets one agent approve on behalf of another
- Transcripts are local (`~/.claude/projects/`); Remote Control stores transcripts server-side
- Deck permission flow: PreToolUse HTTP hook → deck holds response → user taps Allow/Deny → hook returns permission decision in `hookSpecificOutput` (the pattern proven by agentsd / Claude Control, see competitive research)
