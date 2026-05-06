#python
"""Dump mesh vertices to /tmp/modo_drag_result.json."""
import lx
import modo
import json

def get_active_mesh():
    for itm in modo.Scene().iterItems("mesh"):
        return itm

m = get_active_mesh()
verts = sorted([list(v.position) for v in m.geometry.vertices])
with open("/tmp/modo_drag_result.json", "w") as f:
    json.dump({"verts": verts}, f, indent=2)
lx.out("dumped %d verts to /tmp/modo_drag_result.json" % len(verts))
