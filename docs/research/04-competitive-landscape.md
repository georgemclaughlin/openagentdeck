# Companion UIs & Control Surfaces for AI Coding Agents — Landscape Report

**Compiled 2026-07-24.** Focus: what exists around Claude Code, how each tool integrates, real community sentiment, and where Open Agent Deck fits.

---

## 1. Claude Code companion tools

### 1a. GUI "command centers" / desktop apps

| Tool | What it is | Integration | Traction & status |
|---|---|---|---|
| **opcode** (formerly Claudia) — [github mirror](https://github.com/winfunc/opcode) | Tauri 2 desktop GUI: session browser, custom agents, checkpoints, usage dashboard, MCP manager | Reads `~/.claude/projects/` JSONL; spawns CLI runs | **~22k stars**, AGPL, but widely reported **no longer actively maintained**; 267 open issues. Cautionary tale: GUIs that re-implement the CLI rot fast. |
| **Conductor** — [conductor.build](https://www.conductor.build/) (Melty Labs, YC) | Mac-native app running parallel agents in isolated worktrees; review & merge in one window | Manages worktrees, drives agents; GitHub App auth | Free, closed source, Mac-only, real commercial traction (Linear, Vercel, Notion per site). [Show HN](https://news.ycombinator.com/item?id=44594584) had sharp criticism (see §3). |
| **Crystal** — [stravu/crystal](https://github.com/stravu/crystal) | Electron: parallel worktree sessions, diffs, notifications | Spawns Claude Code per worktree | 3.1k stars, **deprecated Feb 2026**, replaced by commercial [Nimbalyst](https://nimbalyst.com/) |
| **CodeAgentSwarm** — [site](https://www.codeagentswarm.com/en) | Multi-terminal workspace with "this terminal is waiting for your decision" notifications, task board | Embedded PTY terminals + notification layer | Modest; notable because its whole pitch is the *"which terminal needs me?"* problem |
| **Vibe Kanban** — [BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban) | Kanban board where cards ARE agent tasks; workspaces with branch/terminal/dev server; 10+ agents | Local Rust/TS server spawning agent CLIs | **27.5k stars** — most-adopted agent-orchestration UI. Built because 2–5 min agent lulls led to "doomscrolling" ([Show HN](https://news.ycombinator.com/item?id=44533004)) |
| **Terragon** — [terragon-oss](https://github.com/terragon-labs/terragon-oss) | Cloud background-agent orchestrator → PRs | Cloud containers | **Shut down** after Anthropic shipped Claude Code on the web. Signal: don't compete with Anthropic's roadmap on cloud orchestration. |

### 1b. Usage monitors (the "cost anxiety" category — huge)

| Tool | What it is | Integration | Traction |
|---|---|---|---|
| **ccusage** — [ryoppippi/ccusage](https://github.com/ryoppippi/ccusage) | CLI: daily/session token & cost reports, 5-hour block tracking | **Reads local JSONL** in `~/.claude`; offline | **17.4k stars** — de-facto standard |
| **Claude Code Usage Monitor** — [repo](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | Live terminal dashboard: burn rate, "will you hit the limit before reset" predictions | Local usage data | ~8.5k stars |
| **CCSeva** — [repo](https://github.com/Iamshankhadeep/ccseva) | Native Swift macOS **menu bar** app: live %, color-coded, 7-day charts | Watches `~/.claude` via file events | Popular at launch; one of many menu-bar clones (ClaudeBar, cc-usage-bar…) |
| **Statuslines** — [claude-powerline](https://github.com/Owloops/claude-powerline), [ccstatusline](https://github.com/sirmalloc/ccstatusline) | Powerline statusline inside Claude Code | Official statusline hook | 6+ competing implementations — glanceable in-context state demand is proven |

### 1c. Remote / mobile control

| Tool | What it is | Integration | Traction |
|---|---|---|---|
| **Happy** — [slopus/happy](https://github.com/slopus/happy) | OSS mobile/web client: E2E-encrypted remote control, voice, push | **Wraps the CLI** + Agent SDK for remote mode | 2.1k stars, active |
| **Omnara** — [omnara-ai/omnara](https://github.com/omnara-ai/omnara) (YC S25) | Web/mobile/watch command center: monitor, approve, steer | Originally CLI wrapper — **publicly abandoned as "unfeasible to maintain with Claude Code's constant updates"**; now MCP + SDK + REST | 2.7k stars; $9/mo hosted |
| **Anthropic Remote Control** (first-party) — [docs](https://code.claude.com/docs/en/remote-control) | Continue a local session from claude.ai/code or mobile | Native | Commoditized the third-party remote-control niche |

### 1d. TUI managers & notifiers

- **[claude-squad](https://github.com/smtg-ai/claude-squad)** (~5.8k stars): tmux + worktrees TUI for multiple agents
- **[ccmanager](https://github.com/kbwo/ccmanager)**: tmux-free TUI, 8 agent CLIs, waiting/busy/idle status via terminal output parsing
- Notifier micro-tools: Chive (macOS, busy/waiting per instance), Claude Code Notifier, ccnudge, Telegram/Discord bridges. A long tail exists because the core product doesn't solve "which session needs me."

---

## 2. Stream Deck ecosystem

### 2a. Elgato's model

- Software organizes **keys, pages, profiles** (per-app auto-switching); plugins are Node.js/WebSocket processes ([SDK](https://github.com/elgatosf/streamdeck)).
- **Stream Deck +**: 8 LCD keys, 4 dials, **touch strip**. Dial + strip segment = an **"Encoder"** action; plugins draw on the strip via **JSON-defined layouts**, receive rotate/press and touch/swipe events ([Dials & Touch Strip guide](https://docs.elgato.com/streamdeck/sdk/guides/dials/)). This is the interaction grammar Open Agent Deck echoes — worth studying.
- **Virtual Stream Deck** (software deck on screen) arrived in v7 but **requires owning physical Elgato hardware**.

### 2b. Claude Code × Stream Deck plugins (all tiny)

| Plugin | What it does | Integration | Traction |
|---|---|---|---|
| **[paultyng/agentsd](https://github.com/paultyng/agentsd)** | Session state per key, **approve/deny/always-allow from hardware**, interrupt, focus window | **HTTP hooks → local server (127.0.0.1:9200)**; synchronous permission responses (120s timeout) | 8 stars, macOS 13+, MIT. Best-architected |
| **yolodeck** ([blog](https://cruftbox.com/2026/07/20/yolodeck-stream-deck-plug-in-for-claude/)) | Windows fork of agentsd | Same hook model | Blog-scale; author inspired by Codex Micro |
| **[JulienCr/streamdeck-claude](https://github.com/JulienCr/streamdeck-claude)** | One key per session: animated "working", **pulsing when it needs you**; press → focus Warp tab | Hooks in settings.json | 1 star |
| **Claude Control** ([Eudaimonia](https://eudaimoniasoftware.com/streamdeck)) | ALLOW/DENY keys flashing with the actual command, token sparkline + context-ring meters, voice, iPhone/Watch companion | HOOKS key auto-installs settings forwarding permission requests to localhost | Free, polished, on official Marketplace |
| **Claude Deck** (Jonny Elwyn) | Usage %/progress/reset countdown per key | **Reads OAuth token from macOS Keychain**, polls usage API — zero config | Free, macOS-only |
| Usage meters ([saeedkolivand](https://github.com/saeedkolivand/claude-usage-streamdeck-plugin), [lenadweb](https://github.com/lenadweb/stream-deck-ai-limits), [Marketplace "Claude Code Usage"](https://marketplace.elgato.com/product/claude-code-usage-ea7abd37-ad12-473a-a9cd-ab0bfeba3e3c)) | Live limits/costs | ccusage-style or usage API | Single-digit stars |
| [streamdeck-mcp](https://github.com/verygoodplugins/streamdeck-mcp) | Claude controls your deck via MCP | MCP server | Niche |

### 2c. Closest analog: **AgentDeck**

**[puritysb/AgentDeck](https://github.com/puritysb/AgentDeck)** — "Physical controller & multi-surface dashboard for AI coding agents." Drives **22 surfaces**: Stream Deck+, Ulanzi D200H, native SwiftUI macOS/iPad/iPhone app (Mac App Store), Android/e-ink, ESP32, LED matrices, TUI. Architecture: hub-and-spoke central daemon (port 9120) aggregating sessions over WebSocket; **hooks for Claude Code/Codex, SSE for OpenCode, PTY parsing as best-effort fallback**; YES/NO steering + custom prompts. **164 stars, 1,347 commits, MIT, very active.** Limitations: Node 22+ daemon, macOS 15+. Also note the **name collision zone**: [tonyofthehills/agent-deck](https://github.com/tonyofthehills/agent-deck) (menubar, 1 star), [claude-world/agent-deck](https://github.com/claude-world/agent-deck) (web orchestrator).

### 2d. Virtual deck apps (non-Elgato)

- **[Touch Portal](https://www.touch-portal.com/)** — phone/tablet macro deck; freemium; "not a Mac-assed app". No AI-agent awareness.
- **Macro Deck** (Windows-centric), **Deckboard** (phone). None target USB touchscreen strips on macOS; none have agent integrations.

---

## 3. What people love / hate (recurring themes, with sources)

1. **"You are the bottleneck" — approval visibility is THE pain.** [claude-code#36885](https://github.com/anthropics/claude-code/issues/36885) requested notification when Claude waits for input across concurrent sessions — **closed "not planned"**, pushing everyone to hooks and third-party tools. "Claude asks for permission a lot, and if you're not there, everything stops. The mental load is worse than the time loss" ([zerotopete](https://www.zerotopete.com/p/stop-babysitting-claude-code-by-setting)). Anthropic acknowledged the framing in "[Beyond permission prompts](https://claude.com/blog/beyond-permission-prompts-making-claude-code-more-secure-and-autonomous)."
2. **Multi-session juggling is normal; idle time is real.** Vibe Kanban founding motivation: 2–5 min agent waits → doomscrolling. Conductor praise: "I can easily bounce between tasks during these natural lulls."
3. **Cost/limit anxiety is durable and monetizable.** 17k+ stars on ccusage; The Register: "[Claude devs complain about surprise usage limits](https://www.theregister.com/2026/01/05/claude_devs_usage_limits/)". People want burn rate, time-to-reset, prediction — glanceably.
4. **Security distrust of closed orchestrators.** Conductor HN: "Full read-write access required to all your GitHub repos… Zero disclosure of data practices." Trust accrues to local-only, open-source, read-mostly tools.
5. **Don't take away the CLI feel.** Conductor HN: "the 'feel' of the way Claude Code outputs text is lost." Winners *augment* the terminal (statuslines, menu bars, decks), not replace it — one reason opcode-style full GUIs stalled.
6. **Worktree friction:** `.env` files and dependency installs don't follow worktrees.
7. **Wrapper fragility.** Omnara: CLI-wrapping "became unfeasible to maintain"; opcode drifted unmaintained. **Hooks + JSONL tailing + statusline are the stable surfaces; PTY wrapping is the fragile one.**

---

## 4. Positioning gap for Open Agent Deck

**Validated:** the deck metaphor for Claude Code resonates — 8+ independent Stream Deck plugins within a year; Elgato Marketplace carries Claude usage plugins; AgentDeck proves people wire agents into physical surfaces. The three killer use-cases everywhere: (1) *which session needs me right now*, (2) *approve/deny without switching windows*, (3) *glanceable usage/burn meters*.

**What does NOT exist — the open intersection:**

1. **No hardware-free deck for Claude Code on macOS.** Every deck-style tool requires Elgato hardware + Stream Deck app, or a fleet daemon (AgentDeck). Elgato's own Virtual Stream Deck requires owning a physical unit. A native macOS app turning a secondary touchscreen strip into the deck has **no incumbent**.
2. **The touchscreen-strip form factor is unclaimed.** Stream Deck+ has the only strip UX, and its Claude plugins barely use it. Nobody has designed a strip-native session UI: one segment per session, pulse on pending approval, swipe to focus, dial to adjust.
3. **Fragmentation, no winner.** Today you'd need agentsd (approvals) + CCSeva (usage) + Chive (attention) + a terminal focuser. Largest direct neighbor (AgentDeck) is 164 stars and is a heavyweight multi-surface hub, not a focused Mac-native product.
4. **macOS-native quality is rare.** The space is Node daemons, Electron, Tauri. CCSeva and AgentDeck's App Store build are the only Swift-native players; neither is a control deck.

**Integration guidance from the field:** the durable stack is **Claude Code hooks (permission events POSTed to localhost — the agentsd/Claude Control pattern) + FSEvents-tailing `~/.claude/projects/` JSONL for session/usage state (ccusage pattern) + optionally the statusline hook**. Avoid PTY wrapping (Omnara's abandoned approach) and full-CLI re-implementation (opcode's fate).

**Risks:** Anthropic keeps absorbing adjacent niches (Remote Control hurt Happy/Omnara; web version killed Terragon); notification/usage micro-tools are crowded. The defensible position is the unclaimed intersection: **local-only, open-source, macOS-native, touchscreen-first, multi-session approve/steer surface** — something Anthropic is unlikely to build (hardware-adjacent UX) and Elgato can't (no Claude Code domain awareness, hardware-locked).

Key hubs: [awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code), [Conductor Show HN](https://news.ycombinator.com/item?id=44594584), [Vibe Kanban Show HN](https://news.ycombinator.com/item?id=44533004), [claude-code#36885](https://github.com/anthropics/claude-code/issues/36885), [Elgato dials/touch-strip docs](https://docs.elgato.com/streamdeck/sdk/guides/dials/), [puritysb/AgentDeck](https://github.com/puritysb/AgentDeck).
