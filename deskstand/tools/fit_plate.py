#!/usr/bin/env python3
"""Put feet from several stand.py builds on one A1 mini plate, for fit tests.

    python3 tools/fit_plate.py [--add PARTS.3mf] OUT.3mf BUILD_DIR [BUILD_DIR ...]

Each BUILD_DIR is a `blender -b -P stand.py -- --out BUILD_DIR ...` output.
Its out/foot.stl goes on the plate side by side with the others, and the
print settings come from the first build's stand_A1mini.3mf. Build each
variant with a different --id_notches so the printed feet can be told apart.

--add puts every object of another Bambu 3MF (e.g. out/rod_gauge.3mf) in rows
in the strip in front of the feet, so both tests print on one plate.
"""
import json, os, re, struct, sys, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_3mf

BED = 180.0


def read_stl(path):
    data = open(path, "rb").read()
    n = struct.unpack_from("<I", data, 80)[0]
    index, verts, tris = {}, [], []
    for i in range(n):
        off = 84 + i * 50 + 12
        tri = []
        for k in range(3):
            v = struct.unpack_from("<3f", data, off + 12 * k)
            key = tuple(round(c, 5) for c in v)
            if key not in index:
                index[key] = len(verts); verts.append(key)
            tri.append(index[key])
        tris.append(tuple(tri))
    return verts, tris


def read_3mf_objects(path):
    """[(name, verts, tris)] for each 3D/Objects/*.model mesh of a Bambu 3MF."""
    objs = []
    with zipfile.ZipFile(path) as z:
        names = sorted((n for n in z.namelist() if re.match(r"3D/Objects/object_\d+\.model$", n)),
                       key=lambda n: int(re.search(r"(\d+)", n.rsplit("/", 1)[1]).group(1)))
        for n in names:
            x = z.read(n).decode()
            v = [tuple(map(float, m)) for m in re.findall(r'<vertex x="([^"]+)" y="([^"]+)" z="([^"]+)"', x)]
            t = [tuple(map(int, m)) for m in re.findall(r'<triangle v1="(\d+)" v2="(\d+)" v3="(\d+)"', x)]
            objs.append((f"{os.path.splitext(os.path.basename(path))[0]}_{len(objs) + 1}", v, t))
    return objs


def place_rows(objs, y0, y1, gap):
    """Lay objs out left to right in rows from y0 upward; exit if past y1."""
    items, x, y, row_h = [], 5.0, y0, 0.0
    for v, _ in objs:
        sx = max(p[0] for p in v) - min(p[0] for p in v)
        sy = max(p[1] for p in v) - min(p[1] for p in v)
        if x + sx > BED - 5:
            x, y, row_h = 5.0, y + row_h + gap, 0.0
        cx = x + sx / 2 - (max(p[0] for p in v) + min(p[0] for p in v)) / 2
        cy = y + sy / 2 - (max(p[1] for p in v) + min(p[1] for p in v)) / 2
        items.append((cx, cy))
        x, row_h = x + sx + gap, max(row_h, sy)
    if y + row_h > y1:
        sys.exit("plate too small for the --add parts")
    return items


def main(out, builds, add=None):
    meshes, items = [], []
    sizes = []
    for b in builds:
        v, t = read_stl(os.path.join(b, "foot.stl"))
        meshes.append((f"foot_{os.path.basename(os.path.normpath(b))}", v, t))
        sizes.append([max(p[i] for p in v) - min(p[i] for p in v) for i in range(3)])
    gap = 8.0
    total = sum(s[0] for s in sizes) + gap * (len(sizes) - 1)
    if total > BED - 10 or max(s[1] for s in sizes) > BED - 10:
        sys.exit(f"plate too small for {len(sizes)} feet ({total:.0f} mm wide)")
    depth = max(s[1] for s in sizes)
    # With --add the feet move to the back edge and the extra parts fill the front.
    feet_y = BED - 5 - depth / 2 if add else BED / 2
    x = (BED - total) / 2
    for k, s in enumerate(sizes):
        items.append((k, (1, 0, 0, 0, 1, 0, 0, 0, 1, x + s[0] / 2, feet_y, 0)))
        x += s[0] + gap
    if add:
        extra = read_3mf_objects(add)
        spots = place_rows([(v, t) for _, v, t in extra], 5.0, feet_y - depth / 2 - gap, 6.0)
        for (name, v, t), (cx, cy) in zip(extra, spots):
            meshes.append((name, v, t))
            items.append((len(meshes) - 1, (1, 0, 0, 0, 1, 0, 0, 0, 1, cx, cy, 0)))
    with zipfile.ZipFile(os.path.join(builds[0], "stand_A1mini.3mf")) as z:
        settings = json.loads(z.read("Metadata/project_settings.config"))
    make_3mf.write_bambu_3mf(out, meshes, items, settings)
    print(f"wrote {out}: {len(builds)} feet" + (f" + {len(meshes) - len(builds)} parts" if add else ""))


if __name__ == "__main__":
    args = sys.argv[1:]
    add = None
    if args[:1] == ["--add"]:
        add, args = args[1], args[2:]
    if len(args) < 2:
        sys.exit(__doc__)
    main(args[0], args[1:], add)
