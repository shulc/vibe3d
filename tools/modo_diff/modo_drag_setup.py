#python
"""Setup: cube + select top face + activate <ACEN_MODE> + xfrm.scale.
Caller must do real mouse drag in viewport to trigger ACEN evaluate.

Usage:
    @modo_drag_setup.py [acen_mode]

acen_mode is one of: select (default), selectauto, auto, border, origin,
local, element, screen.
"""
import lx
import modo
import json

args = lx.args()
acen_mode = args[0] if args else "select"

def get_active_mesh():
    for itm in modo.Scene().iterItems("mesh"):
        return itm

# Setup: cube via Unit Cube macro pattern.
lx.eval("scene.new")
lx.eval('tool.set "prim.cube" on 0')
lx.eval('tool.reset "prim.cube"')
lx.eval('tool.apply')
lx.eval('tool.set "prim.cube" off 0')

# Select top face (4 verts at y=+0.5).
target = {(-0.5,0.5,-0.5), (0.5,0.5,-0.5), (0.5,0.5,0.5), (-0.5,0.5,0.5)}
for p in get_active_mesh().geometry.polygons:
    if {tuple(v.position) for v in p.vertices} == target:
        lx.eval("select.typeFrom polygon")
        lx.eval("select.drop polygon")
        p.select(replace=True)
        break

# Activate ACEN.<mode> + xfrm.scale.
lx.eval('tool.set "actr.%s" on 0' % acen_mode)
lx.eval('tool.set "xfrm.scale" on 0')

# Dump initial state.
verts = sorted([list(v.position) for v in get_active_mesh().geometry.vertices])
with open("/tmp/modo_drag_state.json", "w") as f:
    json.dump({"acen_mode": acen_mode, "before": verts}, f, indent=2)

lx.out("setup done — acen=%s, drag in viewport now" % acen_mode)
