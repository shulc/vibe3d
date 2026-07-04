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
// Interaction model — task 0232, Model B ("arm-then-commit standing
// preview"), superseding 0228's commit-on-release cycle (see
// doc/loop_slice_slider_hud_impl_plan.md):
//
//   HOVER  (no button held) — highlight-only via `wantsEdgeLoopHover()` +
//     the `HoverEdges` capability (needed so app.d's edge picker keeps
//     publishing `hover_state.g_hoveredEdge` while this tool owns the
//     viewport). The mesh is NEVER mutated during hover.
//
//   ARM (LMB-down on a valid hovered ring) — `seedEdge_` latches from
//     `g_hoveredEdge`. If there is no valid hover, or `collectEdgeRing`
//     bails (non-quad / boundary / T-junction guard), the click is a no-op:
//     nothing arms, the event falls through (return false) so a normal
//     edge-select click still works. A valid seed sets `armed_=true`,
//     `scrubbing_=true` and immediately materialises the default-position
//     cut — a STANDING preview that persists on the real mesh.
//
//   SCRUB — repositions the armed preview via THREE equivalent entry points
//     that all converge on `scrubPosition()`:
//       - mesh drag (`onMouseMotion`, gated on `scrubbing_`): cursor →
//         world-ray → `closestPointOnSegmentToRay` against the ORIGINAL
//         (cached-at-arm) seed segment → recovered scalar `t`;
//       - the HUD marker (app.d, `LoopSliceTool.scrubPosition` called
//         directly — the marker has no mesh-drag session of its own);
//       - a Tool-Properties panel edit of `Position` while armed
//         (`onParamChanged`).
//     `scrubPosition()` clamps and re-runs `rebuildCut()` whenever `armed_`
//     — so a HUD/panel scrub moves the STANDING preview even with the mouse
//     up, and a mesh drag moves it while held. Releasing the mouse
//     (`onMouseButtonUp`) sets `scrubbing_=false` but does NOT commit —
//     the preview stays armed (the change vs 0228).
//
//   COMMIT (Enter/Return, `onKeyDown`, or tool-drop while armed+built) —
//     one snapshot-pair undo entry (`MeshLoopSliceEdit`) is recorded, then
//     `before_` is RE-CAPTURED from the now-committed mesh so the tool
//     re-arms for another cut on the next click.
//
//   CANCEL (Esc/RMB) — restores `before_`, discards the standing preview,
//     no undo entry.
//
// Every path that touches the mesh on commit/cancel/rebuild
// (`commitEdit`/`cancelLiveEdit`/`rebuildCut`) first checks `armedKey_`
// (a `mesh.d` `MeshCacheKey` — address + mutationVersion) against the
// CURRENT mesh. `armedKey_` is stamped to reflect the mesh exactly as WE
// last left it after every mutation we make; if some OTHER path swapped the
// mesh out from under an armed preview since then — scene.reset rewrites
// `*mesh` IN PLACE (same address, `mutationVersion` resets — `mesh.d:143`),
// an active-layer switch retargets `meshSrc_()` to a DIFFERENT Layer's mesh
// field entirely (different address) — the key mismatches and every one of
// these paths calls `dropArmedPreview()` instead: clears `armed_` /
// `scrubbing_` / `built_` / `seedEdge_` / `armedKey_` WITHOUT touching the
// mesh or history. app.d additionally calls `dropArmedPreview()` explicitly,
// BEFORE the generic tool-drop, at the two known mesh-swap sites
// (scene.reset / file.new's `onResetTool`, and `onActiveLayerChanged`) —
// see the comments there. `navHistory` (app.d) also widens its
// cancel-an-open-session guard to cover REDO (not just undo) so a redo can
// never apply on top of an uncommitted standing preview.
//
// Count>1 drag is a deliberate v1 no-op on geometry: `positions()` ignores
// `position_` whenever `count_ > 1` (the evenly-spaced law owns every
// position), so scrubbing while Count>1 recomputes the SAME spacing every
// time. Uniform is present for parity but v1 has no Free per-slice law, so
// toggling it off still yields even spacing (documented, not invented). The
// HUD (app.d) is hidden entirely when `count_ > 1` for the same reason.
//
// Headless (`tool.set mesh.loopSliceTool on; tool.attr ... ; tool.doApply`)
// seeds from the FIRST SELECTED EDGE — mirrors `MeshLoopSlice.evaluate`
// (loop_slice.d) — NOT from hover (headless has no cursor) and NEVER sets
// `armed_`/`scrubbing_` (`--test` never arms). applyHeadless() must never
// touch `seedEdge_` / session state: `ToolDoApplyCommand` captures its own
// snapshot pair around the call and IS the undo entry.
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

    // Task 0232: Loop Slice Slider HUD geometry — screen-pixel width
    // (`length_`) and offset (`sliderX_`/`sliderY_`) of the track drawn in
    // the active viewport cell's top-left corner. Pure display geometry:
    // they never affect the cut (onParamChanged() below early-returns for
    // these three names) and are NOT reset by reinitSession() — a user's
    // HUD placement should persist across re-arms within a session.
    int   length_  = 200;
    int   sliderX_ = 20;
    int   sliderY_ = 50;

    // Session state (task 0232, Model B).
    bool         active;
    bool         armed_;       // a standing preview cut sits on the real mesh
    bool         scrubbing_;   // a MESH drag is currently repositioning it (subset of armed_)
    bool         built_;       // true once the last rebuildCut() materialised a cut
    int          seedEdge_ = -1;
    Vec3         seedA_, seedB_;   // ORIGINAL (pre-cut) world-space endpoints, cached at arm
    MeshSnapshot before_;      // idle baseline: mesh == before_ whenever !armed_
    // Address + mutationVersion of the mesh exactly as WE last left it — see
    // the header comment. Stamped at the end of every successful rebuildCut()
    // (and once, trusted, at arm-time). Any commit/cancel/rebuild first checks
    // this against the CURRENT mesh; a mismatch means some OTHER path (reset,
    // layer switch) touched the mesh since, and the preview is dropped rather
    // than committed/restored against the wrong target.
    MeshCacheKey armedKey_;
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

    // Ring highlight before anything is armed; suppressed for the WHOLE armed
    // period (not just a live mesh-drag) — the standing preview already shows
    // the live cut, and a stale ring overlay computed from a frozen/now-
    // invalid hover index would just be noise (task 0232 widens this from
    // 0231's `!dragging_` to `!armed_`).
    override bool wantsEdgeLoopHover() const { return !armed_; }

    // The hover ring must be the ring the SLICE lands on (seed + quad-ring exit
    // rails), NOT the classic edge loop through the hovered edge — those run
    // perpendicular. Without this the highlighted ring and the actual cut point
    // in different directions (task 0231).
    override bool edgeLoopHoverSliceRing() const { return true; }

    // True only during an actual MESH drag (subset of `armed_`) — the app's
    // per-frame hover freeze (isDragging-guard) only needs to hold during a
    // real drag gesture, not for the whole (potentially long) armed period.
    override bool isDragging() const { return scrubbing_; }

    override Param[] params() {
        return [
            Param.float_("position", "Position", &position_, 0.5f)
                 .min(0.001f).max(0.999f),
            Param.int_("count", "Count", &count_, 1).min(1),
            Param.bool_("uniform", "Uniform", &uniform_, true),
            Param.bool_("selectNew", "Select New Polygons", &selectNew_, true),
            // Task 0232 — HUD geometry only, see the field comments above.
            Param.int_("length",  "Length",   &length_,  200).min(20).max(2000),
            Param.int_("sliderX", "Slider X", &sliderX_, 20).min(0),
            Param.int_("sliderY", "Slider Y", &sliderY_, 50).min(0),
        ];
    }

    // -------------------------------------------------------------------
    // Task 0232 — read-only accessors for app.d's HUD block (kept the
    // fields private; the HUD reads through here rather than reaching in).
    // -------------------------------------------------------------------
    public float position() const { return position_; }
    public int   length_px() const { return length_; }
    public int   sliderX()  const { return sliderX_; }
    public int   sliderY()  const { return sliderY_; }
    public int   count()    const { return count_; }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        armed_     = false;
        scrubbing_ = false;
        built_     = false;
        seedEdge_  = -1;
        position_  = 0.5f;
        count_     = 1;
        uniform_   = true;
        selectNew_ = true;
        // length_/sliderX_/sliderY_ deliberately NOT reset — see field comment.
        armedKey_.invalidate();
        before_    = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // D3 (task 0232): an armed+built standing preview is a deliberate
        // placement — commit it on tool-drop, same as any other tool-switch
        // commit point. A mid-scrub interruption, or an armed-but-unbuilt
        // edge case, cancels instead. Both commitEdit()/cancelLiveEdit()
        // self-guard against a mesh swapped out from under us (see their
        // bodies) — but for the two KNOWN swap sites (scene.reset/file.new,
        // active-layer switch) app.d calls `dropArmedPreview()` explicitly
        // BEFORE this ever runs, so `armed_` is already false here in those
        // cases and this branch is a no-op.
        if (active && armed_) {
            if (built_) commitEdit();
            else        cancelLiveEdit();
        }
        active = false;
        dropArmedPreview();
    }

    public override bool hasUncommittedEdit() const {
        return active && armed_;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    // A standing armed preview sits on the mesh across arbitrary frames, so a
    // REDO reachable while armed must cancel it first (else the redo would apply
    // on top of the uncommitted cut and resyncSession() would bake it in). This
    // is what makes the navHistory redo-cancel narrow: it fires ONLY for this
    // tool's armed preview, never for refire-based tools (BoxTool) whose
    // uncommitted edit must redo normally on Ctrl+Shift+Z.
    public override bool cancelsOnRedo() const {
        return active && armed_;
    }

    public override void resyncSession() {
        if (!active) return;
        // An armed standing preview must never be silently wiped by a
        // resync — the only authorized way to end one is commit/cancel
        // (Enter/Esc/RMB/tool-drop), or the navHistory chokepoint's own
        // cancelUncommittedEdit() call, which always runs BEFORE this could
        // be reached for an armed session (see app.d's navHistory). This
        // guard is defence in depth: it should never actually trigger.
        if (armed_) return;
        reinitSession();
    }

    /// Discard the standing preview WITHOUT touching the mesh or recording
    /// anything to history. For exit paths where the underlying mesh may
    /// already have been swapped/overwritten out from under this tool by the
    /// time this runs — scene.reset's `onResetTool` fires AFTER `*mesh = ...`
    /// has already run; an active-layer-change hook fires AFTER the primary
    /// already switched — committing or restoring there would corrupt the
    /// new mesh or fabricate a bogus undo entry (task 0232). Safe to call
    /// even when nothing is armed (no-op).
    public void dropArmedPreview() {
        armed_     = false;
        scrubbing_ = false;
        built_     = false;
        seedEdge_  = -1;
        armedKey_.invalidate();
    }

    override void onParamChanged(string pname) {
        // HUD geometry only — never touches the cut.
        if (pname == "length" || pname == "sliderX" || pname == "sliderY") return;
        if (interactiveParamEdit && armed_) rebuildCut();
    }
    override void evaluate() {}

    /// Single entry point for repositioning the ARMED standing preview —
    /// the mesh-drag path (`onMouseMotion`), the HUD marker (app.d), and a
    /// Tool-Properties panel edit of `Position` (`onParamChanged`) all
    /// converge here so they can never diverge in effect. Clamps and, while
    /// armed, re-runs `rebuildCut()` — so a HUD/panel scrub moves the
    /// standing preview even with the mouse up.
    public void scrubPosition(float p) {
        if      (p < 0.001f) p = 0.001f;
        else if (p > 0.999f) p = 0.999f;
        position_ = p;
        if (armed_) rebuildCut();
    }

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply). Seeds from the FIRST SELECTED EDGE
    // (mirrors MeshLoopSlice) — MUST NOT touch seedEdge_/armed_/scrubbing_/
    // built_; ToolDoApplyCommand wraps this with its own snapshot pair.
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
        if (scrubbing_)                     return false;   // re-entrancy guard

        if (armed_) {
            // D2 (task 0232): a press while already armed re-scrubs the
            // SAME ring — seed stays fixed. To cut a different ring the
            // user commits/cancels first. If the mesh underneath the armed
            // preview was swapped/clobbered since our last touch, drop it
            // instead of re-engaging against the wrong target.
            if (seedEdge_ < 0 || !armedKey_.matches(*mesh)) {
                dropArmedPreview();
                return false;
            }
            seedRail(cast(uint)seedEdge_, seedA_, seedB_);
            scrubbing_ = true;
            return true;
        }

        int hov = g_hoveredEdge;
        if (hov < 0 || hov >= cast(int)mesh.edges.length) return false;

        bool closed;
        auto ring = mesh.collectEdgeRing(cast(uint)hov, closed);
        if (ring.length == 0) return false;   // non-quad/boundary seed — no engage

        seedEdge_ = hov;
        seedRail(cast(uint)hov, seedA_, seedB_);
        armed_     = true;
        scrubbing_ = true;
        built_     = false;
        // Trusted baseline: this IS the mesh we're arming against (nothing
        // could have swapped it out between the hover-read above and here,
        // all synchronous within this one handler).
        armedKey_.stamp(*mesh);
        rebuildCut();   // materialise the default-position cut immediately
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;

        Vec3 origin, dir;
        screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, origin, dir);
        Vec3 hit = closestPointOnSegmentToRay(seedA_, seedB_, origin, dir);

        // `hit` is a clamped POINT; recover the scalar t the kernel wants by
        // re-projecting it onto the (unclamped) segment direction.
        Vec3  ab    = seedB_ - seedA_;
        float denom = dot(ab, ab);
        if (denom > 1e-12f) {
            float t = dot(hit - seedA_, ab) / denom;
            scrubPosition(t);
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        scrubbing_ = false;
        // Model B: mouse-up no longer commits — the preview STAYS armed
        // until Enter (commit) or Esc/RMB (cancel). If the last rebuildCut()
        // somehow failed to build (should not happen — a valid seed always
        // builds), fail safe by cancelling rather than leaving a bogus
        // armed-but-empty state.
        if (!built_) cancelLiveEdit();
        return true;
    }

    // Commit (Enter/Return) / cancel (Esc) the standing preview. RMB is
    // already handled in onMouseButtonDown for the "held mouse" path; this
    // covers the keyboard path, which is how a scrub-free arm (HUD/panel-only
    // scrubbing, mouse never held) gets committed.
    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        if (!active || !armed_) return false;
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                commitEdit();
                return true;
            case SDLK_ESCAPE:
                cancelLiveEdit();
                return true;
            default:
                return false;
        }
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
    //
    // Guarded by `armedKey_` (task 0232 fold #1): if the mesh underneath an
    // armed preview was swapped/clobbered by something else since our last
    // touch, drop the preview instead of restoring/inserting against the
    // WRONG mesh.
    void rebuildCut() {
        if (!before_.filled || seedEdge_ < 0) return;
        if (!armedKey_.matches(*mesh)) { dropArmedPreview(); return; }
        before_.restore(*mesh);
        uint[] newFaceIndices;
        bool ok = mesh.insertEdgeLoops(cast(uint)seedEdge_, positions(), newFaceIndices);
        built_ = ok;
        if (ok && selectNew_)
            foreach (fi; newFaceIndices) mesh.selectFace(cast(int)fi);
        // Re-stamp regardless of `ok` — after this line the mesh is in a
        // KNOWN state WE produced (either the successful cut, or just the
        // restored baseline if insertEdgeLoops failed).
        armedKey_.stamp(*mesh);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null || !before_.filled) return;
        if (!armedKey_.matches(*mesh)) {
            // The mesh underneath us was swapped/clobbered (scene reset,
            // active-layer switch) since our last touch — the standing
            // preview is no longer meaningfully "ours" to commit. Committing
            // here would fabricate a bogus undo entry against the wrong
            // mesh (task 0232 fold #1); silently drop it instead.
            dropArmedPreview();
            return;
        }
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before_, post, "Loop Slice");
        history.record(cmd);
        // Re-arm: the just-committed state becomes the new idle baseline so
        // the tool is ready for another cut (each cut its own undo entry).
        before_ = post;
        dropArmedPreview();
    }

    void cancelLiveEdit() {
        // Same hazard as commitEdit: only restore `before_` if the mesh is
        // still the one we armed against (armedKey_ match) — otherwise there
        // is nothing safely ours to restore; just drop the state.
        if (armedKey_.matches(*mesh) && before_.filled) before_.restore(*mesh);
        dropArmedPreview();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
