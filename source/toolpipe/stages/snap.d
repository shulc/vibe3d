module toolpipe.stages.snap;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;
import std.algorithm : canFind;

import toolpipe.stage    : Stage, TaskCode, ordSnap;
// pipeline imports moved to packet-only — Phase 6 cleanup
import toolpipe.packets  : SnapPacket, SnapHitPacket, SnapType, SnapMode;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;

// ---------------------------------------------------------------------------
// SnapStage — Phase 7.3 of doc/phase7_plan.md / doc/snap_plan.md.
// Sits at ordinal 0x40 (between WORK 0x30 and ACEN 0x60).
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
class SnapStage : Stage, Operator {
    // Phase 1 of doc/operator_refactor_plan.md.
    private SnapPacket _publishedPacket;
    // The per-cursor RESULT (S2 of doc/toolpipe_architecture_plan.md).
    // Storage lives on the stage for the same reason `_publishedPacket` does:
    // the VectorStack holds POINTERS into the publisher, valid for the one
    // `pipeline.evaluate` call.
    private SnapHitPacket _hitPkt;

    Task task() const { return Task.Snap; }
    PacketKind[] requiredPackets() const { return [PacketKind.Subject]; }

    bool evaluate(ref VectorStack vts) {
        // NB: SnapStage shadows Stage.enabled with its own field
        // (default false). `this.enabled` resolves to the SnapStage one.
        if (!this.enabled) return false;
        import toolpipe.packets : WorkplanePacket;
        SnapPacket pkt;
        pkt.enabled       = enabled;
        pkt.enabledTypes  = enabledTypes;
        pkt.snapScope     = snapScope;
        pkt.innerRangePx  = innerRangePx;
        pkt.outerRangePx  = outerRangePx;
        pkt.fixedGrid     = fixedGrid;
        pkt.fixedGridSize = fixedGridSize;
        if (auto wp = vts.get!WorkplanePacket()) {
            pkt.workplaneCenter = wp.center;
            pkt.workplaneNormal = wp.normal;
            pkt.workplaneAxis1  = wp.axis1;
            pkt.workplaneAxis2  = wp.axis2;
        }
        pkt.gridStep = fixedGrid ? fixedGridSize : 1.0f;
        _publishedPacket = pkt;
        vts.put(&_publishedPacket);

        publishSnapHit(vts, pkt);
        return true;
    }

    // ---- the per-cursor RESULT (S2 of doc/toolpipe_architecture_plan.md) ---
    //
    // The snap query is the one thing this stage never published: it shipped
    // the CONFIG and left every consumer to run the query itself. This runs it
    // once, here, and puts the answer on the stack the CONS stage already puts
    // its own per-cursor result on.
    //
    // The gate is `subj.cursorValid`, copied from CONS (`stages/constrain.d`)
    // rather than invented: that flag is stamped true ONLY by the main-thread
    // mouse-event dispatch (app.d's buildToolVts) and the main-thread-bridged
    // raycast provider. Every per-frame render-loop evaluate() and every
    // HTTP-thread subject builder (/api/toolpipe, /api/snap, /api/constrain,
    // /api/path) leaves it false, so the query runs once per real input event,
    // on the main thread, never off it — which matters because the candidate
    // grids snapCursor builds are process-global.
    //
    // No packet is published when the gate fails: an absent SnapHitPacket
    // means "no cursor-valid query this evaluation", exactly as an absent
    // ConstrainHitPacket does. A published packet with `snapped == false`
    // means the query ran and found nothing.
    private void publishSnapHit(ref VectorStack vts, const ref SnapPacket cfg) {
        import toolpipe.packets : SubjectPacket;
        import snap             : snapCursor, SnapResult,
                                  backgroundSourceLayerIndices;
        import math             : Vec3, projectToWindowFull;
        import std.math         : sqrt;

        auto subj = vts.get!SubjectPacket();
        if (subj is null || !subj.cursorValid) return;
        if (subj.mesh is null || subj.viewport.width <= 0) return;

        // The query seed. `snapCursor` ranks candidates by their distance from
        // the cursor PIXEL alone — the seed is never compared against anything;
        // it only reappears as the pass-through `worldPos` on a miss. So the
        // stage, which has no tool and therefore no desired position, passes
        // the origin and publishes no position at all unless something snapped
        // (see SnapHitPacket's contract). Were the seed to acquire meaning,
        // this line would have to become a real derivation, and the packet's
        // "meaningful only when `snapped`" clause is what keeps that honest.
        SnapResult sr = snapCursor(Vec3(0, 0, 0), subj.cursorX, subj.cursorY,
                                   subj.viewport, *subj.mesh, cfg);

        SnapHitPacket hit;   // every field at its documented default
        hit.snapped      = sr.snapped;
        hit.highlighted  = sr.highlighted;
        hit.targetType   = sr.targetType;
        hit.targetIndex  = sr.targetIndex;
        hit.targetSource = sr.targetSource;

        if (sr.snapped) {
            hit.worldPos = sr.worldPos;
            // The screen point + pixel distance are a RE-projection of the
            // winner, not a second opinion about it: `consider` picked the
            // winner by projecting this same world point through this same
            // viewport, so this reproduces the winning distance bit for bit.
            float pxs, pys, ndcZ;
            if (projectToWindowFull(sr.worldPos, subj.viewport, pxs, pys, ndcZ)) {
                hit.screenX = pxs;
                hit.screenY = pys;
                immutable float dx = pxs - cast(float)subj.cursorX;
                immutable float dy = pys - cast(float)subj.cursorY;
                hit.distPx = sqrt(dx * dx + dy * dy);
            }
        }

        // `targetSource` is the snap service's source SLOT (0 = active mesh,
        // 1..N = the (slot-1)-th background source). Resolve the background
        // ones back to a Document-layer index the same way the CONS stage
        // resolves its own hit, with the same fallback to the slot order when
        // the installer supplied no mapping. Slot 0 stays -1: the active
        // layer's index is the Document's business and snap.d does not hold it.
        if (sr.targetSource >= 1) {
            auto bgSrcLayer = backgroundSourceLayerIndices();
            immutable int srcIdx = sr.targetSource - 1;
            hit.layer = (srcIdx < cast(int)bgSrcLayer.length)
                        ? bgSrcLayer[srcIdx] : srcIdx;
        }

        _hitPkt = hit;
        vts.put(&_hitPkt);
    }

    bool     enabled       = false;
    uint     enabledTypes  = SnapType.Vertex
                           | SnapType.EdgeCenter
                           | SnapType.PolyCenter
                           | SnapType.Grid;
    SnapMode snapScope     = SnapMode.Global;
    float    innerRangePx  = 24.0f;
    float    outerRangePx  = 40.0f;
    bool     fixedGrid     = false;
    float    fixedGridSize = 1.0f;

    this() { publishState(); }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Snap; }
    override string   id()       const                          { return "snap"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordSnap; }

    /// Match every default field initialiser at declaration time —
    /// invoked via Stage.reset() by SceneReset / `/api/reset`.
    override void reset() {
        enabled       = false;
        enabledTypes  = SnapType.Vertex
                      | SnapType.EdgeCenter
                      | SnapType.PolyCenter
                      | SnapType.Grid;
        snapScope     = SnapMode.Global;
        innerRangePx  = 24.0f;
        outerRangePx  = 40.0f;
        fixedGrid     = false;
        fixedGridSize = 1.0f;
        // Drop the last per-cursor result too, so a scene reset cannot leave a
        // stale hit behind the stage's pointer (mirrors the CONS stage).
        _hitPkt       = SnapHitPacket.init;
        publishState();
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    /// Snapshot the stage's LIVE user-facing CONFIG fields into a SnapPacket —
    /// the inverse of `restoreConfigFromPacket`. Used by the wrapper's
    /// transform-session undo/redo hooks (P-C) so a mid-run snap toggle reverts
    /// the snap CONFIG together with the geometry. Mirrors
    /// FalloffStage.snapshotConfigToPacket: captures only the STAGE-owned config
    /// fields (the ones a round-trip restores); the workplane cache + gridStep
    /// are re-derived by evaluate() from the upstream WORK stage.
    SnapPacket snapshotConfigToPacket() const {
        SnapPacket p;
        p.enabled       = enabled;
        p.enabledTypes  = enabledTypes;
        p.snapScope     = snapScope;
        p.innerRangePx  = innerRangePx;
        p.outerRangePx  = outerRangePx;
        p.fixedGrid     = fixedGrid;
        p.fixedGridSize = fixedGridSize;
        return p;
    }

    /// Restore the user-facing CONFIG fields from a previously-snapshotted
    /// SnapPacket and re-publish so the status-bar pulldown follows. Used by the
    /// wrapper's in-session snap-refire undo/redo hooks (P-C): an in-session
    /// Ctrl+Z of a transform-session snap change restores the snap config to its
    /// PRE-tweak value (revert hook); redo restores the POST-tweak config (apply
    /// hook). Mirrors FalloffStage.restoreConfigFromPacket — assign + publish, no
    /// session. Does NOT restore the workplane cache / gridStep (evaluate()
    /// re-derives those from the upstream WORK stage).
    void restoreConfigFromPacket(const ref SnapPacket p) {
        enabled       = p.enabled;
        enabledTypes  = p.enabledTypes;
        snapScope     = p.snapScope;
        innerRangePx  = p.innerRangePx;
        outerRangePx  = p.outerRangePx;
        fixedGrid     = p.fixedGrid;
        fixedGridSize = p.fixedGridSize;
        publishState();
    }

    override string[2][] listAttrs() const {
        return [
            ["enabled",       enabled ? "true" : "false"],
            ["types",         typesLabel()],
            ["snapMode",      snapModeLabel()],
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
                    if      (t.length == 0)          continue;
                    else if (t == "vertex")          mask |= SnapType.Vertex;
                    else if (t == "edge")            mask |= SnapType.Edge;
                    else if (t == "edgeCenter")      mask |= SnapType.EdgeCenter;
                    else if (t == "polygon")         mask |= SnapType.Polygon;
                    else if (t == "polyCenter")      mask |= SnapType.PolyCenter;
                    else if (t == "grid")            mask |= SnapType.Grid;
                    else if (t == "workplane")       mask |= SnapType.Workplane;
                    else if (t == "pivot")           mask |= SnapType.Pivot;
                    else if (t == "intersection")    mask |= SnapType.Intersection;
                    else if (t == "worldAxis")       mask |= SnapType.WorldAxis;
                    else if (t == "straightLine")    mask |= SnapType.StraightLine;
                    else if (t == "rightAngle")      mask |= SnapType.RightAngle;
                    else if (t == "box")             mask |= SnapType.Box;
                    else                             return false;
                }
                enabledTypes = mask;
                return true;
            }
            case "snapMode": {
                if      (value == "global")    { snapScope = SnapMode.Global;    return true; }
                else if (value == "component") { snapScope = SnapMode.Component; return true; }
                else if (value == "item")      { snapScope = SnapMode.Item;      return true; }
                return false;
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
            case "vertex":       return SnapType.Vertex;
            case "edge":         return SnapType.Edge;
            case "edgeCenter":   return SnapType.EdgeCenter;
            case "polygon":      return SnapType.Polygon;
            case "polyCenter":   return SnapType.PolyCenter;
            case "grid":         return SnapType.Grid;
            case "workplane":    return SnapType.Workplane;
            case "pivot":        return SnapType.Pivot;
            case "intersection": return SnapType.Intersection;
            case "worldAxis":    return SnapType.WorldAxis;
            case "straightLine": return SnapType.StraightLine;
            case "rightAngle":   return SnapType.RightAngle;
            case "box":          return SnapType.Box;
            default:             return 0;
        }
    }

    string typesLabel() const {
        // Stable, human-readable serialisation — matches the input
        // format of `setAttr("types", ...)` so round-trip is exact.
        string[] tokens;
        if (enabledTypes & SnapType.Vertex)       tokens ~= "vertex";
        if (enabledTypes & SnapType.Edge)         tokens ~= "edge";
        if (enabledTypes & SnapType.EdgeCenter)   tokens ~= "edgeCenter";
        if (enabledTypes & SnapType.Polygon)      tokens ~= "polygon";
        if (enabledTypes & SnapType.PolyCenter)   tokens ~= "polyCenter";
        if (enabledTypes & SnapType.Grid)         tokens ~= "grid";
        if (enabledTypes & SnapType.Workplane)    tokens ~= "workplane";
        if (enabledTypes & SnapType.Pivot)        tokens ~= "pivot";
        if (enabledTypes & SnapType.Intersection) tokens ~= "intersection";
        if (enabledTypes & SnapType.WorldAxis)    tokens ~= "worldAxis";
        if (enabledTypes & SnapType.StraightLine) tokens ~= "straightLine";
        if (enabledTypes & SnapType.RightAngle)   tokens ~= "rightAngle";
        if (enabledTypes & SnapType.Box)          tokens ~= "box";
        if (tokens.length == 0) return "";
        string s = tokens[0];
        foreach (t; tokens[1 .. $]) s ~= "," ~ t;
        return s;
    }

    string snapModeLabel() const {
        final switch (snapScope) {
            case SnapMode.Global:    return "global";
            case SnapMode.Component: return "component";
            case SnapMode.Item:      return "item";
        }
    }

    void publishState() {
        setStatePath("snap/enabled",   enabled   ? "true" : "false");
        setStatePath("snap/types",     typesLabel());
        setStatePath("snap/snapMode",  snapModeLabel());
        setStatePath("snap/fixedGrid", fixedGrid ? "true" : "false");
        // Per-type bits — drives the popup's checked-state on each
        // type entry. Mirrors `enabledTypes & SnapType.<X>` truthiness.
        setStatePath("snap/types/vertex",
                     (enabledTypes & SnapType.Vertex)       ? "true" : "false");
        setStatePath("snap/types/edge",
                     (enabledTypes & SnapType.Edge)         ? "true" : "false");
        setStatePath("snap/types/edgeCenter",
                     (enabledTypes & SnapType.EdgeCenter)   ? "true" : "false");
        setStatePath("snap/types/polygon",
                     (enabledTypes & SnapType.Polygon)      ? "true" : "false");
        setStatePath("snap/types/polyCenter",
                     (enabledTypes & SnapType.PolyCenter)   ? "true" : "false");
        setStatePath("snap/types/grid",
                     (enabledTypes & SnapType.Grid)         ? "true" : "false");
        setStatePath("snap/types/workplane",
                     (enabledTypes & SnapType.Workplane)    ? "true" : "false");
        setStatePath("snap/types/pivot",
                     (enabledTypes & SnapType.Pivot)        ? "true" : "false");
        setStatePath("snap/types/intersection",
                     (enabledTypes & SnapType.Intersection) ? "true" : "false");
        setStatePath("snap/types/worldAxis",
                     (enabledTypes & SnapType.WorldAxis)    ? "true" : "false");
        setStatePath("snap/types/straightLine",
                     (enabledTypes & SnapType.StraightLine) ? "true" : "false");
        setStatePath("snap/types/rightAngle",
                     (enabledTypes & SnapType.RightAngle)   ? "true" : "false");
        setStatePath("snap/types/box",
                     (enabledTypes & SnapType.Box)          ? "true" : "false");
    }

    static float parseFloat(string s) {
        return s.length == 0 ? 0.0f : s.to!float;
    }
}

unittest { // ONE set of snap defaults — the packet's must equal the stage's
    // `SnapPacket.init` is not a second opinion about the snap config: it is
    // the FALLBACK four call sites serve when the pipeline has no SNAP packet
    // (`tools/create/create_common.d` twice, `tools/transform/transform.d`
    // twice), so it is read as if the stage had published it. The two sets
    // disagreed — the packet carried inner 8 / outer 40's ancestor 24, the
    // stage 24 / 40 — which made a packet-less consumer snap with a 3x
    // narrower acceptance and a 1.67x narrower gather, silently. Nothing
    // announced the divergence because no test compared them.
    //
    // This block is that comparison. It deliberately checks EVERY config field
    // rather than only the two ranges: whichever default drifts next, the
    // fallback is wrong in exactly the same silent way.
    auto st = new SnapStage();

    assert(st.innerRangePx == SnapPacket.init.innerRangePx,
        "the SNAP stage owns innerRangePx; SnapPacket.init is the fallback four "
        ~ "call sites serve for it, so the two defaults must be one number");
    assert(st.outerRangePx == SnapPacket.init.outerRangePx,
        "same for outerRangePx — a packet-less consumer must gather exactly as "
        ~ "far as one holding the stage's packet");

    assert(st.enabled       == SnapPacket.init.enabled,       "enabled default drifted");
    assert(st.enabledTypes  == SnapPacket.init.enabledTypes,  "enabledTypes default drifted");
    assert(st.snapScope     == SnapPacket.init.snapScope,     "snapScope default drifted");
    assert(st.fixedGrid     == SnapPacket.init.fixedGrid,     "fixedGrid default drifted");
    assert(st.fixedGridSize == SnapPacket.init.fixedGridSize, "fixedGridSize default drifted");

    // Whole-struct form, and it is not redundant: `snapshotConfigToPacket`
    // starts from `SnapPacket.init` and overwrites only the config fields, so
    // a fresh stage's snapshot is bit-identical to the init packet iff every
    // config default agrees. This catches a field ADDED to one side only.
    assert(st.snapshotConfigToPacket() == SnapPacket.init,
        "a fresh SNAP stage's config snapshot must BE the init packet — if a "
        ~ "new config field lands on one side only, the fallback silently "
        ~ "diverges again");

    // `reset()` restates every initialiser by hand (SceneReset / /api/reset go
    // through it), so it is a third copy of the same set and it drifts too.
    st.innerRangePx = 1.0f;
    st.outerRangePx = 2.0f;
    st.enabled      = true;
    st.reset();
    assert(st.snapshotConfigToPacket() == SnapPacket.init,
        "SnapStage.reset() must restore exactly the declaration initialisers, "
        ~ "which are exactly SnapPacket.init's");
}

// ---------------------------------------------------------------------------
// S2 (a) of doc/toolpipe_architecture_plan.md — the SNAP stage publishes the
// snap RESULT, not only the snap CONFIG.
//
// Phase (a) is an UNREAD publication: the packet goes onto the stack and
// nothing in the tree reads it, so the neutrality argument is a grep, not a
// test. What a test can prove — and what this block proves — is that the
// thing published is the thing the query already returns, and that it is
// published under exactly the gate that keeps it off the HTTP threads:
//
//   1. GATE. No packet without `SubjectPacket.cursorValid`, and none while the
//      stage is disabled. This is the property that keeps the process-global
//      candidate grids a main-thread affair; a publication that ignored the
//      flag would be a thread-safety change dressed as a packet.
//   2. EQUIVALENCE. Field for field, the published packet is what a direct
//      `snapCursor` at the same pixel with the same config returns. A packet
//      that dropped or crossed a field would pass a "packet exists" test and
//      fails this one.
//   3. DERIVATION. `screenX`/`screenY`/`distPx` are the WINNER's own pixel and
//      its distance from the cursor — checked against an independently
//      computed projection, so projecting the wrong point is caught.
//   4. CONTRACT. On a highlight-without-snap, and on an outright miss, the
//      position-shaped fields stay at their documented defaults. The stage
//      supplies no meaningful query seed, and this is what stops that seed
//      from being published as if it were a measurement.
//
// The fixture is three collinear vertices with NO faces (so `needVis` is false
// and ranking is pure screen distance) and a single enabled type, so the whole
// packet is decided by one candidate walk with no grid / workplane traffic.
// ---------------------------------------------------------------------------
unittest {
    import math             : Vec3, Viewport, lookAt, perspectiveMatrix,
                              projectToWindowFull;
    import mesh             : Mesh;
    import toolpipe.packets : SubjectPacket;
    import snap             : snapCursor, SnapResult, invalidateSnapGrids;
    import editmode         : EditMode;
    import std.math         : PI, round, sqrt;

    // snap.d's global candidate grids are keyed by (mesh address, mutation
    // version, viewport); a fresh stack Mesh can land on a recycled address
    // with the same zero version, so drop them rather than trust the key.
    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    m.vertices = [
        Vec3(0.00f, 0, 0),   // 0 — directly under the cursor pixel
        Vec3(0.50f, 0, 0),   // 1 — inside the gather range, outside acceptance
        Vec3(3.00f, 0, 0),   // 2 — outside the gather range entirely
    ];

    float pixDist(Vec3 w, int sx, int sy) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every candidate must project on-screen");
        immutable float dx = qx - cast(float)sx;
        immutable float dy = qy - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    // Cursor A: vertex 0's own pixel — a snap. Cursor B: 50 px to its LEFT,
    // away from the other two — inside the gather range, outside acceptance,
    // i.e. a highlight without a snap.
    float p0x, p0y, p0z;
    assert(projectToWindowFull(m.vertices[0], vp, p0x, p0y, p0z));
    immutable int ax = cast(int)round(p0x), ay = cast(int)round(p0y);
    immutable int bx = ax - 50,             by = ay;

    auto st = new SnapStage();
    st.enabled      = true;
    st.enabledTypes = SnapType.Vertex;   // one type: no grid / workplane traffic
    st.innerRangePx = 20.0f;
    st.outerRangePx = 120.0f;

    // Fixture premises, stated rather than assumed.
    assert(pixDist(m.vertices[0], ax, ay) < st.innerRangePx,
        "fixture: vertex 0 must be inside acceptance at cursor A");
    assert(pixDist(m.vertices[1], ax, ay) > st.innerRangePx,
        "fixture: vertex 1 must not be able to snap at cursor A");
    assert(pixDist(m.vertices[2], ax, ay) > st.outerRangePx,
        "fixture: vertex 2 must be out of the gather range");
    assert(pixDist(m.vertices[0], bx, by) > st.innerRangePx
        && pixDist(m.vertices[0], bx, by) < st.outerRangePx,
        "fixture: at cursor B vertex 0 must highlight but not snap");
    assert(pixDist(m.vertices[1], bx, by) > pixDist(m.vertices[0], bx, by),
        "fixture: cursor B must leave vertex 0 the winner");

    // Build the stack the mouse-event dispatch builds, minus the cursor flag.
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.editMode = EditMode.Vertices;
    subj.viewport = vp;

    // --- 1. GATE: no cursor, no packet --------------------------------------
    {
        VectorStack vts;
        vts.put(&subj);              // cursorValid stays false
        assert(st.evaluate(vts), "the stage is enabled, so it must publish its config");
        assert(vts.get!SnapPacket() !is null, "the CONFIG packet is unconditional");
        assert(vts.get!SnapHitPacket() is null,
            "S2 gate: without `cursorValid` the stage must not run the query — "
            ~ "that flag is what keeps the process-global candidate grids on "
            ~ "the main thread");
    }

    subj.cursorX     = ax;
    subj.cursorY     = ay;
    subj.cursorValid = true;

    // --- ...and no packet at all while the stage is disabled ----------------
    {
        st.enabled = false;
        VectorStack vts;
        vts.put(&subj);
        assert(!st.evaluate(vts), "a disabled stage publishes nothing");
        assert(vts.get!SnapHitPacket() is null,
            "S2 gate: a disabled SNAP stage must not publish a result either");
        st.enabled = true;
    }

    // --- 2. EQUIVALENCE: the packet IS the query's own answer ---------------
    invalidateSnapGrids();
    SnapHitPacket hit;
    SnapPacket    cfg;
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null, "S2: a cursor-valid evaluation must publish the result");
        hit = *p;
        cfg = *vts.get!SnapPacket();
    }

    // The reference: the same query every existing consumer runs for itself,
    // with the config the stage just published. The seed is deliberately a
    // position no candidate sits at — if the packet ever started reporting the
    // seed, the assertions below would see it.
    invalidateSnapGrids();
    immutable Vec3 probeSeed = Vec3(7.5f, -3.25f, 1.125f);
    SnapResult ref_ = snapCursor(probeSeed, ax, ay, vp, m, cfg);
    assert(ref_.snapped && ref_.targetIndex == 0 && ref_.targetType == SnapType.Vertex,
        "fixture: the reference query must snap to vertex 0, else the "
        ~ "equivalence below is vacuous");

    assert(hit.snapped      == ref_.snapped,      "snapped diverged");
    assert(hit.highlighted  == ref_.highlighted,  "highlighted diverged");
    assert(hit.targetType   == ref_.targetType,   "targetType diverged");
    assert(hit.targetIndex  == ref_.targetIndex,  "targetIndex diverged");
    assert(hit.targetSource == ref_.targetSource, "targetSource diverged");
    assert(hit.worldPos.x == ref_.worldPos.x
        && hit.worldPos.y == ref_.worldPos.y
        && hit.worldPos.z == ref_.worldPos.z,
        "S2 equivalence: the published position must be the query's own, "
        ~ "bit for bit — not a re-derivation of it");
    assert(hit.layer == -1,
        "the winner came from the active mesh (slot 0), whose Document-layer "
        ~ "index the snap service does not hold");

    // --- 3. DERIVATION: the screen point is the WINNER's own pixel ----------
    float wx, wy, wz;
    assert(projectToWindowFull(m.vertices[0], vp, wx, wy, wz));
    assert(hit.screenX == wx && hit.screenY == wy,
        "S2: screenX/screenY are the snapped point's projection, so they must "
        ~ "equal an independent projection of the winning vertex");
    assert(hit.distPx == pixDist(m.vertices[0], ax, ay),
        "S2: distPx is that projection's distance from the cursor pixel — the "
        ~ "very number the candidate walk ranked by");
    assert(hit.distPx <= cfg.innerRangePx,
        "a snap by definition landed inside acceptance");

    // --- 4. CONTRACT: highlight without snap publishes no position ----------
    // Cursor B is inside the gather range of vertex 0 and outside acceptance:
    // the element is still named, the position-shaped fields are not.
    subj.cursorX = bx;
    subj.cursorY = by;
    invalidateSnapGrids();
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null,
            "S2: publication is gated on the CURSOR, not on the outcome — a "
            ~ "query that only highlighted still ran, and still publishes");
        assert(!p.snapped && p.highlighted,
            "fixture: cursor B must highlight vertex 0 without snapping to it");
        assert(p.targetIndex == 0 && p.targetType == SnapType.Vertex,
            "a highlight still names its element");
        assert(p.worldPos.x == 0 && p.worldPos.y == 0 && p.worldPos.z == 0,
            "S2 contract: nothing snapped, so no position is published — the "
            ~ "stage's query seed must never reach the wire");
        assert(p.distPx == float.infinity && p.screenX == 0 && p.screenY == 0,
            "S2 contract: the screen fields are paired with `snapped`");
    }

    // --- ...and an outright miss is the packet's own `.init` -----------------
    subj.cursorX = 5;
    subj.cursorY = 5;      // a corner pixel: every candidate is far away
    invalidateSnapGrids();
    {
        VectorStack vts;
        vts.put(&subj);
        assert(st.evaluate(vts));
        auto p = vts.get!SnapHitPacket();
        assert(p !is null,
            "a miss still publishes: an ABSENT packet means the query did not "
            ~ "run, a published one with `snapped == false` means it found "
            ~ "nothing, and downstream must be able to tell those apart");
        assert(*p == SnapHitPacket.init,
            "S2 contract: a miss is the packet's own defaults, field for field");
    }

    invalidateSnapGrids();
}
