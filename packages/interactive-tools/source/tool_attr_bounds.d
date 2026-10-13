module tool_attr_bounds;

import params : Param, ParamFlags, paramGateFloat, paramGateInt;

// The bound every interactive door clamps a tool or stage attribute write to (task
// 9492 / 9519, captures K-A3 table b and K-SC scr_neg). The rows are the EXECUTED
// write column — the value an out-of-range write actually stores — not the
// declared hints: several attributes clamp with nothing declared. Every row
// has a min; an absent max is unbounded (the write is stored as given). Read
// by `tool.attr`, `tool.pipe.attr`, `tool.set` arguments, the scripted one-shot
// (`prim.cube` …), the property panel, the forms panel and the registry; the
// restore paths (presets, the attribute cache, remembered defaults, undo) never
// consult it, so each kernel keeps its own `MAX_` cap.
struct ToolAttrBound {
    string tool, attr;
    double lo, hi;
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
    // The axis datatype clamps a number to [0, 2] (X, Y, Z).
    {"prim.cube", "axis", 0, 2}, {"prim.sphere", "axis", 0, 2},
    {"prim.ellipsoid", "axis", 0, 2}, {"prim.cone", "axis", 0, 2},
    {"prim.cylinder", "axis", 0, 2}, {"prim.capsule", "axis", 0, 2},
    {"prim.torus", "axis", 0, 2},
    // Declared min only: the row is refused outside Wall mode in the capture.
    {"pen", "offset", 0, none},
    // Array, Clone, Mirror and Radial Array share one clone effector (PF-4).
    {"mesh.arrayTool", "numX", 1, none}, {"mesh.arrayTool", "numY", 1, none},
    {"mesh.arrayTool", "numZ", 1, none}, {"mesh.arrayTool", "dist", 0, none},
    {"mesh.clone", "num", 0, none}, {"mesh.clone", "dist", 0, none},
    {"mesh.clone", "snapAngle", 0, kCloneSnapAngleMax},
    {"mesh.mirrorTool", "dist", 0, none},
    {"mesh.radialArrayTool", "count", 1, none}, {"mesh.radialArrayTool", "dist", 0, none},
    {"mesh.loopSliceTool", "count", 1, 1024},
    {"mesh.loopSliceTool", "gap", 0, none},
    {"mesh.loopSliceTool", "position", 0, 1},
    {"mesh.sliceTool", "gap", 0, none},
    // A percent: the reference stores the fraction [0, 1], ours the percent.
    {"mesh.edgeSliceTool", "snap", 0, 100},
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
    {"constrain", "offset", 0, none},
];

/// Replace `p`'s numeric bound hints with its captured row and arm the clamp.
/// False (and `p` untouched) when `toolId` has no row for `p`. Every row names
/// an Int, IntEnum (its numeric value) or Float attribute.
bool applyToolAttrBound(string toolId, ref Param p) {
    import std.math : isFinite;
    foreach (ref b; kToolAttrBounds) {
        if (b.tool != toolId || b.attr != p.name) continue;
        const hasHi = isFinite(b.hi);
        with (p.hints) if (p.kind == Param.Kind.Int || p.kind == Param.Kind.IntEnum) {
            hasMinI = true;  minI = cast(int) b.lo;
            hasMaxI = hasHi; maxI = hasHi ? cast(int) b.hi : 0;
        } else {
            hasMinF = true;  minF = cast(float) b.lo;
            hasMaxF = hasHi; maxF = hasHi ? cast(float) b.hi : 0;
        }
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
