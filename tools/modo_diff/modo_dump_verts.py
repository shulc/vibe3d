#python
"""Dump mesh vertices (post-drag) AND the active tool's attribute
values to <tmpdir>/modo_drag_result.json.

Tool attributes are read via the `tool.attr <toolname> <attr> ?` query
operator that MODO's own Tool Properties uses. For our three tools:

  xfrm.move   : X, Y, Z          (translation offsets)
  xfrm.scale  : factor, X, Y, Z  (scale factor + per-axis)
  xfrm.rotate : angle, startX,
                startY, startZ   (rotation around an axis from start)

For TransformRotate (macro wrapping xfrm.transform with T=0,R=1,S=0)
we read xfrm.transform's RX/RY/RZ instead.

Usage from orchestrator:
    @modo_dump_verts.py [tmpdir] <tool>      # tool ∈ {move, scale, rotate}

Per-worker isolation: pass a unique tmpdir as the first arg.
"""
import lx
import modo
import json


def get_active_mesh():
    for itm in modo.Scene().iterItems("mesh"):
        return itm


# ---- read post-drag tool attributes ---------------------------------
def _q(toolname, attr):
    """Query a tool attribute via the `?` operator. Returns the value
    (float for numeric attrs) or None if the query fails."""
    try:
        return lx.eval("tool.attr %s %s ?" % (toolname, attr))
    except Exception:
        return None


def collect_tool_amount(tool):
    # Only attributes that are safe to query in headless MODO 9 are
    # listed below. Querying per-axis attributes (xfrm.scale's X/Y/Z,
    # xfrm.move's individual axes once `Y` becomes locked) hangs the
    # interpreter — they expose axis-locked modal state that needs a
    # GUI to resolve. We stick to global accumulators.
    if tool == "move":
        return {"tool": "xfrm.move",
                "X": _q("xfrm.move", "X"),
                "Y": _q("xfrm.move", "Y"),
                "Z": _q("xfrm.move", "Z")}
    if tool == "scale":
        # `factor` is the global scale magnitude; per-axis X/Y/Z hang.
        return {"tool": "xfrm.scale",
                "factor": _q("xfrm.scale", "factor")}
    if tool == "rotate":
        # TransformRotate is a macro over xfrm.transform with R=1.
        # Per-axis RX/RY/RZ hang in headless; we omit them — tests rely
        # on geometric rigidity check, not the published angles.
        return {"tool": "xfrm.transform"}
    return None


_args = list(lx.args())
tmpdir = "/tmp"
if _args and _args[0].startswith("/"):
    tmpdir = _args.pop(0)
tool_arg = _args[0] if _args else "move"

err = None
verts = []
tool_amount = None
try:
    m = get_active_mesh()
    verts = sorted([list(v.position) for v in m.geometry.vertices])
except Exception as e:
    err = "verts: " + repr(e)
try:
    tool_amount = collect_tool_amount(tool_arg)
except Exception as e:
    err = (err or "") + " tool: " + repr(e)

# Atomic write so the orchestrator's wait-for-file never sees a partial.
import os
result_path = tmpdir + "/modo_drag_result.json"
tmp = result_path + ".partial"
with open(tmp, "w") as f:
    json.dump({"verts": verts, "tool_amount": tool_amount, "error": err},
              f, indent=2)
os.rename(tmp, result_path)

lx.out("dumped %d verts + tool=%s amount=%r err=%s"
       % (len(verts), tool_arg, tool_amount, err))
