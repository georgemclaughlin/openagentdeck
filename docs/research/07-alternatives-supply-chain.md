# Mac-Touch Alternatives & Strip Supply Chain

**Compiled 2026-07-25.** CONFIRMED = directly sourced; UNCERTAIN = inferred/dated/vendor-claimed. Framing fact: macOS has no native touch stack — every working Mac touch product is either a user-space HID→pointer driver (espresso Flow, ViewSonic vTouch and Dell's driver — both literally UPDD builds) or iPad-based remoting (Duet, Luna). The incumbents all do in user space exactly what an open-source app can do.

## Part A — Alternatives with confirmed macOS touch

| Option | Touch on Mac | Price | Notes |
|---|---|---|---|
| **espresso Displays** (13"/15"/17") | CONFIRMED multi-touch via their free Flow app (Accessibility permission = app-level event synthesis) | $469–799 | No public API/SDK (CONFIRMED absent); smallest is 13.3" 16:9 — not a strip; touch lands as ordinary pointer events |
| **ViewSonic TD1655 / TD1656-2K** | CONFIRMED 10-pt via vTouch — **which is white-label UPDD** (installs "UPDD System Extension and UPDD Commander"); Sonoma-confirmed, Apple Silicon universal | **$304.98** / $379.99 | Cheapest vendor-supported Mac touch monitor; 15.6"/16" 16:9, loses the strip form factor |
| **Dell P2424HT** (23.8" desk touch) | CONFIRMED — Dell hosts a free official UPDD macOS driver | ~$400–520 (UNCERTAIN) | Permanent-desk option |
| **Sidecar (iPad)** | **NOT viable** — finger touch does not drive Mac UI, Apple Pencil only (CONFIRMED, by design) | free | — |
| **Duet Display (iPad)** | CONFIRMED real finger-touch → Mac pointer events | $4–6/mo subscription | Closed; tier details for wired touch UNCERTAIN |
| **Luna Display (iPad)** | CONFIRMED touch gestures | **$89.99 one-time** (USB-C dongle) | Closed but subscription-free |
| **UPERFECT / INNOCN / Arzopa "Mac touch"** | Unsubstantiated or false — no drivers shown; Arzopa's own FAQ: no touch models | — | Avoid claims without a driver download |

**The open-source-native iPad path (fallback rung #1):** the deck could ship its **own iPad companion app** — touch forwarded to the Mac app over network/USB. Zero third-party software, fully open source, and *raw multi-touch* rather than a synthesized pointer — strictly more capable than any driver path. An old iPad mini in landscape ($80–150 used) is genuinely strip-like. Architecturally identical to Duet/Luna minus display mirroring.

**UPDD posture for an open-source app (detail in the dedicated UPDD report):** never bundle (proprietary, per-seat, ~$100–170 historical, current pricing behind portal); lawfully detect-and-document as an optional adapter. Since UPDD moves the pointer, the deck needs no UPDD-specific code for basic operation.

## Part B — Supply chain of the 8.8" 480×1920 class

- **The panel is HannStar HSD088IPW1-A00** (Taiwan): 8.8" a-Si IPS, 1920×480, 600 nits, MIPI-DSI, automotive temperature range, in production 8+ years (datasheet circulating since ~2017). CONFIRMED across five independent panel sellers. Second-source house numbers exist at VSDISPLAY (VS088GF01, VS088SJ01-B — origin UNCERTAIN). BOE supplies the adjacent 12.6" (NV126B5M-N41, in Wisecoco's own listing title).
- **The class is growing** — 7.84"/7.9" 400×1280 → 8.8" 1920×480 → 11.9" 320×1480 → 12.6" 1920×515 → 14" 3840×1100; vslcd's stretched-bar category spans 7.8"–43". **2-year availability: very likely** (automotive design-ins, multiple sources, expanding family).
- **DIY floor is $35**: HSD088IPW1 + driver board kits at vslcd (DHL 5–7 days); strip capacitive touch overlays sold separately (~$10–20, UNCERTAIN). Touch stack: Goodix GT9xx-class on glass (typical-for-class, UNCERTAIN per-unit) → **WCH CH57x USB HID bridge (1A86:E5E3, CONFIRMED — see research/05)**.
- **Purchasing gotcha (CONFIRMED):** two driver-board types ship under identical-looking listings — USB-C DP alt-mode boards (real monitors, Mac-compatible) vs **USB2 "extend screen" virtual-display boards** (vendor Windows software only, never a Mac display). Filter listings accordingly; also see research/06 on speaker-variant SKU fragmentation.

### Price snapshot (US, 2026-07-24/25)

LESOWN 8.8" USB-C touch ~$100–130 (Walmart $109.97–117.97; Amazon bot-blocked) · LESOWN P88D non-touch $103.72 sale · VSDISPLAY 8.8" touch ~$75–90 (UNCERTAIN) · vslcd DIY kit $35 · Wisecoco 12.6" touch $219.99 · Waveshare 7.9" touch $85.95 · Waveshare 11.9" touch ~€129. All Prime-stocked or 5–7 day DHL; no supply stress.

## Fallback ladder (if LESOWN-class touch proves unreadable — ranked for an open-source app)

0. *(Primary path, not a fallback)*: strip touch = standard HID digitizer behind WCH CH57x → IOHIDManager, user-space, fully open.
1. **iPad + our own open-source companion app** — only rung that is both fully open and true multi-touch. (Luna $89.99 / Duet $4–6/mo as closed off-the-shelf alternatives, external to our app.)
2. **Same-class retry:** Waveshare 7.9" touch $85.95 (documented touch chain, wiki, schematics) or the $35 vslcd DIY kit + documented GT911 overlay.
3. **UPDD as optional user-purchased adapter** (~$100–170/seat) — keeps the 8.8" hardware; never bundled.
4. **ViewSonic TD1655 $304.98** — cheapest turnkey vendor-supported Mac touch (vTouch = OEM UPDD).
5. **Dell P2424HT** — free official UPDD driver, desk-permanent.
6. **espresso Touch** $469+ — most polished, most expensive per usable inch, no API; list as "premium supported hardware," don't steer to it.

Avoid: UPERFECT/INNOCN/Arzopa Mac-touch marketing; USB2 "extend screen" board variants; Sidecar for finger input.
