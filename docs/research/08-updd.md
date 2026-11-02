# Touch-Base UPDD — Evaluated as an Optional Adapter for Open Agent Deck

**Compiled 2026-07-25.** Pricing live-quoted from Touch-Base's own purchase API on this date. CONFIRMED/UNCERTAIN marked. Full verdict: viable as an optional, user-purchased escape hatch — never more, and the right consumption mechanism is TUIO, not their C API.

## Product reality (2026)

- **UPDD V7 (7.1.x)**: DriverKit system extension (dext) + user-space daemon — **no kext, no SIP downgrade**, Apple Silicon universal. OEM integrators cite build 07.01.187 supporting Sequoia (+ Tahoe per one source; no first-party Tahoe statement — UNCERTAIN).
- Ships as one product: driver + **UPDD Console** (calibration) + **UPDD Commander** (gesture engine, **contains the built-in TUIO 1.1 server** on macOS) + **UPDD Client API** (C dylib + TCP :4146).
- **Install friction is real:** admin install → approve system extension → grant Accessibility to *three* items (updd, Commander, Daemon) → possible reboot; documented permission-wedge failure mode after macOS updates (toggle Login Item + re-grant). Meaningfully heavier than our own path (Input Monitoring only).

## Hardware coverage

- **Explicitly listed:** eGalax/EETI (98 mentions), ILITEK (14), SiS, FocalTech (thin). **Not listed:** Goodix bridges, and — notably — **WCH 1A86:E5E3**, the cheap-strip default.
- Two safety nets: **generic HID support** (V6+: reads the HID report descriptor and self-configures — the WCH bridge is a conformant digitizer, so this *should* work; UNCERTAIN until trialed) and **free controller additions on request** (CONFIRMED policy, NDA available, bit-level packet definitions).
- The **7-day free trial** (touch-limited per boot) is a cheap lab instrument: use it once per controller family to record compatibility before recommending in docs.

## Licensing & pricing (live quotes, 2026-07-25)

**Per computer**, irrespective of device count. US commercial **$150**; Home/Personal or Academic **$95**; volume $125@5 / $100@10 / $55@100; maintenance 3mo included. Stripe checkout. OEM branded packages start at 100+ licenses — irrelevant to an open-source distribution. **No bundling possible; documenting "buy it if needed" is exactly how their retail channel works.**

## The key macOS fact

System-wide, UPDD drives only the **single mouse cursor** (macOS has no third-party multi-touch injection path). Multi-contact data reaches apps **only** via Commander gestures, the C API, or **TUIO**. So an app consuming UPDD's TUIO feed gets strictly more than UPDD gives the rest of the OS — per-contact multitouch with session IDs.

## Integration posture (adopted)

1. **Primary tier unchanged:** our own IOHIDManager reader.
2. **Build a generic TUIO 1.1 (2Dcur, UDP) input backend** — ~200 lines, dependency-free, fully open, testable without UPDD. UPDD Commander routes per-device TUIO to any host:port (default 127.0.0.1:3333); docs say: "controller misbehaving? UPDD license + Commander TUIO → deck fully functional." Detect-and-consume, zero legal entanglement. Bonus: the TUIO backend is generic — phones, tablets, or any TUIO source can drive the deck.
3. **Detect UPDD presence** (daemon / TCP 4146 / `/Library/Application Support/UPDD`) for two reasons: its dext may **own the device and break our HID reader** (coexistence warning in-app), and to auto-suggest the TUIO backend when a strip's HID path fails.
4. **Never link `libupddapi`** — version-locked proprietary dylib, wrong trade for an open project. TUIO is version-stable and sandbox-friendlier.
5. Multi-monitor mapping: UPDD defaults digitizers to monitor 1 (the classic wrong-display problem) with Identify/EDID-binding remedies — but irrelevant when we consume TUIO's normalized device coordinates and map to our own window.

## Reputation

De-facto standard bundled by pro vendors (Slate RAVEN, ViewSonic vTouch, Dell P2424HT driver, CTOUCH, i3 — all OEM UPDD builds). Decades-old company, still shipping, responsive (free controller adds, refunds on OS-breakage era). Recurring gripes: $150 sticker, post-update permission wedges, occasional re-Identify after display changes, license re-prompts after updates.

## Competitors

None general-purpose: Touch-Up (open, our reference), EETI's free daemon (0x0EEF only), vTouch (ViewSonic-locked). For WCH strips the real menu is: **our HID reader / Touch-Up / UPDD** — in that order for an open-source product.

*(Key sources: touch-base.com product/docs/portal live quotes; support.touch-base.com controller-support, API, TUIO, trial/licensing docs; CTOUCH/i3/Slate OEM articles; SoundFlow & VDMX user threads. Full URL list in the agent transcript of 2026-07-25.)*
