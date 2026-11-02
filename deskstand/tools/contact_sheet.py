"""Compose the render contact sheet. Usage: python3 tools/contact_sheet.py out/"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]
VIEWS = [("1_hero", "Front 3/4"), ("3_profile", "Side profile (display ghosted)"),
         ("6_clip_detail", "Clip + thumb tab on the top bezel"),
         ("2_rear", "Rear 3/4: tie rod through both feet"),
         ("7_insertion", "Insertion: tilt, ride the ramp, seat"),
         ("4_usbc_end", "USB-C end: nothing near the plug"),
         ("5_print_bed", "A1 mini plate: 2 feet + rod, no supports")]
TW, TH = 800, 500

def font(sz):
    for f in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try: return ImageFont.truetype(f, sz)
        except OSError: pass
    return ImageFont.load_default()

rep = json.load(open(os.path.join(OUT, "report.json")))
rows = (len(VIEWS) + 1 + 2) // 3
img = Image.new("RGB", (TW * 3, 90 + TH * rows), (24, 25, 28))
d = ImageDraw.Draw(img)
d.text((24, 16), "Snap-clip desk stand  -  8.8\" strip @ 60 deg, A1 mini, PLA",
       font=font(40), fill=(240, 240, 240))
d.text((24, 62), "Two identical feet + one tie rod. Every number below is computed by stand.py.",
       font=font(20), fill=(170, 170, 175))
for i, (v, lab) in enumerate(VIEWS):
    t = Image.open(os.path.join(OUT, f"{v}.png")).convert("RGB").resize((TW, TH))
    x, y = (i % 3) * TW, 90 + (i // 3) * TH
    img.paste(t, (x, y))
    d.rectangle((x, y, x + len(lab) * 11 + 24, y + 34), fill=(24, 25, 28))
    d.text((x + 12, y + 6), lab, font=font(20), fill=(230, 230, 230))
k = len(VIEWS)
x, y = (k % 3) * TW + 30, 90 + (k // 3) * TH + 22
sn, wc, pr, P = rep["snap"]["nominal"], rep["snap"]["worst"], rep["print"], rep["params"]
m = pr["est_minutes_total"]
lines = [
    f"Parts            2 feet {tuple(pr['foot_bbox_mm'])} + rod {tuple(pr['rod_bbox_mm'])}",
    f"Filament / time  ~{pr['est_grams_total']:.0f} g PLA, ~{m // 60} h {m % 60:02d} m (one plate)",
    f"Tip-back force   {rep['tip_force_N']} N at the screen's top edge",
    f"Snap             {sn['clip_force_N']} N, {sn['clip_lift_mm']} mm lift, {sn['peak_strain_pct']} % strain",
    f"  worst +/-{P['disp_h_tol']} mm  {wc['clip_force_N']} N, {wc['peak_strain_pct']} % (limit {P['pla_strain_max']})",
    f"Contact angle    {wc['first_contact_angle_deg']} deg min (ramp, not a wall)",
    f"Insertion        tilt {sn['insert_tilt_deg']} deg, {wc['insert_margin_deg']} deg margin min",
    f"Footprint        {rep['footprint_depth_mm']} deep, {rep['height_mm']} tall (mm)",
    f"Fit              {P['clr']} mm/side, display {P['disp_t']} mm thick",
    f"Design checks    {sum(rep['checks'].values())}/{len(rep['checks'])} pass",
    "Time/grams are estimates; confirm in Bambu Studio.",
]
for j, l in enumerate(lines):
    d.text((x, y + j * 39), l, font=font(22), fill=(225, 225, 228))
img.save(os.path.join(OUT, "sheet.png"))
print("ok")
