# Open Agent Deck — UX Design Specification

**Version 0.4 · 2026-07-26 · Companion mockups: [`design/strip-states.html`](../design/strip-states.html)**
**Review status: v0.3.3 PASS ×3 — but v0.4 is NOT yet gated.** Planning Phase 0 materially revised three sections on 2026-07-26 and they await a gate: §3's feed semantics (the `status: null` claim is retracted — no artifact contains it), §4's always-allow model (session-scoped from the strip; the strip never writes `~/.claude`), and §9's restart behaviour (idle sessions reappear immediately from the fleet poll, per S7). Prior history: v0.2 passed a two-lens gate (product rigor + design craft). The v0.3 additions (question takeover, frontend-agnostic sessions, Remote Control rule) passed a hybrid PM/engineer/designer gate on round 3 — round 1 REVISE (citations, multi-question, layout collision, release paths → v0.3.1), round 2 REVISE (grid arithmetic, stepper-vs-queue, re-arm → v0.3.2), round 3 PASS with post-pass polish applied in v0.3.3 (label wrap rule, fixed check slot, multi-question ack copy, grid micro-deviations declared, hairline wording). Changelog at bottom. v0.2 passed a two-lens gate (product rigor + design craft). The v0.3 additions (question takeover, frontend-agnostic sessions, Remote Control rule) passed a hybrid PM/engineer/designer gate on round 3 — round 1 REVISE (citations, multi-question, layout collision, release paths → v0.3.1), round 2 REVISE (grid arithmetic, stepper-vs-queue, re-arm → v0.3.2), round 3 PASS with post-pass polish applied in v0.3.3 (label wrap rule, fixed check slot, multi-question ack copy, grid micro-deviations declared, hairline wording). Changelog at bottom.**

The deck's single job: **you know in under one second whether any agent needs you, and you act in one tap.** Everything below serves that sentence or gets cut.

---

## 1. Physical ground truth (all sizing derives from this)

| Fact | Value | Consequence |
|---|---|---|
| Active area | 218.9 × 54.7 mm at 1920×480 | **8.78 px/mm** |
| Apple HIG touch minimum | 44 pt ≈ 6.9 mm | **Minimum touch target 64 px**; primary decision targets ≥ 110 px single-row — with one declared exception: the two-row question grid runs 90 px rows (still 10.3 mm, well above the 64 px floor) to hold the documented 6-target maximum (§4.1) |
| Viewing distance | 50–70 cm, glance not study | Must-read text ≥ 22 px; recognition-only labels may be 15 px; the approval command 38 px; glance numerals 54–76 px |
| Panel | IPS, 600 cd/m², desk-level placement | Dark theme default; avoid pure white fills; **contrast floor 3.5:1 even for recognition labels** |
| Input | 5-point capacitive via our own HID pipeline | We define all gestures; no OS cursor, no hover — **touch or nothing** |

No hover means: no tooltips, no hover-reveals, no hidden affordances. Every control is visible or discoverable by one long-press convention, and any hidden content announces itself (§4).

## 2. Layout — mast, lanes, fuel

```
┌────────┬─────────────┬─────────────┬─────────────┬───────┬────────┐
│  MAST  │   lane 1    │   lane 2    │   lane 3    │ lane 4│  FUEL  │
│ 150 px │   470 px    │   470 px    │   470 px    │ (peek)│ 190 px │
└────────┴─────────────┴─────────────┴─────────────┴───────┴────────┘
```

- **Mast (left, 150 px):** app glyph (ink on lane surface — no brand color here, §7), session tally by state in session order, and the **attention counter** — a 76 px amber numeral when sessions are waiting. Tapping it scrolls to the oldest waiting lane. The mast is the fixed truth: even when waiting lanes are scrolled off-screen, the count is here. All clear shows a quiet ✓.
- **Lanes (center, horizontally scrollable):** one card per session, 470 px wide. Three fit fully; the fourth peeks to teach scrollability (peeked content clips at the edge — it never ellipsizes into fragments). Horizontal drag anywhere on the row scrolls the fleet (momentum + snap to lane edges).
- **Fuel (right, 190 px):** the 5-hour usage block as a vertical gauge showing **remaining** budget — a fuel tank that drains as you spend. Numeral = % left, cap label BLOCK LEFT, plus resets-in and today's spend. Fill is neutral ink; it turns red at ≤ 10 % left. No amber here — amber belongs to attention alone (§3).

### Lane order is stable. Always.

Lanes sit in session-start order, oldest left. The deck **never auto-reorders**: a moving target under a descending finger is how you approve the wrong command. Attention is routed instead by:
1. the mast counter (tap → scroll to oldest waiting lane),
2. amber **edge glow** on a side where an off-screen lane waits (tap → scroll to the **nearest waiting lane on that side**; while lit, the glow strip wins hit-testing over the lane peeking under it),
3. the waiting lane's own pulse.

User-initiated moves are fine: long-press → **Pin** docks a lane leftmost. **Amended — shipped as Edit Layout, §6a, superseding this line's long-press sketch.** The mechanism that reached the strip is a fleet-wide edit MODE rather than a per-lane long-press: still entirely user-initiated (the "never auto-reorders" rule above is unchanged — nothing here moves a card without a finger on it), just a different gesture than originally sketched.

## 3. Lane anatomy

```
┌─┬──────────────────────────────────────────────┐
│▌│  ◈ checkout-api        fix/idempotency-keys  │  ← name 34px semibold · branch 22px mono dim
│▌│                                              │
│▌│  Editing payments/retry.ts            2m 14s │  ← activity 26px · elapsed timer
│▌│                                              │
│▌│  CTX ▓▓▓▓░░░░░░ 41%   $1.84   sonnet ●●○     │  ← meters row, 15px caps labels
└─┴──────────────────────────────────────────────┘
 ↑ light bar, 16px full height — THE state signal
```

- **Light bar (16 px, full height):** color + motion *is* the state. The signature element — the deck reads as a row of status lights first, information second.
- **Name row:** project glyph (deterministic tint from project path), session/project name, branch in mono. **Branch is derived by the deck**, not fed: no surveyed surface supplies it in v2.1.220 (`agents --json` has no branch field; the statusline payload has no git block — both spike-verified), so the deck reads it from the session's `cwd`, which every hook event carries. Non-git directories simply render no branch — never a placeholder. Branch truncates in the middle, keeping prefix and leaf (`feat/…design`); the name never truncates. (Mockup approximates middle-truncation with a tail ellipsis.)
- **Activity line:** live verb from the latest hook event — "Editing payments/retry.ts", "Running pnpm test", "Waiting in terminal" — plus elapsed time in current state. Plain verbs, sentence case.
- **Meters row:** context bar (neutral fill; **red ≥ 90 %** with label "compaction soon" — no amber, see below), session cost, model label, effort dots. **The context bar fills as the window is consumed** and quotes `used_percentage` unaltered — the §2 fuel-gauge rule (remaining, drains as you spend) is about the *account usage* gauge and does not reach this meter. Claude Code reports context as used and the user reads that number on their own statusline; a deck that shows its complement makes them invert one of the two in their head. Staleness dims this reading (§7); it never annotates it. Data sources: context % and cost from the statusline relay (§5); effort from the hook payload's `effort.level`; model from statusline/agents feed. Any meter whose feed is absent renders as an empty slot — never a fabricated zero or a stale value. `effort` is a newer payload field than its neighbors: the integration smoke tests assert its presence explicitly, so a Claude Code release dropping it degrades to empty slots, not silent staleness.

  **Amended — the numeric reading beside the bar (`ctx:N%`) now follows its own three-step colour ramp, ALWAYS, never staleness-dimmed.** `ContextLoad`: calm below 50% (blue), caution 50–74% (orange), alarm 75%+ (red) — one rule, read by both this card's own footer number and the detail band's own big-number readout (below).

  **Amended again — the divergence this paragraph first described did not survive a second live screenshot.** The bar was NOT left "unchanged": a follow-on found it still dimming to grey whenever the reading passed 30 s old (`MaxAges.contextPercent`) — most cards, most of the time, on a supervision deck where sessions sit idle between turns — and, even fresh, still filling from the OLD two-step ladder (neutral / red at 90%) rather than `ContextLoad`. Both are retired: the bar now reads `ContextLoad` too, unconditionally, so the red line MOVES from 90% to 75% (orange from 50%) to match the number exactly, and neither the bar nor the number carries an age signal any more. The semantic reason, stated once for both: a context percentage does not decay — an idle session's context is exactly what it was, and the last reading stays true until the next turn moves it. `LaneView.contextStale` survives only for the one place age genuinely still matters: an alarm raised on an old reading is a red the deck can no longer vouch for (the `meters` gate), which is a question about the alarm, not the number.

  **The detail band's own big-number readout.** When the band is open, the SELECTED session's own `ctx:N%` renders large (matching the toolbar usage readout's own size) beside the band's collapse control, in the same three-step colour. The selected card's own footer number hides for exactly as long as the band stays open on it — every other card in the fleet keeps its own reading, band open or not.
- **Sessions bind to frontends, not terminals.** A session's frontend may be a terminal *or* the Claude Code desktop app. Hooks are **expected** to be engine-level and fire identically for both — Spike C verifies this (open question §10.6), and the failure mode is honest by structure: if desktop-app sessions don't fire hooks, they simply never appear as lanes; the deck never shows a session it can't hear. The deck records each session's frontend and points at the right one everywhere: tap-to-focus raises the terminal window or the app; timeout copy names it ("falls back to the terminal / the app"). Desktop-app sessions may lack a statusline feed — their context/cost meters follow the empty-slot rule, never fabrication.
- **Background sessions** (from `claude agents --json`): lane carries a small `BG` tag beside the branch; the fleet feed's background-only **`state`** field (spike-observed `working` → `done`) drives working/finished, since `status` reads `idle` for both an idle interactive session and a completed background one. Tap opens a read-only transcript peek **on the main display** (there is no frontend window to focus); the deck reads the transcript itself — the advertised `claude logs <id>` is not implemented at v2.1.220 (research/09-spike-results.md S9). **Meters are live, not empty:** background sessions do emit the statusline feed (spike-verified real context %/cost), so BG lanes carry the same meters as any other. All other anatomy is identical.
- **Whole lane = one touch target.** Tap → frontend-owned session: its window comes to front on the main display; background session: transcript peek. Long-press (600 ms) → lane sheet: **Pin · Rename · Dismiss** (Dismiss appears on done/error/ended lanes). **No Stop in v1** — and the spike hardened this: no surface exists to stop a frontend-owned session, and for background sessions the dispatch banner advertises `claude stop <id>` but **it is not implemented at v2.1.220** (not in `claude --help`; invoking it starts a new session — research/09-spike-results.md S9). Stop returns in v1.2 (§10.2) only when a real mechanism exists; a smoke test watches for the banner and the CLI to agree.

### State vocabulary (color is never the only channel)

| State | Bar color | Motion | Redundant glyph |
|---|---|---|---|
| Working | instrument blue `#5E9EE6` | card wash: steady, in the lane's own identity colour — no motion | animated ⋯ in activity line |
| Needs you | amber `#FFB13D` | card wash: pulses 1.2 s between a low and a high opacity, in the lane's own identity colour | **!** badge (approval) / **?** badge (question) on glyph |
| Done | green `#57C785` | one 600 ms bloom, then solid; fades toward idle after 10 min | ✓ badge |
| Error | red `#E8604C` | solid (no motion — errors don't dance) | ✕ badge |
| Idle | warm gray `#6B6558` | none | — |

**Amber is reserved.** Saturated amber appears only for needs-you signals (bar, badge, mast counter, edge glow, takeover chrome, timeout warnings). Resource warnings (context, fuel) escalate straight from neutral to red at their critical threshold, so a busy fleet can never impersonate the "someone needs me" glance. Error-red and resource-red stay unambiguous because they differ in scale, position, and channel — error is a full-height bar + ✕ badge; resource-red is a small inline fill that **must never appear without its text label**. That labeling rule is what keeps the double duty safe; it survives any future redesign of the meters.

**Amended — the ctx NUMBER (not the bar) is the one exception to "neutral until critical," and deliberately so.** `ContextLoad`'s own three-step ramp (blue calm / orange caution at 50% / red alarm at 75%) paints the fleet card's own footer reading unconditionally — never neutral, never grey, at any percent. This does not reopen the amber reservation above (the ramp never touches amber/yellow). A live screenshot found the footer's own number reading grey in one glance and blue-ish in the next — the inconsistency was the number disagreeing with the bar and the "Working" chip beside it, both already blue-ish by way of the system accent colour, while the number itself only ever drew grey or red. One rule, stated once, was the fix — for the number.

**Amended again — the ctx BAR is no longer an exception to this exception; it joined the ramp too.** The claim just above ("does not change the BAR, which still escalates straight from neutral to red at 90%") did not hold: the bar was ALSO found greying, on a live screenshot of the identical 36% card shown twice, blue in one and grey in the other — thirty seconds of idle time between them, nothing else different. Both context surfaces — the bar along the card's top edge and the number in its footer — now read `ContextLoad` unconditionally; the resource-red boundary this section's own table implies for context moved with it, from 90% to 75%, orange from 50%. "Resource warnings escalate straight from neutral to red at their critical threshold" no longer describes the context meter (it still describes the account-usage gauge, unchanged) — context escalates in three named steps now, always, never neutral and never dimmed.

Color-blind safety: states are additionally distinguished by motion pattern and badge shape. Reduce Motion (system setting, respected): the wash's pulse collapses to a static two-step opacity change — working holds its steady 0.14, needs-you is pinned at 0.30 — rather than breathing or pulsing.

## 4. The approval takeover (the product's climax)

When a `PreToolUse` permission request arrives, that session's lane **expands in place** to 940 px (320 ms ease-out; neighbors compress, never reorder). If the requesting lane is partially off-screen or 940 px doesn't fit at its position, the row performs the **minimal scroll** that fits the expanded card — smallest possible displacement, animated before the buttons arm.

```
┌─┬────────────────────────────────────────────────────────────────────┐
│▌│  ◈ web · feat/nav-redesign                     ( NEXT: infra )     │  ← read…
│▌│  ┌────────────────────────────────────────────────────────────────┐│
│▌│  │ BASH · WANTS TO RUN          falls back to terminal in 1:32    ││
│▌│  │ $ git push --force origin main                                 ││  ← …the whole command,
│▌│  └────────────────────────────────────────────────────────────────┘│     full width
│▌│                                        [  DENY  ] [    ALLOW    ]  │  ← …then act
└─┴────────────────────────────────────────────────────────────────────┘
```

(The countdown lives in the well head on every takeover — you learn the budget as you read, and the action row stays pure.)

Reading on top, acting at the bottom — the command well spans the full card width and the eye travels read → decide → tap in one direction.

- **The command verbatim, never silently clipped.** 38 px mono on a full-width recessed well. Long single lines **wrap** — no horizontal clipping, ever. Content taller than the well shows a mandatory **"▾ N more lines"** chip and a hard fade edge; vertical drag inside the well scrolls it (horizontal drag still scrolls the fleet — axis decides). Allow does not arm until any "more lines" chip has been on screen through the arm delay. No scroll-to-end requirement — that would punish the 95 % single-line case. For Edit: filename + one-line ± summary, same rules.
- **Deny and Allow: equal size (260 × 110 px), tap once.** Allow is the common case; friction here defeats the product. Deny sits left of Allow in the bottom-right action row (mirrorable for left-hand placement).
- **Always allow: long-press Allow (600 ms fill ring)** creates a **session-scoped** rule, confirmed by an on-strip toast ("Always allowing `pnpm test` in web, this session — undo"). Never a single tap: a glance surface must not create standing policy by accident. The hint is printed on the button itself — no hidden affordances.
- **The strip never writes to `~/.claude`.** A session-scoped rule lives in the deck's own memory and dies with the session. **Durable** rules are made in the settings window, where the exact diff is previewed before any byte is written (INV-C1). This resolves the conflict between this section and INV-C1 the planning phase surfaced: the fast gesture stays fast because it is not a config write at all.
- **Supervision loss is always visible.** Any rule — session or durable — suppresses the `PreToolUse` the deck relies on, so the deck stops seeing that action. The mast therefore carries a persistent muted chip, tappable to review and revoke. It reads **“≥ N muted”**, never a bare count: the deck can enumerate the rules it created, but not pre-existing `permissions.allow` entries, project-layer settings, or a `PATH` wrapper's injected set — an exact number would be a figure it cannot back (INV-C12, gap SG10). An instrument that goes quiet without saying so is indistinguishable from a calm situation, which is the one confusion this product exists to remove.
- **Arm delay:** buttons arm 250 ms after the expansion animation settles; **any takeover-to-takeover transition — auto-advance or user promotion — arms at 400 ms** (a rhythm tap must die on an unarmed button). A touch that began before expansion cannot land on a button.
- **Resolution is acknowledged synchronously.** The deck holds the hook's HTTP request; writing the response *is* the confirmation. On Allow: lane returns to Working with activity "Running `<tool>`…". On Deny: lane returns to its prior state. Only if the response write itself fails does the lane show "Answer in terminal". There is no PostToolUse watchdog — deny never produces one and long tools produce one late; neither may be used as an ack.
- **Timeout, honestly:** the hook hold has a hard budget (120 s). "falls back to terminal in 1:32" is visible the whole time — a consequence disclosure doesn't appear at the last moment — and the top-edge hairline drains alongside it, brightening to full amber in the final 20 s (it is amber-tinted throughout — the takeover is already amber chrome; the last 20 s raise intensity, not hue). On expiry the card contracts to a compact amber lane reading "Waiting in terminal — tap to answer there". No race with the terminal exists while the deck holds the hook (the terminal prompt only appears after the hook returns); after fallback, the terminal is the sole authority and the deck just points at it.
- **Headless has no terminal to fall back to.** For background sessions the takeover reads "No terminal behind this session — unanswered becomes deny in 1:32"; on expiry the deck returns deny ("No operator response"). The denial surfaces as a persistent line item on the lane ("Auto-denied Bash · 2m ago") — but **the live fleet feed owns the light bar**: a denied agent may route around the denial and keep working, so the bar goes red only when the fleet feed reports a failure state, never because the deck denied something. **Feed semantics (spike-verified, v2.1.220 — failure value induced in S18):** background rows carry a `state` field ∈ {`working`, `done`, **`blocked`**}, and **both `state` and `status` are optional keys** — observed values are `status` ∈ {`busy`, `idle`}, with **no explicit `null` anywhere in the corpus**. **A killed session reports `state: "blocked"` — not the `failed` this spec originally assumed — on a row that still carries `status: "idle"`, so `status` must never be read as the failure signal.** That mismatch is exactly why the deck treats **any unrecognized `state`/`status` value as unknown, not as error**, holds the lane's prior state, and logs it: the wrong-enum guess degraded to "the lane never turns red" instead of "the lane lies". **This defensive rule is load-bearing — do not replace it with a positive match on a value list.** Only `blocked` (and any future value explicitly verified as a failure) lights the bar red. The integration smoke tests assert this enum so a value change surfaces as a test failure rather than a mislit lane. Never leave a headless agent hanging on a prompt nobody can see.
- **Queue, not chorus — and no dead ends:** one takeover at a time; additional requests pulse compact in their own lanes showing their **remaining** countdown ("terminal in 0:41"), and the takeover shows a `NEXT: infra` chip. **Tapping a queued waiting lane or the NEXT chip promotes that request to the takeover** (the current one demotes back to the queue, unanswered) — urgency is the user's call, not FIFO's. Resolving a takeover auto-advances to the next request **only if its lane is already fully in view**; otherwise the routing signals light up and the deck waits for the tap. If a request arrives while a finger is down, expansion waits for touch-up.
- **Remote Control collision — don't race the phone.** Premise (inferred from §4's sequencing, **verified in Spike C**): while the deck holds a hook, the frontend prompt — and any mobile push tied to it — hasn't fired yet, so a 120 s hold would delay the phone alert for a user who isn't at the desk. If pushes prove independent of the hook, this rule is unnecessary and is dropped. Otherwise: for sessions under Remote Control, the deck holds for **15 s only**, then releases with no decision — the prompt and its push fire, and the lane stays amber reading "Sent to your phone · also in the terminal — tap to open" (copy follows the frontend per §3 — "…also in the app" for desktop sessions; the at-desk user the 15 s hold serves must see the nearer option too). These lanes count in the mast WAITING tally and edge glows like any needs-you. If remote-controlled state proves undetectable from documented surfaces (open question §10), the fallback is a global setting: Hold approvals · 120 s / 15 s / off.

### 4.1 Questions are the second takeover payload (AskUserQuestion)

Claude's `AskUserQuestion` is a tool call, so it arrives on the **same held `PreToolUse` channel** as approvals. One call carries an **array of questions** (docs show up to four; no hard cap documented — the stepper handles N), each with 2–4 options (label + one-line description) and optional multiSelect. The "Other" free-text escape is a **host convention per the docs**, not a built-in — each frontend implements its own, and the deck's is answered **in the deck**: tapping Other expands an inline text field in the takeover itself (shipped 2026-08-06), not a hand-off to the session's terminal. Same skeleton, different payload: **the well reads, the bottom zone acts.** (Schema and citations: research/03 §1.1b.)

```
┌─┬────────────────────────────────────────────────────────────────────┐
│▌│  ◈ web · feat/nav-redesign                                         │
│▌│  │ ASKS · AUTH METHOD · 1 OF 2      falls back to the app in 1:44  │
│▌│  │ Which auth approach should I use for the API routes?            │
│▌│                                                                    │
│▌│  [ JWT middleware ] [ Session cookies ] [ Other… ]                 │
└─┴────────────────────────────────────────────────────────────────────┘
```

- **Two surfaces, one interaction rule each — shipped 2026-08-07.** A question with no preview on any option resolves the way the rest of this section describes below: single-select on **one tap**, the action zone fixed and never scrolling. A question carrying at least one preview gets a full-strip stage instead — the same relationship a terminal dialog has to the rest of the screen: it owns the glass, the fleet and the band go dark beneath it. There, **the first tap focuses** an option (the mockup swaps into a preview pane, uncapped, beside the option list) and **the second tap commits** — mirroring the terminal's own highlight-then-Enter, with the focused row saying what its second tap does ("tap to choose") so the rule is discoverable rather than assumed. The uncapped pane is the point: it shows the 19-line mockup whole, the one thing the band's own capped options band could never do. Dismissing the stage (**✕**, deck-UI only) answers nothing: it collapses back to the band, where the same question resolves single-select on one tap again, previews capped-and-marked rather than shown in full — see below for that band's own overflow rule. *(Updated — this surface was the right-hand inspector through phase 1; the band replaced it as the deck's one detail surface, and the inspector itself has since been removed outright.)*
- **Options are the actions.** Each option renders as a button — label carries the decision; the description is support text (see §7). **Labels are never silently clipped:** a label wraps to 2 lines (covering the documented ~5-word maximum), and when it does, the description yields — one line in the 110 px row, hidden in a 90 px grid cell. **On the band** (a preview-less question, or the same question once the stage above is dismissed), single-select resolves on one tap after the standard arm delay — the full-strip stage's own two-tap rule is above. There is no Deny — an unanswered question has no destructive branch, which makes this the *safer* takeover.
- **The band's action zone never scrolls past a fixed cap, and every target within it is counted.** The target count is **options + Other + DONE (when multiSelect)** — maximum 4 + 1 + 1 = 6. **1–3 targets:** one row, 110 px tall. **4–6 targets:** a fixed **3-column × 2-row grid, 90 px rows** — six cells hold the documented maximum exactly. Cell order: options in given order, then Other, then **DONE always the final cell**. Buttons never move, never paginate, never slide — the no-moving-targets rule applies doubly to an action zone. Height check at maximum: header 44 + well ~130 + 2×90 + gaps ≈ 430 px < 452 available. (The 90 px grid row is a declared exception to §1's 110 px primary-target floor — see §1.) **When previews force the band past its own cap** (`QuestionOptionsBand.maxHeight`), this fixed grid gives way to a scrollable list behind an explicit **"▾ N more options"** marker — the band scrolls, capped-and-marked, rather than silently dropping options past the first; the full-strip stage above is what a previewed question gets instead of living behind that keyhole at all.
- **Multiple questions step, answers ship once.** The well head shows `1 OF 2`; answering a question advances the stepper in place. **A stepper advance is a takeover transition: the next question's targets arm at 400 ms** (§4) — new buttons must never inherit a rhythm tap aimed at the old ones. **The 120 s budget and its drain hairline span the whole call**, not per question. Because the hook holds one tool call, **all answers return together when the last question resolves**. Releasing mid-stepper (timeout, headless expiry — **and nothing else**) releases the whole call unanswered — partial answers are never submitted. Other no longer belongs on that list: it answers in place, exactly like an option (see below), and never releases anything.
- **Demotion keeps the hold.** Promoting another request away from a mid-stepper question does **not** release it — the question returns to the queue held, with its remaining countdown, exactly like any queued request (§4). On re-promotion the stepper restarts at question 1 with selections cleared — safe precisely because answers ship only once, at the end. Deck-local selections are never worth breaking the queue guarantee for.
- **multiSelect:** taps toggle — amber inset ring + a check in a **fixed leading slot reserved whether or not the cell is selected**, so toggling never reflows the label (buttons never move; neither do their words — the mockup approximates with an inline ✓). `DONE` sits in the final cell, disabled until ≥ 1 selected (disabled = hairline outline + dim ink — never faint, §7). DONE confirms that question and advances/submits. Never resolve a multi-select on first tap. Other joins the picked set as one entry, sorting last, exactly like an option someone tapped — see the row below.
- **"Other…" is answered in the deck, not routed to the frontend.** Tapping Other expands an inline text field in the takeover itself, keyed to the question on screen so switching questions (forward, or Back) never shows a draft typed against a different one; Submit (or Return) injects the typed text the same way a tapped option is injected — **single-select ships it outright and advances/submits, exactly like a tapped option; multiSelect joins it into the picked set as one entry, sorting after every offered option, and `DONE` submits as usual.** Typing over an existing typed answer replaces it — there is exactly one Other slot, never two. Nothing here releases the hold or focuses the session's terminal; the old "detect-and-route" fallback this line once described did not ship, because tapping an option answering outright (verified below) held for typed text too. On a **headless** session Other works identically — there was never a frontend it needed to reach.
- **Resolution ack, same as approvals (§4):** the response write is the confirmation; the lane returns to Working with "Answered — JWT middleware" (multi-question calls: "Answered — 3 questions").
- **Answer mechanics: shipped, unconditionally.** The mechanism is documented (research/03 §1.1b) — PreToolUse hooks return `hookSpecificOutput.updatedInput`, which "directly replaces tool arguments before the tool runs" — and the behaviour is **verified against a real interactive terminal session** (research/09-spike-results.md S6e): the deck's injected answer completed the tool call in **19 ms**, the terminal rendered "User answered Claude's questions → Teal", **no picker was ever shown**, and Claude's reply used the injected choice. Verified for deck-dispatched SDK sessions too (S6b). Tapping an option answers outright, and — shipped 2026-08-06 — so does typing one: Other's text is injected the identical way, never routed to a frontend picker. This section used to reserve a "Tier 2" fallback — detect-and-route, releasing the hold and focusing the frontend if the injected-answer approach did not pan out — for the case the spike above went the other way. It did not, for options OR for free text, so there is no second tier left in this build: do not reintroduce a release-and-focus path for either.
- Timeout, queueing, promotion, and the **well-overflow rules** (§4: wrap, "▾ N more lines" chip + fade, vertical-drag scroll) apply unchanged — long question text inherits them verbatim; a headless question that expires returns deny ("No operator response") — never auto-pick an option on Claude's behalf.

## 5. Ambient & empty states

- **Lights-out mode (idle desk jewelry):** after 90 s with no waiting sessions and no touch, the UI fades to near-black — only the light bars remain at their true lane positions, breathing, plus a ghosted clock and block-remaining. Any touch or state change wakes it; a needs-you always wakes it. **The waking touch is consumed** — it never lands on a lane or button.
- **First run:** three plain steps on the strip — "Claude Code found ✓" → big button **Install deck hooks** (the exact settings.json diff previews on the main display before anything writes; the diff includes both the HTTP hooks *and* the statusline relay) → "Start a session in any terminal. It shows up here." If a statusline is already configured, the relay wraps it: the existing command keeps rendering, the relay passes its output through and forwards the JSON — declared in the preview. Empty state after setup: "No sessions running. Start `claude` in any terminal."
- **Deck disconnected has two distinct failures:** hooks silent → mast glyph dims with ⚠ and one quiet line "Hooks not responding — Reinstall". Strip display unplugged → the deck hands off to window mode on the main display (§8) automatically, and returns to the strip when it reappears. Never a modal for either.

## 6. Gesture grammar (complete)

| Gesture | Where | Action |
|---|---|---|
| Tap | lane (terminal session) | Focus session's terminal window |
| Tap | lane (background session) | Transcript peek on main display |
| Tap | queued waiting lane | **Promote its request to the takeover** |
| Tap | NEXT chip | Promote next queued request |
| Tap | Allow / Deny | Resolve permission |
| Tap | question option (single-select) | Answer the question |
| Tap | question option (multiSelect) | Toggle selection; `DONE` confirms |
| Tap | "Other…" option | Expand an inline text field in the takeover |
| Tap / Return | Other's Submit | Answer with the typed text — same as tapping an option, single-select ships/advances, multiSelect joins the picked set |
| Long-press | Allow | Always-allow (fill ring, scoped rule + undo toast) |
| Long-press | lane | Sheet: Pin · Rename · Dismiss |
| Drag horizontal | lane row | Scroll fleet (snap to lane edges) |
| Drag vertical | approval well | Scroll long command content |
| Tap | mast counter | Scroll to oldest waiting lane |
| Tap | edge glow | Scroll to nearest waiting lane on that side (glow wins hit-testing while lit) |
| Tap | fuel gauge | Cycle detail: block left → resets-in → today $ → tok/min |
| Touch anywhere | lights-out mode | Wake (touch consumed) |

Nothing depends on force, multi-finger, or hover. All targets ≥ 64 px.

## 6a. Edit Layout (fleet reorder — shipped)

§2's "the deck never auto-reorders" still holds: everything below is USER-initiated, never automatic — a fleet-wide **mode**, not a per-lane gesture, and it supersedes §2's own earlier long-press-to-Pin sketch, which never shipped in that form.

- **Entry / exit.** A toolbar button — **Edit Layout** ↔ **Done** — enters and leaves the mode; disabled below two visible cards (nothing to reorder). The button, and the mode itself, is hidden while the detail band is open: editing is a FLEET-WIDE affordance and the banded fleet is a narrow single-card rail with nothing left to reorder against, so opening the band ends edit mode outright rather than leaving it running underneath a control it can no longer reach. Reselecting a card and reopening the band is how a person returns to browsing.
- **The wiggle.** Every participating card tilts and bobs continuously while editing — the reverse-engineered SpringBoard signature: two independent, per-card-randomized oscillators (rotation ≈0.28 s cycle, bounce ≈0.36 s cycle, each duration jittered ±0.025 s so no two cards ever beat together) rather than one synchronized circular motion, which reads as home-made. Amplitude is SIZE-derived, not a fixed angle: a fleet card holds the same ~1.5 pt of corner travel a 60 pt icon shows at ±2°, which on a 300 pt card works out to well under a degree of tilt while the vertical bounce (0–2 pt) stays full-throw — barely tilt, still bob, the large-widget posture. Ticks at 30 Hz (the CPU lever, deliberately below the display's own refresh rate — a wiggle does not need to interpolate at 120 Hz to read as organic). Each card's own wiggle rhythm is keyed to its surface (the tab or window hosting it), not its session id, so a `/exit` and a fresh session in the same tab keeps the same rhythm its predecessor had — matching how the order itself persists, below.
- **Drag.** A long-enough press-and-move lifts a card — scaled up, shadowed, drawn above its neighbors — and glues it to the finger; the rest of the row flows around it the instant the finger's position crosses the midline between the current slot and a neighbor's, with hysteresis so an equidistant boundary does not flicker back and forth. Releasing settles the card into its slot and writes the new order once, not once per neighbor it passed on the way there.
- **Persistence.** The manual order is keyed on each card's SURFACE — the terminal tab or window a session is hosted in — not its session id, so a `/exit` and a fresh session in the same tab keeps the position a person dragged it to; the order survives a relaunch. A card with no host address (the deck can watch that session but not address it) has nothing to key an order on, so it neither wiggles nor drags — it rides the fallback tail, after every ordered card, in its original session-start position relative to the others like it. A hidden card, revealed from the shelf, is visible in edit mode but does not itself participate — the shelf stays a read-only door onto the fleet, never a second reorderable surface.
- **Reduce Motion.** The wiggle is suppressed outright — a still fleet in edit mode, no tilt, no bob. The drag itself is unaffected: a lifted card wears a static border instead of the scale-and-shadow lift, and the reorder works exactly the same way underneath it.
- **V1 limits.** The fleet cannot scroll while editing — the slot map and the drag glue both read screen-space coordinates, and a scroll offset moving underneath an in-flight drag would be a second, disagreeing source of truth. A fleet that overflows the strip's own width can only reorder the cards already on screen; reaching a card past the fold needs a future scroll-aware version of the drag math, not this one.

## 7. Type & color tokens

| Role | Spec |
|---|---|
| Session name | SF Pro Display Semibold 34 |
| Activity line | SF Pro Text Regular 26 |
| Branch / anything git | SF Mono 22 |
| Approval command | SF Mono 38, full-width well, wraps |
| Question text | SF Pro Medium 32, in the well (28 when the two-row grid is present — vertical rhythm over size, declared) |
| Option label | SF Pro Semibold 26 — carries the decision; wraps to 2 lines rather than clipping (description yields when it does). DONE in a grid cell renders at 26, a declared step down from the 28 button token |
| Option description | SF Pro 17, wraps to 2 lines in the 110 px row; clamps to 1 line in 90 px grid cells (declared); recognition-tier — the label alone must suffice to decide |
| Countdown / fallback line | SF Pro 19 (both takeovers, one size, one home: the well head) |
| Micro labels (CTX, BLOCK LEFT, NEXT) | SF Pro 15 caps; tracking two-step system: +8 % inline, +10 % standalone |
| Glance numerals | SF Pro Display Light — 54 (fuel), 76 (mast attention) |
| Buttons | SF Pro Semibold 28 caps; hint line 17. Disabled = hairline outline + dim ink `#9A9080` — never faint |

Surfaces: bg `#16130F` (warm umber-black, never blue-black) · lane `#201C16` · recessed well `#120F0B` · ink `#EDE6D6` · dim ink `#9A9080` (≈ 5.4:1 on lane) · faint `#787060` (≈ 3.5:1 on lane — the floor; nothing inside a takeover may use it) · hairlines `#2E2820`. Readout accents (goal 18): violet `#BE93D4` · cyan `#4EC9B0` — text colours for the information→colour role model (branch and tool by default), never state colours, and every role is user-repointable in Settings. The context gauge's own BAR used to dim to faint once its reading passed 30 s old — reading never removed once fed, only marked. **Amended:** the `ctx:N%` NUMBER beside it no longer dims with age. **Amended again:** neither does the BAR any more — a follow-on found it still greying live, the identical mechanism, one surface later; both now read `ContextLoad` (blue/orange/red) unconditionally, staleness or not. §3's own amendments carry the full account, including why: a context percentage does not decay, so nothing about it should have been drawn as though it does. All fills are flat — no decorative gradients on an instrument (functional glows and drain trails excepted: the edge glow and the timeout hairline are gradients by nature). Brand coral `#D97757` appears **exactly once**: the first-run install button. State colors own all other meaning (§3).

## 8. Window mode (no strip required)

The identical 4:1 canvas as a frameless always-on-top window, default 1280×320, min 960×240, snapping to the bottom edge of the main display. Same layout, same tokens, scaled; pointer replaces touch (click = tap, click-hold = long-press). Window mode is the adoption funnel and the daily driver for people who never buy the strip — it is not a degraded mode. It is also the automatic fallback when the strip disappears (§5).

## 9. Edge cases (design answers, not TODOs)

| Case | Behavior |
|---|---|
| 12 sessions | Scroll + mast tally + edge glows; no shrinking below 470 px |
| Session runs in the Claude Code desktop app | **Expected** identical lanes and takeovers (hook parity is engine-level in principle but **unverified — never exercised by the spike**, §3 and §10.6); if hooks don't fire there, such sessions simply never appear as lanes. When they do: tap focuses the app window; timeout copy says "the app"; meters follow the empty-slot rule if no statusline feed |
| Session under Remote Control (phone/web attached to a local session) | 15 s hold only, then release so the mobile push fires; lane reads "Sent to your phone · also in the terminal — tap to open"; counts in mast tally + edge glows (§4) |
| Claude Code on the web (cloud sessions) | Invisible to the deck by design — nothing runs locally; the deck is a local-fleet instrument and never fakes remote state |
| Question with 4 options + Other (+ DONE if multiSelect) | 4–6 total targets → fixed 3×2 grid of 90 px rows — the action zone never scrolls (§4.1); order: options, Other, DONE final |
| Multi-question call (up to 4) | Stepper in place, `N OF M` in the well head; all answers return together on the last resolution; any release abandons the whole call (§4.1) |
| Question from a headless session expires | Deck returns deny ("No operator response") — never auto-pick an option (§4.1) |
| 0 sessions | Empty state line; lights-out after 90 s |
| Two approvals simultaneously | Oldest expands; others pulse compact with remaining countdown + NEXT chip; tap any to promote (§4) |
| Approval for an off-screen lane | Edge glow + mast count; takeover expands only when scrolled into view — the command must be read before it's actionable. Mast/glow tap goes there |
| Long or multi-line command | Wraps; "▾ N more lines" chip + fade edge when clipped vertically; well scrolls on vertical drag; opening verb always visible; Allow arms only after the chip has been visible through the arm delay |
| Requesting lane partially visible / 940 px doesn't fit | Minimal-scroll rule (§4): smallest displacement that fits the card, animated before buttons arm |
| Session crashes / SessionEnd without Stop | Lane turns error red with "Session ended unexpectedly", persists 10 min or until dismissed |
| Normal SessionEnd | Lane holds 60 s (green if it just finished), then collapses — but only while the strip is untouched for ≥ 5 s and no takeover is active; neighbors close the gap in one animation |
| Same project, two sessions | Branch + session name disambiguate; glyph tint identical (project-derived) |
| Deck answers, HTTP response write fails | Lane shows "Answer in terminal" — the only case that copy appears pre-timeout (§4) |
| User answers in terminal after fallback | Next hook event updates the lane; the deck never shows stale approval UI post-fallback |
| Deck app restarts mid-fleet | Held approvals fail their hooks → terminal prompts appear (honest by accident — the terminal was always the authority of record). Lanes repopulate as each session emits its next hook event; sessions idle at a prompt **reappear immediately**, because the fleet poll lists them (S7 shows five idle interactive rows). Hook-derived detail fills in as each session next speaks. The earlier "Sessions reappear on their next activity" copy was written before S7 and would have been untrue |
| Strip unplugged mid-session | Automatic window-mode handoff (§5, §8); pending takeover re-renders in the window, countdown intact |
| Background session's request expires | Deck returns deny ("No operator response"); lane shows "Auto-denied `<tool>` · Nm ago"; light bar follows the fleet feed, not the denial (§4) |

## 10. Open questions (tracked, not blocking)

1. Should completed background sessions offer **merge/PR actions** on-strip? (v1: no — the terminal owns git.)
2. Effort dial interactivity + Stop for deck-dispatched sessions (v1.2) — placements reserved. **Stop is blocked on a real mechanism:** the SDK can interrupt sessions the deck itself dispatched, but the CLI's advertised `claude stop <id>` does not exist at v2.1.220 (research/09-spike-results.md S9); a smoke test flags it if that changes.
3. Sound: a single soft chime on needs-you, off by default?
4. Multi-Mac / multi-user fleets — out of scope v1.
5. **Another tool may already own the hooks.** The spike ran under a wrapper on `PATH` that injects its own `--settings` hook set into every `claude` invocation (research/09-spike-results.md caveat 0). The installer must therefore detect pre-existing hooks — from a wrapper, another deck, or the user's own config — and merge rather than clobber, the same way §5's statusline relay wraps an existing statusline. Needs a first-run design and a test case.
6. Is Remote Control attachment detectable from documented surfaces? Determines whether the 15 s hold is automatic or a setting (§4).
7. ~~Does an interactive frontend honor PreToolUse allow-with-modified-input for AskUserQuestion?~~ **Answered: yes — Tier 1 confirmed for interactive terminal sessions (spike S6e).** Remaining Spike C items: Do desktop-app sessions fire the same hook set as terminal sessions (§3)? Does a held PreToolUse hook actually delay the Remote Control mobile push (decides whether the 15 s rule exists at all, §4)?

---

### v0.2 changelog (review findings addressed)

**From product review (all 5 blockers):** command wrapping + "N more lines" affordance + well-scroll gesture + chip-armed Allow (§4, §6, §9); synchronous hook-response ack replacing the PostToolUse watchdog (§4, §9); queue promote/demote via tap, in-view-only auto-advance, remaining countdowns on queued lanes (§4, §6); background sessions fully specced — BG tag, transcript peek, headless timeout = deny (§3, §4, §6, §9); Stop cut from v1 sheet, Dismiss added (§3). Effort dots retained *with* their data source cited — the hook payload carries `effort.level` (see research/03, §1.1). Also adopted: statusline-relay onboarding + coexistence + empty meter slots (§5, §3); amber exclusivity — resource warnings go neutral→red only (§2, §3); edge-glow nearest-on-side + hit-test priority (§2, §6); always-visible countdown (§4); 400 ms re-arm on advance (§4); hook-only done copy; cold-start, expansion-geometry, lane-removal, and unplug rows (§9); lights-out touch consumption (§5, §6).

**v0.3.2 (hybrid gate, round 2):** action-zone arithmetic closed — targets counted as options + Other + DONE, max 6, 1–3 → one 110 px row, 4–6 → 3×2 grid at 90 px (declared exception in §1), DONE always final; stepper demotion keeps the hold (release = Other/timeout/headless expiry only; re-promotion restarts at Q1, selections cleared); stepper advance re-arms at 400 ms and the 120 s budget spans the whole call; Reduce Motion covers the question bar; Tier 2 tap scoped to well/option zone; RC copy follows the frontend; question text inherits well-overflow rules; B3 grid frame added; version ledger established.

**v0.3.1 (hybrid gate, round 1):** research/03 §1.1b added with cited AskUserQuestion schema (questions is an array — multi-question is real), PreToolUse `updatedInput`, SDK answering pattern, desktop-app parity graded PARTIALLY documented, push timing graded NOT documented; multi-question stepper; fixed non-scrolling option layout; Tier 2 release+focus; headless Other suppressed; countdown unified to the well head on both takeovers; type roles tokenized; option descriptions wrap; multiSelect visuals; ?/! badges registered.

**v0.3 additions:** question takeover — AskUserQuestion as the second payload on the same held-hook channel, options-as-actions, multiSelect DONE, Other→frontend, tiered answer mechanics gated on Spike C (§4.1, §6, §9); frontend-agnostic sessions — terminal or desktop app, focus and copy follow the frontend (§3, §9); Remote Control collision — 15 s hold so the deck never delays the phone push (§4, §9); cloud sessions explicitly out (§9); open questions 5–6 added.

**From design-craft review (both blockers):** fuel gauge now shows *remaining* and drains, neutral fill, red ≤ 10 % — a fuel gauge that fills as you spend is a misleading instrument (§2); faint tier raised to `#787060` with a 3.5:1 floor and banned inside takeovers (§7). Also adopted: command 31→38 px; coral reduced to exactly one appearance and the mast glyph flattened to ink-on-surface (§2, §7); mockup frame B rebuilt as frame A + minutes for lane-order continuity; hold-hint 17 px full-opacity; per-lane breathe phase from session-id hash (§3 — superseded by the wash redesign: working is a steady wash now, no breathe to phase); two-step tracking system (§7); spec/mockup drift reconciled (76 px mast numeral, dim/faint hexes, 38 px command).
