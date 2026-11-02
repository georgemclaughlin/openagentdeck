# LV39 — the queued-message composer, recorded 2026-08-14

Captured live with `cmux read-screen` (cmux 0.63.1) against a Claude Code
2.1.231 session that was mid-turn with one message queued, on a development
machine, minutes after the deck refused a quick action with "The deck cannot
send to this session".

What is byte-faithful to the recording, and what is not:

- `screen-queued.txt`'s COMPOSER line is byte-identical to the recording:
  `e2 9d af` (the prompt glyph) + `c2 a0` (NO-BREAK SPACE, the same byte pair
  LV30's empty composer carries) + the sentence
  `Press up to edit queued messages`. This is Claude Code's own queued-state
  placeholder, drawn where LV30 recorded emptiness.
- The queued-echo line above the box (`  ❯ /surf-a`) keeps the recording's
  SHAPE (indent, glyph, ordinary space, text) with the queued text itself
  synthesized; the recording's own queued text was the deck's `/compact`.
- Transcript lines, the pane title, and the footer path are SYNTHESIZED —
  the privacy absolute (no real session content in fixtures). The footer's
  chrome line (`⏵⏵ bypass permissions …`) is product chrome, kept as recorded.

Why it exists: `Composer.read`'s fails-closed rule ("any text after the last
prompt glyph is a draft") read this placeholder as `holdingText`, so the deck
refused to send to a session in exactly the state where a send would have
QUEUED cleanly — measured the same night by the deck's own later send landing
as a queued message. The placeholder sentence is pinned as empty-equivalent;
anything else after the glyph still refuses.
