"""Parametric desk stand for an 8.8" 1920x480 touchscreen strip.

Run:  blender -b -P stand.py -- --out out/ [--<param> <value> ...]
      Two identical snap-clip feet (concept C; A and B were dropped).

Every stand is one 2D side profile extruded along the display's width. The
profile is built in a frame attached to the display itself:

    s = distance up the screen from its bottom edge   (unit vector u)
    t = distance out of its back face toward the user (unit vector n)

so changing the display size, tilt angle, or clearances re-derives every
feature. All lengths are millimetres; 1 Blender unit = 1 mm.
"""
import bpy, bmesh, math, sys, os, json, tempfile
from mathutils import Vector, Matrix

# ---------------------------------------------------------------- parameters
P = dict(
    # Display (measure yours with calipers and edit these first).
    disp_w=232.0, disp_h=65.5, disp_t=13.5, bezel=5.0, disp_mass_g=380.0,
    disp_edge_r=0.3,     # round on the display's top-front edge ("basically
                         # sharp" = under ~0.3); the hook grips only the flat
    angle=60.0,          # screen tilt from the desk, degrees
    # FDM fit. Per-side gap between the display and printed walls. 0.35 is a
    # free slide-in on a well-tuned A1 mini; drop to 0.25 for a snug fit.
    clr=0.35,
    relief_r=0.8,        # dog-bone relief at the slot's inner corners
    # Cradle walls.
    lip_h=2.5,           # front lip height over the screen face (< bezel)
    lip_t=3.5,           # lip thickness at its root
    lip_chamfer=1.2,     # 45 deg chamfer on the lip's outer top edge (finger side)
    lip_draft=22.0,      # inner lip face leans out this far (deg) so the
                         # display can tilt forward about its bottom edge
    back_t=4.5,          # rigid backrest thickness (the display leans on it)
    back_gap=3.0,        # rigid backrest stops this far below the display top
    under_slot=5.0,      # material between the slot's lowest point and desk
    # Base.
    rear_angle=50.0,     # slope of the rear flank, degrees from desk
    tail_t=4.0,          # rear tail plate thickness
    base_rear=60.0,      # minimum tail end, mm behind the display's bottom-back
                         # edge; lengthened automatically to meet min_tip_N
    # Feet.
    foot_w=18.0,         # width of each foot
    foot_inset=45.0,     # foot centre distance from each display end
    # The hook (nose_ov, nose_r, nose_t, tab, tab_rise, ramp_stop) is at its
    # limits: first contact ~40.4 vs 40 deg, strain ~0.83 vs 1.0 %, flat-face
    # bearing ~0.32 vs 0.3 mm. Any change there needs tools/regress.sh.
    # Snap clip. A spring finger rises behind the rigid backrest (separated by
    # a slot), turns forward over the display's top edge as an arm, and ends
    # in a nose: one straight ramp from the retaining corner up to a thumb tab.
    flex_len=30.0,       # finger free length (slot depth below the display top)
    flex_t=1.8,          # finger thickness
    slot_w=1.6,          # slot between backrest and finger; its full-round floor
                         # (r = slot_w/2) is the finger's tension-side root
    arm_t=1.6,           # arm thickness
    top_gap=1.2,         # gap above the seated display's top edge (covers the
                         # +disp_h_tol case plus print/shrink error, independent
                         # of clr; 0.8 was lifted by a real display 0.5 mm tall)
    nose_ov=1.75,        # nose overlap of the top bezel, measured down from the
                         # seated display's top edge (so clr doesn't move it)
    nose_t=2.2,          # nose thickness in front of the screen
    nose_r=0.25,         # round on the retaining corner (the hook's lower point).
                         # The corner is acute (~44 deg), so a round eats
                         # r / tan(angle/2) of the flat face: keep it small
    tab=3.0,             # thumb tab: ramp continues this far past the nose
    tab_rise=1.0,        # tab tip sits this far above the arm top, so the
                         # display corner can't ride onto it
    ramp_stop=0.8,       # the ramp aims at (tab, tab_rise) but stops this far
                         # (along s) short of it; the display must never pass
                         # this point, so it sets the ramp-end clearance
    tab_t=1.4,           # thumb tab thickness, constant: its top runs parallel
                         # to the ramp and it ends in one full round (r = tab_t/2)
    pla_E=3000.0,        # PLA flexural modulus, MPa (printed, conservative)
    pla_strain_max=1.0,  # % peak strain allowed, repeated-use PLA snap
    mu=0.35,             # PLA-on-glass/bezel friction during insertion
    disp_h_tol=0.5,      # snap checks hold for display heights +/- this
    # Tie rod: one bar through a tunnel in both feet keeps them parallel and
    # spaced. The tunnel runs along X, i.e. vertical when printed: no bridging.
    rod_w=8.0, rod_h=5.0,  # rod section (y, z) in use
    rod_clr=0.25,        # per-side clearance in the tunnel (A1 mini prints
                         # vertical holes ~0.1 mm small, so this is a slip fit)
    rod_rib=0.10,        # interference of each of the two opposed side crush
                         # ribs: they centre the rod and are what hold it
    rod_fit=0.0,         # extra width on the printed rod only; the tunnel keeps
                         # rod_w. Wall settings change how big the tunnel prints
                         # (Arachne + inner/outer/inner print it truer, so a rod
                         # that gripped stock-settings feet slides in these).
                         # Tune it with out/rod_gauge.3mf: see PRINTING.md.
    rod_wall=2.5,        # minimum material around the tunnel
    id_notches=0,        # notches cut into the tail end, to tell test feet apart
    rod_overhang=3.0,    # rod length past each foot's outer face
    # Silicone bump-on pads (10 mm) recessed into the base, toe and tail.
    pad_d=10.2, pad_depth=0.6, pad_inset=7.0,
    tunnel_chamfer=0.6,  # 45 deg lead-in at both tunnel mouths
    line_w=0.42,         # nozzle line width, for minimum-feature checks
    min_tip_N=5.0,       # design rule: tip-back force at the screen's top edge
                         # (a firm tap is 1-2 N; 5 N keeps the tail short)
    tip_margin=1.15,     # the auto-sized tail aims this far above min_tip_N
)

# Bambu Studio print settings embedded in out/stand_A1mini.3mf, applied over
# profiles/process.json (0.20mm Standard @BBL A1M). Edit values here.
BAMBU_SETTINGS = {
    "layer_height": "0.2",
    # The spring's 1.8 / 1.6 mm finger and arm aren't whole numbers of 0.42 mm
    # lines; Arachne spreads the remainder instead of weak gap-fill (stock: classic).
    "wall_generator": "arachne",
    # Body, lip and tunnel walls a line thicker; the spring is solid perimeter
    # either way (the first print's 2 walls held), so 4 bought nothing (stock: 2).
    "wall_loops": "3",
    # Channel and tunnel walls come out more accurate (stock: inner/outer).
    "wall_sequence": "inner-outer-inner wall",
    # Print +Y is the tail, so the seam lands there, never on the clip (stock: aligned).
    "seam_position": "back",
    # Body needs stiffness only; gyroid travel never crosses the thin spring (stock: grid).
    "sparse_infill_pattern": "gyroid",
    "sparse_infill_density": "15%",
    # The two flat faces are the ones you see (stock: 5 / 3).
    "top_shell_layers": "5",
    "bottom_shell_layers": "4",
    # The first layer is a full profile; this handles first-layer squish (stock: 0).
    "elefant_foot_compensation": "0.15",
    # Crisper fit faces; inner walls are already flow-limited (stock: 200).
    "outer_wall_speed": "150",
    # Printed on its side, a foot has no overhangs; the tunnel is a vertical hole.
    "enable_support": "0",
    # Each foot sits on a 74 x 117 mm face (stock: auto).
    "brim_type": "no_brim",
    # Shown in Bambu Studio as this preset plus the modifications above.
    "print_settings_id": "0.20mm Standard @BBL A1M",
}

def args():
    """`--out out/` plus any parameter override: `--angle 50`."""
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    o = {"out": "out", "renders": "1"}
    for i in range(0, len(a) - 1, 2):
        k, v = a[i].lstrip("-"), a[i + 1]
        if k in P:
            P[k] = float(v)
        else:
            o[k] = v
    return o

OPTS = args()   # parsed first: every derived constant below reads P

# ---------------------------------------------------------------- frame math
TH = math.radians(P["angle"])
U = Vector((math.cos(TH), math.sin(TH)))      # up the screen, in (y, z)
N = Vector((-math.sin(TH), math.cos(TH)))     # out of the screen face
C = P["clr"]
T, H = P["disp_t"], P["disp_h"]
# Lift the frame so the slot's lowest corner sits `under_slot` above the desk.
Z0 = P["under_slot"] + C * (math.sin(TH) + math.cos(TH))
ORIGIN = Vector((0.0, Z0))

def L(s, t):
    """Display-frame (s, t) -> world (y, z)."""
    return ORIGIN + U * s + N * t

def on_desk(t):
    """Point where the line t=const meets the desk (z = 0)."""
    s = -(Z0 + t * math.cos(TH)) / math.sin(TH)
    return L(s, t)

# ---------------------------------------------------------------- 2D profile
FILLET_LOG = []   # (requested, achieved) radius of every rounded corner

def fillet(pts, radii, seg90=8):
    """Round each polygon corner by its radius (convex and concave alike).
    A corner whose edges are too short gets a smaller round; every request
    and what it actually got goes to FILLET_LOG, so a check can catch it."""
    out, n = [], len(pts)
    FILLET_LOG.clear()
    for i in range(n):
        p, r = Vector(pts[i]), radii[i]
        if r <= 0:
            out.append(p); continue
        a, b = Vector(pts[i - 1]), Vector(pts[(i + 1) % n])
        d1, d2 = (a - p).normalized(), (b - p).normalized()
        ang = d1.angle(d2)
        if ang < 1e-3 or abs(ang - math.pi) < 1e-3:
            out.append(p); continue
        tl = min(r / math.tan(ang / 2), (a - p).length * 0.45, (b - p).length * 0.45)
        FILLET_LOG.append((r, tl * math.tan(ang / 2)))
        r = tl * math.tan(ang / 2)
        p1, p2 = p + d1 * tl, p + d2 * tl
        c = p + (d1 + d2).normalized() * (r / math.sin(ang / 2))
        v1, v2 = p1 - c, p2 - c
        sweep = math.atan2(v1.x * v2.y - v1.y * v2.x, v1.dot(v2))
        k = max(2, math.ceil(seg90 * abs(sweep) / (math.pi / 2)))
        for j in range(k + 1):
            a_ = sweep * j / k
            out.append(c + Vector((v1.x * math.cos(a_) - v1.y * math.sin(a_),
                                   v1.x * math.sin(a_) + v1.y * math.cos(a_))))
    return out

def clean_poly(pts, tol=0.01):
    """Drop near-duplicate and collinear points. Either one triangulates into
    a zero-area sliver on the flat cap, which slicers flag as a bad mesh."""
    out = list(pts)
    changed = True
    while changed and len(out) > 3:
        changed = False
        for i in range(len(out)):
            a, p, b = out[i - 1], out[i], out[(i + 1) % len(out)]
            d1, d2 = p - a, b - p
            if d1.length < tol or abs(d1.x * d2.y - d1.y * d2.x) < tol * 1e-2 * max(d1.length + d2.length, 1):
                del out[i]; changed = True; break
    return out

def profile():
    """Closed side profile in world (y, z), plus dog-bone relief centres and
    the tail position. Built in the display frame, so every feature follows
    the display size, tilt and clearances."""
    tf = T + C + P["lip_t"]
    lh, lc = P["lip_h"], P["lip_chamfer"]
    lip_in = T + C + (lh + C) * math.tan(math.radians(P["lip_draft"]))
    g = clip_geometry()
    top, nf = g["top"], g["nose_front"]
    pts = [
        (on_desk(tf), 2.0),                              # front toe
        (L(lh - lc, tf), 0.5),                           # lip outer chamfer
        (L(lh, tf - lc), 0.5),
        (L(lh, lip_in), 0.5),                            # lip top, inside
        (L(-C, T + C), 0),                               # slot floor, front
        (L(-C, -C), 0),                                  # slot floor, back
        # Rigid backrest: the display leans on this to within back_gap of
        # its top edge, so touches never load the spring.
        (L(g["back_top"], -C), 0.8),
        (L(g["back_top"], g["back_rear"]), 0.8),
        (L(g["root"], g["back_rear"]), P["slot_w"] / 2 - 0.01),  # slot floor
        (L(g["root"], g["fin_front"]), P["slot_w"] / 2 - 0.01),  # (full round)
        # Spring finger and arm.
        (L(top, g["fin_front"]), 1.0),                   # arm root, tension side
        (L(top, T + C), 0),                              # arm underside, front
        (L(retain_s(), T + C), P["nose_r"]),               # retaining corner
        # Tab end: the ramp is cut off by a short end face, so the tip is two
        # obtuse/right corners that round properly instead of one acute point.
        *tab_points(top),                                # ramp end, round, tab top
        (L(top + P["arm_t"], g["fin_rear"]), 1.5),       # arm top, rear
        (L(g["root"], g["fin_rear"]), 3.0),              # finger root, rear
    ]
    F = L(g["root"], g["fin_rear"])
    tt = P["tail_t"]
    ky = F.x + (F.y - tt) / math.tan(math.radians(P["rear_angle"]))
    ry = max(P["base_rear"], ky + 8, tail_for_tip(P["tip_margin"] * P["min_tip_N"]))
    pts += [
        (Vector((ky, tt)), 8.0),                         # flank-to-tail swoop
        (Vector((ry, tt)), 2.0),                         # tail end, top
        (Vector((ry, 0.0)), 1.0),                        # tail end, desk
    ]
    poly = clean_poly(fillet([p for p, _ in pts], [r for _, r in pts]))
    reliefs = [L(-C, T + C), L(-C, -C)]
    return poly, reliefs, ry

def tab_frame(top):
    """Ramp end A (s, t), ramp direction d and tab-side normal n, in (s, t).
    The ramp runs from the retaining corner toward the aim point
    (top + arm_t + tab_rise, nose_front + tab) and stops ramp_stop short."""
    s_r, t_r = retain_s(), T + C                     # retaining corner
    s_aim = top + P["arm_t"] + P["tab_rise"]
    t_aim = T + C + P["nose_t"] + P["tab"]
    d = Vector((s_aim - s_r, t_aim - t_r)).normalized()
    k = (s_aim - P["ramp_stop"] - s_r) / d.x
    A = Vector((s_r, t_r)) + d * k
    return A, d, Vector((d.y, -d.x))                 # n: toward the arm

def tab_points(top):
    """(point, radius) pairs from the ramp's end to where the tab top meets
    the arm top: one explicit half-circle (the ramp runs tangent into it),
    then the tab top parallel to the ramp at constant thickness."""
    A, d, n = tab_frame(top)
    w = P["tab_t"]
    c = A + n * (w / 2)
    k = 12
    arc = [c + (-n * math.cos(math.pi * j / k) + d * math.sin(math.pi * j / k)) * (w / 2)
           for j in range(k + 1)]
    B = arc[-1]
    s_arm = top + P["arm_t"]
    J = B - d * ((B.x - s_arm) / d.x)                # tab top meets arm top
    return [(L(p.x, p.y), 0) for p in arc] + [(L(J.x, J.y), 1.0)]

def retain_s():
    """s of the hook's retaining corner: nose_ov below the seated display's
    top edge (the display bottom sits at s = -C)."""
    return H - C - P["nose_ov"]

def hook_flat_bearing(dh):
    """mm of the seated display's flat front face (above its own edge round)
    that bears on the hook's flat (90 deg) retaining face, not its round. On the round a forward
    pull can cam the hook open. The round at an acute corner eats
    r / tan(angle/2) of the face, not r."""
    A, d, _ = tab_frame(clip_geometry()["top"])
    ang = math.acos(max(-1.0, min(1.0, d.x)))          # face runs along +s
    # A printed outer corner is never sharper than about half a line width.
    r = max(P["nose_r"], P["line_w"] / 2)
    flat_start = retain_s() + r / math.tan(ang / 2)
    return (H + dh - C - P["disp_edge_r"]) - flat_start

def ramp_end_s():
    """s where the straight ramp ends and the tab's round begins. The display
    corner's path must stay below this."""
    return tab_frame(clip_geometry()["top"])[0].x

def clip_geometry():
    """Named (s, t) stations of the backrest/finger/arm/nose."""
    back_rear = -C - P["back_t"]
    fin_front = back_rear - P["slot_w"]
    return dict(top=H - C + P["top_gap"],         # arm underside
                back_top=H - P["back_gap"],
                back_rear=back_rear,
                fin_front=fin_front,
                fin_rear=fin_front - P["flex_t"],
                root=H - P["flex_len"],
                nose_front=T + C + P["nose_t"])

def tunnel_centre(poly, ry):
    """Lowest, rearmost spot where the tie-rod tunnel keeps `rod_wall` of
    material all round it. Searched, so it follows any profile change."""
    hw = P["rod_w"] / 2 + P["rod_clr"] + P["rod_wall"]
    hh = P["rod_h"] / 2 + P["rod_clr"] + P["rod_wall"]
    ring = [Vector((x, y)) for x in (-hw, 0, hw) for y in (-hh, 0, hh)]
    for zi in range(int(hh * 10), 400):
        z = zi / 10
        for yi in range(int(ry * 10), -200, -5):
            c = Vector((yi / 10, z))
            if all(inside(c + d, poly) for d in ring):
                return c
    raise SystemExit("no room for the tie-rod tunnel")

# ---------------------------------------------------------------- 3D build
def extrude(name, poly, x0, x1):
    """Extrude a (y, z) polygon along X into a closed mesh object."""
    bm = bmesh.new()
    a = [bm.verts.new((x0, p.x, p.y)) for p in poly]
    b = [bm.verts.new((x1, p.x, p.y)) for p in poly]
    bm.faces.new(a); bm.faces.new(list(reversed(b)))
    n = len(poly)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob

def circle(c, r, n=20):
    return [Vector((c.x + r * math.cos(2 * math.pi * i / n),
                    c.y + r * math.sin(2 * math.pi * i / n))) for i in range(n)]

def apply_mods(ob):
    bpy.context.view_layer.objects.active = ob
    for m in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)

def frustum_cutter(name, poly, x0, x1, grow):
    """Prism along X whose ends flare by `grow` (45 deg), so a hole gets the
    same chamfer as the faces it passes through."""
    c = sum(poly, Vector((0, 0))) / len(poly)
    def scaled(k):
        return [c + (p - c).normalized() * ((p - c).length + k) for p in poly]
    rings = [(x0 - 0.01, scaled(grow)), (x0 + grow, scaled(0)),
             (x1 - grow, scaled(0)), (x1 + 0.01, scaled(grow))]
    bm = bmesh.new()
    vs = [[bm.verts.new((x, p.x, p.y)) for p in r] for x, r in rings]
    n = len(poly)
    bm.faces.new(vs[0]); bm.faces.new(list(reversed(vs[-1])))
    for a, b in zip(vs, vs[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(ob)
    return ob

def subtract(ob, cutter):
    m = ob.modifiers.new(cutter.name, "BOOLEAN")
    m.object, m.operation, m.solver = cutter, "DIFFERENCE", "EXACT"
    apply_mods(ob)
    bpy.data.objects.remove(cutter)

def rib_height():
    return P["rod_clr"] + P["rod_rib"]

def tunnel_outline(tc):
    """Tunnel section with two opposed trapezoid crush ribs on its side
    walls. Gravity can't open a gap at either: the rod is pinched across its
    8 mm width, centred, by 2 x rod_rib."""
    w = P["rod_w"] + 2 * P["rod_clr"]
    h = P["rod_h"] + 2 * P["rod_clr"]
    # Trapezoid ribs: 2 mm base, 0.5 mm flat crest. A crest the slicer can
    # print, yet narrow enough to yield rather than shave when the rod goes in.
    r, b, c = rib_height(), 1.0, 0.25
    return [tc + Vector(v) for v in ((-w / 2, -h / 2), (w / 2, -h / 2),
                                     (w / 2, -b), (w / 2 - r, -c), (w / 2 - r, c), (w / 2, b),
                                     (w / 2, h / 2), (-w / 2, h / 2),
                                     (-w / 2, b), (-w / 2 + r, c), (-w / 2 + r, -c), (-w / 2, -b))]

def rect(c, w, h):
    return [c + Vector(v) for v in ((-w / 2, -h / 2), (w / 2, -h / 2),
                                    (w / 2, h / 2), (-w / 2, h / 2))]

def make_part(name, width):
    poly, reliefs, ry = profile()
    # No chamfer on the two flat faces: a 0.6 mm one would thin the 1.8/1.6 mm
    # spring and the 1.15 mm lip land right at the faces. The slicer's
    # elephant-foot compensation handles the first layer; only the tunnel
    # mouths are chamfered (below).
    ob = extrude(name, poly, -width / 2, width / 2)
    x0, x1 = -width / 2, width / 2
    # Dog-bone reliefs: printed inside corners round off, the display's don't.
    d = P["relief_r"] * 0.55
    for k, rc in enumerate(reliefs):
        dirn = (-U + (N if k == 0 else -N)).normalized()
        subtract(ob, extrude(f"{name}_relief{k}", circle(rc + dirn * d, P["relief_r"]),
                             x0 - 1, x1 + 1))
    # Tie-rod tunnel, chamfered at both mouths.
    tc = tunnel_centre(poly, ry)
    subtract(ob, frustum_cutter(f"{name}_tunnel", tunnel_outline(tc), x0, x1,
                                P["tunnel_chamfer"]))
    # Pad pockets in the base.
    toe = on_desk(T + C + P["lip_t"]).x
    for k, y in enumerate((toe + P["pad_inset"], ry - P["pad_inset"])):
        bpy.ops.mesh.primitive_cylinder_add(radius=P["pad_d"] / 2,
                                            depth=2 * P["pad_depth"],
                                            location=(0, y, 0), vertices=48)
        cut = bpy.context.object; cut.name = f"{name}_pad{k}"
        subtract(ob, cut)
    # Identification notches in the tail end face (fit-test feet).
    n = int(P["id_notches"])
    for k in range(n):
        bpy.ops.mesh.primitive_cube_add(size=1, location=((k - (n - 1) / 2) * 3.0, ry, 1.0))
        cut = bpy.context.object; cut.name = f"{name}_id{k}"
        cut.scale = (1.0, 2.0, 4.0)      # z -1..3: never coplanar with the base
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        subtract(ob, cut)
    # A relief circle can cross a profile edge a few microns from one of its
    # vertices; the boolean then leaves a near-duplicate vertex and a sliver.
    bm = bmesh.new(); bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.002)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=0.002)
    bm.to_mesh(ob.data); bm.free()
    ob["tunnel_yz"] = (tc.x, tc.y)
    return ob

def make_rod(tc):
    """Tie rod spanning both feet, with end chamfers and engraved alignment
    marks at each foot's inner face."""
    xs = P["disp_w"] / 2 - P["foot_inset"]
    # Overhang shrinks before the rod outgrows the bed (wide-foot variants).
    over = min(P["rod_overhang"], (BED - 10) / 2 - xs - P["foot_w"] / 2)
    half = xs + P["foot_w"] / 2 + max(over, 0.0)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, tc[0], tc[1]))
    rod = bpy.context.object; rod.name = "tie_rod"
    rod.scale = (2 * half, P["rod_w"] + P["rod_fit"], P["rod_h"])
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bev = rod.modifiers.new("b", "BEVEL"); bev.width, bev.segments = 0.6, 1
    apply_mods(rod)
    for k, x in enumerate((-(xs - P["foot_w"] / 2), xs - P["foot_w"] / 2)):
        bpy.ops.mesh.primitive_cube_add(size=1, location=(x, tc[0], tc[1] + P["rod_h"] / 2))
        m = bpy.context.object; m.name = f"mark{k}"
        m.scale = (0.6, P["rod_w"] + 2, 0.8)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        subtract(rod, m)
    return rod

GAUGE_STEPS = (0.1, 0.2, 0.3, 0.4, 0.5)   # extra rod width per stub, mm

def make_gauge_stub(k, extra, length=30.0):
    """Short rod stub `extra` wider than the current rod, for a fit test in
    printed feet. Stub k carries k+1 notches across its top at one end."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0))
    st = bpy.context.object; st.name = f"gauge_{k + 1}"
    st.scale = (length, P["rod_w"] + P["rod_fit"] + extra, P["rod_h"])
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bev = st.modifiers.new("b", "BEVEL"); bev.width, bev.segments = 0.6, 1
    apply_mods(st)
    for n in range(k + 1):
        bpy.ops.mesh.primitive_cube_add(size=1, location=(length / 2 - 3 - 1.6 * n, 0, P["rod_h"] / 2))
        m = bpy.context.object; m.name = f"notch{k}_{n}"
        m.scale = (0.6, P["rod_w"] + 2, 0.8)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        subtract(st, m)
    return st

def feet():
    """Both feet in use position."""
    W = P["disp_w"]
    out = []
    for side in (-1, 1):
        ob = make_part(f"foot_{'L' if side < 0 else 'R'}", P["foot_w"])
        ob.location.x = side * (W / 2 - P["foot_inset"])
        out.append(ob)
    return out

# ---------------------------------------------------------------- display mock
def mat(name, rgb, rough=0.5, emit=None, alpha=1.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1)
        b.inputs["Emission Strength"].default_value = 1.0
    if alpha < 1:
        b.inputs["Alpha"].default_value = alpha
        m.surface_render_method = "DITHERED"
    return m

def box(name, size, loc, rot_x=0.0, material=None, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1)
    ob = bpy.context.object; ob.name = name
    ob.scale = size; ob.location = loc; ob.rotation_euler = (rot_x, 0, 0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        m = ob.modifiers.new("b", "BEVEL"); m.width, m.segments = bevel, 3
    if material: ob.data.materials.append(material)
    return ob

def display_mock(mats):
    """Display resting in the slot: on the floor (s=-C), against the back (t=-C)."""
    W = P["disp_w"]
    def at(s, t, x=0.0):
        p = L(s - C, t - C); return Vector((x, p.x, p.y))
    obs = [box("display", (W, H, T), at(H / 2, T / 2), TH, mats["bezel"],
               P["disp_edge_r"])]
    bz = P["bezel"]
    obs.append(box("screen", (W - 2 * bz, H - 2 * bz, 0.2), at(H / 2, T + 0.05),
                   TH, mats["screen"]))
    # USB-C on the right short side, centred: receptacle, plug, cable stub.
    xe = W / 2
    obs.append(box("usbc_port", (0.4, 8.9, 3.2), at(H / 2, T / 2, xe + 0.1), TH,
                   mats["port"]))
    obs.append(box("usbc_plug", (22, 12.0, 6.5), at(H / 2, T / 2, xe + 11.2), TH,
                   mats["plug"], 1.5))
    bpy.ops.mesh.primitive_cylinder_add(radius=2.0, depth=40,
                                        location=at(H / 2, T / 2, xe + 42))
    cab = bpy.context.object; cab.name = "usbc_cable"
    cab.rotation_euler = (0, math.pi / 2, 0); cab.data.materials.append(mats["plug"])
    obs.append(cab)
    return obs

def insertion_ghost(phi_deg, mats, alpha):
    """Translucent display at an insertion tilt (seated when phi = 0)."""
    phi = math.radians(phi_deg)
    s0, t0 = -C, T + C
    sc, tc = -C + H / 2, C + T / 2
    cs, sn = math.cos(phi), math.sin(phi)
    s1 = s0 + (sc - s0) * cs - (tc - t0) * sn
    t1 = t0 + (sc - s0) * sn + (tc - t0) * cs
    if phi_deg == 0:
        t1 -= 2 * C                          # pushed home against the backrest
    p = L(s1, t1)
    m = mat(f"ghost{phi_deg}", (0.05, 0.12, 0.30), 0.3, alpha=alpha)
    return box(f"ghost{phi_deg}", (P["disp_w"], H, T), (0, p.x, p.y), TH + phi, m, P["disp_edge_r"])

# ---------------------------------------------------------------- analysis
def tri_mesh(ob):
    """(vertices, triangles) of a mesh; the concave side caps are n-gons, so
    triangulate with bmesh rather than fanning."""
    bm = bmesh.new(); bm.from_mesh(ob.data)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    v = [tuple(x.co) for x in bm.verts]
    bm.verts.index_update()
    t = [tuple(x.index for x in f.verts) for f in bm.faces]
    bm.free()
    return v, t

def mesh_health(ob):
    """Watertightness the slicer cares about, on the triangles it will see:
    every edge shared by exactly two faces, no sliver triangles."""
    bm = bmesh.new(); bm.from_mesh(ob.data)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bad_edges = sum(1 for e in bm.edges if len(e.link_faces) != 2)
    degenerate = sum(1 for f in bm.faces if f.calc_area() < 1e-6)
    bm.free()
    return dict(non_manifold_edges=bad_edges, degenerate_faces=degenerate)

def print_estimate(ob, height):
    """Estimate for the PRINTING.md settings (A1 mini, 0.4 nozzle, 0.20 mm,
    4 walls, 5/4 shells, 15% gyroid). Bambu Studio 02.02.00.85's CLI segfaulted on
    macOS during development, so this stands in until the part is sliced in the GUI; expect +/-20%.

    Walls = side area x 4 x 0.44 mm; shells = cap area x 1.8 mm (9 layers);
    the rest is 15% infill. Effective flow including accel limits, travel and
    retraction on this small, detailed part: walls 8, shells 11, infill
    15 mm^3/s, plus 2 s per layer."""
    bm = bmesh.new(); bm.from_mesh(ob.data)
    vol = bm.calc_volume(signed=False)
    cap = sum(f.calc_area() for f in bm.faces if abs(f.normal.z) > 0.99)
    side = sum(f.calc_area() for f in bm.faces if abs(f.normal.z) <= 0.99)
    bm.free()
    walls = min(vol, side * 4 * 0.44)
    shells = min(vol - walls, cap / 2 * 1.8)
    infill = max(0.0, vol - walls - shells) * 0.15
    grams = (walls + shells + infill) / 1000 * 1.24
    secs = walls / 8 + shells / 11 + infill / 15 + height / 0.2 * 2
    return round(grams, 1), round(secs / 60)

def to_st(p):
    """World (y, z) -> display frame (s, t)."""
    d = p - ORIGIN
    return Vector((d.dot(U), d.dot(N)))

def inside(pt, poly):
    """Even-odd point-in-polygon."""
    x, y, ins = pt.x, pt.y, False
    for i in range(len(poly)):
        a, b = poly[i - 1], poly[i]
        if (a.y > y) != (b.y > y):
            if x < a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y):
                ins = not ins
    return ins

def display_pose(phi, dh=0.0, step=0.2):
    """Display outline (s, t) tilted forward by `phi` about its bottom-front
    edge, which sits in the floor/lip corner. phi=0 is seated; dh makes the
    display that much taller than nominal (measurement tolerance)."""
    s0, t0 = -C, T + C
    e = 0.02          # inset so faces resting on walls don't count as hits
    hd = H + dh
    c4 = [(-C + e, T + C - e), (hd - C - e, T + C - e), (hd - C - e, C + e), (-C + e, C + e)]
    rect = []
    for k in range(4):
        a, b = c4[k], c4[(k + 1) % 4]
        n = int(max(abs(b[0] - a[0]), abs(b[1] - a[1])) / step) + 1
        for j in range(n):
            f = j / n
            rect.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
    cs, sn = math.cos(phi), math.sin(phi)
    return [Vector((s0 + (s - s0) * cs - (t - t0) * sn,
                    t0 + (s - s0) * sn + (t - t0) * cs)) for s, t in rect]

def exit_edge(p, poly):
    """Nearest profile edge directly below p (in -s): returns (s, tangent)."""
    best = None
    for i in range(len(poly)):
        a, b = poly[i - 1], poly[i]
        if (a.y > p.y) != (b.y > p.y):
            sx = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
            if sx <= p.x and (best is None or sx > best[0]):
                best = (sx, (b - a).normalized())
    return best

def beam_path():
    """Centreline of the spring, root to nose, as (point, thickness) samples."""
    g = clip_geometry()
    tc = (g["fin_front"] + g["fin_rear"]) / 2
    sa = g["top"] + P["arm_t"] / 2
    path = []
    n1 = 120
    for i in range(n1):
        path.append((Vector((g["root"] + (sa - g["root"]) * i / n1, tc)), P["flex_t"]))
    n2 = 120
    tn = T + C + P["nose_t"] / 2
    for i in range(n2 + 1):
        path.append((Vector((sa, tc + (tn - tc) * i / n2)), P["arm_t"]))
    return path

def kt_fillet(r, h):
    """Bending stress concentration at a fillet of radius r on a section of
    thickness h. Power-law fit to Peterson's shoulder-fillet chart for
    bending at large D/d: 1.45 at r/h = 0.3, 1.36 at 0.44, 1.9 at 0.1."""
    return 1 + 0.22 * (r / h) ** -0.6

def slot_floor_r():
    """Radius the slot floor's full round actually gets: fillet() caps each
    tangent length at 0.45 of the slot width, so it falls short of slot_w/2."""
    return min(P["slot_w"] / 2 - 0.01, 0.45 * P["slot_w"])

def root_kts():
    """(finger-root Kt, arm-root Kt): the worse face of each, since the
    insertion force both lifts and pushes back, loading either face."""
    fin = max(kt_fillet(slot_floor_r(), P["flex_t"]), kt_fillet(3.0, P["flex_t"]))
    arm = max(kt_fillet(1.0, P["arm_t"]), kt_fillet(1.5, P["arm_t"]))
    return fin, arm

def beam_response(Q, Fdir, R, d):
    """Unit-load method on the spring centreline (Euler-Bernoulli, bending
    only). For a unit force along Fdir at Q: displacement of R along d, and
    the peak bending strain per newton, with Kt applied within 1.5 mm of the
    finger and arm roots."""
    E, b = P["pla_E"], P["foot_w"]
    path = beam_path()
    g = clip_geometry()
    kf, ka = root_kts()
    sa = path[-1][0].x
    disp, peak = 0.0, 0.0
    cross = lambda a, f: a.x * f.y - a.y * f.x
    arm_s = path[-1][0].x
    for (p0, h), (p1, _) in zip(path, path[1:]):
        x = (p0 + p1) / 2
        ds = (p1 - p0).length
        if abs(x.x - arm_s) < 1e-6 and x.y > Q.y:
            break                    # past a load applied under the arm
        I = b * h ** 3 / 12
        M = cross(Q - x, Fdir)
        disp += M * cross(R - x, d) / (E * I) * ds
        on_arm = abs(x.x - sa) < 1e-6
        if not on_arm and x.x - g["root"] < 1.5:
            kt = kf
        elif on_arm and x.y - path[0][0].y < 1.5 + P["flex_t"] / 2:
            kt = ka
        else:
            kt = 1.0
        peak = max(peak, abs(M) * (h / 2) / (E * I) * kt)
    return disp, peak * 100

def nearest_edge(p, poly):
    """Tangent of the profile edge closest to p."""
    best, tan = 1e9, None
    for i in range(len(poly)):
        a, b = poly[i - 1], poly[i]
        ab = b - a
        f = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
        dist = (a + ab * f - p).length
        if dist < best:
            best, tan = dist, ab.normalized()
    return tan

def sweep(poly, dh):
    """One insertion sweep for a display dh taller than nominal."""
    g = clip_geometry()
    rigid_top = g["back_top"] + 0.5
    states, open_phi, rigid_phi, last_hit = [], None, None, None
    for k in range(0, 161):
        deg = k * 0.25
        hits = [p for p in display_pose(math.radians(deg), dh) if inside(p, poly)]
        flex = [p for p in hits if p.x > rigid_top]
        if open_phi is None and states and not flex:
            open_phi = deg               # top is now fully in front of the clip
        if rigid_phi is None and any(p.x <= rigid_top for p in hits):
            rigid_phi = deg              # tilt at which the rigid lip blocks
        pts = []
        for p in flex:
            ex = exit_edge(p, poly)
            if ex:
                pts.append((p, ex[1], deg, p.x - ex[0]))
        if pts:
            states.append(pts); last_hit = deg
    # First touch: bisect between the last hitting step and the next one.
    first = None
    if last_hit is not None:
        lo, hi = last_hit, last_hit + 0.25
        for _ in range(16):
            mid = (lo + hi) / 2
            fl = [p for p in display_pose(math.radians(mid), dh, 0.05)
                  if inside(p, poly) and p.x > rigid_top]
            lo, hi = (mid, hi) if fl else (lo, mid)
        fl = [p for p in display_pose(math.radians(lo), dh, 0.05)
              if inside(p, poly) and p.x > rigid_top]
        p = fl[0]
        first = (p, nearest_edge(p, poly), lo)
    # Highest point the display's top-back corner reaches on its way past
    # the clip: the tab tip must stay well above it.
    s0, t0 = -C, T + C
    cs_, ct_ = H + dh - C - s0, C - t0
    corner_s = max(s0 + cs_ * math.cos(math.radians(d / 4)) - ct_ * math.sin(math.radians(d / 4))
                   for d in range(0, int((open_phi or 20) * 4) + 1))
    return states, first, open_phi, rigid_phi, corner_s

def contact(state, dh):
    """Force direction on the clip (ramp normal + friction) and the contact
    angle: inward surface normal vs the display corner's velocity. 0 deg is
    head-on (a wall), 90 deg is grazing."""
    p, tan, deg = state[:3]
    n_in = Vector((tan.y, -tan.x))                   # normal into the clip
    if n_in.x < 0:
        n_in = -n_in                                 # clip is above (+s)
    a = display_pose(math.radians(deg), dh, 0.05)
    b = display_pose(math.radians(deg - 0.05), dh, 0.05)
    i = min(range(len(a)), key=lambda j: (a[j] - p).length)
    v = (b[i] - a[i]).normalized()
    approaching = n_in.dot(v) > 0       # else the point is leaving the surface
    if not approaching:
        n_in = -n_in                                 # facing the incoming corner
    f = (n_in + tan * (P["mu"] * (1 if v.dot(tan) > 0 else -1))).normalized()
    return f, math.degrees(math.acos(max(-1, min(1, n_in.dot(v))))), approaching

def snap_analysis():
    """Sweep the display through its insertion arc and size the snap.

    Insertion: bottom edge in the channel, top tilted forward, rotate back
    about the bottom-front edge, in 0.25 deg steps. A display point inside
    the profile below the rigid backrest top is a hard collision (only the
    drafted lip can cause one). Above it, the point is in the spring; its
    depth above the surface beneath it is the lift the nose must make at
    that instant. Every instant is sized: force along the ramp normal plus
    friction, unit-load method on the real finger/arm path, Kt from the real
    root radii. The worst instant governs. First touch is found by bisection
    and must meet the ramp, not a wall. All of it is repeated for displays
    disp_h_tol shorter and taller than nominal; the worst case is reported."""
    poly = [to_st(p) for p in profile()[0]]
    R = Vector((retain_s(), T + C))                 # retaining corner
    out = dict(cases={})
    tol = P["disp_h_tol"]
    for dh in (-tol, 0.0, tol):
        states, first, open_phi, rigid_phi, corner_s = sweep(poly, dh)
        case = dict(insert_tilt_deg=open_phi, lip_blocks_at_deg=rigid_phi,
                    insert_margin_deg=(rigid_phi or 40.0) - (open_phi or 40.0),
                    clip_lift_mm=round(max((st[3] for pts in states for st in pts), default=0), 2))
        worst = (0, 0, 0)
        for st in (st for pts in states for st in pts):
            f, _, approaching = contact(st, dh)
            if not approaching:
                continue                 # behind a fillet, moving away: no load
            per_N, strain_per_N = beam_response(st[0], f, R, Vector((1, 0)))
            back_per_N, _ = beam_response(st[0], f, R, Vector((0, -1)))
            F = st[3] / per_N
            if F * strain_per_N > worst[1]:
                worst = (F, F * strain_per_N, F * back_per_N)
        case.update(clip_force_N=round(worst[0], 1), peak_strain_pct=round(worst[1], 2),
                    nose_backshift_mm=round(worst[2], 2),
                    first_contact_angle_deg=round(contact(first, dh)[1], 1) if first else None)
        seated = [Vector((p.x, p.y - 2 * C)) for p in display_pose(0.0, dh)]
        case["seated_clear"] = not any(inside(p, poly) for p in seated)
        case["tab_clearance_mm"] = round(ramp_end_s() - corner_s, 2)
        out["cases"][f"{dh:+.1f}"] = case
    # Beyond the band: a display taller than disp_h_tol must still meet the
    # ramp at a sliding angle, not lock on the tab end.
    first = sweep(poly, tol + 0.5)[1]
    out["overshoot_first_contact_deg"] = round(contact(first, tol + 0.5)[1], 1) if first else None
    cs = out["cases"].values()
    nom = out["cases"]["+0.0"]
    out.update(
        nominal=nom,
        worst=dict(
            clip_force_N=max(c["clip_force_N"] for c in cs),
            peak_strain_pct=max(c["peak_strain_pct"] for c in cs),
            first_contact_angle_deg=min(c["first_contact_angle_deg"] or 0 for c in cs),
            insert_margin_deg=min(c["insert_margin_deg"] for c in cs),
            seated_clear=all(c["seated_clear"] for c in cs),
            tab_clearance_mm=min(c["tab_clearance_mm"] for c in cs)),
        kt_roots=[round(k, 2) for k in root_kts()])
    return out

def backrest_compliance():
    """mm of give per N pressed at the rigid backrest's top (cantilever from
    the slot floor). The display leans on this face."""
    g = clip_geometry()
    Lb = g["back_top"] - g["root"]
    I = P["foot_w"] * P["back_t"] ** 3 / 12
    return Lb ** 3 / (3 * P["pla_E"] * I)

def tip_pivot(ry):
    """Rear tipping point: the rear pad's centre. A domed bump-on bears near
    its middle, so the pad's outer edge would overstate stability."""
    return ry - P["pad_inset"]

def tip_moments(pivot_y):
    """(restoring N*mm from the display's weight, tipping N*mm per N pressed
    into the screen's top edge) about a rear pivot at y = pivot_y."""
    m_d = P["disp_mass_g"] / 1000
    cg = L(H / 2 - C, T / 2 - C)
    p = L(H - C, T - C)
    f = Vector((math.sin(TH), -math.cos(TH)))        # into the screen
    r = p - Vector((pivot_y, 0))
    return m_d * 9.81 * (pivot_y - cg.x), -(r.x * f.y - r.y * f.x)

def tail_for_tip(force):
    """Shortest tail whose tip-back force reaches `force`. Both moments are
    linear in the pivot position, so solve it directly."""
    r0, t0 = tip_moments(0.0)
    r1, t1 = tip_moments(1.0)
    # force * (t0 + (t1 - t0) y) = r0 + (r1 - r0) y
    y = (r0 - force * t0) / (force * (t1 - t0) - (r1 - r0))
    return y + P["pad_inset"]

def tip_force():
    """Force (N) pressed into the screen's top edge that tips the stand back
    about the rear pad. Ignores stand mass for a conservative number."""
    restoring, tipping = tip_moments(tip_pivot(profile()[2]))
    return restoring / tipping if tipping > 0 else float("inf")

# ---------------------------------------------------------------- export
def export_stl(ob, path, print_rot):
    """Export a copy of `ob` in print orientation, resting on z=0, centred."""
    dup = ob.copy(); dup.data = ob.data.copy()
    bpy.context.collection.objects.link(dup)
    dup.location = (0, 0, 0); dup.rotation_euler = print_rot
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    dup.select_set(True); bpy.context.view_layer.objects.active = dup
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    vs = [v.co for v in dup.data.vertices]
    mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
    mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
    ctr = (mn + mx) / 2
    dup.data.transform(Matrix.Translation((-ctr.x, -ctr.y, -mn.z)))
    bpy.ops.wm.stl_export(filepath=path, export_selected_objects=True,
                          apply_modifiers=True)
    size = mx - mn
    return dup, (round(size.x, 1), round(size.y, 1), round(size.z, 1))

# Print orientation: the foot lies on a side face (profile flat, no
# overhangs), so the spring bends within the layers. World +X goes to -Z, so
# the right-hand foot's outer face is the one on the bed.
PRINT_ROT = (0, math.pi / 2, 0)

# ---------------------------------------------------------------- render
def setup_scene():
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.resolution_x, sc.render.resolution_y = 1600, 1000
    sc.eevee.taa_render_samples = 48
    w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.57, 0.60, 1)
    w.node_tree.nodes["Background"].inputs[1].default_value = 0.6
    for rot, e in (((math.radians(50), 0, math.radians(-35)), 3.5),
                   ((math.radians(70), 0, math.radians(150)), 1.2)):
        ld = bpy.data.lights.new("sun", "SUN"); ld.energy = e; ld.angle = 0.25
        lo = bpy.data.objects.new("sun", ld); lo.rotation_euler = rot
        sc.collection.objects.link(lo)
    return sc

def look(cam, target):
    d = Vector(target) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()

def camera(loc, target, lens=50, ortho=None):
    cd = bpy.data.cameras.new("cam"); cd.lens = lens; cd.clip_end = 5000
    if ortho:
        cd.type = "ORTHO"; cd.ortho_scale = ortho
    co = bpy.data.objects.new("cam", cd); bpy.context.scene.collection.objects.link(co)
    co.location = loc; look(co, target); bpy.context.scene.camera = co
    return co

def render(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)

def ground(mats, size=2000, z=0.0, m="ground"):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, z))
    g = bpy.context.object; g.data.materials.append(mats[m]); return g

# ---------------------------------------------------------------- checks
def design_checks(rep):
    """Design rules the part must meet. Any failure fails the build."""
    sn, mh, lw = rep["snap"]["worst"], rep["mesh"], P["line_w"]
    tf = T + C + P["lip_t"]
    land = tf - P["lip_chamfer"] - (T + C + (P["lip_h"] + C) *
                                    math.tan(math.radians(P["lip_draft"])))
    tol = f'(display height +/-{P["disp_h_tol"]} mm)'
    return {
        "tip-back force >= min_tip_N": rep["tip_force_N"] >= P["min_tip_N"],
        f"display seats with no interference {tol}": sn["seated_clear"],
        f"insertion tilt margin >= 4 deg before the lip blocks {tol}": sn["insert_margin_deg"] >= 4,
        f"first clip contact >= 40 deg off head-on {tol}": sn["first_contact_angle_deg"] >= 40,
        f"peak snap strain <= pla_strain_max over the sweep {tol}":
            sn["peak_strain_pct"] <= P["pla_strain_max"],
        "lip stays on the bezel (1 mm margin)": P["lip_h"] <= P["bezel"] - 1,
        "nose stays on the bezel (1 mm margin)": P["nose_ov"] <= P["bezel"] - 1,
        # Flat on flat: the display's flat face (past disp_edge_r) against the
        # hook's flat face (past its round). 0.3 mm is ~0.75 line widths, more
        # than the hook's printed position error.
        "display flat face bears >= 0.75 mm on the hook's flat face (nominal)":
            hook_flat_bearing(0.0) >= 0.75,
        f"display flat face bears >= 0.3 mm on the hook's flat face {tol}":
            hook_flat_bearing(-P["disp_h_tol"]) >= 0.3,
        "backrest gives <= 0.03 mm/N": rep["backrest_mm_per_N"] <= 0.03,
        "spring + lip features >= 2 line widths": min(P["arm_t"], P["flex_t"], P["lip_t"]) >= 2 * lw,
        "lip top land >= 2 line widths": land >= 2 * lw,
        "ramp end >= 1.0 mm above the display corner's path (nominal)":
            rep["snap"]["nominal"]["tab_clearance_mm"] >= 1.0,
        f"ramp end >= 0.5 mm above the corner's path {tol}": sn["tab_clearance_mm"] >= 0.5,
        f"display {P['disp_h_tol'] + 0.5} mm taller than nominal still meets the ramp at >= 30 deg":
            (rep["snap"]["overshoot_first_contact_deg"] or 0) >= 30,
        "rod gripped: free gap between the crush ribs <= -0.1 mm":
            (P["rod_w"] + 2 * P["rod_clr"] - 2 * rib_height()) - P["rod_w"] <= -0.1,
        "slot >= 2 line widths": P["slot_w"] >= 2 * lw,
        "every round >= 0.3 mm gets >= 90% of its radius": all(
            got >= 0.9 * req for req, got in rep["fillets"] if req >= 0.3),
        "watertight mesh": mh["non_manifold_edges"] == 0 and mh["degenerate_faces"] == 0,
        "plate layout fits the A1 mini bed": rep["plate_fits"],
    }

# ---------------------------------------------------------------- plate
BED = 180.0

def plate_layout(foot_size, rod_size, gap=8.0):
    """Placements on the A1 mini plate (bed coordinates, part centres): the
    rod along the front, both feet behind it. The second foot is turned
    over so that both feet show their textured-PEI face on the outside."""
    fx, fy, fz = foot_size
    rx, ry_, _ = rod_size
    y_rod = 6 + ry_ / 2
    y_feet = 6 + ry_ + gap + fy / 2
    dx = fx / 2 + gap / 2
    items = [("rod", (1, 0, 0, 0, 1, 0, 0, 0, 1, BED / 2, y_rod, 0)),
             ("foot", (1, 0, 0, 0, 1, 0, 0, 0, 1, BED / 2 + dx, y_feet, 0)),
             ("foot", (-1, 0, 0, 0, 1, 0, 0, 0, -1, BED / 2 - dx, y_feet, fz))]
    fits = (2 * fx + gap <= BED - 10 and rx <= BED - 10
            and 6 + ry_ + gap + fy <= BED - 5)
    return items, fits

# ---------------------------------------------------------------- main
def main():
    o = OPTS
    out = os.path.abspath(o["out"]); os.makedirs(out, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    setup_scene()
    mats = dict(
        pla=mat("pla", (0.09, 0.09, 0.095), 0.5),
        bezel=mat("bezel", (0.015, 0.015, 0.017), 0.25),
        screen=mat("screen", (0.01, 0.02, 0.04), 0.08, emit=(0.02, 0.06, 0.14)),
        port=mat("port", (0.0, 0.0, 0.0), 0.5),
        plug=mat("plug", (0.05, 0.05, 0.055), 0.4),
        ground=mat("ground", (0.62, 0.62, 0.63), 0.75),
        plate=mat("plate", (0.16, 0.16, 0.17), 0.6),
        ghost=mat("ghost", (0.05, 0.12, 0.30), 0.3, alpha=0.55),
    )
    parts = feet()
    rod = make_rod(parts[0]["tunnel_yz"])
    for p in parts + [rod]:
        p.data.materials.clear()        # booleans leave an empty slot 0
        p.data.materials.append(mats["pla"])

    # Analysis and report.
    rep = dict(params=P)
    rep["tip_force_N"] = round(tip_force(), 2)
    rep["backrest_mm_per_N"] = round(backrest_compliance(), 4)
    rep["snap"] = snap_analysis()
    poly, _, ry = profile()
    rep["footprint_depth_mm"] = round(ry - min(p.x for p in poly), 1)
    rep["height_mm"] = round(max(p.y for p in poly), 1)
    rep["fillets"] = [(round(a, 3), round(b, 3)) for a, b in FILLET_LOG]

    foot_p, foot_size = export_stl(parts[0], os.path.join(out, "foot.stl"), PRINT_ROT)
    rod_p, rod_size = export_stl(rod, os.path.join(out, "tie_rod.stl"), (0, 0, 0))
    rep["mesh"] = {k: mesh_health(foot_p)[k] + mesh_health(rod_p)[k]
                   for k in ("non_manifold_edges", "degenerate_faces")}
    gf, mf = print_estimate(foot_p, foot_size[2])
    gr, mr = print_estimate(rod_p, rod_size[2])
    rep["print"] = dict(foot_bbox_mm=foot_size, rod_bbox_mm=rod_size,
                        est_grams_total=round(2 * gf + gr, 1),
                        est_minutes_total=2 * mf + mr)
    items, rep["plate_fits"] = plate_layout(foot_size, rod_size)
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
    import make_3mf
    names = ["foot", "rod"]
    meshes = [("snap_foot", *tri_mesh(foot_p)), ("tie_rod", *tri_mesh(rod_p))]
    item_list = [(names.index(n), m) for n, m in items]
    make_3mf.write_3mf(os.path.join(out, "stand_generic.3mf"), meshes, item_list)
    rep["checks"] = design_checks(rep)
    rep["PASS"] = all(rep["checks"].values())
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(rep, f, indent=1)
    print("REPORT", json.dumps({k: v for k, v in rep.items() if k not in ("params", "checks")}))
    for k, ok in rep["checks"].items():
        print("CHECK", "ok  " if ok else "FAIL", k)
    if o["renders"] != "0":
        render_all(out, mats, parts, rod, foot_p, rod_p, items, rep)
    root = os.path.dirname(os.path.abspath(__file__))
    settings = make_3mf.bambu_settings(os.path.join(root, "profiles", "bambu_project_settings.json"),
                                       os.path.join(root, "profiles", "process.json"), BAMBU_SETTINGS)
    make_3mf.write_bambu_3mf(os.path.join(out, "stand_A1mini.3mf"), meshes, item_list, settings,
                             plate_thumbnail(os.path.join(out, "5_print_bed.png")))
    write_gauge(out, make_3mf, settings)
    if not rep["PASS"]:
        sys.exit(1)

def write_gauge(out, make_3mf, settings):
    """out/rod_gauge.3mf: one stub per GAUGE_STEPS entry, side by side on the
    plate, with the same embedded settings as the stand."""
    tmp = tempfile.mkdtemp()
    meshes, items = [], []
    for k, extra in enumerate(GAUGE_STEPS):
        st = make_gauge_stub(k, extra)
        dup, size = export_stl(st, os.path.join(tmp, f"g{k}.stl"), (0, 0, 0))
        meshes.append((f"rod_gauge_+{extra:.1f}mm", *tri_mesh(dup)))
        y = BED / 2 + (k - (len(GAUGE_STEPS) - 1) / 2) * (size[1] + 6)
        items.append((k, (1, 0, 0, 0, 1, 0, 0, 0, 1, BED / 2, y, 0)))
    make_3mf.write_bambu_3mf(os.path.join(out, "rod_gauge.3mf"), meshes, items, settings)

def plate_thumbnail(path, size=512):
    """PNG bytes of the print-bed render, centre-cropped square, or None."""
    if not os.path.exists(path):
        return None
    import numpy as np
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
    x0 = (w - h) // 2
    sq = bpy.data.images.new("thumb", h, h, alpha=True)
    sq.pixels = px[:, x0:x0 + h].ravel().tolist()
    sq.scale(size, size)
    out = path + ".thumb.png"
    sq.filepath_raw, sq.file_format = out, "PNG"
    sq.save()
    data = open(out, "rb").read(); os.remove(out)
    return data

def render_all(out, mats, parts, rod, foot_p, rod_p, items, rep):
    foot_p.hide_render = rod_p.hide_render = True
    disp = display_mock(mats)
    g = ground(mats)
    tgt = (0, 25, 30)
    camera((260, -330, 210), tgt, 55); render(os.path.join(out, "1_hero.png"))
    camera((-300, 330, 230), tgt, 55); render(os.path.join(out, "2_rear.png"))
    # README shot: raised front-left 3/4, so a foot's profile, its clip and
    # the screen all read in one image.
    camera((-340, -150, 175), (-15, 30, 30), 52)
    render(os.path.join(out, "8_readme.png"))
    # Profile: ghost the display so the section reads.
    disp[0].data.materials[0] = mats["ghost"]
    for ob in disp[1:]:
        ob.hide_render = True
    camera((600, 33, 38), (0, 33, 38), ortho=150)
    render(os.path.join(out, "3_profile.png"))
    disp[0].data.materials[0] = mats["bezel"]
    for ob in disp[1:]:
        ob.hide_render = False
    camera((235, -120, 90), (130, 10, 30), 60)
    render(os.path.join(out, "4_usbc_end.png"))
    fx = parts[1].location.x
    camera((fx + 90, -110, 150), (fx, 18, 60), 60)
    render(os.path.join(out, "6_clip_detail.png"))
    # Insertion sequence, same pivot as snap_analysis().
    for ob in disp:
        ob.hide_render = True
    ghosts = [insertion_ghost(phi, mats, a) for phi, a in
              ((rep["snap"]["nominal"]["insert_tilt_deg"], 0.18), (8.0, 0.28), (0.0, 0.65))]
    camera((600, 33, 40), (0, 33, 40), ortho=150)
    render(os.path.join(out, "7_insertion.png"))
    for gh in ghosts:
        bpy.data.objects.remove(gh)
    # Print plate, laid out exactly as in the 3MF.
    for ob in disp + parts + [rod, g]:
        ob.hide_render = True
    bpy.ops.mesh.primitive_plane_add(size=BED, location=(BED / 2, BED / 2, -0.01))
    bpy.context.object.data.materials.append(mats["plate"])
    src = {"foot": foot_p, "rod": rod_p}
    for n, m in items:
        ob = src[n].copy(); bpy.context.collection.objects.link(ob)
        ob.hide_render = False
        ob.matrix_world = Matrix(((m[0], m[3], m[6], m[9]), (m[1], m[4], m[7], m[10]),
                                  (m[2], m[5], m[8], m[11]), (0, 0, 0, 1)))
    gr = ground(mats, 3000, -0.5); gr.location = (BED / 2, BED / 2, -0.5)
    camera((BED / 2 + 40, BED / 2 - 120, 330), (BED / 2, BED / 2, 5), 50)
    render(os.path.join(out, "5_print_bed.png"))

main()
