"""Flatten a Bambu Studio system profile by resolving its `inherits` chain.

The Bambu Studio CLI crashes on system presets that inherit from parents;
a flattened copy slices fine.  Usage:
    python3 flatten_profile.py <profiles/BBL/<kind>> "<preset name>" out.json
"""
import json, os, sys

def load(folder, name):
    with open(os.path.join(folder, name + ".json")) as f:
        d = json.load(f)
    parent = d.get("inherits")
    if parent:
        base = load(folder, parent)
        base.update(d)
        d = base
    return d

folder, name, out = sys.argv[1:4]
d = load(folder, name)
d.pop("inherits", None)
d["from"] = "system"
with open(out, "w") as f:
    json.dump(d, f, indent=1)
print(out, d.get("type"), len(d))
