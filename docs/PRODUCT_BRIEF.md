# Open Agent Deck — Product Brief

**Version 0.1 · 2026-07-24 · Status: research synthesis, pre-build**

A native macOS app that turns a ~$110 touchscreen strip display (8.8" 480x1920 bar) into a live control deck for Claude Code: glanceable state for every running session, approve/deny from the strip, and one-tap focus — the Codex Micro idea, done the way reviewers said it should have been done, for Claude Code, in software, open source.

Supporting research: [Codex Micro](research/01-codex-micro.md) · [Strip hardware & macOS](research/02-strip-display-hardware.md) · [Claude Code integration surface](research/03-claude-code-integration.md) · [Competitive landscape](research/04-competitive-landscape.md)

---

## 1. Why this product, why now

Three findings line up almost perfectly:

**1. The Codex Micro named the job and proved the demand — then fumbled the execution.**
OpenAI's $230 macro pad sold out in a day. Its real invention wasn't hardware; it was framing: *"a physical approval-latency reduction tool… the gap between the agent being ready and the developer being aware."* The single feature everyone loved — even skeptics — was the **live status lights** ("Its completely pointless yet I still want it. IDK, its the status lights that look fun" — HN). And every serious critique targeted the same three flaws:

- Static keycaps, no screen → ZDNet: *"the Codex Micro seems very 2015… dynamic key faces beat static keycaps."*
- Hard 6-agent ceiling with LEDs that only work inside the ChatGPT desktop app — dark for CLI users.
- $230, closed, single-vendor lock-in.

A touchscreen strip is precisely the "what if the status light were also a screen and a button" product.

**2. Claude Code is the *only* agent CLI with an officially documented surface for building this.**
The Codex Micro's status channel is a proprietary, undocumented JSON-RPC protocol between the device and the ChatGPT app (already reverse-engineered by third parties, which proves the hunger). Claude Code, by contrast, officially ships everything a deck needs:

- **HTTP hooks** — Claude Code will POST lifecycle events (SessionStart, PreToolUse, Notification, Stop…) directly to `localhost`. No shell scripts, no scraping.
- **PreToolUse hooks can answer permission prompts** — the deck can hold the request and return allow/deny when the user taps. (Pattern proven in the field by the `agentsd` and Claude Control Stream Deck plugins.)
- **`claude agents --json`** — documented fleet state: every background session with `working | needs-input | idle | completed | failed`.
- **Statusline JSON** — per-render context %, session cost, git state.
- **Headless mode + Agent SDK** — dispatch and stream new work from the deck.

We ride documented surfaces only. The graveyard (Omnara's abandoned PTY wrapper, unmaintained opcode) died re-implementing or wrapping the CLI.

**3. The niche is verifiably empty.**
Every existing Claude deck requires Elgato hardware + their app, or a heavyweight Node daemon (AgentDeck, 164 stars). Elgato's own Virtual Stream Deck requires owning physical Elgato hardware. Nobody ships macOS software for the 8.8" strip category at all — even Corsair left Mac touch support for its own Xeneon Edge strip to a hobbyist GitHub driver. Meanwhile the underlying pains are enormous and validated: "which session needs me" (the #1 ask; Anthropic closed the notification issue as *not planned*), approve-without-window-switching, and cost anxiety (ccusage: 17.4k stars).

**The one-line thesis:** *the human is now the bottleneck in agentic coding, and the fix deserves dedicated glass — not another window buried behind the terminal.*

---

## 2. Who it's for

**Primary: the parallel-session Claude Code power user.** Runs 2–6 sessions across projects/worktrees daily. Their pains, in their words:

1. *"Claude asks for permission a lot, and if you're not there, everything stops. The mental load is worse than the time loss."*
2. Vibe Kanban's founding insight: 2–5 minute agent lulls turn into doomscrolling because there's no ambient signal for "you're needed."
3. Usage-limit anxiety: burn rate, time-to-reset, "will I hit the wall before 5pm?"

**Secondary:** single-session users who want a beautiful ambient status display + usage meter (the CCSeva/menu-bar crowd, but nicer), and the desk-setup community (r/battlestations energy — the Codex Micro proved peripherals are identity objects).

**Explicitly not for v1:** Windows/Linux, non-Claude agents, cloud orchestration, teams.

---

## 3. Product principles

1. **Glance, don't read.** Sub-second comprehension at arm's length. Color = state, motion = change, text is the last resort. Adopt (and credit) the Codex Micro's proven color language: white=idle, blue=thinking, green=done, amber=needs-you, red=error.
2. **Touch to act, never to type.** The strip handles decisions (approve/deny/focus/steer). Typing stays in the terminal. We *augment* the CLI — the #1 lesson from Conductor's backlash ("the 'feel' of Claude Code is lost") and opcode's decay.
3. **Ride documented surfaces only.** Hooks, `agents --json`, statusline, headless CLI, Agent SDK. Never PTY-wrap, never re-implement the CLI, treat raw JSONL as an optional enrichment that can break without taking the product down.
4. **Open source is a hard constraint, not positioning.** Every core function — display, touch, hooks, approvals — must work with zero paid or closed dependencies, implemented in our own open code (license: MIT or Apache-2.0; decide before first release). Commercial components (e.g., the UPDD touch driver) may exist only as *optional, user-provided adapters* the app detects — never bundled, never required, never the documented happy path. Local-only, no cloud, no account, no repo permissions. The field shows trust accrues exactly here.
5. **Hardware-optional, strip-optimized.** Gorgeous full-screen on a 480x1920 strip; still fully functional as a slim always-on-top window on any Mac (a "dock bar" at the screen edge). The strip is the aspirational demo; the free window mode is the adoption funnel. Nobody is forced to buy anything.
6. **Zero-config magic.** First launch: detect Claude Code, offer one tap to install hooks (scoped, reviewable, uninstallable), sessions appear. No YAML.

---

## 4. The product

### 4.1 The strip layout (1920x480 landscape)

```
┌──────────┬────────────────────┬────────────────────┬────────────────────┬──────────┐
│  STATUS  │  api-server   ⚡︎   │  webapp       ●    │  infra        ✓    │  USAGE   │
│  RAIL    │  feat/auth  $1.20  │  fix/nav    $0.45  │  main       $2.10  │  RAIL    │
│          │  ▁▂▅ Editing       │  ⚠ AWAITING        │  Done 4m ago       │  ▓▓▓░ 62%│
│  3 live  │  auth.ts…          │  Bash: git push…   │  "Tests passing"   │  resets  │
│  1 needs │  ctx ▓▓░░ 41%      │  [ALLOW]  [DENY]   │  ctx ▓▓▓░ 71%      │  in 2h11 │
│  you     │                    │  [ALWAYS ALLOW]    │                    │  $4.20/h │
└──────────┴────────────────────┴────────────────────┴────────────────────┴──────────┘
   global      session lane         session lane        session lane        burn rail
```

- **Session lanes** (the heart): one card per session — project + branch, state color wash, live activity line ("Editing auth.ts", "Running pytest"), context-fill bar, session cost. Lanes auto-sort by urgency: **needs-you first**, then working, then idle/done. More sessions than fit → horizontal scroll; the status rail always shows the true count. (Codex Micro capped at 6. We don't.)
- **Approval takeover:** when a permission request arrives, that lane expands, pulses amber, and shows **the actual command verbatim** with big Allow / Deny / Always-allow targets — the Claude Control/agentsd interaction, but with room to actually read what you're approving. Untouched, it times out gracefully and the terminal prompt proceeds as normal — the deck never blocks the CLI.
- **Tap-to-focus:** tap any lane → its terminal window comes to the front on your main display (Accessibility API; proven by agentsd).
- **Usage rail:** 5-hour block gauge, burn rate, time-to-reset — the ccusage jobs, ambient.
- **Completion moments:** when a session finishes, the lane pulses green — the exact dopamine the Codex Micro's frosted keys delivered, but with the commit summary on it.

### 4.2 The homage details (make it lovable, not just useful)

- **Effort dial:** a touch dial rendered on-strip per deck-dispatched session, echoing the Codex Micro's one genuinely novel control (reasoning knob). Honest constraint: it can only apply to sessions the deck launched via the SDK; terminal-owned sessions show effort read-only.
- **Personality without cosplay:** the strip idles as a calm ambient piece (subtle breathing gradient per session color) — desk-jewelry mode is a feature, not shame.

### 4.3 What v1 deliberately does NOT do

Launch sessions from voice, kanban planning, diff review, remote/mobile, multi-machine fleets, non-Claude agents. Every one of those has an incumbent; none of them is the unclaimed core.

---

## 5. Architecture (validated by research)

```
┌───────────────────────────── Open Agent Deck.app (Swift/SwiftUI) ─────────────────────────────┐
│                                                                                                │
│  Strip renderer ── full-screen borderless NSWindow on the 480x1920 display                     │
│                    (found via CoreGraphics display APIs; window mode on any display)           │
│  Touch engine  ── IOHIDManager reads the strip's HID digitizer directly (Input Monitoring      │
│                    permission). True multi-touch, hit-test in-app. Bypasses macOS's missing    │
│                    touch stack AND the wrong-display mapping problem entirely.                 │
│  Local server  ── http://127.0.0.1:<port>  ← Claude Code HTTP hooks POST here                  │
│                    · telemetry: SessionStart/Stop/PreToolUse/PostToolUse/Notification          │
│                    · permissions: PreToolUse held open until tap → allow/deny in response      │
│  Fleet poller  ── `claude agents --json` every ~2s for background-session states               │
│  Usage feed    ── statusline JSON relay + (optional, best-effort) ~/.claude JSONL enrichment   │
│  Dispatch      ── `claude -p / --bg` headless; later: TS Agent SDK sidecar for deck-owned      │
│                    sessions (interrupt, setModel/effort, streaming)                            │
│  Focus         ── Accessibility API to raise the session's terminal window                     │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Why native Swift and not Electron/Tauri:** "macOS-native quality is rare" is a named gap in the landscape; IOHIDManager and Accessibility work is Swift-natural; a deck must feel instant and sip battery. The TS Agent SDK, if/when we want it for deck-dispatched sessions, runs as a small sidecar — not a reason to make the whole app Electron.

**The critical technical risk — touch on macOS — is real but fully mapped.** macOS has no touchscreen stack; out-of-box touch on these strips is unconfirmed-to-broken, and when it half-works it maps to the wrong display. Our design sidesteps all of it by reading the HID digitizer directly, a pattern proven by Touch-Up (MIT) and MacXeneonEdgeTouchDriver (MIT, same product category — Corsair's strip). Fallback ladder if a controller misbehaves — **open paths first, commercial never required**: our own HID parsing → TouchUpCore framework (MIT) → display-only mode with mouse/keyboard (still useful) → window mode, which needs no hardware at all. UPDD ($150/$95 per computer, closed) is at most an optional detected adapter for users who already own it — consumed through a **generic open TUIO listener** (UPDD Commander ships a TUIO server; ~200 lines of dependency-free open code on our side, never linking their dylib), and the deck warns when UPDD's driver owns a device our HID reader expects. It is not a rung the product stands on. (Full analysis: research/08.)

---

## 6. De-risk plan — Milestone 0 (before any real build)

1. **Buy the hardware** (~$110–140): the cited LESOWN 8.8" USB-C touch unit (Amazon B0DQY31J9C). Note the vendor's own constraints: direct full-featured USB-C port, no hubs. Optionally also a ~$80 HDMI+USB-touch variant — its touch interface is isolated on its own USB device, easiest to probe. (Both units combined are still less than one Codex Micro.)
2. **Spike A — display:** plug in, confirm macOS drives 480x1920, rotation, brightness; full-screen borderless SwiftUI window on it.
3. **Spike B — touch:** `hidutil list` / IORegistryExplorer to inspect the controller's HID interfaces; minimal IOHIDManager tap dumping digitizer reports; confirm contact coordinates arrive.
4. **Spike C — hooks:** hand-write settings.json HTTP hooks pointing at a 30-line local server; run a real session; verify the event stream (including a held PreToolUse permission round-trip).

All three spikes green → the product is buildable exactly as designed. Spike B red → fallback ladder, product still viable.

## 7. Roadmap after v1

- **v1.1:** Always-allow rule writing (scoped, reviewable), richer per-tool approval cards (diff preview for Edit), sounds/haptic-style feedback, themes.
- **v1.2:** Dispatch from the deck: canned workflows as radial quick-actions (review PR, fix failing tests — the joystick homage), deck-owned SDK sessions with live effort dial and interrupt.
- **v1.3:** Plugin packaging — ship the hook config as a Claude Code plugin for one-command setup; OTel export option for teams.
- **Later/maybe:** other strip sizes (12.6" 1920x515, Corsair Xeneon Edge), iPad companion, Codex/other-agent adapters (the deck's server API stays agent-agnostic internally).

## 8. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Strip touch controller quirks on macOS | High | Milestone 0 spike; fallback ladder; window mode needs no hardware |
| Anthropic ships a first-party equivalent | Medium | They avoid hardware-adjacent UX (closed the notification issue "not planned"); we're OSS riding official surfaces — absorption would validate, not kill |
| Claude Code update velocity breaks integrations | Medium | Documented surfaces only; graceful degradation per feed; integration smoke tests |
| Race between deck approval and terminal approval | Low | Deck defers on timeout; treat terminal as source of truth; handle "already answered" |
| Name collision ("AgentDeck", "agent-deck" exist) | Low | Keep "Open Agent Deck" (distinct, descriptive) or rename before launch — decide pre-announcement |

## 9. What "people love it" looks like

- **The 30-second demo that sells it:** three sessions breathing on the strip; one flips amber and pulses showing `git push --force`; you tap **Deny** without leaving your editor; the lane sighs back to blue. Caption: *"stop babysitting your agents."*
- **Metrics:** median approval latency (Notification→decision) under 5s; ≥3 parallel sessions per active user; deck opened daily (ambient retention); stars/forks as OSS proxy.
- **The emotional job:** replace tab-cycling anxiety with a calm control room. The Codex Micro was mocked as a toy and *still* sold out on status lights alone — pair that delight with actual utility on documented rails, free, and this is the thing people screenshot on r/ClaudeAI.
