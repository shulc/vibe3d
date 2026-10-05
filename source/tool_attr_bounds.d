module tool_attr_bounds;

import params : Param, ParamFlags, paramGateFloat, paramGateInt;

// The bound every interactive door clamps a tool attribute write to (task
// 9492, capture K-A3, findings_K-A3.md table b). The rows are the EXECUTED
// write column — the value an out-of-range write actually stores — not the
// declared hints: several attributes clamp with nothing declared. An absent
// side is unbounded (the write is stored as given). Read by the `tool.attr`
// door, the property panel, the forms panel and the registry; the
// stored-state paths (presets, the attribute cache, undo) never consult it,
// so each kernel keeps its own `MAX_` cap.
struct ToolAttrBound {
    string tool, attr;
    double lo = -double.infinity, hi = double.infinity;
}

private enum double none = double.infinity;
// The clone angle snap's bound is 90 in the reference's internal unit
// (radians); ours stores degrees (K-A3 PF-5).
private enum double kCloneSnapAngleMax = 90.0 * 180.0 / 3.14159265358979323846;

static immutable ToolAttrBound[] kToolAttrBounds = [
    {"prim.cube", "segmentsX", 1, none}, {"prim.cube", "segmentsY", 1, none},
    {"prim.cube", "segmentsZ", 1, none}, {"prim.cube", "segmentsR", 1, none},
    {"prim.cube", "radius", 0, none},
    {"prim.sphere", "sides", 3, 1024}, {"prim.sphere", "segments", 1, 1024},
    {"prim.sphere", "order", 0, 32},
    {"prim.cone", "sides", 3, 1024}, {"prim.cone", "segments", 1, 1024},
    {"prim.cylinder", "sides", 3, 1024}, {"prim.cylinder", "segments", 1, 1024},
    {"prim.capsule", "sides", 3, 1024}, {"prim.capsule", "segments", 1, 1024},
    {"prim.capsule", "endsegments", 1, none},
    {"prim.ellipsoid", "sides", 3, 1024}, {"prim.ellipsoid", "segments", 2, none},
    // Torus sides / segments / ring radius (matched by their defaults 24 / 12).
    {"prim.torus", "majorSegments", 3, 1024}, {"prim.torus", "minorSegments", 2, none},
    {"prim.torus", "majorRadius", 0, none},
    // Array, Clone, Mirror and Radial Array share one clone effector (PF-4).
    {"mesh.arrayTool", "numX", 1, none}, {"mesh.arrayTool", "numY", 1, none},
    {"mesh.arrayTool", "numZ", 1, none}, {"mesh.arrayTool", "dist", 0, none},
    {"mesh.clone", "num", 0, none}, {"mesh.clone", "dist", 0, none},
    {"mesh.clone", "snapAngle", 0, kCloneSnapAngleMax},
    {"mesh.mirrorTool", "distance", 0, none},
    {"mesh.radialArrayTool", "count", 1, none}, {"mesh.radialArrayTool", "weld", 0, none},
    {"mesh.loopSliceTool", "count", 1, 1024},
    {"mesh.loopSliceTool", "gap", 0, none},
    {"mesh.sliceTool", "gap", 0, none},
    {"mesh.edgeSliceTool", "snap", 0, 1},
    {"edge.bevel", "width", 0, none}, {"edge.bevel", "roundLevel", 0, none},
    {"edge.extend", "segments", 1, none},
    {"edge.extrude", "width", 0, none},
    {"mesh.vertexBevel", "inset", 0, none},
    {"mesh.vertexExtrude", "width", 0, none},
    {"vert.merge", "dist", 0, none},
    {"poly.bevel", "segments", 0, none},
    {"xfrm.jitter", "rangeX", -1e9, 1e9}, {"xfrm.jitter", "rangeY", -1e9, 1e9},
    {"xfrm.jitter", "rangeZ", -1e9, 1e9},
    {"xfrm.linearAlignTool", "weight", 0, 1},
    {"xfrm.radialAlignTool", "side", 3, none}, {"xfrm.radialAlignTool", "weight", 0, 1},
    {"xfrm.quantize", "X", 0, 1e9}, {"xfrm.quantize", "Y", 0, 1e9},
    {"xfrm.quantize", "Z", 0, 1e9},
    {"xfrm.smooth", "iter", 1, none}, {"xfrm.smooth", "strn", 0, 1},
    {"xfrm.smooth", "sharpThreshold", 0, 180},
    {"mesh.topoPen", "smoothStrength", 0, none},
];

/// Replace `p`'s numeric bound hints with its captured row and arm the clamp.
/// False (and `p` untouched) when `toolId` declares no row for `p`.
bool applyToolAttrBound(string toolId, ref Param p) {
    import std.math : isFinite;
    foreach (ref b; kToolAttrBounds) {
        if (b.tool != toolId || b.attr != p.name) continue;
        const hasLo = isFinite(b.lo), hasHi = isFinite(b.hi);
        if (p.kind == Param.Kind.Int) {
            p.hints.hasMinI = hasLo; p.hints.minI = hasLo ? cast(int) b.lo : 0;
            p.hints.hasMaxI = hasHi; p.hints.maxI = hasHi ? cast(int) b.hi : 0;
        } else if (p.kind == Param.Kind.Float) {
            p.hints.hasMinF = hasLo; p.hints.minF = hasLo ? cast(float) b.lo : 0;
            p.hints.hasMaxF = hasHi; p.hints.maxF = hasHi ? cast(float) b.hi : 0;
        } else return false;
        p.flags |= ParamFlags.EnforceBounds;
        return true;
    }
    return false;
}

/// Re-clamp the value already stored through `p` to its armed bounds: the
/// panel's widgets write the field directly and clamp only a two-sided range.
void clampStoredToBounds(ref Param p) {
    if (p.kind == Param.Kind.Int) {
        int v;
        if (paramGateInt(p, *p.iptr, v)) *p.iptr = v;
    } else if (p.kind == Param.Kind.Float) {
        float v;
        if (paramGateFloat(p, *p.fptr, v)) *p.fptr = v;
    }
}
