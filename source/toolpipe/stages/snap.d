module toolpipe.stages.snap;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;
import std.algorithm : canFind;

import toolpipe.stage    : Stage, TaskCode, ordSnap;
import toolpipe.pipeline : ToolState;
import toolpipe.packets  : SnapPacket, SnapType;
import popup_state       : setStatePath;

// ---------------------------------------------------------------------------
// SnapStage — Phase 7.3 of doc/phase7_plan.md / doc/snap_plan.md.
// Sits at LXs_ORD_SNAP = 0x40 (between WORK 0x30 and ACEN 0x60).
//
// Publishes a SnapPacket with the master enable flag, the
// candidate-type bitmask and the inner / outer pixel ranges. The
// actual snap math runs on demand in source/snap.d's `snapCursor`,
// since snap candidates depend on the live cursor position and can't
// be precomputed once per pipeline.evaluate.
//
// HTTP setAttr keys:
//   `enabled`       : "true" / "false"
//   `types`         : CSV — "vertex,edgeCenter,polyCenter,grid"
//                     (recognised tokens: vertex, edge, edgeCenter,
//                      polygon, polyCenter, grid, workplane)
//   `innerRange`    : float, screen pixels
//   `outerRange`    : float, screen pixels
//   `fixedGrid`     : "true" / "false"
//   `fixedGridSize` : float, world units
// ---------------------------------------------------------------------------
class SnapStage : Stage {
    bool   enabled       = false;
    uint   enabledTypes  = SnapType.Vertex
                         | SnapType.EdgeCenter
                         | SnapType.PolyCenter
                         | SnapType.Grid;
    float  innerRangePx  = 8.0f;
    float  outerRangePx  = 24.0f;
    bool   fixedGrid     = false;
    float  fixedGridSize = 1.0f;

    this() { publishState(); }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Snap; }
    override string   id()       const                          { return "snap"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordSnap; }

    override void evaluate(ref ToolState state) {
        state.snap.enabled       = enabled;
        state.snap.enabledTypes  = enabledTypes;
        state.snap.innerRangePx  = innerRangePx;
        state.snap.outerRangePx  = outerRangePx;
        state.snap.fixedGrid     = fixedGrid;
        state.snap.fixedGridSize = fixedGridSize;
        // Snapshot workplane state. WORK stage has already run (ord
        // 0x30 < SNAP 0x40) so state.workplane is populated.
        state.snap.workplaneCenter = state.workplane.center;
        state.snap.workplaneNormal = state.workplane.normal;
        state.snap.workplaneAxis1  = state.workplane.axis1;
        state.snap.workplaneAxis2  = state.workplane.axis2;
        // Resolve grid step. Dynamic mode (the default) matches
        // vibe3d's visible grid, which is hard-coded at 1.0 in
        // app.d; if/when that becomes zoom-adaptive, this picks
        // up the same value.
        state.snap.gridStep = fixedGrid ? fixedGridSize : 1.0f;
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    override string[2][] listAttrs() const {
        return [
            ["enabled",       enabled ? "true" : "false"],
            ["types",         typesLabel()],
            ["innerRange",    format("%g", innerRangePx)],
            ["outerRange",    format("%g", outerRangePx)],
            ["fixedGrid",     fixedGrid ? "true" : "false"],
            ["fixedGridSize", format("%g", fixedGridSize)],
        ];
    }

private:
    bool applySetAttr(string name, string value) {
        switch (name) {
            case "enabled":
                if      (value == "true"  || value == "1") { enabled = true;  return true; }
                else if (value == "false" || value == "0") { enabled = false; return true; }
                return false;
            case "types": {
                uint mask = 0;
                foreach (tok; value.split(",")) {
                    auto t = tok.strip;
                    if      (t.length == 0)         continue;
                    else if (t == "vertex")         mask |= SnapType.Vertex;
                    else if (t == "edge")           mask |= SnapType.Edge;
                    else if (t == "edgeCenter")     mask |= SnapType.EdgeCenter;
                    else if (t == "polygon")        mask |= SnapType.Polygon;
                    else if (t == "polyCenter")     mask |= SnapType.PolyCenter;
                    else if (t == "grid")           mask |= SnapType.Grid;
                    else if (t == "workplane")      mask |= SnapType.Workplane;
                    else                            return false;
                }
                enabledTypes = mask;
                return true;
            }
            case "innerRange": innerRangePx  = parseFloat(value); return true;
            case "outerRange": outerRangePx  = parseFloat(value); return true;
            case "fixedGrid":
                if      (value == "true"  || value == "1") { fixedGrid = true;  return true; }
                else if (value == "false" || value == "0") { fixedGrid = false; return true; }
                return false;
            case "fixedGridSize": fixedGridSize = parseFloat(value); return true;
            case "fixedGridToggle":
                fixedGrid = !fixedGrid;
                return true;
            // typeToggle <name> — flip a single type bit. Powers the
            // Snap popup's per-type checkboxes via snap.toggleType.
            case "typeToggle": {
                uint bit = typeBit(value);
                if (bit == 0) return false;
                enabledTypes ^= bit;
                return true;
            }
            default: return false;
        }
    }

    static uint typeBit(string name) {
        switch (name) {
            case "vertex":     return SnapType.Vertex;
            case "edge":       return SnapType.Edge;
            case "edgeCenter": return SnapType.EdgeCenter;
            case "polygon":    return SnapType.Polygon;
            case "polyCenter": return SnapType.PolyCenter;
            case "grid":       return SnapType.Grid;
            case "workplane":  return SnapType.Workplane;
            default:           return 0;
        }
    }

    string typesLabel() const {
        // Stable, human-readable serialisation — matches the input
        // format of `setAttr("types", ...)` so round-trip is exact.
        string[] tokens;
        if (enabledTypes & SnapType.Vertex)     tokens ~= "vertex";
        if (enabledTypes & SnapType.Edge)       tokens ~= "edge";
        if (enabledTypes & SnapType.EdgeCenter) tokens ~= "edgeCenter";
        if (enabledTypes & SnapType.Polygon)    tokens ~= "polygon";
        if (enabledTypes & SnapType.PolyCenter) tokens ~= "polyCenter";
        if (enabledTypes & SnapType.Grid)       tokens ~= "grid";
        if (enabledTypes & SnapType.Workplane)  tokens ~= "workplane";
        if (tokens.length == 0) return "";
        string s = tokens[0];
        foreach (t; tokens[1 .. $]) s ~= "," ~ t;
        return s;
    }

    void publishState() {
        setStatePath("snap/enabled",   enabled   ? "true" : "false");
        setStatePath("snap/types",     typesLabel());
        setStatePath("snap/fixedGrid", fixedGrid ? "true" : "false");
        // Per-type bits — drives the popup's checked-state on each
        // type entry. Mirrors `enabledTypes & SnapType.<X>` truthiness.
        setStatePath("snap/types/vertex",
                     (enabledTypes & SnapType.Vertex)     ? "true" : "false");
        setStatePath("snap/types/edge",
                     (enabledTypes & SnapType.Edge)       ? "true" : "false");
        setStatePath("snap/types/edgeCenter",
                     (enabledTypes & SnapType.EdgeCenter) ? "true" : "false");
        setStatePath("snap/types/polygon",
                     (enabledTypes & SnapType.Polygon)    ? "true" : "false");
        setStatePath("snap/types/polyCenter",
                     (enabledTypes & SnapType.PolyCenter) ? "true" : "false");
        setStatePath("snap/types/grid",
                     (enabledTypes & SnapType.Grid)       ? "true" : "false");
        setStatePath("snap/types/workplane",
                     (enabledTypes & SnapType.Workplane)  ? "true" : "false");
    }

    static float parseFloat(string s) {
        return s.length == 0 ? 0.0f : s.to!float;
    }
}
