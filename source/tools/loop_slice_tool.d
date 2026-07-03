module tools.loop_slice_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import hover_state : g_hoveredEdge;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.loop_slice_edit : MeshLoopSliceEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

alias LoopSliceEditFactory = MeshLoopSliceEdit delegate();

// ---------------------------------------------------------------------------
// LoopSliceTool — interactive Loop Slice / edge-loop cut (factory id
// `mesh.loopSliceTool`). Coexists with the one-shot `mesh.loopSlice` /
// `mesh.addLoop` commands (source/commands/mesh/loop_slice.d) — those stay
// untouched; this tool is a hover-seeded, drag-to-position alternative that
// reuses the SAME kernel (`Mesh.collectEdgeRing` + `Mesh.insertEdgeLoops`).
//
// v1 scope: Position (single cut) + Count/Uniform (evenly-spaced multi-cut,
// `(k+1)/(count+1)`) + Select New Polygons. Deferred (not greyed, simply
// absent): Inset / Tension / Preserve Curvature / Reverse / Keep Aspect /
// Split / Cap / Gap / Profiles / Free per-slice / Edit=Add-Remove /
// Slice-Selected / Keep-Quads / Slice-N-gon / HUD slider. No n-gon ring
// support (kernel stays quads-only).
//
// Interaction model (see doc/loop_slice_tool_impl_plan.md — this is the
// REVISED §M3, superseding that doc's ghost-preview draft):
//
//   HOVER  (no button held) — highlight-only via `wantsEdgeLoopHover()` +
//     the `HoverEdges` capability (needed so app.d's edge picker keeps
//     publishing `hover_state.g_hoveredEdge` while this tool owns the
//     viewport). The mesh is NEVER mutated during hover.
//
//   SEED LATCH (LMB-down) — `seedEdge_` is latched from `g_hoveredEdge` at
//     the moment of mouse-down and frozen for the whole gesture. If there
//     is no valid hover, or `collectEdgeRing` bails (non-quad / boundary /
//     T-junction guard), the click is a no-op: no drag begins, nothing is
//     selected, the event falls through (return false) so a normal
//     edge-select click still works. A valid seed immediately materialises
//     the default-position cut (so a plain click — no drag — inserts one
//     loop at the current `position_`; dragging repositions it before
//     release).
//
//   DRAG (LMB held) — mutate/revert on the REAL mesh, exactly like
//     EdgeBevelTool's `rebuildPreview`: restore the `before_` baseline, then
//     re-run `insertEdgeLoops(seedEdge_, positions())`. "What you see" IS
//     "what you get" by construction — there is no separate ghost buffer.
//     The cursor is mapped to a position along the ORIGINAL (cached at
//     mouse-down) seed-edge segment via `closestPointOnSegmentToRay`; since
//     that helper returns a CLAMPED POINT (not a scalar), `t` is recovered
//     from the returned point by projecting it back onto the segment.
//
//   COMMIT (LMB-up) — the live mutation IS the result: one snapshot-pair
//     undo entry (`MeshLoopSliceEdit`) is recorded, then `before_` is
//     RE-CAPTURED from the now-committed mesh so the tool re-arms for
//     another cut (Blender loop-cut style — the tool stays active; each cut
//     is its own undo entry). `deactivate()` never commits (each release
//     already did); if interrupted mid-drag it CANCELS (reverts to
//     `before_`) instead, so the mesh never drifts out of sync with the
//     undo history.
//
// Count>1 drag is a deliberate v1 no-op on geometry: `positions()` ignores
// `position_` whenever `count_ > 1` (the evenly-spaced law owns every
// position), so dragging while Count>1 recomputes the SAME spacing every
// frame. Uniform is present for parity but v1 has no Free per-slice law, so
// toggling it off still yields even spacing (documented, not invented).
//
// Headless (`tool.set mesh.loopSliceTool on; tool.attr ... ; tool.doApply`)
// seeds from the FIRST SELECTED EDGE — mirrors `MeshLoopSlice.evaluate`
// (loop_slice.d) — NOT from hover (headless has no cursor). applyHeadless()
// must never touch `seedEdge_` / drag state: `ToolDoApplyCommand` captures
// its own snapshot pair around the call and IS the undo entry.
// ---------------------------------------------------------------------------
final class LoopSliceTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory       history;
    LoopSliceEditFactory factory;

    // Panel params (shared by the interactive path and `tool.attr`).
    float position_  = 0.5f;
    int   count_     = 1;
    bool  uniform_    = true;
    bool  selectNew_  = true;

    // Session state.
    bool         active;
    bool         dragging_;    // between a valid seed-latch and mouse-up
    bool         built_;       // true once the current drag materialised a cut
    int          seedEdge_ = -1;
    Vec3         seedA_, seedB_;   // ORIGINAL (pre-cut) world-space endpoints, cached at latch
    MeshSnapshot before_;      // idle baseline: mesh == before_ whenever !dragging_
    Viewport     cachedVp;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, LoopSliceEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Loop Slice"; }

    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    // HoverEdges: needed so app.d's picker keeps writing hover_state while
    // this tool owns the viewport (pickEdges() gates on wantsHoverForType).
    override ToolFlag flags() const { return ToolFlag.HoverEdges; }

    // Ring highlight before a drag starts; suppressed mid-drag (the real
    // mesh already shows the live cut — a stale ring overlay on top of it,
    // computed from a frozen/now-invalid hover index, would just be noise).
    override bool wantsEdgeLoopHover() const { return !dragging_; }

    override bool isDragging() const { return dragging_; }

    override Param[] params() {
        return [
            Param.float_("position", "Position", &position_, 0.5f)
                 .min(0.001f).max(0.999f),
            Param.int_("count", "Count", &count_, 1).min(1),
            Param.bool_("uniform", "Uniform", &uniform_, true),
            Param.bool_("selectNew", "Select New Polygons", &selectNew_, true),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        dragging_  = false;
        built_     = false;
        seedEdge_  = -1;
        position_  = 0.5f;
        count_     = 1;
        uniform_   = true;
        selectNew_ = true;
        before_    = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // Each cut already committed on its own mouse-up; a mid-drag
        // interruption (e.g. a tool switch) cancels rather than commits, so
        // the mesh never drifts out of sync with the undo history.
        if (active && dragging_) cancelLiveEdit();
        active    = false;
        dragging_ = false;
        seedEdge_ = -1;
    }

    public override bool hasUncommittedEdit() const {
        return active && dragging_;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit && dragging_) rebuildCut();
    }
    override void evaluate() {}

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply). Seeds from the FIRST SELECTED EDGE
    // (mirrors MeshLoopSlice) — MUST NOT touch seedEdge_/dragging_/built_;
    // ToolDoApplyCommand wraps this with its own snapshot pair.
    // -------------------------------------------------------------------
    override bool applyHeadless() {
        if (*editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0)      return false;
        if (!mesh.hasAnySelectedEdges()) return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        bool closed;
        auto ring = mesh.collectEdgeRing(cast(uint)ei, closed);
        if (ring.length == 0) return false;

        uint[] newFaceIndices;
        bool ok = mesh.insertEdgeLoops(cast(uint)ei, positions(), newFaceIndices);
        if (!ok) return false;
        if (selectNew_)
            foreach (fi; newFaceIndices) mesh.selectFace(cast(int)fi);
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Edges)    return false;
        if (dragging_)                      return false;   // re-entrancy guard

        int hov = g_hoveredEdge;
        if (hov < 0 || hov >= cast(int)mesh.edges.length) return false;

        bool closed;
        auto ring = mesh.collectEdgeRing(cast(uint)hov, closed);
        if (ring.length == 0) return false;   // non-quad/boundary seed — no engage

        seedEdge_ = hov;
        seedRail(cast(uint)hov, seedA_, seedB_);
        dragging_ = true;
        built_    = false;
        rebuildCut();   // materialise the default-position cut immediately
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging_) return false;

        Vec3 origin, dir;
        screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, origin, dir);
        Vec3 hit = closestPointOnSegmentToRay(seedA_, seedB_, origin, dir);

        // `hit` is a clamped POINT; recover the scalar t the kernel wants by
        // re-projecting it onto the (unclamped) segment direction.
        Vec3  ab    = seedB_ - seedA_;
        float denom = dot(ab, ab);
        if (denom > 1e-12f) {
            float t = dot(hit - seedA_, ab) / denom;
            if      (t < 0.001f) t = 0.001f;
            else if (t > 0.999f) t = 0.999f;
            position_ = t;
        }
        rebuildCut();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragging_ = false;
        if (built_) commitEdit();
        else {
            // Should not happen (a valid seed always builds), but keep the
            // mesh at rest if it somehow does.
            if (before_.filled) before_.restore(*mesh);
            refreshCaches();
        }
        seedEdge_ = -1;
        built_    = false;
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        // No gizmo/ghost overlay in the revised (mutate/revert) model — the
        // real mesh already shows the live cut. Only the viewport needs
        // caching, for the seed-edge ray cast in onMouseMotion.
        cachedVp = vp;
    }

private:
    // The directed world-space endpoints `position_`/`t` are measured against
    // — MUST match the direction `insertEdgeLoops` actually treats as this
    // seed edge's p-rail, or a drag toward one end lands the cut near the
    // OTHER end. `mesh.edges[seedEdge][0..1]`'s stored order is NOT reliable
    // for this (it's whichever direction `rebuildEdges` first saw while
    // scanning faces in ascending index order, which need not agree with
    // `collectEdgeRing`'s own face-visit order). Instead replicate exactly
    // what `collectEdgeRing` does: the FIRST face `facesAroundEdge` yields
    // (== its own `incFaces[0]`) is the face whose local winding direction
    // for this edge becomes the p-rail's (a,b) — findEdgeInFace + a face-array
    // read reproduce that direction without needing access to the kernel's
    // private `EdgeRingEntry` fields. Exact for a CLOSED ring (the seed
    // edgeKey is only ever touched once, via this face — cube/cylinder belts,
    // the common case); for an OPEN (boundary-terminated) ring the OTHER
    // incident face also touches the same edgeKey and — if it happens to sit
    // at a LOWER face-array index — the kernel's actual direction can flip
    // relative to this. Documented v1 limitation (not invented/fixed here):
    // an open-ring drag may occasionally run toward the opposite end from
    // the cursor; the resulting cut is still valid, undoable geometry.
    void seedRail(uint seedEdge, out Vec3 a, out Vec3 b) {
        uint firstFace = uint.max;
        foreach (fi; mesh.facesAroundEdge(seedEdge)) { firstFace = fi; break; }
        if (firstFace == uint.max) {
            // Unreachable in practice (collectEdgeRing already validated a
            // ring exists at the call site) — fall back to the raw order.
            uint va = mesh.edges[seedEdge][0], vb = mesh.edges[seedEdge][1];
            a = mesh.vertices[va]; b = mesh.vertices[vb];
            return;
        }
        int j0 = mesh.findEdgeInFace(firstFace, mesh.edgeKeyOf(seedEdge));
        auto face = mesh.faces[firstFace];
        uint va = face[j0], vb = face[(j0 + 1) % face.length];
        a = mesh.vertices[va];
        b = mesh.vertices[vb];
    }

    // Evenly-spaced positions for count_ > 1: (k+1)/(count_+1). count_ == 1
    // uses the live drag position_ directly. Uniform is present for parity
    // only — v1 has no Free per-slice law, so it does not change this.
    float[] positions() const {
        if (count_ <= 1) return [position_];
        float[] pos;
        pos.reserve(count_);
        foreach (k; 0 .. count_)
            pos ~= (k + 1.0f) / (count_ + 1.0f);
        return pos;
    }

    // The mutate/revert preview: restore the idle baseline, then reapply the
    // cut from the ORIGINAL seedEdge_ index (valid again immediately after
    // the restore — insertEdgeLoops rebuilds `edges` from scratch every call,
    // so seedEdge_ would be stale against the mesh's CURRENT edge array).
    void rebuildCut() {
        if (!before_.filled || seedEdge_ < 0) return;
        before_.restore(*mesh);
        uint[] newFaceIndices;
        bool ok = mesh.insertEdgeLoops(cast(uint)seedEdge_, positions(), newFaceIndices);
        built_ = ok;
        if (ok && selectNew_)
            foreach (fi; newFaceIndices) mesh.selectFace(cast(int)fi);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null || !before_.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before_, post, "Loop Slice");
        history.record(cmd);
        // Re-arm: the just-committed state becomes the new idle baseline so
        // the tool is ready for another cut (each cut its own undo entry).
        before_ = post;
    }

    void cancelLiveEdit() {
        if (before_.filled) before_.restore(*mesh);
        dragging_ = false;
        built_    = false;
        seedEdge_ = -1;
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
