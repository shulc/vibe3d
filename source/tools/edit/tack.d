module tools.edit.tack;

import bindbc.opengl;
import bindbc.sdl;
import std.math : atan2, abs, PI;
import std.json : JSONValue;

import operator : VectorStack;
import tool;
import mesh;
import math;
import change_bus : MeshEditScope;
import params : Param;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import shader : Shader, LitShader, drawLitPreview;
import hover_state : g_hoveredFace;
import eventlog : queryMouse;
import document : primaryModelSpace;

version (unittest) import std.conv : to;

// ---------------------------------------------------------------------------
// computeTackTransform / applyTackTransform — the captured alignment rule
// (task 0126, doc/tack_tool_plan.md "Phase-0 CAPTURE RESULTS", RFB-injection
// re-capture). Pure module-level free functions (no GL, no Tool instance
// needed) so they're directly unit-testable in `dub test --config=tests`
// against a hand-verified golden fixture — same discipline as
// tools/mirror.d's rebuildMirrorPreview / MirrorParams-free helpers.
//
// Rule (all four unknowns capture-verified against a live reference build,
// two independent seated clicks against the SAME source/target pair):
//   1. Moving set = the CONNECTED ISLAND of the source polygon (see
//      Mesh.connectedComponentVertices, mesh.d) — NOT just the picked
//      face's own corners, NOT the whole mesh.
//   2. Rotation = R180(n_tgt) . R_shortestArc(n_src -> n_tgt): the minimal
//      rotation mapping the source-face normal onto the target-face
//      normal, THEN a 180-degree twist about the target normal. Net effect:
//      source normal ends CO-FACING with the target normal (dot = +1), but
//      tangent-flipped 180 degrees. This composed R was IDENTICAL across
//      both captured clicks against the same source/target pair — the
//      twist is frame-determined, not click-determined.
//   3. Translation anchor = the CLICKED point on the target face (NOT the
//      target centroid) — the source-face centroid lands EXACTLY there
//      after rotation: `t = clickedPoint - R * srcCentroidBefore`.
//
// CAVEAT (documented per the capture brief, doc/tack_tool_plan.md): this
// was captured from ONE source/target geometry pairing. Two independent
// clicks against that same pair confirm the twist is click-independent, but
// a genuinely different source-tangent/target-edge pairing could in
// principle reveal the 180-degree twist is geometry/edge-pairing-specific
// rather than a universal fixed rule. Implement the fixed
// R180 . R_shortestArc rule exactly as captured — do not layer any other
// twist-resolution heuristic on top (e.g. edge-alignment) without a fresh
// capture to justify it.
// ---------------------------------------------------------------------------

/// The rigid transform a tack computes: `after = rotation * before + translation`
/// (rotation applied about the ORIGIN — `rotation`'s translation column is
/// zero, see `pivotRotationMatrix(Vec3(0,0,0), ...)`).
struct TackTransform {
    float[16] rotation = [
        1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1,
    ];
    Vec3 translation = Vec3(0, 0, 0);
}

/// Compute the rigid (R, t) that:
///   - rotates `srcNormal` onto `tgtNormal` by the shortest arc, then twists
///     180 degrees about `tgtNormal` (net: co-facing, tangent-flipped);
///   - translates so `srcCentroid`, after that rotation, lands exactly on
///     `clickedPoint`.
TackTransform computeTackTransform(Vec3 srcCentroid, Vec3 srcNormal,
                                   Vec3 tgtNormal, Vec3 clickedPoint)
{
    Vec3 sn = normalize(srcNormal);
    Vec3 tn = normalize(tgtNormal);

    float c    = dot(sn, tn);
    Vec3  axis = cross(sn, tn);
    float s    = axis.length;

    float[16] rsa;
    if (s < 1e-8f) {
        if (c > 0.0f) {
            // Already co-facing — shortest arc is the identity.
            rsa = identityMatrix;
        } else {
            // Anti-parallel: the cross product is degenerate (any axis
            // perpendicular to sn gives the same 180-degree result).
            Vec3 tmp  = (abs(sn.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
            Vec3 perp = normalize(cross(sn, tmp));
            rsa = pivotRotationMatrix(Vec3(0, 0, 0), perp, cast(float) PI);
        }
    } else {
        Vec3  rotAxis = axis / s;
        // atan2(s, c) recovers the angle between the two unit vectors
        // robustly (avoids acos's poor conditioning near +-1).
        float angle = atan2(s, c);
        rsa = pivotRotationMatrix(Vec3(0, 0, 0), rotAxis, angle);
    }

    float[16] r180 = pivotRotationMatrix(Vec3(0, 0, 0), tn, cast(float) PI);
    // Apply shortest-arc FIRST, then the 180-degree twist:
    // rot = r180 . rsa  (matMul4(a,b) applies b first, then a — the same
    // left-multiply convention as the composeFor chains in math.d).
    float[16] rot = matMul4(r180, rsa);

    Vec3 rotatedCentroid = transformPoint(rot, srcCentroid);
    Vec3 translation     = clickedPoint - rotatedCentroid;

    TackTransform xf;
    xf.rotation    = rot;
    xf.translation = translation;
    return xf;
}

/// Apply `rotation`/`translation` (about the origin) to every vertex marked
/// `true` in `islandMask` — `v_new = rotation * v + translation`. Vertices
/// outside the mask (the read-only target island, any other disjoint mesh
/// part) are left untouched. No-op (returns without touching the mesh) if
/// `islandMask.length` doesn't match the vertex count.
void applyTackTransform(ref Mesh mesh, in bool[] islandMask,
                        in float[16] rotation, Vec3 translation)
{
    if (islandMask.length != mesh.vertices.length) return;
    bool any = false;
    foreach (i; 0 .. islandMask.length) {
        if (!islandMask[i]) continue;
        Vec3 rv = transformPoint(rotation, mesh.vertices[i]);
        mesh.vertices[i] = rv + translation;
        any = true;
    }
    if (any) mesh.commitChange(MeshEditScope.Position);
}

/// Non-cumulative preview rebuild (mirrors tools/mirror.d's
/// rebuildMirrorPreview): restores `previewMesh` fully from `baseSnap`
/// EVERY call, then re-applies the (freshly recomputed) tack transform —
/// so N successive hover-motion calls never accumulate on top of each
/// other. `sourceFace` indexes into the (just-restored) `previewMesh` — its
/// index is stable across a tack (positions move, topology doesn't), so
/// reading centroid/normal off `previewMesh` right after the restore is
/// exactly equivalent to reading them off the live committed mesh.
void rebuildTackPreview(const ref MeshSnapshot baseSnap, ref Mesh previewMesh,
                       in bool[] islandMask, int sourceFace,
                       Vec3 targetNormal, Vec3 clickedPoint)
{
    baseSnap.restore(previewMesh);
    if (sourceFace < 0 || sourceFace >= cast(int)previewMesh.faces.length) return;
    Vec3 srcCentroid = previewMesh.faceCentroid(cast(uint)sourceFace);
    Vec3 srcNormal   = previewMesh.faceNormal(cast(uint)sourceFace);
    auto xf = computeTackTransform(srcCentroid, srcNormal, targetNormal, clickedPoint);
    applyTackTransform(previewMesh, islandMask, xf.rotation, xf.translation);
}

// ---------------------------------------------------------------------------
// TackParams — headless-only inputs (task 0126 Phase 4, fold #1: applyHeadless
// builds its OWN source-face + target from tool params / selection, mirroring
// Mirror's headless mask rule). Tack has no options panel — there is no
// reference options panel; these two fields exist ONLY because a headless
// one-shot has no cursor to click with.
// The INTERACTIVE commit path (onMouseButtonDown) never reads these — it
// derives target face + anchor point entirely from live hover/click.
// ---------------------------------------------------------------------------
struct TackParams {
    int  targetFace  = -1;           // headless: explicit target polygon index
    Vec3 targetPoint = Vec3(0, 0, 0); // headless: explicit anchor point on that face
}

// ---------------------------------------------------------------------------
// TackTool — interactive polygon-to-polygon rigid alignment (factory id
// `mesh.tack`). Modelled on VertexTool's per-click-immediate-commit
// lifecycle (each click commits straight to the document mesh, no deferred
// deactivate()-time commit like Mirror/Box) combined with Mirror's
// snapshot-restore non-cumulative OWN preview mesh for the hover phase
// (rebuildTackPreview above).
//
// Lifecycle:
//   activate()  — reads the pre-selected source polygon from the live face
//                 selection (first selected face; none selected => no-op
//                 guard, matching Mirror's "no interaction => no mirror").
//                 Captures the connected-island mask once (topology-stable
//                 across tacks — a tack only repositions vertices).
//   hover       — every frame, reads `g_hoveredFace` (this tool declares
//                 ToolFlag.HoverPolygons so app.d's existing pickFaces loop
//                 keeps it live) and the current target-face ray hit as the
//                 live anchor; rebuilds the non-cumulative preview.
//   click       — LEFT, no modifiers: commits the SAME transform onto the
//                 real mesh (snapshot pre -> apply -> snapshot post -> one
//                 "Tack" undo entry), re-uploads GPU, re-bases the preview
//                 baseline, and stays active for repeated tacks.
// ---------------------------------------------------------------------------
class TackTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*  gpu;
    LitShader litShader;


    TackParams params_;

    // Source polygon + its connected island, captured at activate(). -1 =
    // no source selected => every interaction is a safe no-op.
    int    sourceFace_ = -1;
    bool[] islandMask_;

    // Preview baseline — re-captured after every commit so the NEXT hover
    // preview builds from the just-committed geometry, not the original.
    MeshSnapshot baseSnap_;
    Mesh         previewMesh_;
    GpuMesh      previewGpu_;
    bool         previewActive_;

    int  hoveredTargetFace_ = -1;
    // LAYER-LOCAL, both of them (task 0619). `targetNormal_` is
    // `mesh.faceNormal`, a winding normal of LOCAL vertices; `clickedPoint_`
    // is the cursor ray's hit against the plane those local values define,
    // resolved in local space by `localAimRay` below. Both are handed
    // straight to `rebuildTackPreview` / `computeTackTransform`, which write
    // LOCAL vertex coordinates — so local is the space this pair must be in.
    Vec3 clickedPoint_;
    Vec3 targetNormal_;

    // The WORLD-space viewport `draw()` was handed. Named `vpWorld_` (task
    // 0619) so a use that needs an AIMING space cannot pick it up by
    // accident. This tool's aiming kind is **RayPlane** (§1.2), which does
    // NOT compose the viewport — see `localAimRay`.
    Viewport vpWorld_;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
    }

    void destroy() {}

    override string name() const { return "Tack"; }

    // Wants the standard face-hover pipeline (app.d's pickFaces loop) so
    // `g_hoveredFace` tracks the cursor while this tool is active — the
    // same mechanism XfrmTransformTool's element-falloff hover relies on.
    override ToolFlag flags() const { return ToolFlag.HoverPolygons; }

    override void activate() {
        sourceFace_ = firstSelectedFace();
        islandMask_ = (sourceFace_ >= 0)
            ? mesh.connectedComponentVertices(cast(uint)sourceFace_)
            : [];
        baseSnap_          = MeshSnapshot.capture(*mesh);
        hoveredTargetFace_ = -1;
        previewActive_     = false;
        previewGpu_.init();
    }

    override void deactivate() {
        previewGpu_.destroy();
        previewActive_ = false;
    }

    // Every click commits immediately (per-click undo, VertexTool-style) —
    // nothing is ever left pending across frames.
    override bool hasUncommittedEdit() const { return false; }
    override void cancelUncommittedEdit() {}

    override void resyncSession() {
        // External undo/redo moved geometry beneath the tool (or restored a
        // different topology) — re-derive the island from the live mesh and
        // re-base the preview baseline.
        if (sourceFace_ >= 0 && sourceFace_ < cast(int)mesh.faces.length)
            islandMask_ = mesh.connectedComponentVertices(cast(uint)sourceFace_);
        else
            islandMask_ = [];
        baseSnap_ = MeshSnapshot.capture(*mesh);
    }

    private int firstSelectedFace() const {
        foreach (i, b; mesh.selectedFaces)
            if (b) return cast(int)i;
        return -1;
    }

    // ----- Params (headless-only convenience — see TackParams doc) --------

    override Param[] params() {
        return [
            Param.int_("targetFace", "Target Face (headless)", &params_.targetFace, -1),
            Param.vec3_("targetPoint", "Target Point (headless)", &params_.targetPoint, Vec3(0, 0, 0)),
        ];
    }

    // ----- Headless one-shot (fold #1: builds its OWN source + target from
    // live selection + params_ — ToolHeadlessCommand never calls activate(),
    // so sourceFace_/islandMask_ are never populated on that throwaway
    // instance). Mirrors Mirror's applyHeadless building its own mask. -----

    override bool applyHeadless() {
        int srcFace = firstSelectedFace();
        if (srcFace < 0) return false;
        if (params_.targetFace < 0 || params_.targetFace >= cast(int)mesh.faces.length) return false;

        bool[] mask = mesh.connectedComponentVertices(cast(uint)srcFace);
        Vec3 srcCentroid = mesh.faceCentroid(cast(uint)srcFace);
        Vec3 srcNormal   = mesh.faceNormal(cast(uint)srcFace);
        Vec3 tgtNormal   = mesh.faceNormal(cast(uint)params_.targetFace);

        auto xf = computeTackTransform(srcCentroid, srcNormal, tgtNormal, params_.targetPoint);
        applyTackTransform(*mesh, mask, xf.rotation, xf.translation);
        gpu.upload(*mesh);
        return true;
    }

    // ----- Test-introspection (task 0234 pattern, GET /api/tool/state) ----

    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]              = JSONValue("mesh.tack");
        root["sourceFace"]        = JSONValue(sourceFace_);
        root["hoveredTargetFace"] = JSONValue(hoveredTargetFace_);
        root["previewActive"]     = JSONValue(previewActive_);
        return root;
    }

    // ----- Live preview (hover) --------------------------------------------

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        if (!visualOnly) vpWorld_ = vp;

        hoveredTargetFace_ = g_hoveredFace;
        previewActive_ = false;

        if (sourceFace_ >= 0 && hoveredTargetFace_ >= 0
            && hoveredTargetFace_ < cast(int)mesh.faces.length)
        {
            // AIMING KIND: **RayPlane** (task 0619 §1.2). Both the anchor and
            // the normal are LAYER-LOCAL (`faceCentroid`/`faceNormal` read
            // `mesh.vertices`), and a local plane maps under `M` exactly onto
            // the plane of the DRAWN face — so the plane needs no carrying.
            // Only the cursor ray does: it is born in world space and is
            // moved into local by `screenPointToLocalRay`.
            Vec3 tgtCentroid = mesh.faceCentroid(cast(uint)hoveredTargetFace_);
            targetNormal_    = mesh.faceNormal(cast(uint)hoveredTargetFace_);

            int mx, my;
            queryMouse(mx, my);
            Vec3 origin, dir;
            screenPointToLocalRay(cast(float)mx, cast(float)my, vpWorld_,
                                  primaryModelSpace(), origin, dir);
            Vec3 hit;
            if (rayPlaneIntersect(origin, dir, tgtCentroid, targetNormal_, hit)) {
                clickedPoint_ = hit;
                rebuildTackPreview(baseSnap_, previewMesh_, islandMask_,
                                   sourceFace_, targetNormal_, clickedPoint_);
                previewGpu_.upload(previewMesh_);
                previewActive_ = true;
            }
        }

        if (!previewActive_) return;

        drawLitPreview(litShader, shader, vp, previewGpu_);
    }

    // ----- Commit (LEFT click, no modifiers — mirrors Mirror/VertexTool) --

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_CTRL | KMOD_SHIFT)) return false;   // reserved for camera / modifiers

        // Read the hover fresh rather than the possibly one-frame-stale
        // draw()-cached hoveredTargetFace_ — input_router.d's refreshHoverPickAt
        // re-runs the hover pick synchronously at the click pixel BEFORE
        // dispatching to the active tool's onMouseButtonDown, precisely so a
        // fast click after a cursor jump doesn't commit against a stale
        // target (same reasoning as XfrmTransformTool.tryPickElement).
        hoveredTargetFace_ = g_hoveredFace;

        // No source selected, or nothing valid hovered => safe no-op (no
        // mesh change, no undo entry) — mirrors Mirror's "no-interaction =>
        // no-mirror" guard.
        if (sourceFace_ < 0 || hoveredTargetFace_ < 0
            || hoveredTargetFace_ >= cast(int)mesh.faces.length)
            return false;

        Vec3 tgtCentroid = mesh.faceCentroid(cast(uint)hoveredTargetFace_);
        Vec3 tgtNormal   = mesh.faceNormal(cast(uint)hoveredTargetFace_);

        // Recompute the exact clicked point at the actual mouse-down pixel
        // (not the possibly one-frame-stale draw()-cached clickedPoint_).
        //
        // AIMING KIND: **RayPlane** (task 0619 §1.2). The whole plane test
        // runs in the LAYER'S LOCAL space: the anchor and normal above are
        // already local, and the cursor ray is carried in.
        //
        // ⚠ THE TRAP (§1.2, written here because this is the site it is
        // instinctive at): the tempting alternative is "transform
        // `tgtCentroid`/`tgtNormal` to WORLD and meet the world ray there".
        // That compiles, and it aims correctly — but it yields a WORLD `hit`,
        // and `applyTackTransform` two lines below writes `hit` into LOCAL
        // vertex coordinates via `computeTackTransform`'s translation. The
        // bug simply moves one call deeper and gets harder to see. Local is
        // chosen BECAUSE the consumer is local.
        Vec3 origin, dir;
        screenPointToLocalRay(cast(float)e.x, cast(float)e.y, vpWorld_,
                              primaryModelSpace(), origin, dir);
        Vec3 hit;
        if (!rayPlaneIntersect(origin, dir, tgtCentroid, tgtNormal, hit))
            return true;   // ray parallel to target plane — consumed, no-op

        Vec3 srcCentroid = mesh.faceCentroid(cast(uint)sourceFace_);
        Vec3 srcNormal   = mesh.faceNormal(cast(uint)sourceFace_);

        MeshSnapshot pre = MeshSnapshot.capture(*mesh);
        auto xf = computeTackTransform(srcCentroid, srcNormal, tgtNormal, hit);
        applyTackTransform(*mesh, islandMask_, xf.rotation, xf.translation);
        gpu.upload(*mesh);

        commitTackEdit(pre);

        // Re-base the preview baseline so the NEXT hover builds from the
        // just-committed geometry (tool stays active for repeated tacks).
        baseSnap_ = MeshSnapshot.capture(*mesh);
        return true;
    }

    private void commitTackEdit(MeshSnapshot pre) {
        if (history is null || gestureFactory is null) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Tack");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }
}
