# Snap-clip desk stand — printing and fitting

The stand holds the 8.8" strip display at 60°. It has two identical feet, each
with a bottom channel and a spring clip that snaps over the top bezel. One tie rod
passes through both feet to keep them parallel and evenly spaced. All three parts
print on one A1 mini plate with no supports. Both short ends of the display stay
clear, so nothing comes near the USB-C plug.

## 1. Measure the display first

The fit depends on the display's real dimensions. Measure with calipers, and
rebuild if your numbers differ:

| Parameter | Default | Drives |
|---|---|---|
| `disp_t` | 13.5 mm | channel width (+`clr` per side, 0.35 mm) |
| `disp_h` | 65.5 mm (listed 65.0; the real one measured taller) | clip height (the checks also cover ±0.5 mm) |
| `bezel` | 5.0 mm | the lip (2.5 mm) and the clip nose (1.75 mm) must stay inside it |
| `disp_edge_r` | 0.3 mm | round on the display's top-front edge. The hook grips only the flat face above it, so a softly rounded display (1 mm or more) needs a rebuild, and may need a different hook |

```sh
blender -b -P stand.py -- --out out --disp_t 13.7   # any parameter in P can be overridden
python3 tools/contact_sheet.py out                  # render sheet
tools/regress.sh                                    # rebuild across the whole fit range
```

The build runs 20 design checks, and if any fail it exits non-zero with the list.
They cover:
- tip force,
- snap strain and contact angle, over the whole insertion and for displays 0.5 mm
  shorter and taller than measured,
- insertion margin,
- bezel clearances, and the thumb tab's clearance over the display corner's path,
- that the crush ribs actually grip the rod,
- lip and spring widths in line widths,
- a watertight triangle mesh,
- fit on the bed.

`tools/regress.sh` rebuilds 18 variants: `clr` 0.20–0.50, `disp_t` ±0.3,
`disp_h` ±0.5, `rod_clr` 0.20/0.30, a 24 mm foot, and angles 50–65°. All of them pass. At steeper angles the tail
lengthens on its own to keep tip force ≥ 5 N (a firm tap is 1–2 N). `out/report.json` holds every
number.

## 2. Files

| File | What |
|---|---|
| `out/stand_A1mini.3mf` | **Open this.** A Bambu Studio project: both feet and the rod are already placed on the 180 × 180 plate, with the print settings from section 3 embedded. If Studio asks, accept loading the project's settings. |
| `out/stand_generic.3mf` | The same plate as a plain 3MF with no settings, for other slicers. |
| `out/fit_test.3mf` | Clip-height fit test: two single feet, 1 tail notch = 0.6 mm and 2 notches = 0.4 mm of designed room above a 65.5 mm display (tab raised to 1.4 mm). Make your own with `tools/fit_plate.py`. |
| `out/test_plate.3mf` | Both tests on one plate: the two fit-test feet plus the five rod-gauge stubs. Made with `tools/fit_plate.py --add out/rod_gauge.3mf`. |
| `out/rod_gauge.3mf` | Rod fit gauge: five 30 mm rod stubs, 0.1 to 0.5 mm wider than the rod, same settings. See "Rod fit" below. |
| `out/foot.stl`, `out/tie_rod.stl` | Single parts in print orientation. Print 2 × foot and 1 × rod. |

One foot sits upside down on the plate. That's intentional: both feet then have
their textured-PEI face available for the outside.

## 3. Bambu Studio settings — A1 mini, 0.4 mm nozzle, Bambu PLA Basic

`out/stand_A1mini.3mf` already embeds these (printer **Bambu Lab A1 mini 0.4 nozzle**,
**Bambu PLA Basic**, **0.20mm Standard @BBL A1M** plus the changes below), and Studio
shows them as modified values on that preset. They live in `BAMBU_SETTINGS` in
`stand.py`. If you use the generic 3MF or another project, set them by hand:

| Setting (Bambu Studio name) | Set to | Stock | Why |
|---|---|---|---|
| Quality › Wall generator | **Arachne** | Classic | The spring's finger (1.8 mm) and arm (1.6 mm) aren't whole numbers of 0.42 mm lines. Classic would fill the leftover with weak gap-fill right where the spring bends. Arachne spreads it evenly across continuous walls. |
| Strength › Wall loops | **3** | 2 | One more line on the body, lip and tunnel walls. The spring is solid perimeter either way: the first test print held with 2. |
| Quality › Wall ordering | **Inner/Outer/Inner** | Inner/Outer | The channel and tunnel walls come out more accurate, and the outside stays clean. |
| Quality › Seam position | **Back** | Aligned | Print +Y is the tail end, so the seam lands on the tail, never on the clip. This holds for the flipped foot too. |
| Strength › Sparse infill | 15 %, **Gyroid** | 15 %, Grid | The body only needs stiffness. Gyroid travel never crosses the thin spring. |
| Strength › Top / bottom shell layers | **5 / 4** | 5 / 3 | These two flat faces are the ones you see. |
| Quality › Elephant foot compensation | **0.15 mm** | 0 | The first layer is a full profile, including the channel and tunnel. The flat faces have no chamfer, because a 0.6 mm one would thin the 1.8/1.6 mm spring and the lip's 1.15 mm flat top right at the faces, so this setting handles first-layer squish. The tunnel mouths do have real 0.6 mm chamfers. |
| Speed › Outer wall | **150 mm/s** | 200 | Crisper fit faces. Inner walls are already flow-limited. |
| Support | **Off** | Off | Printed on its side, a foot has no overhangs. The tunnel is a vertical hole. |
| Brim | **None** | Auto | Each foot sits on a 74 × 117 mm face. |
| Plate | Textured PEI | — | Clean it with dish soap. No glue. |

The model estimates about 55 g of PLA and about 1 h 30 min for the whole plate,
accurate to within about 20%. Check the real figures in the slicer. The Bambu
Studio command-line slicer crashes on this machine, so this couldn't be sliced
automatically.

**First print: one foot plus the rod.** Check five things:
- the display slides into the channel,
- the clip snaps,
- the rod goes through with a firm push past the two crush ribs,
- with the display clipped in, pull its top edge firmly toward you at the clip.
  It must not come out unless you lift the tab. If it does, your display's edge is
  rounder or the display is shorter than assumed: rebuild with your `disp_edge_r`
  and `disp_h`,
- the printed part matches your calipers. The one number that matters: from the
  channel floor to the underside of the clip arm, measured along the screen
  direction, should be 66.7 mm (`disp_h` + `top_gap`). The display must be at
  least 1 mm shorter than that.

Then print the second foot. If the channel is tight, rebuild with `--clr 0.45`; if
the display rattles, use `--clr 0.25`. For the rod, see "Rod fit" below.

**Rod fit.** How snugly the rod grips depends on your slicer settings as much
as on the model: the embedded settings (Arachne walls, inner/outer/inner order)
print the tunnel truer, and so a little larger, than Bambu's stock settings.
A rod that gripped feet printed with stock settings will slide in feet printed
with these. Fix it on the rod, which is a cheap reprint, and leave the feet:

1. Print `out/rod_gauge.3mf` (about 15 minutes, 6 g). Each stub's notch count is how
   many tenths of a millimetre wider than the current rod it is: 1 notch
   = +0.1 mm, up to 5 notches = +0.5 mm.
2. Push each stub, chamfered end first, into a foot's tunnel. Pick the narrowest
   one that needs a firm push and then stays put when you shake the foot.
3. Rebuild with that value, e.g. `--rod_fit 0.3`, and print only the rod.

If even the narrowest stub won't go in, the tunnels printed small: rebuild with
`--rod_rib 0.05` and reprint the feet. If the widest is still loose, keep going
with `--rod_fit` above 0.5.

## 4. Why it prints on its side

Each layer is a complete copy of the side profile. The spring bends within the
plane of the layers, so all of its stress runs along continuous extruded lines
and never tries to peel layers apart. Layer separation is the usual way printed
snaps fail, and this orientation designs it out. It also needs no supports. The
channel and the tunnel are both shaped by XY motion, which is the A1 mini's
most accurate axis.

## 5. Snap-fit engineering

"Worst" means across the whole insertion and for displays 0.5 mm shorter or taller.

| | Nominal | Worst | Rule / method |
|---|---|---|---|
| Nose lift | 2.69 mm | 3.21 mm | The display outline is swept in 0.25° steps about its bottom-front edge. Its top-back corner rises 1.4–1.75 mm while it passes the clip. |
| Snap force | 3.8 N per clip | 4.7 N | Unit-load bending along the real finger and arm centreline, with force along the ramp normal plus friction (μ 0.35). Every contact point at every step is sized (points moving away from the nose carry no load); the worst governs. |
| Peak strain | 0.68 % | 0.83 % | Limit 1.0 % for repeated-use PLA snaps (Bambu PLA Basic breaks at about 2–3 %). Kt is taken from the real root radii: 1.36 at the full-round slot floor (r 0.8), 1.29 at the arm root. |
| First-contact angle | 40.7° | 40.4° | Found by bisection to the instant of first touch. The display meets a ramp, never a wall; friction would lock it below about 20°.  |
| Ramp end over the corner's path | 1.62 mm | 1.13 mm | Measured to where the straight ramp ends. Past that point the tab is a constant 1.4 mm thick and ends in one full round, so nothing on the clip is pointed. The hook's retaining corner has only a small r 0.25 round, because at an acute corner a round eats r / tan(angle/2) of the flat face. The display's flat front face (above its own 0.3 mm edge round) bears on 0.82 mm of the hook's flat 90° face, or 0.32 mm for a display 0.5 mm short, so a forward pull can't cam the hook open. A display 1.0 mm taller than nominal still first meets the ramp, at 40.0°. |
| Insertion tilt / margin | 14.25° / 8.25° | 8.0° | The drafted lip doesn't block until 22.5°. |
| Seated load | none | none | 1.2 mm gap above the display and 0.7 mm in front of it. The spring is never preloaded, so PLA creep can't relax it. |
| What the display leans on | rigid 4.5 mm backrest, up to 3 mm below its top edge | | 0.016 mm/N. Touches go into the backrest, never into the spring, which sits behind it across a 1.6 mm slot. |
| Retention | 90° face | | A forward pull closes the slot and pushes the nose down harder. Lift the tab to release. |

## 6. Fitting

1. **The pads are required.** Press a 10 mm silicone bump-on into each of the four
   0.6 mm pockets under the feet. The pockets locate the pads, and the pads stand
   proud of the base. Bare PLA slides on a desk at about 1.5 N; the pads raise that
   to about 6 N.
2. Press the rod through both tunnels with a slight twist (it's a firm press, not a slide) with the clips facing the same way. Turn each
   foot so its **textured face points outward**, away from the other foot. Line up
   each foot's inner face with the engraved mark on the rod. Two opposed crush ribs
   centre and pinch the rod, so the first push is firm and after that they hold the
   spacing.
3. Rest the display's bottom edge in both channels, with the top tilted about 15°
   toward you.
4. **Click both clips at the same time**, one hand at each foot. Pinch the top edge
   of the display toward the back of the foot, thumb on the bezel and fingers
   behind the foot. Both clips engage at the same tilt, so they can't go in one at
   a time. **Always pinch, never push.** The two snaps take up to about 9 N together at the top edge,
   and an unsupported push of more than about 5.75 N tips the stand backward.
   Pinching keeps that force inside your hands.
5. To remove the display, lift **both** thumb tabs together, about 3 mm, and tilt
   the top forward.

Optional: a 0.5 mm self-adhesive felt or silicone strip on each backrest face
protects the back of the display and adds friction against sideways sliding.

A right-angle USB-C cable is neater, because the plug then runs along the display
instead of sticking out to the side.

PLA softens at about 55–60 °C. If the back of your display gets hot, print in
PETG instead, with the same settings and the PETG profile.
