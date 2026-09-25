module tools.slice.edge_slice_tool;
import display_state : DrawPlan;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : round;
import ImGui = d_imgui;
import d_imgui.imgui_h;   // ImDrawList / ImVec2 / IM_COL32 for the `t = %` HUD

import operator : VectorStack;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import hover_state : g_hoveredEdge, g_hoverIndexSpaceStale, TargetHighlightKeeper;
import shader : Shader, LitShader;
import command_history : CommandHistory, PreparedHistoryKind;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import tools.common.session_mesh_key : SessionMeshKey;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, ToolHandles, gizmoSize, getGizmoPixels;
import viewport_scheme : schemeColor, SchemeColor;
import document : Layer, primaryModelSpace;
import overlay_space : OverlaySpace;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedNamedGpuParamDoorClient;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedDeactivateEffect, PreparedDeactivateKind, PreparedEdgeSliceParamEffect,
    PreparedEdgeSliceParamKind;
import prepared_edge_slice_activation : PreparedEdgeSliceActivationOwner;
import prepared_edge_slice_deactivate : PreparedEdgeSliceDeactivateOwner;
import prepared_edge_slice_param_update : PreparedEdgeSliceParamUpdateOwner;
import mesh_gpu : GpuUploadOwner;
import symmetry : mirrorEdgePoint;
import toolpipe.packets : SymmetryPacket;
import handler : BoxHandlerBatchResourceOwner;

// (m0, m1): the point's mirror edge under the symmetry that was live when it
// latched (`mirrorEdgePoint`), or ~0u, in the mesh edge's stored order like
// (v0, v1); `mflip` when that order reverses the mirror of (v0, v1), so the
// mirror point sits at `1 - t` along it. Every chain follows the measured
// ownership law (C1-sym-own / C1-own-off, gap rows 290 and 314): a point is
// owned where it was CLICKED, in BASE-mesh terms, whichever side made the edge;
// its base polygons are located at every bake from its effective position
// (`locateBase`). `facePoint` / `latchFaces` are the latch-time answer: the
// first for introspection, the second to park a point whose indices a re-bake
// re-used for something else (see `pointRail`).
private struct EdgeSliceChainPoint {
    uint v0, v1; float t;
    uint m0 = ~0u, m1 = ~0u; bool mflip;
    bool facePoint;
    uint[] latchFaces;
}

struct PreparedEdgeSliceActivationImage {
    bool valid;
    void clear() nothrow @nogc { valid = false; }
}

struct PreparedEdgeSliceDeactivateImage {
    bool valid, expectedActive, expectedArmed, expectedScrubbing, expectedBuilt;
    int expectedPhase, expectedDragPart, expectedActivePoint;
    SessionMeshKey expectedArmedKey;
    uint[] expectedEdges, expectedPointVerts; float[] expectedPointT;
    MeshSnapshot expectedLive, expectedBefore;
    Mesh candidate; uint deliveryFlags, deliveryDomains;
    bool appliesMesh, historyEligible, carrierMismatch;
    void clear() nothrow @nogc {
        valid = appliesMesh = historyEligible = carrierMismatch = false;
        expectedEdges = null; expectedPointVerts = null; expectedPointT = null;
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        candidate = Mesh.init;
        deliveryFlags = deliveryDomains = 0;
    }
}

struct PreparedEdgeSliceParamImage {
    bool valid, recognized, appliesState, appliesMesh, invalidateRedo;
    string pname;
    bool expectedActive, expectedArmed, expectedScrubbing, expectedBuilt;
    int expectedPhase, expectedDragPart, expectedActivePoint;
    SessionMeshKey expectedArmedKey;
    bool expectedSplit, expectedMiddle; float expectedSnap, expectedProxy;
    float expectedTA, expectedTB;
    uint[] expectedEdges, expectedPointVerts; float[] expectedPointT;
    MeshSnapshot expectedLive, expectedBefore;
    bool nextArmed, nextScrubbing, nextBuilt;
    int nextPhase, nextDragPart, nextActivePoint;
    SessionMeshKey nextArmedKey; float nextProxy;
    uint[] nextEdges, nextPointVerts; float[] nextPointT;
    private EdgeSliceChainPoint[] nextChainPoints;
    private size_t nextMirrorSegments; private bool[] nextParked;
    Mesh candidate; uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        valid = recognized = appliesState = appliesMesh = invalidateRedo = false;
        pname = null;
        expectedEdges = null; expectedPointVerts = null; expectedPointT = null;
        nextEdges = null; nextPointVerts = null; nextPointT = null;
        nextChainPoints = null; nextMirrorSegments = 0; nextParked = null;
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        candidate = Mesh.init; deliveryFlags = deliveryDomains = 0;
    }
}

/// The `t = %` HUD readout string — mirrors `loopSliceHudLabel`
/// (loop_slice_tool.d) so both slice-family tools print the same shape.
string edgeSliceHudLabel(float t) {
    import std.format : format;
    return format("%.2f %%", t * 100.0f);
}


private Vec3 lerpVec3(Vec3 a, Vec3 b, float t) {
    return a + (b - a) * t;
}

// Edge Slice's base-mesh ownership (C1-sym-own / C1-own-off, gap rows 290/314);
// module-level so tests/unit/edge_slice_locate_base_test.d drives them.
// The BASE-mesh polygons point `q` lies in: the faces of the base edge it
// is on (all faces of a base vertex at an edge end), else the one base
// polygon it is inside (`facePoint`). Tolerances are relative to the edge
// or polygon size; a polygon is tested in its Newell plane, so a point on
// a chord of a WARPED polygon is still inside it.
uint[] locateBase(const Vec3[] vs, const uint[2][] es, const uint[][] fs,
                  Vec3 q, out bool facePoint) {
    import std.math : abs, sqrt;
    facePoint = false;
    uint[] faces;
    foreach (e; es) {
        const a = vs[e[0]], b = vs[e[1]];
        const ab = b - a;
        const len2 = dot(ab, ab);
        if (len2 <= 1e-20f) continue;
        const len = sqrt(len2);
        const s = dot(q - a, ab) / len2;
        if (s < -1e-4f || s > 1.0f + 1e-4f) continue;
        if ((a + ab * s - q).length() > 1e-4f * len) continue;
        const atA = s <= 1e-4f, atB = s >= 1.0f - 1e-4f;
        foreach (fi, f; fs) {
            bool hasA, hasB;
            foreach (v; f) { if (v == e[0]) hasA = true; if (v == e[1]) hasB = true; }
            if ((atA && hasA) || (atB && hasB) || (hasA && hasB)) faces ~= cast(uint)fi;
        }
        return faces;
    }
    facePoint = true;
    float best = float.infinity;
    foreach (fi, f; fs) {
        float d;
        if (pointInPolygon(q, vs, f, d) && d < best) { best = d; faces = [cast(uint)fi]; }
    }
    return faces;
}

// `q` inside polygon `f`, tested in the polygon's Newell plane: within the
// polygon's own warp of that plane (plus a size-relative slack), and inside
// its outline projected there (crossing number). `dist`: the plane distance.
bool pointInPolygon(Vec3 q, const Vec3[] vs, const uint[] f, out float dist) {
    import std.math : abs, sqrt;
    dist = float.infinity;
    if (f.length < 3) return false;
    Vec3 n = Vec3(0, 0, 0), c = Vec3(0, 0, 0);
    float size = 0;
    foreach (i, vi; f) {
        const p0 = vs[vi], p1 = vs[f[(i + 1) % f.length]];
        n.x += (p0.y - p1.y) * (p0.z + p1.z);
        n.y += (p0.z - p1.z) * (p0.x + p1.x);
        n.z += (p0.x - p1.x) * (p0.y + p1.y);
        c = c + p0;
        const l = (p1 - p0).length();
        if (l > size) size = l;
    }
    const nl = n.length();
    if (nl <= 1e-20f || size <= 0) return false;
    n = n * (1.0f / nl);
    c = c * (1.0f / f.length);
    float warp = 0;
    foreach (vi; f) { const w = abs(dot(vs[vi] - c, n)); if (w > warp) warp = w; }
    dist = abs(dot(q - c, n));
    if (dist > warp + 1e-4f * size) return false;
    // A 2D frame in the plane.
    Vec3 u = abs(n.x) < 0.9f ? cross(n, Vec3(1, 0, 0)) : cross(n, Vec3(0, 1, 0));
    u = u * (1.0f / u.length());
    const w = cross(n, u);
    const qx = dot(q - c, u), qy = dot(q - c, w);
    bool inside;
    foreach (i, vi; f) {
        const a = vs[vi] - c, b = vs[f[(i + 1) % f.length]] - c;
        const ax = dot(a, u), ay = dot(a, w), bx = dot(b, u), by = dot(b, w);
        if ((ay > qy) != (by > qy) && qx < ax + (qy - ay) * (bx - ax) / (by - ay))
            inside = !inside;
    }
    return inside;
}

// ---------------------------------------------------------------------------
// EdgeSliceTool — interactive N-cut chain (factory id `mesh.edgeSliceTool`),
// driving the EXISTING `Mesh.edgeSliceEx(edgeA, edgeB, tA, tB, splitPolygons)`
// kernel unchanged. Coexists with the one-shot `mesh.edgeSlice` command
// (source/commands/mesh/edge_slice.d) — untouched.
//
// Gesture (task 0295, F2 — supersedes the two-edge-only v1 model): hover an
// edge (HoverEdges capability) -> click LATCHES a chain point (edge + `t`
// derived from the click's projection) -> drag scrubs that point's `t` while
// the mouse is held -> click a second, DISTINCT edge latches a second point
// and immediately materialises a live preview cut on the real mesh
// (mutate/revert, non-cumulative) -> a THIRD+ click EXTENDS the chain (does
// NOT commit-and-reseed — the v1 behaviour this replaces): each new point
// slices a strip from the previous point's exact cut vertex to the new one,
// via the SAME `Mesh.edgeSliceEx`. The whole chain stands as ONE uncommitted
// preview across frames until Enter / tool-drop, which commits every latched
// segment as ONE undo entry.
//
// F1 (task 0295): a click landing at t=0/1 (an edge endpoint) is a valid
// cut — the kernel reuses the existing corner vertex instead of inserting a
// coincident one (see `insertEdgePoint`, mesh.d). This is also the mechanism
// that lets a chain segment continue exactly from the previous segment's
// shared cut vertex (`pickSeedSubEdge` below).
//
// Headless (`tool.set mesh.edgeSliceTool on; tool.attr ... edges [e0,e1,...];
// ...; tool.doApply`) reads `edgesParam_`/`tA_`/`tB_`/`split_` directly and
// NEVER touches `armed_`/`scrubbing_`/session state — `ToolDoApplyCommand`
// wraps its own snapshot pair around `applyHeadless()`. A deterministic
// `chainArm` trigger param (picker-free) arms the SAME chain state a click
// sequence would produce, without committing, so a synthetic Enter / tool-off
// can exercise the real interactive commit path in a test.
// ---------------------------------------------------------------------------
// Session (tool session model, slice M3): the chain IS the tool's attribute
// image — `chain` (a PodArray over `latchedPoints_`), `edges`, `activePoint` —
// and the SESSION owns its gesture steps (each latch, re-pick drag or Middle
// boundary is one), their redo, and the first point's group with the
// activation row it joins. The tool reports its step boundaries and rebuilds
// its preview from the image (`rebuildPreviewFromAttrs`).
final class EdgeSliceTool : Tool, TargetHighlightKeeper,
                            PreparedToolDoorClient, PreparedToolParamDoorClient {
    mixin PreparedNamedGpuParamDoorClient;
public:
    enum Show { None, Position }

    static immutable IntEnumEntry[2] showTable = [
        IntEnumEntry(cast(int)Show.None,     "none",     "None"),
        IntEnumEntry(cast(int)Show.Position, "position", "Position"),
    ];

    enum Phase { Idle, EdgeA, EdgeB }

    // A latched chain click: the edge's endpoint VERTEX PAIR (stable across
    // an intervening edgeSliceEx's rebuildEdges() — vertex indices only ever
    // grow, mesh.d:10445) plus a click `t`. The live edge is re-resolved each
    // bake via `Mesh.edgeIndexOf(v0, v1)`.
    //
    // S2: `t`'s meaning differs by producer — `tFromLocalRailClick`
    // (interactive latch/scrub path) already returns `effectiveT(raw)`, so `t` here is the
    // EFFECTIVE value; `pointsFromEdgesParam` (headless `edges`-param path)
    // stores the RAW panel value (`tA_`/`tB_`/0.5f interior) straight through,
    // unconverted. Both `bakeChainFrom` and `chainPointPos` re-apply
    // `effectiveT(p.t)` unconditionally, which is safe for the
    // already-effective interactive case ONLY because `effectiveT` is
    // idempotent (re-clamping/re-snapping/re-forcing-to-middle an already
    // effective value reproduces it) — so the double application never
    // changes the interactive path's result.
    private alias ChainPoint = EdgeSliceChainPoint;

private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;


    // Panel params (sticky — NOT reset by reinitSession/activate, matching
    // Slice/Loop-Slice's other tool options).
    bool  split_  = true;
    bool  middle_ = false;
    float snap_   = 0.5f;
    Show  show_   = Show.Position;

    // Headless "edges" param (IntArray) — the ordered chain edge list.
    // Kept in sync with latchedPoints_ by the interactive latch so the two
    // paths converge on the same kernel calls.
    uint[] edgesParam_;

    // Deterministic commit driver (task 0295, F2, objection 2 — picker-free
    // test coverage of commitChain/deactivate-commit). Its VALUE is unused —
    // writing it is purely a trigger; onParamChanged("chainArm") reads
    // edgesParam_ fresh and arms the chain it describes without committing.
    uint[] chainArm_;

    // Confirmed chain points — advances ONLY at click-latch (or chainArm),
    // clears ONLY at commit/cancel. NEVER mutated by preview rebuilds.
    ChainPoint[]  latchedPoints_;
    MeshSnapshot  chainBefore_;   // the ONE undo baseline for the whole chain

    // Headless-only "first t" / "last t" (interior points default to 0.5 —
    // a deliberate v1 surface limitation, see pointsFromEdgesParam). Also
    // double as panel params for the LAST interactively-latched point's
    // scrub display (see onMouseMotion).
    float tA_ = 0.5f;
    float tB_ = 0.5f;
    Phase phase_ = Phase.Idle;

    // Session state (mirrors LoopSliceTool's Model B: arm-then-commit
    // standing preview), generalised from a single pair to an N-point chain.
    bool         active;
    bool         armed_;       // >=2 points latched -> a standing preview sits on the real mesh
    bool         scrubbing_;   // the last latched point's `t` is being dragged
    bool         built_;       // true once the last bake actually produced a cut
    // Segments the LAST interactive bake produced (test introspection,
    // `bakedSegments`), so a silently dropped segment shows as fewer than
    // `latchedPoints_.length - 1`. Written by `rebuildPreview` and `armChain`,
    // cleared when the armed preview is dropped; the prepared paths and the activation
    // resets never differ from it (a tool is built fresh per activation), so
    // they do not write it (task 7114).
    size_t       lastBakedSegments_;
    size_t       lastMirrorSegments_;   // the mirror chain's count, same bake
    bool[]       parked_;               // per point, same bake: its rail was not remade (`pointRail`)
    int          dragPart_ = -1;
    // IDENTITY guard, asked between mouse events: "is the baseline I armed
    // still on the mesh I armed it on?". It keys on TOPOLOGY + address + the
    // vertex/face counts (`SessionMeshKey`), never on `mutationVersion`: a
    // live subpatch preview publishes `Position` on this mesh every refresh
    // frame, and a position-keyed guard dropped the chain between two clicks,
    // leaving the cut on the mesh with no history row (task 7112, items
    // 21/23/24; see `tools/common/session_mesh_key.d`).
    SessionMeshKey armedKey_;  // mesh identity guard (scene reset / item-selection change)
    // The WORLD-space viewport `draw()` was handed (task 0619 rename). All
    // five uses were re-read and classified:
    //   * `tFromLocalRailClick` — the **Closest** aiming kind (§1.3), which
    //     runs its election in WORLD space and therefore wants exactly this,
    //     un-composed, with the rail lifted to meet it.
    //   * `toolHandlesJson` / `toolHandles_.test` — the handle bank, and it
    //     wants exactly this world viewport, because task 0645 lifted the
    //     bank's POSITIONS instead. Its positions came from `chainPointPos`
    //     (LOCAL) and were DRAWN with this same world viewport: draw and
    //     hit-test agreed with each OTHER while both sat where the geometry
    //     would be at the identity pose, and converting only one of them
    //     would have broken the one property that worked. `draw()` now lifts
    //     every handle position through `OverlaySpace` once, which moves the
    //     drawing and the hit-testing together because they read the same
    //     `handles_[]` objects.
    //   * the `draw()` write itself.
    // `drawHud` is the one use that needed the AIMING space instead; it now
    // builds its own via `aimSpace` and does not read this field.
    Viewport     vpWorld_;

    // Active-point index (task 0321, D2) — which `latchedPoints_[]` entry a
    // scrub/drag or a numeric `activePoint`/`pointT` panel edit targets. Set
    // by every latch producer (latchFirstPoint/appendPoint/armChain) to the
    // point it just latched, and by a re-pick press (onMouseButtonDown, D3)
    // to whichever earlier handle was grabbed. `pointProxy_` is the
    // Param-bound mirror of `latchedPoints_[activePoint_].t`, exactly
    // LoopSliceTool's `positionProxy_` <-> `positions_[current_]` pattern.
    int          activePoint_ = -1;
    float        pointProxy_  = 0.5f;

    // Cut-point handles (lazily built inside a live GL context) — one per
    // latched point.
    BoxHandler[] handles_;
    ToolHandles  toolHandles_;
    version(unittest) bool suppressRefreshForTest_;

    enum float HANDLE_HALF_PX = 5.0f;
    enum Vec3  HANDLE_COLOR = schemeColor(SchemeColor.toolPath);

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
    }

    override string name() const { return "Edge Slice"; }

    // Its arm is the activation row the first-gesture undo pops (§22).
    // A recording command through the UI door closes its live operation first
    // and the tool stays (slice M2; captured C1-h-sel-fam, K-commit). Slice M3:
    // its session owns the steps (H2), the window opens at the first press
    // (C-H1-es), and a Middle press is a boundary without a clone (the static
    // no-clone flag, C-H5-es-mmb). `pointT` is a proxy (`syncProxy`), not part
    // of the image.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, commandClose: CommandClose.uiDoor,
            sessionSteps: true, opensAt: OpensAt.firstPress, noClone: true,
            imageAttrs: ["chain", "edges", "activePoint"],
            haulAttrs: ["chain", "edges", "activePoint"] };
        return policy;
    }

    /// The kernel-side cap of the chain (slice M3, R4.3): a vibe3d budget,
    /// not a captured law. A latch past it is refused; the `chain` Param is
    /// not injectable, so no other route can grow it.
    enum size_t kMaxEdgeSliceChainPoints = 4096;

    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    // HoverEdges: needed so app.d's picker keeps writing g_hoveredEdge while
    // this tool owns the viewport (pickEdges() gates on wantsHoverForType).
    override ToolFlag flags() const { return ToolFlag.HoverEdges; }

    // Freezes the hover pick during a scrub — only the latched edge stays
    // highlighted while its `t` is being dragged.
    override bool isDragging() const { return scrubbing_; }

    override Param[] params() {
        return [
            Param.intArray_("edges", "Edges", &edgesParam_).transient(),
            Param.intArray_("chainArm", "Chain Arm", &chainArm_).transient().action(),
            Param.podArray_("chain", "Chain", &latchedPoints_),
            Param.float_("tA", "t on Edge A", &tA_, 0.5f).min(0.0f).max(1.0f).transient(),
            Param.float_("tB", "t on Edge B", &tB_, 0.5f).min(0.0f).max(1.0f).transient(),
            // Active-point index + numeric edit (task 0321, D2) — re-targets
            // any already-latched chain point (not just the tail) for a
            // panel-driven `t` edit; also the picker-free test driver for the
            // re-pick+drag gesture (D3).
            Param.int_("activePoint", "Active Point", &activePoint_, -1).transient(),
            Param.float_("pointT", "Point t", &pointProxy_, 0.5f).min(0.0f).max(1.0f).transient(),
            Param.bool_("split", "Split Polygons", &split_, true),
            Param.bool_("middle", "Split at Middle", &middle_, false),
            Param.float_("snap", "Snap Value", &snap_, 0.5f).min(0.0f),
            Param.intEnum_("show", "Show", cast(int*)&show_, showTable, cast(int)Show.Position),
        ];
    }

    // Pure `t` law shared by BOTH the interactive scrub (tFromLocalRailClick) and the
    // headless path (applyHeadless) so they never diverge: Split at Middle
    // forces 0.5 first, then Snap Value quantizes, then clamp to the closed
    // unit interval. task 0295 F1: the clamp is CLOSED ([0,1]) — t==0/1 is a
    // valid endpoint cut (the kernel reuses the corner instead of inserting a
    // coincident vertex there), so it no longer needs the open-interval
    // buffer the pre-F1 tool used.
    public float effectiveT(float raw) const {
        float t = middle_ ? 0.5f : raw;
        if (snap_ > 0.0f) {
            float step = snap_ / 100.0f;
            t = round(t / step) * step;
        }
        if (t < 0.0f) t = 0.0f;
        if (t > 1.0f) t = 1.0f;
        return t;
    }

    // Test-introspection (GET /api/tool/state) — mirrors LoopSliceTool.toolStateJson.
    // edgeA/tA report the FIRST latched point, edgeB/tB the LAST — so a
    // replay test can assert chain growth (edgeB advances with every click;
    // edgeA is stable since the chain's first point is never re-cut).
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("edgeSlice");
        root["hoveredEdge"] = JSONValue(g_hoveredEdge);

        int   edgeAOut = -1, edgeBOut = -1;
        float tAOut = 0.5f, tBOut = 0.5f;
        if (latchedPoints_.length > 0) {
            auto first = latchedPoints_[0];
            auto last  = latchedPoints_[$ - 1];
            edgeAOut = cast(int)(*mesh).edgeIndexOf(first.v0, first.v1);
            edgeBOut = cast(int)(*mesh).edgeIndexOf(last.v0, last.v1);
            tAOut    = effectiveT(first.t);
            tBOut    = effectiveT(last.t);
        }
        root["edgeA"] = JSONValue(edgeAOut);
        root["edgeB"] = JSONValue(edgeBOut);
        root["tA"]    = JSONValue(tAOut);
        root["tB"]    = JSONValue(tBOut);
        final switch (phase_) {
            case Phase.Idle:  root["phase"] = JSONValue("idle");  break;
            case Phase.EdgeA: root["phase"] = JSONValue("edgeA"); break;
            case Phase.EdgeB: root["phase"] = JSONValue("edgeB"); break;
        }
        root["armed"]  = JSONValue(armed_);
        root["built"]  = JSONValue(built_);
        root["activePoint"] = JSONValue(activePoint_);
        root["pointT"]      = JSONValue(pointProxy_);
        root["split"]  = JSONValue(split_);
        root["middle"] = JSONValue(middle_);
        root["snap"]   = JSONValue(snap_);
        root["show"]   = JSONValue(wireTagForValue(showTable, cast(int)show_));
        // Pure derivation (NOT a counter) — the number of BAKED segments the
        // current latched chain describes.
        root["chainSegments"] = JSONValue(
            latchedPoints_.length >= 1 ? cast(long)(latchedPoints_.length - 1) : 0L);
        // Pure derivation: each latched point's stored vertex pair,
        // in chain order. Unlike edgeA/edgeB it does not re-resolve through
        // the (already cut) live mesh, so it stays readable under a standing
        // preview.
        auto pairs = JSONValue.emptyArray;
        foreach (p; latchedPoints_)
            pairs.array ~= JSONValue([JSONValue(p.v0), JSONValue(p.v1)]);
        root["latchedPairs"] = pairs;
        // Task 7137: each point's `t` in chain order, and whether the active
        // point follows the mouse (the released state a redo re-arm leaves).
        auto ts = JSONValue.emptyArray;
        foreach (p; latchedPoints_) ts.array ~= JSONValue(p.t);
        root["latchedT"]  = ts;
        root["scrubbing"] = JSONValue(scrubbing_);
        // A counter, unlike `chainSegments`: what the last bake returned.
        root["bakedSegments"] = JSONValue(cast(long)lastBakedSegments_);
        root["mirrorBakedSegments"] = JSONValue(cast(long)lastMirrorSegments_);
        auto fp = JSONValue.emptyArray, pk = JSONValue.emptyArray;
        foreach (i, p; latchedPoints_) {
            Vec3 ra, rb;
            fp.array ~= JSONValue(p.facePoint);
            pk.array ~= JSONValue(!liveRail(i, ra, rb));
        }
        root["latchedFacePoint"] = fp;
        root["latchedParked"] = pk;
        return root;
    }

    // Test-introspection (GET /api/tool/handles) — one part per latched point
    // (see draw()).
    override JSONValue toolHandlesJson() const {
        return toolHandles_ is null ? JSONValue(null) : toolHandles_.toJson(vpWorld_);
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    final PreparedEdgeSliceActivationImage buildPreparedActivation()
            nothrow @nogc {
        return PreparedEdgeSliceActivationImage(true);
    }
    final void installPreparedActivation(
            ref PreparedEdgeSliceActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; armed_ = false; scrubbing_ = false; built_ = false;
        phase_ = Phase.Idle; latchedPoints_ = []; edgesParam_ = [];
        parked_ = null;
        dragPart_ = -1; activePoint_ = -1;
        armedKey_ = SessionMeshKey.init; chainBefore_ = MeshSnapshot.init;
        image.clear();
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.EdgeSlice, false);
        scope(failure) context.discard();
        auto owner = PreparedEdgeSliceActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareEdgeSliceActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.EdgeSlice, ok);
    }

    private void reinitSession() {
        armed_      = false;
        scrubbing_  = false;
        built_      = false;
        phase_      = Phase.Idle;
        latchedPoints_ = [];
        parked_ = null;
        edgesParam_    = [];
        dragPart_   = -1;
        activePoint_ = -1;
        // split_/middle_/snap_/show_ deliberately NOT reset — sticky tool
        // options, matching Slice's other panel settings (Loop-Slice, unlike
        // Slice, DOES reset its own options in reinitSession — not the
        // analogue here).
        armedKey_.invalidate();
        chainBefore_ = MeshSnapshot.init;
    }

    // The command close (slice M2): the Enter body — a chain of >= 2 points
    // is committed as one row, a lone point cancels (`commitChain`'s own
    // rule) — and the tool stays armed with nothing latched.
    override bool commitOperation() {
        if (!active) return false;
        commitChain();
        return true;
    }

    override void deactivate() {
        // A chain of >=2 latched points is a deliberate placement — commit it
        // on tool-drop, same as Loop Slice. A lone latched point (or none)
        // has nothing worth keeping, so it cancels instead.
        if (active) {
            if (latchedPoints_.length >= 2) commitChain();
            else                            cancelLiveEdit();
        }
        active = false;
        dropArmedPreview();
        // Release the cut-point handles' GL objects (VAO+VBO each) — a fresh
        // tool instance is built per activation, so without this every
        // activate->draw->deactivate cycle leaks a VAO+VBO per handle.
        foreach (h; handles_) if (h !is null) h.destroy();
        handles_ = [];
    }

    final PreparedEdgeSliceDeactivateImage buildPreparedDeactivateState(
            ref Mesh live) {
        PreparedEdgeSliceDeactivateImage image; image.valid = true;
        image.expectedActive = active; image.expectedArmed = armed_;
        image.expectedScrubbing = scrubbing_; image.expectedBuilt = built_;
        image.expectedPhase = cast(int)phase_; image.expectedDragPart = dragPart_;
        image.expectedActivePoint = activePoint_; image.expectedArmedKey = armedKey_;
        image.expectedEdges = edgesParam_.dup;
        image.expectedPointVerts.length = latchedPoints_.length * 2;
        image.expectedPointT.length = latchedPoints_.length;
        foreach (i, p; latchedPoints_) {
            image.expectedPointVerts[i * 2] = p.v0;
            image.expectedPointVerts[i * 2 + 1] = p.v1;
            image.expectedPointT[i] = p.t;
        }
        image.expectedLive = MeshSnapshot.capture(live);
        image.expectedBefore = chainBefore_;
        if (!active) return image;
        const identityCurrent = armedKey_.matches(live) && chainBefore_.filled;
        if (latchedPoints_.length >= 2 && identityCurrent && history !is null &&
                gestureFactory !is null) {
            image.candidate = detachedPreparedMesh(live);
            auto shadow = beginPreparedShadow(image.candidate);
            const n = bakeChainInto(image.candidate, image.expectedBefore,
                latchedPoints_);
            // Even a zero-segment result has restored the activation baseline;
            // legacy commitChain then runs cancelLiveEdit and keeps that restore.
            image.appliesMesh = true;
            image.historyEligible = n > 0;
            drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
                image.deliveryDomains); shadow.close();
        } else if (latchedPoints_.length < 2 && identityCurrent) {
            image.candidate = detachedPreparedMesh(live);
            auto shadow = beginPreparedShadow(image.candidate);
            image.expectedBefore.restore(image.candidate);
            drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
                image.deliveryDomains); shadow.close(); image.appliesMesh = true;
        }
        return image;
    }

    final bool preparedDeactivateStateMatches(
            in PreparedEdgeSliceDeactivateImage image, ref const Mesh live) const
            nothrow @nogc {
        if (!image.valid || active != image.expectedActive || armed_ != image.expectedArmed ||
            scrubbing_ != image.expectedScrubbing || built_ != image.expectedBuilt ||
            cast(int)phase_ != image.expectedPhase || dragPart_ != image.expectedDragPart ||
            activePoint_ != image.expectedActivePoint || armedKey_ != image.expectedArmedKey ||
            edgesParam_ != image.expectedEdges ||
            latchedPoints_.length != image.expectedPointT.length ||
            !image.expectedLive.matches(live) || !image.expectedBefore.matches(chainBefore_)) return false;
        foreach (i, p; latchedPoints_)
            if (p.v0 != image.expectedPointVerts[i * 2] ||
                p.v1 != image.expectedPointVerts[i * 2 + 1] || p.t != image.expectedPointT[i])
                return false;
        return true;
    }

    final void installPreparedDeactivateState(
            ref PreparedEdgeSliceDeactivateImage image) nothrow @nogc {
        if (!image.valid) return;
        active = false; armed_ = false; scrubbing_ = false; built_ = false;
        phase_ = Phase.Idle; latchedPoints_ = null; edgesParam_ = null;
        parked_ = null;
        dragPart_ = -1; activePoint_ = -1; armedKey_ = SessionMeshKey.init;
        chainBefore_ = MeshSnapshot.init; handles_ = null; image.clear();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context,
            Layer layer, GpuUploadOwner uploadOwner,
            BoxHandlerBatchResourceOwner handlerDestroy) {
        if (context is null) return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.EdgeSlice, false, false);
        scope(failure) context.discard();
        auto owner = PreparedEdgeSliceDeactivateOwner.prepare(this, layer);
        bool ok = owner !is null;
        // Under a live subpatch preview the cage upload is suppressed and a
        // prepared upload without origin maps is REFUSED
        // (`GpuUploadOwner.beginPreparedUpload`), which refused the whole
        // tool switch and left the chain live under later rows (task 7114,
        // item 8). There the display follows the delivery of the installed
        // mesh image instead, as the legacy commit's `refreshDisplay` did.
        if (ok && owner.appliesMesh)
            ok = owner.deliveryFlags != 0 && uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains) &&
                (gpu.suppressCageUpload || context.prepareUpload(uploadOwner, owner.candidate));
        bool historyPrepared;
        if (ok && owner.historyEligible) {
            auto cmd = cast(MeshSessionEdit)gestureFactory();
            if (cmd !is null) {
                cmd.setSnapshots(owner.beforeSnapshot, MeshSnapshot.capture(owner.candidate),
                    "Edge Slice");
                historyPrepared = context.prepare(cmd, PreparedHistoryKind.Plain).accepted;
                ok = historyPrepared;
            } else ok = context.prepareGestureCarrierMismatch();
        }
        if (ok && handles_.length > 0)
            ok = handlerDestroy !is null && handlerDestroy.owns(handles_) &&
                context.prepareDestroy(handlerDestroy);
        if (ok) ok = historyPrepared ? context.markHistoryInstall()
                                     : context.markNoHistoryInstall();
        if (ok) ok = context.prepareEdgeSliceDeactivate(owner);
        if (!ok) context.discard();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.EdgeSlice, historyPrepared, ok);
    }

    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer layer,
            ulong threadIdentity, ulong contextIdentity) {
        auto upload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity);
        auto handlers = new BoxHandlerBatchResourceOwner(handles_, threadIdentity,
            contextIdentity);
        return prepareDeactivate(context, layer, upload, handlers).resourceAccepted;
    }

    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        return prepareActivate(context).accepted;
    }

    public override bool hasUncommittedEdit() const {
        return active && (armed_ || latchedPoints_.length > 0);
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    // Shift+click = apply the chain and re-arm (EditSession.applyAndContinue;
    // captured law, task 7114 item 8). A chain of fewer than two points has
    // nothing to apply and keeps the session. True iff `commitChain` recorded
    // a row: it may cancel instead (a zero-segment bake), and the TOP ENTRY'S
    // IDENTITY is compared rather than the stack length, which stops growing
    // once the history is at its depth cap.
    public override bool commitUncommittedEdit() {
        if (!active || latchedPoints_.length < 2 || history is null) return false;
        const top0 = topHistoryCommand();
        commitChain();
        return topHistoryCommand() !is top0;
    }

    private const(Object) topHistoryCommand() const {
        const ue = history.undoEntries();
        return ue.length ? ue[$ - 1].cmd : null;
    }

    // Everything the tool derives from its chain attributes (slice M3, R4.3):
    // the phase and arm by the chain's length, the proxy, the preview — the
    // former per-point peel's tail, now the image's one rebuild. The chain's
    // baseline is the mesh as the first point found it; a chain seated on a
    // tool that has none yet (the session's redo replay of the first group)
    // takes the current mesh, which the session checked is the mesh that
    // group left. Released: an undo or redo never leaves a scrub running.
    override void rebuildPreviewFromAttrs() {
        scrubbing_ = false;
        dragPart_  = -1;
        const n = latchedPoints_.length;
        if (n == 0) { cancelLiveEdit(); return; }
        if (!chainBefore_.filled) {
            chainBefore_ = MeshSnapshot.capture(*mesh);
            armedKey_.stamp(*mesh);
            if (history !is null) history.invalidateRedo();
        }
        armed_ = n >= 2;
        phase_ = n >= 2 ? Phase.EdgeB : Phase.EdgeA;
        syncProxy();
        rebuildPreview();
    }

    public override void resyncSession() {
        if (!active) return;
        if (armed_ || latchedPoints_.length > 0) return;   // only commit/cancel may end a live chain
        reinitSession();
    }

    /// Discard the standing preview WITHOUT touching the mesh or recording
    /// anything to history. Safe to call even when nothing is armed, and safe
    /// to call after scene.reset has already swapped the underlying mesh — see
    /// the defensive `file.new` callback in registration.d.
    public void dropArmedPreview() {
        sessionOperationEnded();   // the operation ends with its preview (slice M3)
        armed_         = false;
        scrubbing_     = false;
        built_         = false;
        lastBakedSegments_ = 0;
        lastMirrorSegments_ = 0;
        parked_ = null;
        phase_         = Phase.Idle;
        latchedPoints_ = [];
        edgesParam_    = [];
        dragPart_      = -1;
        activePoint_   = -1;
        armedKey_.invalidate();
        chainBefore_   = MeshSnapshot.init;
    }

    override void evaluate() {}

    private static bool preparedParamRecognized(string pname) pure nothrow @nogc {
        return pname == "chainArm" || pname == "activePoint" || pname == "pointT" ||
            pname == "split" || pname == "middle" || pname == "snap" ||
            pname == "tA" || pname == "tB" || pname == "show";
    }

    private void storePreparedPoints(ref uint[] verts, ref float[] ts,
            const ChainPoint[] pts) const {
        verts.length = pts.length * 2; ts.length = pts.length;
        foreach (i, p; pts) {
            verts[i * 2] = p.v0; verts[i * 2 + 1] = p.v1; ts[i] = p.t;
        }
    }

    private ChainPoint[] loadPreparedPoints(const uint[] verts,
            const float[] ts) const {
        ChainPoint[] pts; pts.length = ts.length;
        foreach (i; 0 .. ts.length) {
            pts[i] = ChainPoint(verts[i * 2], verts[i * 2 + 1], ts[i]);
        }
        return pts;
    }

    final PreparedEdgeSliceParamImage buildPreparedParamUpdate(
            string pname, ref Mesh live) {
        PreparedEdgeSliceParamImage image; image.valid = true; image.pname = pname;
        image.recognized = preparedParamRecognized(pname);
        image.expectedActive = active; image.expectedArmed = armed_;
        image.expectedScrubbing = scrubbing_; image.expectedBuilt = built_;
        image.expectedPhase = cast(int)phase_; image.expectedDragPart = dragPart_;
        image.expectedActivePoint = activePoint_; image.expectedArmedKey = armedKey_;
        image.expectedSplit = split_;
        image.expectedMiddle = middle_; image.expectedSnap = snap_;
        image.expectedProxy = pointProxy_; image.expectedTA = tA_; image.expectedTB = tB_;
        image.expectedEdges = edgesParam_.dup;
        storePreparedPoints(image.expectedPointVerts, image.expectedPointT, latchedPoints_);
        image.expectedLive = MeshSnapshot.capture(live); image.expectedBefore = chainBefore_;
        image.nextArmed = armed_; image.nextScrubbing = scrubbing_; image.nextBuilt = built_;
        image.nextPhase = cast(int)phase_; image.nextDragPart = dragPart_;
        image.nextActivePoint = activePoint_; image.nextArmedKey = armedKey_;
        image.nextProxy = pointProxy_;
        image.nextEdges = edgesParam_.dup;
        image.nextPointVerts = image.expectedPointVerts.dup;
        image.nextPointT = image.expectedPointT.dup;
        image.nextChainPoints = latchedPoints_.dup;
        image.nextMirrorSegments = lastMirrorSegments_;
        image.nextParked = parked_.dup;
        if (!image.recognized || pname == "show") return image;

        if (pname == "activePoint") {
            image.appliesState = true;
            int maxIdx = cast(int)latchedPoints_.length - 1;
            image.nextActivePoint = maxIdx < 0 ? -1 :
                activePoint_ < 0 ? 0 : activePoint_ > maxIdx ? maxIdx : activePoint_;
            if (image.nextActivePoint >= 0)
                image.nextProxy = latchedPoints_[image.nextActivePoint].t;
            return image;
        }

        ChainPoint[] nextPoints;
        MeshSnapshot baseline;
        if (pname == "chainArm") {
            nextPoints = pointsFromEdgesParamIn(live);
            if (nextPoints.length < 2) return image;
            baseline = MeshSnapshot.capture(live);
            image.nextActivePoint = cast(int)nextPoints.length - 1;
            image.nextProxy = nextPoints[$ - 1].t;
            image.nextArmed = true; image.nextPhase = cast(int)Phase.EdgeB;
        } else {
            nextPoints = latchedPoints_.dup;
            if (pname == "pointT") {
                if (activePoint_ < 0 || activePoint_ >= cast(int)nextPoints.length)
                    return image;
                nextPoints[activePoint_].t = pointProxy_;
                image.appliesState = true;
            } else if (!armed_) return image;
            if (!chainBefore_.filled || nextPoints.length == 0) return image;
            if (!armedKey_.matches(live)) {
                image.nextArmed = false; image.nextScrubbing = false;
                image.nextBuilt = false;
                image.nextPhase = cast(int)Phase.Idle;
                image.nextPointVerts = null; image.nextPointT = null;
                image.nextChainPoints = null;
                image.nextEdges = null; image.nextDragPart = -1;
                image.nextActivePoint = -1; image.nextArmedKey.invalidate();
                image.appliesState = true;
                return image;
            }
            baseline = chainBefore_;
        }

        image.candidate = detachedPreparedMesh(live);
        auto shadow = beginPreparedShadow(image.candidate);
        const n = bakeChainInto(image.candidate, baseline, nextPoints,
            image.nextMirrorSegments, image.nextParked);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains); shadow.close();
        image.appliesState = true; image.appliesMesh = true;
        image.invalidateRedo = history !is null;
        image.nextBuilt = n > 0;
        image.nextArmedKey.stampAs(image.candidate, cast(size_t)mesh);
        storePreparedPoints(image.nextPointVerts, image.nextPointT, nextPoints);
        image.nextChainPoints = nextPoints;
        return image;
    }

    final bool preparedParamUpdateMatches(in PreparedEdgeSliceParamImage image,
            ref const Mesh live) const nothrow @nogc {
        if (!image.valid || image.pname is null ||
            image.recognized != preparedParamRecognized(image.pname) ||
            active != image.expectedActive || armed_ != image.expectedArmed ||
            scrubbing_ != image.expectedScrubbing || built_ != image.expectedBuilt ||
            cast(int)phase_ != image.expectedPhase || dragPart_ != image.expectedDragPart ||
            activePoint_ != image.expectedActivePoint || armedKey_ != image.expectedArmedKey ||
            split_ != image.expectedSplit ||
            middle_ != image.expectedMiddle || snap_ != image.expectedSnap ||
            pointProxy_ != image.expectedProxy || tA_ != image.expectedTA ||
            tB_ != image.expectedTB || edgesParam_ != image.expectedEdges ||
            latchedPoints_.length != image.expectedPointT.length ||
            !image.expectedLive.matches(live) || !image.expectedBefore.matches(chainBefore_))
            return false;
        foreach (i, p; latchedPoints_)
            if (p.v0 != image.expectedPointVerts[i * 2] ||
                p.v1 != image.expectedPointVerts[i * 2 + 1] || p.t != image.expectedPointT[i])
                return false;
        return true;
    }

    final void installPreparedParamUpdate(ref PreparedEdgeSliceParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        if (!image.appliesState) { image.clear(); return; }
        armed_ = image.nextArmed; scrubbing_ = image.nextScrubbing;
        built_ = image.nextBuilt; phase_ = cast(Phase)image.nextPhase;
        dragPart_ = image.nextDragPart; activePoint_ = image.nextActivePoint;
        armedKey_ = image.nextArmedKey;
        pointProxy_ = image.nextProxy; edgesParam_ = image.nextEdges;
        latchedPoints_ = image.nextChainPoints;
        lastMirrorSegments_ = image.nextMirrorSegments;
        parked_ = image.nextParked;
        if (image.pname == "chainArm" && image.appliesMesh)
            chainBefore_ = image.expectedLive;
        image.clear();
    }

    final PreparedEdgeSliceParamEffect prepareParamChanged(string pname,
            PreparedRecordContext context, Layer layer, GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedEdgeSliceParamEffect(
            preparedToolStateOwner, PreparedEdgeSliceParamKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedEdgeSliceParamUpdateOwner.prepare(this, layer, pname);
        bool ok = owner !is null;
        bool installHistory;
        if (ok && owner.invalidateRedo) {
            auto redo = context.prepareInvalidateRedo();
            ok = redo.accepted; installHistory = redo.mustInstall;
        }
        if (ok && owner.appliesMesh)
            ok = owner.deliveryFlags != 0 && uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains) &&
                context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = installHistory ? context.markHistoryInstall()
                                    : context.markNoHistoryInstall();
        if (ok) ok = context.prepareEdgeSliceParamUpdate(owner);
        if (!ok) context.discard();
        return PreparedEdgeSliceParamEffect(preparedToolStateOwner,
            owner is null ? PreparedEdgeSliceParamKind.None : owner.effectKind, ok);
    }

    // A panel edit of a geometry-affecting option while a preview is armed
    // must refresh it immediately (mirrors LoopSliceTool's onParamChanged
    // convention) — otherwise toggling Split Polygons / Split at Middle /
    // Snap Value, or editing tA/tB directly (rather than scrubbing the
    // handle), would silently wait for the next scrub to take effect.
    // `show` is display-only and never touches geometry.
    //
    // `chainArm` (task 0295, F2, objection 2) runs BEFORE the `!armed_` guard
    // — it is the deterministic, picker-free chain driver: it arms the exact
    // chain state a click sequence over edgesParam_ would produce, without
    // committing, so a subsequent real Enter / tool-drop exercises the
    // genuine commitChain()/deactivate() path.
    override void onParamChanged(string pname) {
        if (pname == "chainArm") { armChain(); return; }
        // Active-point index + numeric `t` edit (task 0321, D2) — re-target
        // any latched point and re-bake via the same whole-polyline engine a
        // scrub/drag uses. Handled BEFORE the `!armed_` guard below: a
        // 1-point chain (phase_ EdgeA, not yet armed_) can still have its
        // sole point's `t` edited (rebuildPreview() is a harmless no-op restore
        // in that case — bakeChainFrom needs >=2 points to cut anything).
        if (pname == "activePoint") {
            int maxIdx = cast(int)latchedPoints_.length - 1;
            if (maxIdx < 0)                  activePoint_ = -1;
            else if (activePoint_ < 0)        activePoint_ = 0;
            else if (activePoint_ > maxIdx)   activePoint_ = maxIdx;
            syncProxy();
            return;
        }
        if (pname == "pointT") {
            // Bounds guard (task 0321 opponent fold, Risk #5) — a `pointT`
            // write must never index `latchedPoints_[-1]` or past the end,
            // e.g. right after a peel shrank the chain out from under a
            // stale `activePoint_`.
            if (activePoint_ < 0 || activePoint_ >= cast(int)latchedPoints_.length) return;
            latchedPoints_[activePoint_].t = pointProxy_;
            rebuildPreview();
            return;
        }
        if (!armed_) return;
        if (pname == "split" || pname == "middle" || pname == "snap"
            || pname == "tA" || pname == "tB")
            rebuildPreview();
    }

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply). Reads edgesParam_/tA_/tB_/split_ ONLY —
    // MUST NOT touch armed_/scrubbing_/phase_/latchedPoints_/session state;
    // ToolDoApplyCommand wraps this with its own snapshot pair. Accepts an
    // N-edge chain (length >= 2) via the SAME bakeChainFrom engine the
    // interactive path uses.
    // -------------------------------------------------------------------
    override bool applyHeadless() {
        auto pts = pointsFromEdgesParam();
        if (pts.length < 2) return false;
        auto baseline = MeshSnapshot.capture(*mesh);
        size_t n = bakeChainFrom(baseline, pts);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { closeOwnOperation(false); return true; }
        // H5 (C-H5-es-mmb): a Middle press inside the live chain opens an
        // operation boundary of its own — one step, no point, no clone
        // (no-clone is the policy's, applied by the session).
        if (e.button == SDL_BUTTON_MIDDLE && latchedPoints_.length > 0) {
            sessionStepBegins(PressKind.middle);
            sessionStepEnds();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Edges)    return false;

        // Re-pick (task 0321, D3): a press ON an already-latched point's
        // handle grabs IT as the drag target — "grab the point under the
        // cursor" rather than always scrubbing the tail. Checked BEFORE the
        // hovered-edge latch/append logic below. draw() registers exactly one
        // part per latched point; `part < latchedPoints_.length` stays as a
        // bound on the index the grab writes.
        if (toolHandles_ !is null && latchedPoints_.length >= 1) {
            int part = toolHandles_.test(cast(int)e.x, cast(int)e.y, vpWorld_);
            if (part >= 0 && part < cast(int)latchedPoints_.length) {
                sessionStepBegins();   // a re-pick drag is a gesture step (H2, EW)
                activePoint_ = part;
                syncProxy();
                scrubbing_   = true;
                dragPart_    = part;
                return true;
            }
        }

        // A hover HELD over a stale subpatch-preview index space names an edge
        // of the mesh before the last bake, not of this one: absorb the click
        // without latching; the user clicks again once the build lands (task
        // 7114, item 22 hypothesis (e), measured live in the task's evidence).
        if (g_hoverIndexSpaceStale) return true;
        int h = g_hoveredEdge;
        if (h < 0 || h >= cast(int)mesh.edges.length) return false;

        const SymmetryPacket* sym = vts.get!SymmetryPacket();
        if (phase_ == Phase.Idle) {
            sessionStepBegins();
            latchFirstPoint(h, cast(float)e.x, cast(float)e.y, sym);
            return true;
        }

        // EdgeA (1 point latched) or EdgeB (>=2 latched): a further click
        // EXTENDS the chain (task 0295, F2) — it no longer commits+reseeds
        // (the v1 behaviour this replaces). Reject a click on the SAME edge
        // as the last latched point (no zero-length segment).
        //
        // S3: explicit uint comparison rather than `cast(int)lastEdge == h`
        // — the old form only worked because edgeIndexOf's ~0u "not found"
        // sentinel casts to -1, which can never coincide with `h` (already
        // guarded non-negative above); that safety was implicit in the
        // wraparound, not stated. Guard the sentinel by name instead.
        uint lastEdge = (*mesh).edgeIndexOf(latchedPoints_[$ - 1].v0, latchedPoints_[$ - 1].v1);
        if (lastEdge != ~0u && lastEdge == cast(uint)h) return false;
        if (latchedPoints_.length >= kMaxEdgeSliceChainPoints) return true;   // the cap refuses the point
        sessionStepBegins();
        appendPoint(h, cast(float)e.x, cast(float)e.y, sym);
        return true;
    }

    // Only touches the mesh (via rebuildPreview) while ACTIVELY SCRUBBING an
    // already-latched point AND armed_ (>=2 points, so a bake is meaningful).
    // Mere hovering between clicks must NEVER mutate the mesh: the app's own
    // picker (g_hoveredEdge) is re-evaluated against whatever the CURRENT
    // mesh looks like, so a speculative hover-triggered cut would desync the
    // NEXT click's captured vertex pair from chainBefore_'s indices (a
    // restore-then-index-out-of-bounds hazard). Between clicks nothing is
    // drawn for the next point but the application's target-edge highlight.
    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_ || latchedPoints_.length == 0) return false;
        // Generalised (task 0321, D2/D3) from the hard-wired last point to
        // `activePoint_` — set to the tail by latchFirstPoint/appendPoint/
        // armChain, or to a re-picked earlier point by onMouseButtonDown.
        if (activePoint_ < 0 || activePoint_ >= cast(int)latchedPoints_.length) return false;
        Vec3 ra, rb;
        if (!liveRail(activePoint_, ra, rb)) return true;  // parked
        latchedPoints_[activePoint_].t = tFromLocalRailClick(ra, rb,
            cast(float)e.x, cast(float)e.y);
        syncProxy();
        if (armed_) rebuildPreview();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        scrubbing_ = false;
        dragPart_  = -1;
        // Model B: mouse-up never commits — the preview (once built) STANDS
        // until Enter / tool-drop / another click extends it. The press..release
        // is one gesture step of the session (slice M3).
        sessionStepEnds();
        return true;
    }

    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        if (!active || latchedPoints_.length == 0) return false;
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                // The same body the command close runs, through the session
                // (slice M3), which closes its account of the operation.
                closeOwnOperation(true);
                return true;
            default:
                return false;
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        if (!visualOnly) vpWorld_ = vp;
        if (!active || latchedPoints_.length == 0) return;

        // Parked points (see `pointRail`) are skipped: no marker, no handle;
        // each handle's part id stays its point's index.
        Vec3[] positions;
        int[] partOf;
        foreach (i; 0 .. latchedPoints_.length) {
            Vec3 q;
            if (!chainPointPos(i, q)) continue;
            positions ~= q;
            partOf ~= cast(int)i;
        }
        if (positions.length == 0) return;

        // Nothing is drawn for a point that has not been clicked: before the
        // press the display is the target-edge highlight alone (drawn by the
        // application), and the point's cut appears at its PRESS (task 7114,
        // measured law). Chords between latched points are baked mesh edges.
        ensureHandleCount(positions.length);

        immutable float handleScale = HANDLE_HALF_PX / getGizmoPixels();
        // The bank's own space, settled (task 0645). `positions` are LOCAL —
        // they lerp raw `mesh.vertices` — while `BoxHandler.pos`,
        // `gizmoSize`, `Handler.draw` and `ToolHandles.hitTest` are all
        // WORLD. One lift here serves the draw AND the hit-test, because they
        // read these very objects; that is the whole reason the comment on
        // `vpWorld_` above says converting the hit-test alone would break the
        // one property that worked.
        const auto os = OverlaySpace.ofPrimary();
        toolHandles_.begin();
        foreach (i, pos; positions) {
            const Vec3 posW  = os.pos(pos);
            handles_[i].pos  = posW;
            handles_[i].size = gizmoSize(posW, vp, handleScale);
            toolHandles_.add(handles_[i], partOf[i]);
        }
        toolHandles_.setHaul(dragPart_);
        int mx, my;
        queryMouse(mx, my);
        toolHandles_.update(mx, my, vp);

        foreach (hd; handles_) hd.draw(shader, vp);

        if (show_ == Show.Position && partOf[$ - 1] == cast(int)latchedPoints_.length - 1)
            drawHud(vp, positions[$ - 1], effectiveT(latchedPoints_[$ - 1].t));
    }

private:
    void latchFirstPoint(int h, float sx, float sy, const SymmetryPacket* sym) {
        ChainPoint p;
        p.v0 = mesh.edges[h][0];
        p.v1 = mesh.edges[h][1];
        p.t  = tFromLocalRailClick(mesh.vertices[p.v0], mesh.vertices[p.v1], sx, sy);
        assignMirror(p, sym);
        seatFirstPoint(p, cast(uint)h);
        // The first point's base IS the mesh `seatFirstPoint` just captured.
        assignBase(latchedPoints_[0]);
        scrubbing_ = true;
        dragPart_  = 0;
    }

    // Everything a first latch does except deriving `t` from the click and
    // starting the scrub — shared with the redo replay (task 7137).
    void seatFirstPoint(ChainPoint p, uint h) {
        chainBefore_ = MeshSnapshot.capture(*mesh);
        latchedPoints_ = [p];
        edgesParam_    = [h];
        phase_     = Phase.EdgeA;
        activePoint_ = 0;
        syncProxy();
        armedKey_.stamp(*mesh);
        // No cut yet — armed_/built_ stay false until a second point latches.
        //
        // Task 0429: the first latch writes NOTHING to the mesh, but it OPENS
        // the standing-preview session (hasUncommittedEdit() is true from one
        // point on) — invalidate redo here too, by the uniform "a standing-
        // preview session opened" rule. Side benefit: no redo step can ever
        // land under a 1-point chain, whose chainBefore_ (captured above)
        // would be stale against the redone mesh. One corner of this call is
        // an extrapolation pending capture — see the task file's CQ-A
        // (task 0429) before removing it.
        if (history !is null) history.invalidateRedo();
    }

    void appendPoint(int h, float sx, float sy, const SymmetryPacket* sym) {
        ChainPoint p;
        p.v0 = mesh.edges[h][0];
        p.v1 = mesh.edges[h][1];
        p.t  = tFromLocalRailClick(mesh.vertices[p.v0], mesh.vertices[p.v1], sx, sy);
        assignMirror(p, sym);
        assignBase(p);
        latchedPoints_ ~= p;
        edgesParam_    ~= cast(uint)h;
        armed_     = true;
        scrubbing_ = true;
        dragPart_  = cast(int)(latchedPoints_.length - 1);
        activePoint_ = cast(int)(latchedPoints_.length - 1);
        syncProxy();
        phase_     = Phase.EdgeB;
        armedKey_.stamp(*mesh);
        rebuildPreview();
    }

    // The point's mirror edge under the live symmetry (captured law: the cut is
    // mirrored from EITHER side, no leading side; task 7114 item 6). Stored
    // with the point, so every re-bake — scrub, commit, the prepared switch —
    // bakes the same mirror chain without asking the pipe again.
    void assignMirror(ref ChainPoint p, const SymmetryPacket* sym) {
        uint m0, m1;
        if (sym !is null && mirrorEdgePoint(*mesh, *sym, p.v0, p.v1, m0, m1)) {
            // The kernel reads `t` along the edge's STORED direction.
            const e = mesh.edgeIndex(m0, m1);
            if (e == ~0u) return;
            p.mflip = mesh.edges[e][0] != m0;
            p.m0 = p.mflip ? m1 : m0;
            p.m1 = p.mflip ? m0 : m1;
        }
    }

    // Records, for introspection, whether the point landed off every base
    // edge (a click on any chord the tool made, primary or mirror).
    void assignBase(ref ChainPoint p) {
        Vec3 ra, rb;   // at the latch the clicked edge is live
        if (!chainBefore_.filled || !pointRail(*mesh, p, ra, rb)) return;
        p.latchFaces = locateBase(chainBefore_.vertices, chainBefore_.edges, chainBefore_.faces,
                                  lerpVec3(ra, rb, effectiveT(p.t)), p.facePoint);
    }

    static bool sharesFace(const uint[] a, const uint[] b) {
        foreach (f; a)
            foreach (g; b) if (f == g) return true;
        return false;
    }

    // Deterministic chain driver (task 0295, F2, objection 2): reads
    // edgesParam_ fresh and arms the chain it describes without committing,
    // so a subsequent real onKeyDown/deactivate exercises the genuine
    // commitChain() path in a picker-free test.
    void armChain() {
        auto pts = pointsFromEdgesParam();
        if (pts.length < 2) return;
        // It stands for the click sequence, so the session records what that
        // sequence would: one gesture step per point (slice M3) — the first
        // is the window's first group. The images need only the prefixes; the
        // chain is baked once, below.
        const edges = edgesParam_.dup;
        foreach (k; 0 .. pts.length) {
            sessionStepBegins();
            latchedPoints_ = pts[0 .. k + 1].dup;
            edgesParam_    = k + 1 <= edges.length ? edges[0 .. k + 1].dup : edges.dup;
            activePoint_   = cast(int)k;
            sessionStepEnds();
        }
        edgesParam_ = edges.dup;
        latchedPoints_ = pts;
        activePoint_   = cast(int)latchedPoints_.length - 1;
        syncProxy();
        chainBefore_   = MeshSnapshot.capture(*mesh);
        // Task 0429: the headless arm bakes the preview into the real mesh
        // DIRECTLY (bypassing rebuildPreview), so it is its own redo-
        // invalidation write-point — same law as rebuildPreview()/
        // LoopSliceTool.rebuildCut().
        if (history !is null) history.invalidateRedo();
        size_t n = bakeChainFrom(chainBefore_, latchedPoints_);
        // Stamp AFTER baking — bakeChainFrom mutates the mesh (bumps
        // topologyVersion), so stamping before it would leave armedKey_
        // stale the instant this returns, and commitChain()'s
        // armedKey_.matches() guard would then (wrongly) treat the just-armed
        // chain as clobbered-from-under-us and drop it without recording.
        armedKey_.stamp(*mesh);
        armed_ = true;
        built_ = n > 0;
        lastBakedSegments_ = n;
        phase_ = Phase.EdgeB;
        // S1: bakeChainFrom just mutated the mesh — keep the GPU upload in
        // step (mirrors rebuildPreview/commitChain),
        // so this stays consistent if ever exercised with a visible window.
        refreshCaches();
    }

    // Keep the Param-bound `pointProxy_` mirror in sync with
    // `latchedPoints_[activePoint_].t` after any mutation not itself driven
    // by a "pointT" param write (a re-pick, a peel, a fresh latch) — mirrors
    // LoopSliceTool's `syncProxy`/`positionProxy_`.
    void syncProxy() {
        if (activePoint_ >= 0 && cast(size_t)activePoint_ < latchedPoints_.length)
            pointProxy_ = latchedPoints_[activePoint_].t;
    }

    // Build a ChainPoint[] from edgesParam_ against the CURRENT mesh — shared
    // by applyHeadless (baseline == current mesh, nothing cut yet) and
    // armChain (same precondition: the deterministic driver arms straight
    // from the idle mesh). Interior points (neither first nor last) default
    // to t=0.5, mirroring the kernel's own interior convention
    // (mesh.d edgeSlice's cutT[i]=0.5 for interior path edges) — headless
    // chains have no per-interior-t param (a deliberate v1 surface
    // limitation; interactive interior points cut at their clicked t).
    ChainPoint[] pointsFromEdgesParam() const {
        return pointsFromEdgesParamIn(*mesh);
    }

    ChainPoint[] pointsFromEdgesParamIn(ref const Mesh work) const {
        ChainPoint[] pts;
        if (edgesParam_.length < 2) return pts;
        pts.length = edgesParam_.length;
        foreach (i, ei; edgesParam_) {
            if (ei >= work.edges.length) return null;
            pts[i].v0 = work.edges[ei][0];
            pts[i].v1 = work.edges[ei][1];
            if (i == 0)                           pts[i].t = tA_;
            else if (i == edgesParam_.length - 1)  pts[i].t = tB_;
            else                                   pts[i].t = 0.5f;
        }
        return pts;
    }

    // Compose the two existing helpers exactly as LoopSliceTool's mesh-drag
    // does: screenPointToRay -> closestPointOnSegmentToRay -> reproject onto
    // the (unclamped) segment direction to recover the scalar t, then apply
    // the panel's effectiveT law (Split at Middle / Snap Value / clamp).
    //
    // AIMING KIND: **Closest** (task 0619,
    // doc/tool_aiming_item_transform_plan.md §1.3). This is the ONE aiming
    // kind whose correct space is **WORLD**, and it is deliberately the
    // opposite of the tack/magnet/stroke RayPlane law two files over:
    //
    //   * The closest-approach election is NOT affine-invariant. Under a
    //     non-uniform `M` the 3D-nearest point of the LOCAL segment to the
    //     local ray maps to a DIFFERENT point than the 3D-nearest point of
    //     the WORLD segment to the world ray. The user aims at the rail as
    //     it is DRAWN, so world is the election the cursor means.
    //   * Applying §1.2's "move it into local" law here compiles, and is
    //     invisible at identity AND under uniform scale — it goes wrong only
    //     under a non-uniform one. That is why the caller-facing parameter
    //     names say `Local` and this comment says WORLD.
    //   * The result converts back for FREE: what leaves here is a RATIO
    //     along the rail, and an affine map preserves ratios along a line.
    //     So the world-space `t` IS the local `t` `chainPointPos` /
    //     `Mesh.edgeSliceEx` want. No back-transform, no new primitive.
    //
    // The rename from `tFromClick` (task 0619) is the compile gate: every
    // call site had to be re-read to confirm it passes LOCAL endpoints
    // (all four do — they are raw `mesh.vertices[]` reads).
    float tFromLocalRailClick(Vec3 rail0Local, Vec3 rail1Local, float sx, float sy) const {
        const ms = primaryModelSpace();
        Vec3 rail0 = ms.toWorldPoint(rail0Local);
        Vec3 rail1 = ms.toWorldPoint(rail1Local);
        Vec3 origin, dir;
        screenPointToRay(sx, sy, vpWorld_, origin, dir);
        Vec3 hit = closestPointOnSegmentToRay(rail0, rail1, origin, dir);
        Vec3 ab = rail1 - rail0;
        float denom = dot(ab, ab);
        float raw = denom > 1e-12f ? dot(hit - rail0, ab) / denom : 0.5f;
        return effectiveT(raw);
    }

    // A point's rail in the mesh a bake is BUILDING, read when its step starts:
    // false — the point is PARKED — when (v0, v1) is not an edge there, because
    // a re-bake under other parameters (a snap, Split Polygons) did not remake
    // the cut-made vertices it latched on (and in-range indices may then name
    // unrelated ones). A parked point owns nothing and splits nothing; the bake
    // reports it (`parked_`) and `liveRail` hides it from every other reader.
    static bool pointRail(ref Mesh m, const ChainPoint p, out Vec3 a, out Vec3 b) {
        if (p.v0 >= m.vertices.length || p.v1 >= m.vertices.length) return false;
        if (m.edgeIndexOf(p.v0, p.v1) == ~0u) return false;
        a = m.vertices[p.v0];
        b = m.vertices[p.v1];
        return true;
    }

    // THE reader of latched point `i`'s rail on the live mesh — draw, handles,
    // HUD, a scrub, introspection: false for a point the last bake parked (it
    // is not drawn and has no handle), or whose indices are out of range.
    bool liveRail(size_t i, out Vec3 a, out Vec3 b) const {
        if (i >= latchedPoints_.length || (i < parked_.length && parked_[i])) return false;
        const p = latchedPoints_[i];
        if (p.v0 >= mesh.vertices.length || p.v1 >= mesh.vertices.length) return false;
        a = mesh.vertices[p.v0];
        b = mesh.vertices[p.v1];
        return true;
    }

    bool chainPointPos(size_t i, out Vec3 pos) const {
        Vec3 a, b;
        if (!liveRail(i, a, b)) return false;
        pos = lerpVec3(a, b, effectiveT(latchedPoints_[i].t));
        return true;
    }

    // AIMING KIND: **Pixel** (task 0619 §1.1) — `anchor` is a LOCAL point
    // (`chainPointPos` lerps raw `mesh.vertices`), and
    // the label has to land on the pixel that point is DRAWN at. The law for
    // this kind is "keep the geometry local, compose the viewport":
    // `proj*(view*M)*v == proj*view*(M*v)` exactly, and `aimSpace` is the
    // only way to obtain the composed viewport (`AimViewport`, math.d §2.0).
    // Once per call, not per vertex — there is no loop here.
    void drawHud(const ref Viewport vp, Vec3 anchorLocal, float t) {
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
        float sx, sy, ndcZ;
        if (!projectToWindowFull(anchorLocal, vpAim.vp, sx, sy, ndcZ)) return;
        ImDrawList* dl = ImGui.GetForegroundDrawList();
        string label = edgeSliceHudLabel(t);
        dl.AddText(ImVec2(sx + 10.0f, sy - 8.0f), IM_COL32(255, 255, 255, 235), label);
    }

    void ensureHandleCount(size_t n) {
        while (handles_.length < n)
            handles_ ~= new BoxHandler(Vec3(0, 0, 0), HANDLE_COLOR);
        while (handles_.length > n) {
            handles_[$ - 1].destroy();
            handles_.length = handles_.length - 1;
        }
        if (toolHandles_ is null) toolHandles_ = new ToolHandles();
    }

    // -------------------------------------------------------------------
    // bakeChainFrom — the PURE per-frame re-bake (task 0295, F2, objection 1
    // — the earlier draft's bakeSegment mutated chain counters on every
    // onMouseMotion, corrupting the seed after the first frame). Restores
    // `baseline`, walks the polyline ONCE re-cutting each segment via
    // Mesh.edgeSliceEx, threading the kernel-returned cut vertex as the next
    // segment's exact seed. Mutates NO tool/chain state — `latchedPoints_`
    // only ever advances at click-latch/armChain and clears at commit/cancel.
    //
    // Returns the number of segments successfully baked (pts.length - 1 on
    // full success; a smaller count if a later segment's destination edge
    // doesn't resolve against `baseline` — see the linear-chain limit note
    // on pointsFromEdgesParam/pickSeedSubEdge — or fails to reach).
    // -------------------------------------------------------------------
    size_t bakeChainFrom(ref MeshSnapshot baseline, const ChainPoint[] pts) {
        return bakeChainInto(*mesh, baseline, pts, lastMirrorSegments_, parked_);
    }

    size_t bakeChainInto(ref Mesh work, ref MeshSnapshot baseline,
            const ChainPoint[] pts) {
        size_t mirrorN;
        bool[] parked;
        return bakeChainInto(work, baseline, pts, mirrorN, parked);
    }

    // Restores `baseline` and bakes `pts`. Returns the chain steps that wrote
    // the mesh; `mirrorN` the mirror side's (points latched under symmetry).
    //
    // Every chain — clicked, scripted (`chainArm`) or headless — follows the
    // measured ownership law (C1-sym-own and C1-own-off, gap rows 290/314,
    // tests/test_edge_slice_symmetry.d): the chain is ONE ordered list of
    // clicked points that crosses the plane freely; segment k cuts only when
    // points k and k+1 share a BASE polygon, so a crossing segment makes
    // nothing; an edge point on a non-cutting step still splits its edge (the
    // first point too, once the chain has two); each cut and split is baked
    // again at the points' mirror images. Each step bakes its primary part,
    // then its mirror part, so the preview's numbering is append-only per
    // point and a point latched on a cut-made edge (C1-3b) names vertices the
    // re-bake recreates before the step that needs them.
    size_t bakeChainInto(ref Mesh work, ref MeshSnapshot baseline,
            const ChainPoint[] pts, out size_t mirrorN, out bool[] parked) {
        baseline.restore(work);
        parked = new bool[pts.length];
        if (pts.length < 2) return 0;
        auto img = new ChainPoint[pts.length];
        auto hasImg = new bool[pts.length];
        foreach (i, p; pts) {
            if (p.m0 == ~0u || p.m1 == ~0u) continue;
            img[i] = ChainPoint(p.m0, p.m1, p.mflip ? 1.0f - effectiveT(p.t) : p.t);
            hasImg[i] = true;
        }
        // Base polygons from each point's EFFECTIVE position (a snap can move
        // it onto a base vertex), located when its step starts: point i's
        // vertices exist from step i - 1 on (append-only numbering).
        auto faces = new uint[][pts.length];
        auto isFace = new bool[pts.length];
        void locate(size_t i) {
            // A parked point (see `pointRail`) owns nothing and splits nothing.
            Vec3 ra, rb;
            if (!pointRail(work, pts[i], ra, rb)) {
                faces[i] = null;
                isFace[i] = true;
                parked[i] = true;
                return;
            }
            const q = lerpVec3(ra, rb, effectiveT(pts[i].t));
            faces[i] = locateBase(baseline.vertices, baseline.edges, baseline.faces, q, isFace[i]);
            // Live indices naming an edge that is not where the point was
            // clicked (no base polygon in common with the latch) are parked
            // too; a snap onto a base vertex keeps the edge's polygons.
            if (pts[i].latchFaces.length && !sharesFace(pts[i].latchFaces, faces[i])) {
                faces[i] = null;
                isFace[i] = true;
                parked[i] = true;
            }
        }
        locate(0);
        size_t n;
        uint seedP = ~0u, seedM = ~0u;
        foreach (k; 0 .. pts.length - 1) {
            locate(k + 1);
            if (sharesFace(faces[k], faces[k + 1])) {
                // A start ON a vertex (a snapped end) continues from that
                // vertex, so the cut leaves through the shared polygon rather
                // than through the latched edge's own faces.
                if (seedP == ~0u) seedP = cornerAt(work, pts[k]);
                if (hasImg[k] && seedM == ~0u) seedM = cornerAt(work, img[k]);
                if (bakeSegmentInto(work, pts, k, seedP)) ++n;
                else seedP = ~0u;
                if (hasImg[k] && hasImg[k + 1] && bakeSegmentInto(work, img, k, seedM)) ++mirrorN;
                else seedM = ~0u;
                continue;
            }
            // No shared base polygon: no cut; the step's edge points split.
            uint unused;
            bool wrote = k == 0 && splitPointInto(work, pts[0], isFace[0], unused);
            wrote = splitPointInto(work, pts[k + 1], isFace[k + 1], seedP) || wrote;
            if (wrote) ++n;
            // The image of a face point is one too.
            bool wroteM = k == 0 && hasImg[0] && splitPointInto(work, img[0], isFace[0], unused);
            if (hasImg[k + 1])
                wroteM = splitPointInto(work, img[k + 1], isFace[k + 1], seedM) || wroteM;
            else seedM = ~0u;
            if (wroteM) ++mirrorN;
        }
        return n;
    }

    // The vertex `p` sits on when its effective `t` is an end of its edge.
    uint cornerAt(ref Mesh work, const ChainPoint p) {
        const e = work.edgeIndexOf(p.v0, p.v1);
        if (e == ~0u) return ~0u;
        const t = effectiveT(p.t);
        if (t <= 1e-5f) return p.v0;
        if (t >= 1.0f - 1e-5f) return p.v1;
        return ~0u;
    }

    // Split `p`'s edge at its `t` (an edge point that no segment reached).
    // `v`: the vertex now at the point (a reused corner at t = 0/1), or ~0u
    // for a face point or an unresolved edge. True when the mesh changed.
    bool splitPointInto(ref Mesh work, const ChainPoint p, bool facePoint, out uint v) {
        v = ~0u;
        if (facePoint) return false;
        const e = work.edgeIndexOf(p.v0, p.v1);
        if (e == ~0u) return false;
        float t = effectiveT(p.t);
        if (work.edges[e][0] != p.v0) t = 1.0f - t;
        if (t <= 1e-5f) { v = work.edges[e][0]; return false; }
        if (t >= 1.0f - 1e-5f) { v = work.edges[e][1]; return false; }
        const vi = work.addEdgePoint(e, t);
        if (vi == uint.max) return false;
        // `addEdgePoint` leaves the selection to its caller: the same drop and
        // grow `edgeSliceEx`'s points-only arm runs around this splice. The
        // splice publishes itself (the bus witness in the symmetry cells).
        work.clearFaceSelectionResize();
        work.clearEdgeSelectionResize();
        work.syncSelection();
        v = vi;
        return true;
    }

    // Segment k of `pts` (from point k to point k+1); `seed` threads the
    // kernel-returned cut vertex into the next segment (no position scanning).
    // False when the segment does not resolve or does not reach.
    bool bakeSegmentInto(ref Mesh work, const ChainPoint[] pts, size_t k, ref uint seed) {
        uint eB = work.edgeIndexOf(pts[k + 1].v0, pts[k + 1].v1);
        if (eB == ~0u) return false;   // destination not a live baseline edge

        EdgeSliceResult r;
        // No seed: a segment whose start no earlier step materialised (the
        // first one, or one after a face point) — cut from the point itself.
        if (seed == ~0u) {
            uint eA = work.edgeIndexOf(pts[k].v0, pts[k].v1);
            if (eA == ~0u) return false;
            r = work.edgeSliceEx(eA, eB, effectiveT(pts[k].t), effectiveT(pts[k + 1].t), split_);
        } else {
            uint sub = pickSeedSubEdgeIn(work, seed, eB);
            if (sub == ~0u) return false;
            float endT = (work.edges[sub][0] == seed) ? 0.0f : 1.0f;
            r = work.edgeSliceEx(sub, eB, endT, effectiveT(pts[k + 1].t), split_);
        }
        // S4 (mesh-robustness batch: gate on `!r.meshChanged`, not
        // `facesSplit==0`): in split mode, facesSplit==0 can be a KEPT
        // insert (meshChanged==true — a legitimate chain that
        // degenerated to a plain edge-split) that CONTINUES the chain,
        // not only a dead-end signal. This check is effectively inert
        // whenever split_==false — edgeSliceEx's points-only branch
        // (mesh.d) reports facesSplit=2/meshChanged=true as a bare
        // SUCCESS MARKER for any distinct, in-range edge pair (no
        // face-path/connectivity requirement at all in that mode), so
        // meshChanged is always true there. It only bites when
        // split_==true and the whole segment truly resolved to nothing
        // (no path AND no vertex spliced in).
        if (!r.meshChanged) return false;
        seed = r.cutVertB;
        return true;
    }

    // Continuation sub-edge choice (task 0295, F2, decision #2 — the
    // residual ambiguity: `seed` is a shared endpoint of the (typically 2-3)
    // live edges left after the previous segment's cut: the two half-edges
    // of the just-split edge, plus that face's own new chord edge). Keep the
    // one that reaches destEdge with a non-degenerate path; tie-break by
    // proximity to destEdge's midpoint, then lowest edge index.
    // `vibe3d-divergence`: the SDK is silent on which faces the reference
    // chords here — the bar is a valid, duplicate-free chain (the measured
    // seg-2 capture's shared-vertex reuse), not face-choice parity.
    //
    // W1 (perf): `reaches` used to be read back from a REAL
    // `(*mesh).edgeSliceEx(sub, destEdge, ..., split_)` call wrapped in a
    // `MeshSnapshot.capture`/`restore` probe — a whole-mesh dup+restore PER
    // CANDIDATE, and `bakeChainFrom` calls this per chain segment on every
    // `onMouseMotion`/`rebuildPreview`, so it was O(segments*candidates)
    // whole-mesh copies per mouse-move. `Mesh.edgeSliceReachable` is the same
    // face-incidence + dual-graph BFS `edgeSliceEx` runs internally, factored
    // out read-only (mesh.d), so the probe is gone entirely. One subtlety
    // preserved exactly: with Split Polygons OFF, `edgeSliceEx`'s
    // points-only branch never consults face connectivity at all — it
    // unconditionally succeeds (facesSplit=2) for any distinct, in-range
    // edge pair — so `reaches` must mirror that unconditional success rather
    // than running the BFS in that case (the BFS would wrongly reject
    // candidates with no face-adjacency path that the points-only cut would
    // have happily taken).
    uint pickSeedSubEdge(uint seed, uint destEdge) {
        return pickSeedSubEdgeIn(*mesh, seed, destEdge);
    }

    uint pickSeedSubEdgeIn(ref Mesh work, uint seed, uint destEdge) {
        uint[] candidates;
        foreach (sub; work.edgesAroundVertex(seed)) candidates ~= sub;
        if (candidates.length == 0) return ~0u;
        if (destEdge >= work.edges.length) return candidates[0];

        Vec3 destMid = lerpVec3(work.vertices[work.edges[destEdge][0]],
                                 work.vertices[work.edges[destEdge][1]], 0.5f);

        uint  best        = ~0u;
        float bestDist     = float.infinity;
        bool  bestReaches  = false;

        foreach (sub; candidates) {
            bool reaches;
            if (sub == destEdge) reaches = false;            // same-edge no-op, any split_ setting
            else if (!split_)    reaches = true;              // points-only: unconditional success
            else                 reaches = work.edgeSliceReachable(sub, destEdge);

            uint  other = work.edgeOtherVertex(sub, seed);
            float dist  = (work.vertices[other] - destMid).length();

            bool better = (best == ~0u)
                || (reaches && !bestReaches)
                || (reaches == bestReaches && dist < bestDist)
                || (reaches == bestReaches && dist == bestDist && sub < best);
            if (better) { best = sub; bestDist = dist; bestReaches = reaches; }
        }
        return best;
    }

    // The ONE-undo boundary (task 0295, F2, objection 2/3). Commits the
    // LATCHED polyline (bakeChainFrom re-cuts from chainBefore_ using
    // latchedPoints_ alone).
    void commitChain() {
        if (history is null || gestureFactory is null || !chainBefore_.filled) {
            dropArmedPreview();
            return;
        }
        if (latchedPoints_.length < 2) { cancelLiveEdit(); return; }
        // IDENTITY guard (topology, not position); see the `armedKey_` field note.
        if (!armedKey_.matches(*mesh)) {
            // The mesh underneath us was swapped/clobbered since our last
            // touch — nothing safely ours to commit.
            dropArmedPreview();
            return;
        }

        size_t n = bakeChainFrom(chainBefore_, latchedPoints_);
        if (n == 0) {
            // task 0303 (fuzz-found) — UPDATED for the mesh-robustness batch:
            // `edgeSliceEx` no longer ALWAYS undoes Pass 1 on a Pass-2 no-op.
            // A legitimate chain that degenerates to a plain edge-split (a
            // real vertex kept and finalized, facesSplit==0 but
            // meshChanged==true) is now RETAINED by the kernel and COUNTED
            // by `bakeChainFrom` (gated on `!meshChanged`, not
            // `facesSplit==0`) — so it never reaches this branch. `n==0`
            // here means every segment genuinely resolved to nothing (e.g. a
            // t=0/1 endpoint-reuse cut landing ADJACENT, in the shared
            // face's winding, to another segment's cut point, with no
            // vertex spliced in at all — the TRUE no-op case). The kernel
            // leaves the mesh exactly as chainBefore_ in that case, so
            // recording an edit here would be a genuine no-op undo entry —
            // cancel instead, mirroring applyHeadless's n==0 contract.
            cancelLiveEdit();
            return;
        }
        auto edit = cast(MeshSessionEdit) gestureFactory();
        if (edit is null) {
            // The factory bound at registration builds a different command than
            // this tool fills. Counted, never silent — and the chain is ALREADY
            // baked into the mesh at this point, so the preview is torn down the
            // way the success path below does it rather than leaving the tool
            // armed over an edit nothing can undo.
            noteGestureCarrierMismatch();
            dropArmedPreview();
            refreshCaches();
            return;
        }
        auto post = MeshSnapshot.capture(*mesh);
        edit.setSnapshots(chainBefore_, post, "Edge Slice");
        recordGestureEdit(edit, GestureRecordMode.Plain);   // EXACTLY ONE entry for the whole chain
        dropArmedPreview();     // clears latchedPoints_/chainBefore_ — next
                                 // chain recaptures chainBefore_ at its own
                                 // first latch/armChain.
        refreshCaches();
    }

    void cancelLiveEdit() {
        // Restores chainBefore_ — the WHOLE chain, never a per-segment
        // baseline — so RMB/Ctrl+Z/redo-cancel unwinds every baked segment.
        // IDENTITY guard (topology, not position); see the `armedKey_` field note.
        if (armedKey_.matches(*mesh) && chainBefore_.filled) chainBefore_.restore(*mesh);
        dropArmedPreview();
        refreshCaches();
    }

    // The mutate/revert preview: restore chainBefore_, then re-bake the
    // latched chain via bakeChainFrom. Guarded by armedKey_: if the mesh
    // underneath an armed preview was swapped/clobbered by something else
    // since our last touch, drop the preview instead of restoring/cutting
    // against the WRONG mesh. Re-bakes only the latched chain. Hovering never
    // writes the mesh and draws nothing for a not-yet-clicked point: the
    // pre-click display is the target-edge highlight alone, and a point's cut
    // appears at its PRESS (task 7114; measured law, see the design doc).
    void rebuildPreview() {
        if (!chainBefore_.filled || latchedPoints_.length == 0) return;
        // IDENTITY guard (topology, not position); see the `armedKey_` field note.
        if (!armedKey_.matches(*mesh)) { dropArmedPreview(); return; }
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);

        // Task 0429: a standing-preview write into the real mesh (append-
        // latch bake, scrub, pointT/param regrade, peel re-bake — every path
        // funnels through here except armChain's direct bake) invalidates
        // the redo timeline like any new action — see LoopSliceTool.
        // rebuildCut()'s comment for the full law + the /api/undo-bypass
        // residual corner.
        if (history !is null) history.invalidateRedo();
        size_t n = bakeChainFrom(chainBefore_, latchedPoints_);
        built_ = n > 0;
        lastBakedSegments_ = n;
        armedKey_.stamp(*mesh);
        refreshCaches();
    }

    void refreshCaches() {
        version(unittest) if (suppressRefreshForTest_) return;
        refreshDisplay(mesh, gpu);
    }

public:
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && meshSrc_ !is null &&
            &layer.meshRef() is meshSrc_();
    }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest(ref Mesh oldMesh) {
        active = false; armed_ = true; scrubbing_ = true; built_ = true;
        phase_ = Phase.EdgeB; latchedPoints_ = [ChainPoint(1,2,0.25f)];
        edgesParam_ = [3,4]; dragPart_ = 5; activePoint_ = 6;
        split_ = false; middle_ = true; snap_ = 0.75f; show_ = Show.None;
        chainArm_ = [7,8]; tA_ = 0.2f; tB_ = 0.8f; pointProxy_ = 0.3f;
        vpWorld_.view[0] = 9; armedKey_.stamp(oldMesh);
        chainBefore_ = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest(
            ref Mesh oldMesh) const {
        return !active && armed_ && scrubbing_ && built_ && phase_ == Phase.EdgeB &&
            latchedPoints_.length == 1 && latchedPoints_.ptr !is null &&
            edgesParam_ == [3,4] && edgesParam_.ptr !is null && dragPart_ == 5 &&
            activePoint_ == 6 && !split_ && middle_ && snap_ == 0.75f &&
            show_ == Show.None && chainArm_ == [7,8] && tA_ == 0.2f &&
            tB_ == 0.8f && pointProxy_ == 0.3f && vpWorld_.view[0] == 9 &&
            armedKey_.matches(oldMesh) && chainBefore_.filled;
    }
    version(unittest) final bool preparedActivationForTest(
            ref Mesh oldMesh) const {
        return active && !armed_ && !scrubbing_ && !built_ && phase_ == Phase.Idle &&
            latchedPoints_.length == 0 && latchedPoints_.ptr is null &&
            edgesParam_.length == 0 && edgesParam_.ptr is null && dragPart_ == -1 &&
            activePoint_ == -1 && !split_ && middle_ && snap_ == 0.75f &&
            show_ == Show.None && chainArm_ == [7,8] && tA_ == 0.2f &&
            tB_ == 0.8f && pointProxy_ == 0.3f && vpWorld_.view[0] == 9 &&
            armedKey_ == SessionMeshKey.init && !chainBefore_.filled;
    }
    version(unittest) final void seedPreparedDeactivateForTest(ref Mesh live) {
        suppressRefreshForTest_ = true;
        active = true; edgesParam_ = [0, 1]; tA_ = 0.25f; tB_ = 0.75f;
        armChain();
    }
    version(unittest) final bool preparedDeactivateInstalledForTest() const
            nothrow @nogc {
        return !active && !armed_ && !scrubbing_ && !built_ &&
            phase_ == Phase.Idle && latchedPoints_.length == 0 &&
            edgesParam_.length == 0 && dragPart_ == -1 && activePoint_ == -1 &&
            armedKey_ == SessionMeshKey.init && !chainBefore_.filled &&
            handles_.length == 0;
    }
    version(unittest) final void mutatePreparedDeactivateForTest()
            nothrow @nogc { scrubbing_ = !scrubbing_; }
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool armedPreview = false) {
        suppressRefreshForTest_ = true; active = true; edgesParam_ = [0, 1];
        tA_ = 0.25f; tB_ = 0.75f;
        if (armedPreview) armChain();
    }
    version(unittest) final void setPreparedActivePointForTest(int value)
            nothrow @nogc { activePoint_ = value; }
    version(unittest) final void setPreparedPointProxyForTest(float value)
            nothrow @nogc { pointProxy_ = value; }
    version(unittest) final bool preparedParamStateForTest(bool armedExpected,
            int activePointExpected) const {
        return active && armed_ == armedExpected &&
            activePoint_ == activePointExpected &&
            (!armedExpected || (latchedPoints_.length == 2 &&
                armedKey_.matches(*mesh)));
    }
    version(unittest) final void mutatePreparedParamForTest()
            nothrow @nogc { middle_ = !middle_; }
}
