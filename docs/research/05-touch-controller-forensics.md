# Touch Controllers in 8.8" 480×1920 Strip Monitors — macOS IOHIDManager Feasibility

**Compiled 2026-07-25.** Claims marked **CONFIRMED** (primary evidence: source code, lsusb/dmesg dumps, USB captures) or **INFERRED** (strong indirect evidence).

---

## 1. Executive summary

The dominant touch interface in the cheap 8.8" 480×1920 strip class is **not** eGalax or ILITEK — it is a **WCH (Nanjing QinHeng) USB-to-I2C bridge MCU** presenting as a standard USB HID multitouch digitizer, almost always enumerating as:

> **VID 0x1A86, PID 0xE5E3 — "wch.cn USB2IIC_CTP_CONTROL"** (QinHeng Electronics)

Behind the bridge sits an I2C capacitive controller (typically Goodix GT9xx-class — INFERRED). The bridge exposes a textbook Windows-precision-touch HID descriptor (usage page 0x0D, Touch Screen 0x04, contact count/ID/tip switch/16-bit X/Y, up to 6 contacts per report — CONFIRMED via full USB capture). Linux binds `hid-multitouch` with no quirks.

On macOS these enumerate as ordinary HID devices; **no kernel driver seizes them**. Two independent open-source macOS user-space drivers (Touch-Up; two Corsair Xeneon Edge drivers — the Xeneon's touch bridge is itself a wch.cn part) read this device class via IOHIDManager with the Input Monitoring TCC permission. **The deck's direct-HID architecture is validated by working prior art.**

**Verdict for a random LESOWN-class 8.8" strip:**

| Question | Probability | Basis |
|---|---|---|
| Enumerates as USB HID on macOS | ~95% | Standard HID class-3 device; enumeration is OS-agnostic. Residual: single-cable USB-C units with misbehaving internal hubs (Touch-Up issue #10, "Prechen" pattern) |
| Readable via IOHIDManager + Input Monitoring | ~85–90% | CONFIRMED for the same wch.cn family (Xeneon Edge, two working drivers); no macOS kernel grab exists |
| Reports true multi-touch contacts | ~75–85% | Stock 1A86:E5E3 descriptor is a 6-contact parallel digitizer (CONFIRMED by capture); deduction for firmware variants proven single-touch (Xeneon Edge) |

## 2. Controller identification

- **WCH 1A86:E5E3 "USB2IIC_CTP_CONTROL" — the class default. CONFIRMED** on a generic 1920×480 strip ([francip gist](https://gist.github.com/francip/4183e2a860af34dd4aa0d1c98366f76b)), a Wisecoco unit (`hid-multitouch ... [wch.cn CH57x]`, [RPi forums t=368455](https://forums.raspberrypi.com/viewtopic.php?t=368455)), and dozens of Linux/BSD machines ([linux-hardware](https://linux-hardware.org/?id=usb:1a86-e5e3)). Bridge chip family: WCH CH57x. LESOWN/VSDISPLAY/KEEBMONKEY using the same bridge is **INFERRED** (same HannStar HSD088IPW1 panel + same ODM board ecosystem, [vslcd 8.8" kit](https://www.vslcd.com/8.8inch-1920x480-tft-lcd-panel-with-driver-board.html)); no per-brand lsusb dump found.
- **Same silicon, custom VID: Corsair Xeneon Edge = 27C0:0859, mfr "wch.cn". CONFIRMED** ([ajvwhite driver](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver), [ymlaine driver](https://github.com/ymlaine/TouchscreenDriver)). **Critical caveat:** this firmware variant is **single-touch only** over USB (report ID 7, 7 bytes, absolute X 0–16383 / Y 0–9599, no contact count) — proof that **WCH firmware varies per product**: some are 6-contact digitizers, some single-touch absolute pointers. Never hard-code a report layout.
- **ILITEK 222A:0001** ("Multi-Touch-V3000") — real second family, mostly in larger portable monitors ([linux-hardware](https://linux-hardware.org/index.php?id=usb:222a-0001)); UPDD ships Mac-capable builds for it (INFERRED workable on Mac).
- **eGalax/EETI 0EEF** — classic industrial/open-frame controller; official Mac driver exists ([eeti.com](https://www.eeti.com/drivers_Mac.html)); not observed in current strips.
- Not observed in this class: SiS, FocalTech-USB, Weida, T-Sinus.

## 3. HID descriptor behavior (1A86:E5E3, CONFIRMED via usbmon capture)

Source: [cnblogs decode of a 1a86:e5e3](https://www.cnblogs.com/zyly/p/17747761.html) —

- Application collection: Usage Page 0x0D (Digitizer), Usage 0x04 (Touch Screen)
- Report ID 1 (Input, 52 bytes): up to **6 contacts, parallel mode**; per contact: Tip Switch → Contact ID (8b) → X (16b LE) → Y (16b LE) → width; trailing Contact Count byte
- Report ID 2 (Feature): Contact Count Maximum; Report ID 3: vendor blob (likely THQA)
- Logical X/Y max 4096 → **panel-normalized coordinates, not pixels**; rescale + axis-swap to the 480×1920 surface
- Fully Microsoft Windows Touch HID conformant (binds Linux `hid-multitouch` quirk-free)
- Mouse-fallback interface: possible but unconfirmed, variant-dependent

## 4. macOS access facts

- macOS does **not** block user-space HID access to touch digitizers; the risk is the opposite — its generic pointer pipeline may *also* interpret reports. Both Xeneon drivers seize (`kIOHIDOptionsTypeSeizeDevice`) so "macOS does not also consume the touchscreen as a generic pointer device"; Touch-Up defaults to shared mode with opt-in seize.
- Required permission: **Input Monitoring** (TCC) — `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`. Accessibility only needed to inject events (the deck doesn't).
- Vendor "no Mac touch" disclaimers (Wisecoco: "non-disclosure of the Mac OS's touch communication protocol"; KEEBMONKEY "Macs display only") mean *"no OS touch stack, we ship no driver"* — **not** that the device fails to enumerate. For a direct-HID app this is the normal, expected case.
- Field failures exist: Touch-Up issue #10 — a Prechen portable over single-cable USB-C failed; over HDMI + USB the touch device enumerated but reported nothing. Generic matching works broadly, not universally.

## 5. Touch-Up source review (first-hand, 2026-07-25 — repo cloned and read)

[shueber/Touch-Up](https://github.com/shueber/Touch-Up), **MIT** (© 2024 Sebastian Hueber). App layer (Swift: cursor injection, calibration UI, per-display mapping) + `TouchUpCore` (C, ~850 lines, `HIDInterpreter.c`) — the part relevant to the deck. Load-bearing mechanics, verified in source:

1. **Matching:** single dictionary `{UsagePage: 0x0D, Usage: kHIDUsage_Dig_TouchScreen}` — brand-agnostic, no VID/PID list.
2. **Combo-digitizer selection:** several HID interfaces can share one USB `locationID`; it counts logical collections containing a `ContactIdentifier` per interface and registers only the interface with the most — **hot-swapping** if a richer interface enumerates later (connect order is non-deterministic). Ignored-sibling removal is a no-op so the screen doesn't "disconnect" spuriously.
3. **Report framing:** per-device `IOHIDQueue` (depth 1000); input-value callback lazily adds elements to the queue; the queue-drain callback reads values until empty — *empty queue = one complete report processed* → dispatch contacts.
4. **Hybrid-mode pagination:** detects `contactCount > numCollections` with continuation reports (contact count 0) and maintains a `hybridOffset` so paginated contacts reassemble correctly.
5. **Seize is opt-in and idempotent** (`SetTouchDevicesSeized`), applied live to current and future devices; released on close.
6. **Normalization:** X/Y scaled by each element's logical min/max; elements identified by walking up to the application collection and classifying logical-collection children.
7. Limits: max 4 touchscreens; state keyed by `IOHIDDeviceRef` (not locationID).

**Applicability to Open Agent Deck:** the deck needs exactly this bottom layer and *none* of Touch-Up's upper layers (no cursor injection, no calibration UI — we hit-test in our own window). Options: (a) reimplement in Swift following this design (~1–2 days, cleanest), or (b) vendor `HIDInterpreter.c` + a thin Swift wrapper under MIT attribution. Either is fully open-source compatible. The Spike B checklist inherits items 2–4 above as required behaviors, not nice-to-haves.

## 6. Implementation requirements distilled (for Spike B / v1)

1. Match by usage page 0x0D / usage 0x04 — never by VID/PID (though 0x1A86 may be prioritized for defaults)
2. Parse by element usage (Tip 0x42, ContactID 0x51, ContactCount 0x54, GD X/Y 0x30/0x31) with per-element logical min/max normalization — never hard-code byte layouts (the Xeneon variant proves layouts differ within one silicon family)
3. Implement hybrid-mode pagination
4. Open non-seized first; ship seize as a setting (default on if the device exposes pointer-ish sibling collections)
5. Request Input Monitoring up front; distinguish permission-denial from device absence
6. Expect logical-space coordinates; rescale + rotate to 480×1920

**Buying tell-tales:** good — "5-point capacitive, driver-free", "Raspberry Pi touch supported", dedicated TOUCH USB port, reviews mentioning "USB2IIC"/"wch.cn". Avoid — "Windows/Android only" touch with proprietary single-cable hubs (the Prechen pattern); the Xeneon Edge itself if multi-touch matters (single-touch firmware).

## Key sources

[ajvwhite/MacXeneonEdgeTouchDriver](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver) · [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver) · [shueber/Touch-Up](https://github.com/shueber/Touch-Up) (+ issue #10) · [cnblogs 1a86:e5e3 usbmon capture](https://www.cnblogs.com/zyly/p/17747761.html) · [RPi forums t=368455](https://forums.raspberrypi.com/viewtopic.php?t=368455) · [francip 1920×480 gist](https://gist.github.com/francip/4183e2a860af34dd4aa0d1c98366f76b) · [linux-hardware 1a86-e5e3](https://linux-hardware.org/?id=usb:1a86-e5e3) / [27c0-0859](https://linux-hardware.org/?id=usb:27c0-0859) / [222a-0001](https://linux-hardware.org/index.php?id=usb:222a-0001) · [Touch-Base UPDD](https://www.touch-base.com/) · [EETI Mac drivers](https://www.eeti.com/drivers_Mac.html) · [vslcd 8.8" kit](https://www.vslcd.com/8.8inch-1920x480-tft-lcd-panel-with-driver-board.html) · [nachtimwald IOHIDManager permissions](https://nachtimwald.com/2020/11/08/macos-iohidmanager-permission-issue/)
