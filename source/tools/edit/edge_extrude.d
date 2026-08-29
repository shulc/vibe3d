module tools.edit.edge_extrude;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, CubicArrow, ToolHandles, HandleState, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import drag : screenAxisDelta, gesturePrevPixel;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;

import std.math : abs, sqrt;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;

/// The interactive tool records into `MeshSessionEdit` — a before/after
/// `MeshSnapshot` pair, or an operation-log `MeshEditDelta` — with the label
/// reading "Edge Extrude". Its `EdgeExtrudeEditFactory` alias is gone as of
/// task 1905 phase B (as are `BoxEditFactory` and the rest of the create
/// family's): the carrier is built through `Tool.gestureFactory`, a plain
/// `Command delegate()`, and this file downcasts to the class it fills.
// ---------------------------------------------------------------------------
// EdgeExtrudeTool — interactive Edge Extrude (factory id `edge.extrude`).
//
// Modelled on BoxTool / PenTool (NOT TransformTool): topology-creating tools
// own their undo plumbing and commit ONE before/after MeshSnapshot record
// command at deactivate. TransformTool's vertex-position-delta MeshVertexEdit
// cannot undo added verts/faces, so it is unusable here.
//
// Session model (the BoxTool commit pattern):
//   activate()  — capture `before` = MeshSnapshot.capture(mesh) (geometry +
//                 selection); reset extrude/width to 0 (identity ⇒ no-op).
//                 ALSO compute the gizmo anchor (selection centroid) + the two
//                 handle axes (extrude = averaged neighbour-polygon normal;
//                 width = in-plane inset direction) from the ORIGINAL
//                 pre-extrude selection, so the gizmo doesn't jump as the mesh
//                 changes during the drag.
//   drag        — restore `before` (re-establishes the original cage AND the
//                 original edge selection), recompute the (extrude,width) pair
//                 from the accumulated screen-space mouse delta, re-run
//                 Mesh.extrudeEdgesByMask on the restored selection, then
//                 gpu.upload + cache refresh.
//   deactivate() — if any geometry was built (extrude or width nonzero),
//                 capture `after`, build a MeshSessionEdit via the injected
//                 factory, setSnapshots(before, after, "Edge Extrude"), and push
//                 it onto history as ONE undo step.
//
// Interaction (two REAL clickable gizmo handles, matching the reference
// modeler's edge-extrude tool, registered in a `ToolHandles` arbiter):
//   - Handle EXTRUDE = a BLUE Arrow anchored at the selection centroid,
//     pointing along the averaged extrude direction. Dragging it changes
//     `extrude` only (mouse delta projected onto the arrow's screen-space
//     direction → world distance → param delta).
//   - Handle WIDTH = a RED CubicArrow (a shaft with a small cube at the tip,
//     matching the reference modeler's scale-axis handle / vibe3d's
//     ScaleHandler) running from the gizmo anchor along the in-plane inset
//     direction. Dragging it changes `width` only.
// Both handles get their highlight (Rollover) state ONLY from the
// ToolHandles arbiter's update→setState pass (the handle-arbiter model), so
// they highlight on hover and the dragged handle stays highlighted while
// hauling. No more blind whole-screen 2-axis drag.
//
// The headless path (`tool.set edge.extrude on; tool.attr edge.extrude
// extrude <v>; tool.attr edge.extrude width <v>; tool.doApply`) drives the
// SAME kernel through applyHeadless(); ToolDoApplyCommand wraps it with a
// snapshot pair for undo (so applyHeadless MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class EdgeExtrudeTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;


    // Parameters — exposed via params() so both the Tool Properties panel
    // and the headless tool.attr path write into them.
    float extrude_ = 0.0f;
    float width_   = 0.0f;

    // Interactive session state.
    bool          active;          // between activate() and deactivate()
    bool          built;           // true once a nonzero extrude/width built topology
    /// Captured at activate() (geometry + selection). TWO readers, and after
    /// task 1903 Stage N only one of them is about undo:
    ///   1. `commitEdit`'s rewind — `before.restore(*mesh)` puts the clean cage
    ///      and the ORIGINAL edge selection back so the committed re-run
    ///      extrudes the right edges. That is a preview baseline, the use
    ///      `MeshSnapshot` is correct for, and it is permanent.
    ///   2. the DEGENERATE-DELTA fallback — when the committed re-run records
    ///      an empty delta, this pairs with a fresh capture through
    ///      `setSnapshots` so the history entry is still well-formed.
    /// Reader 2 used to be the `VIBE3D_UNDO_TRACKER=0` arm as well; Stage N
    /// deleted the flag and kept the fallback (ruling N-R1). The open question
    /// it answers — should a zero-delta tool commit record a whole-mesh pair or
    /// refuse? — is task 1905's, because it is a tool COMMIT-semantics
    /// decision, and this field cannot go until 1905 answers it.
    MeshSnapshot  before;
    Viewport      cachedVp;        // last frame's viewport (for the gizmo handles)

    // Gizmo frame, computed at activate() from the ORIGINAL (pre-extrude)
    // selection. `gizmoValid` is false when there is no extrudable selection
    // (empty mesh) — the handles are then not drawn / not registered.
    bool gizmoValid;
    Vec3 anchor;        // selection centroid (analytic, updated each frame in draw())
    Vec3 baseAnchor;    // ORIGINAL pre-extrude selected-edge centroid (fixed per frame from selection)
    Vec3 extrudeAxis;   // unit: averaged neighbour-polygon normal (ridge lift dir)
    Vec3 widthAxis;     // unit: in-plane inset direction (perpendicular to edge tangent)
    ulong gizmoSelHash;  // selection signature the gizmo frame was built for

    // Drag state — which handle (part id) is being hauled, and the per-handle
    // base param + last mouse position for the axis-projected delta.
    enum int PART_EXTRUDE = 0;
    enum int PART_WIDTH    = 1;
    enum int PART_FREE     = 2;    // off-handle blind 2-axis screen drag
    int   dragPart = -1;           // -1 = none, PART_EXTRUDE / PART_WIDTH / PART_FREE
    int   dragLastMX, dragLastMY;  // last mouse pos (incremental on-handle drags)
    int   dragStartMX, dragStartMY;// drag-start mouse pos (total-delta free drag)
    float dragBaseExtrude, dragBaseWidth;
    // Ctrl axis-lock for the free drag, LATCHED once a clear direction is set
    // so it never flips mid-drag: 0 = unlocked, 1 = extrude-only, 2 = width-only.
    int   freeLockAxis = 0;

    // Pixel→param scale for the off-handle free drag (matches the tool's prior
    // blind whole-screen 2-axis drag scale).
    enum float FREE_SCALE = 0.01f;

    // Two registered, clickable gizmo handles + their arbiter.
    Arrow       extrudeArrow;      // BLUE — extrude (cone head)
    CubicArrow  widthArrow;        // RED  — width   (cube head, scale-axis style)
    ToolHandles toolHandles;

    enum Vec3 EXTRUDE_COLOR = schemeColor(SchemeColor.toolOffset);
    enum Vec3 WIDTH_COLOR   = schemeColor(SchemeColor.toolWidth);

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        // Geometry placeholders; the real anchor/axes are written each frame
        // in draw() from the activate()-computed gizmo frame.
        extrudeArrow = new Arrow(Vec3(0, 0, 0), Vec3(0, 0, 1), EXTRUDE_COLOR);
        widthArrow   = new CubicArrow(Vec3(0, 0, 0), Vec3(1, 0, 0), WIDTH_COLOR);
        toolHandles  = new ToolHandles();
    }

    void destroy() {
        if (extrudeArrow !is null) extrudeArrow.destroy();
        if (widthArrow   !is null) widthArrow.destroy();
    }

    override string name() const { return "Edge Extrude"; }

    // Edge Extrude only makes sense on an edge selection.
    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        return [
            Param.float_("extrude", "Extrude", &extrude_, 0.0f),
            Param.float_("width",   "Width",   &width_,   0.0f),
        ];
    }

    override void activate() {
        active   = true;
        reinitSession();
    }

    // (Re)initialise the edit session against the CURRENT mesh — shared by
    // activate() and resyncSession() (undo/redo migration P1) so the two can't
    // drift. Deliberately does NOT set `active` (resyncSession keeps the tool
    // active; activate() owns the flag): re-snapshots the cage + selection,
    // clears any built preview + params, and re-derives the gizmo/edge-selection
    // frame. Re-capturing `before` here is the selection-index liveness fix —
    // after a topology-changing undo the stored edge selection is re-derived
    // live from the now-current mesh (Objection 5).
    private void reinitSession() {
        built    = false;
        dragPart = -1;
        extrude_ = 0.0f;
        width_   = 0.0f;
        // Snapshot the cage + selection at the start of the session. The
        // per-drag revert+reapply restores from here; the commit pairs it
        // with the final `after`.
        before = MeshSnapshot.capture(*mesh);
        // Build the gizmo anchor + axes from the original pre-extrude
        // selection so the handles stay put across the drag.
        computeGizmoFrame();
    }

    override void deactivate() {
        // Commit one undo step iff a nonzero param actually built topology.
        if (active && built && (extrude_ != 0.0f || width_ != 0.0f))
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // Commit guard mirror: deactivate() (:196) records exactly when
    // `active && built && (extrude_ != 0 || width_ != 0)`, so that IS the
    // "would a commit fire now" predicate.
    public override bool hasUncommittedEdit() const {
        return active && built && (extrude_ != 0.0f || width_ != 0.0f);
    }

    // Category A cancel — restore the clean cage via the shared helper.
    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    // Resync after a committed undo/redo moved geometry beneath the active
    // tool: re-capture the session baseline + rebuild the gizmo from the now-
    // current mesh, and clear any (now invalid) built preview state. Shares the
    // one (re)init body with activate() so the two can't drift.
    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    // Framework "apply and continue" (task 0461, Shift+click): commit the live
    // edit as its own undo entry, keeping the tool active; the driver follows
    // with resyncSession() to re-arm in place. Mirrors deactivate()'s commit
    // guard minus the teardown.
    public override bool commitUncommittedEdit() {
        if (!hasUncommittedEdit()) return false;
        commitEdit();
        return true;
    }

    // A parameter changed. Two callers, distinguished by `interactiveParamEdit`
    // (set by PropertyPanel only):
    //   - Interactive Tool Properties edit → rebuild the live preview from the
    //     clean cage (the same revert+reapply the drag path uses), so the
    //     panel's Extrude/Width sliders update the mesh immediately.
    //   - Headless `tool.attr ...; tool.doApply` → leave the mesh untouched.
    //     applyHeadless() runs the kernel once from the clean cage; mutating
    //     the mesh on every attr write would double-apply AND poison
    //     ToolDoApplyCommand's pre-snapshot (captured AFTER the attr writes).
    override void onParamChanged(string name) {
        if (interactiveParamEdit) rebuildPreview();
    }
    override void evaluate() {}

    // Read-only test/introspection seam (mirrors poly.bevel / edge.bevel):
    // exposes the tool's live params to /api/tool/state + the step-trace `tool`
    // block so a per-step differential (trace_diff) can route this headless
    // `tool.doApply` edit by its identity and read extrude/width.
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]     = JSONValue("edgeExtrude");
        root["extrude"]  = JSONValue(extrude_);
        root["width"]    = JSONValue(width_);
        root["built"]    = JSONValue(built);
        root["dragPart"] = JSONValue(dragPart);
        return root;
    }

    // -----------------------------------------------------------------------
    // Headless apply (tool.doApply). Runs the kernel on the current edge
    // selection. MUST NOT snapshot — ToolDoApplyCommand wraps with undo.
    // -----------------------------------------------------------------------
    override bool applyHeadless() {
        if (*editMode != EditMode.Edges) return false;
        // If a live drag previously built preview topology, restore the clean
        // cage first so the kernel applies exactly once (idempotent). In the
        // pure headless flow (no drag) `before` == the current mesh, so this
        // is a no-op and ToolDoApplyCommand's pre-snapshot stays clean.
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.edges.length == 0) return false;
        if (extrude_ == 0.0f && width_ == 0.0f) return true;   // no-op success
        auto mask = currentMask();
        // task 1903 Stage H: extrudeEdgesByMask takes `ref MeshEditBatch` now.
        // `ToolDoApplyCommand` wraps this whole call with a MeshSnapshot, so
        // this batch is unrecorded — recording one here would build a delta
        // no caller reads and discard it.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extrudeEdgesByMask(mask, extrude_, width_);
        ed.close();
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    // -----------------------------------------------------------------------
    // Interactive drag — driven by the two registered handles, NOT a blind
    // whole-screen 2-axis drag.
    //
    // LMB-down: hit-test the arbiter. The arrow part begins an extrude drag
    // (records the base extrude); the box part begins a width drag (records
    // the base width). A click that hits neither handle does nothing (no
    // blind drag starts).
    // -----------------------------------------------------------------------
    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            // Cancel: drop any built topology, restore the original cage.
            cancelLiveEdit();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera
        if (*editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0 || !gizmoValid) return false;

        // Ask the arbiter which handle (if any) the click landed on.
        int part = toolHandles.test(e.x, e.y, cachedVp);

        dragLastMX      = e.x;
        dragLastMY      = e.y;
        dragStartMX     = e.x;
        dragStartMY     = e.y;
        dragBaseExtrude = extrude_;
        dragBaseWidth   = width_;
        freeLockAxis    = 0;   // fresh latch for any new free drag

        if (part == PART_EXTRUDE || part == PART_WIDTH) {
            // On-handle: single-axis world-projected incremental drag.
            dragPart = part;
            toolHandles.setHaul(part);
            return true;
        }

        // Off-handle (miss): begin a blind 2-axis screen-space free drag —
        // up/down → extrude, left/right → width. No handle is captured, so we
        // do NOT setHaul.
        dragPart = PART_FREE;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || !gizmoValid) return false;

        if (dragPart == PART_FREE) {
            // Off-handle blind 2-axis screen drag. Use the TOTAL delta from the
            // drag start (not incremental) so the Ctrl axis-lock below can pin
            // one axis cleanly without accumulating drift. Screen mapping (NOT
            // world-axis): up (−dy) → +extrude, right (+dx) → +width.
            int dx = e.x - dragStartMX;
            int dy = e.y - dragStartMY;
            extrude_ = dragBaseExtrude + (-dy) * FREE_SCALE;
            width_   = dragBaseWidth   + ( dx) * FREE_SCALE;
            // Ctrl locks the drag to ONE axis. LATCH the axis the first time
            // Ctrl is held with a clear dominant direction (>= LATCH_PX), then
            // keep it for as long as Ctrl stays down — recomputing dominance
            // every frame let a near-diagonal / direction-changing drag flip
            // the lock between extrude and width ("doesn't always lock").
            // Releasing Ctrl clears the latch (free 2-axis resumes; re-pressing
            // re-latches).
            if (SDL_GetModState() & KMOD_CTRL) {
                if (freeLockAxis == 0) {
                    enum int LATCH_PX = 4;
                    if (abs(dx) >= LATCH_PX || abs(dy) >= LATCH_PX)
                        freeLockAxis = (abs(dy) >= abs(dx)) ? 1 : 2;
                }
                if      (freeLockAxis == 1) width_   = dragBaseWidth;    // EXTRUDE only
                else if (freeLockAxis == 2) extrude_ = dragBaseExtrude;  // WIDTH only
            } else {
                freeLockAxis = 0;
            }
            if (width_ < 0.0f) width_ = 0.0f;
            rebuildPreview();
            dragLastMX = e.x;
            dragLastMY = e.y;
            return true;
        }

        // On-handle: project the per-event mouse delta onto the screen-space
        // direction of the dragged handle's WORLD axis to get a world-space
        // distance, then map that distance directly to the param (1 world unit
        // = 1 param unit, since both extrude and width are world-space offsets
        // the kernel adds along these very axes). screenAxisDelta returns
        // `axis * d`; the signed magnitude `d` along the unit axis IS the param
        // delta.
        // The previous pixel comes from the cooked gesture, not from this
        // tool's own pair — same integer subtraction, sourced one level up.
        // `dragLastMX/MY` stay written as the fallback when no gesture is
        // published and as the other half of the debug agreement check. The
        // PART_FREE branch above measures from the PRESS pixel, not the
        // previous one, and is deliberately left alone.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         dragLastMX, dragLastMY, prevMX, prevMY);
        Vec3 axis = (dragPart == PART_EXTRUDE) ? extrudeAxis : widthAxis;
        bool skip;
        // Projected in the space the arm is DRAWN in, and converted back into
        // the LOCAL length the kernel means (task 0645) — one OverlayAxis in
        // both roles, so the arm the pixels are dotted against is the arm on
        // screen and the geometry follows it.
        const auto os = OverlaySpace.ofPrimary();
        const auto ax = os.axis(axis);
        Vec3 delta = screenAxisDelta(e.x, e.y, prevMX, prevMY,
                                     os.pos(anchor), ax.dir, cachedVp, skip);
        if (!skip) {
            // ax.dir is unit ⇒ a signed WORLD distance; toLocal makes it the
            // param's own unit.
            float d = ax.toLocal(dot(delta, ax.dir));
            if (dragPart == PART_EXTRUDE) extrude_ += d;
            else                          width_   += d;
            // Width is a shrink amount: the kernel no-ops for width < ~0 and
            // treats tiny widths as a no-op. Clamp to >= 0 so a backward drag
            // can't drive it negative.
            if (width_ < 0.0f) width_ = 0.0f;
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        return true;
    }


    // Read-only test seam (task 0645) — GET /api/tool/handles. The registry
    // stays the hit-testing authority; this only exposes its already-drawn
    // state, and that state is the ONLY place a handle's SPACE is observable
    // from outside the process. Mirrors PolyBevelTool / EdgeBevelTool, which
    // carried it already.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // Selection may have changed since activate() (e.g. the user picked a
        // different edge in the viewport before grabbing a handle). Recompute
        // the gizmo FRAME (anchor + the fixed axes) when it does — but never
        // mid-drag (the moving set is frozen for the whole haul), and never
        // once a preview is BUILT: applying an extrude/width reselects the
        // lifted ridge edges, which changes the selection hash. Recomputing
        // then would reset baseAnchor to the ridge centroid (= orig +
        // extrude_*axis) while extrude_ still holds its value, so the analytic
        // anchor = baseAnchor + extrude_*axis would double-count and the gizmo
        // would jump (e.g. when switching from the extrude to the width
        // handle). The frame is frozen for the rest of the session once built.
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Edges) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        // Anchor is computed ANALYTICALLY from the extrude VALUE, not the live
        // mesh: anchor = baseAnchor + extrude_ * extrudeAxis. This makes the
        // gizmo slide outward with the extrude value even when width==0 (the
        // kernel no-ops for width<1e-6, so no ridge is built and the live
        // selection stays on the original edge — but the handle gives
        // predictive feedback regardless). When width>0 the ridge centroid IS
        // baseAnchor + extrude_*extrudeAxis (ridge = original + extrude*averaged
        // normal), so this also reproduces the prior "follows the live edge"
        // behaviour. The AXES stay fixed (computed once from the ORIGINAL
        // pre-extrude neighbour normals); only the position moves.
        anchor = baseAnchor + extrudeAxis * extrude_;   // LOCAL, like the kernel

        // ONE overlay space for the pass (task 0645): both arms are positioned
        // in it and `toolHandles.update` below hit-tests these same objects, so
        // drawing and hitting cannot land in different spaces.
        const auto os        = OverlaySpace.ofPrimary();
        const auto extrudeAx = os.axis(extrudeAxis);
        const auto widthAx   = os.axis(widthAxis);
        const Vec3 anchorW   = os.pos(anchor);

        // Position the two handles, screen-stable via gizmoSize(). The WIDTH
        // handle mirrors ScaleHandler's axis arrows: shaft from anchor+axis*
        // (size/7) to anchor+axis*size, with a fixed-size cube head (size*0.03).
        float armLen   = gizmoSize(anchorW, vp, 1.0f);
        float cubeHalf = gizmoSize(anchorW, vp, 0.03f);
        extrudeArrow.start = anchorW + extrudeAx.dir * (armLen / 6.0f);
        extrudeArrow.end   = anchorW + extrudeAx.dir * armLen;
        extrudeArrow.color = EXTRUDE_COLOR;
        widthArrow.start         = anchorW + widthAx.dir * (armLen / 7.0f);
        widthArrow.end           = anchorW + widthAx.dir * armLen;
        widthArrow.fixedCubeHalf = cubeHalf;
        widthArrow.color         = WIDTH_COLOR;

        // Single test+update pass: register both handles (arrow priority over
        // width on overlap — extrude is the primary action), keep the hauled
        // handle highlighted, then hand each handle its HandleState.
        toolHandles.begin();
        toolHandles.add(extrudeArrow, PART_EXTRUDE);
        toolHandles.add(widthArrow,   PART_WIDTH);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        extrudeArrow.draw(shader, vp);
        widthArrow.draw(shader, vp);
    }

private:
    // The mask the kernel runs on: empty selection ⇒ whole mesh (matching the
    // mesh.delete / mesh.edge_extrude convention).
    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandEdgeMask();
    }

    // Revert to the pre-extrude cage + selection, then rebuild from the
    // current extrude/width. Identity params leave the mesh restored (no-op).
    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        if (extrude_ == 0.0f && width_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        // task 1903 Stage H: unrecorded — this is the per-drag-frame preview
        // rerun (§9), which must stay off the op-log.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.extrudeEdgesByMask(mask, extrude_, width_);
        ed.close();
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }

        // Delta path. Re-run the kernel ONCE inside a Mesh edit batch so the
        // committed extrude self-records an operation-log delta. This adds one
        // extra kernel run per session (cheap, off the per-drag hot path); the
        // interactive preview loop in rebuildPreview() stays batchless (HP5 —
        // zero tracker cost per mouse-motion frame).
        //
        // before.restore MUST precede the batch: a built preview left the mesh
        // as the lifted ridge AND reselected the post-extrude ridge edges.
        // currentMask() reads mesh.selectedEdges, so without the rewind the
        // batch would extrude the WRONG (ridge) edges. The restore rewinds the
        // clean cage + the ORIGINAL edge selection; it is the un-tracked
        // rewind, NOT part of the logged batch.
        before.restore(*mesh);

        // task 1903 Stage H: the RECORDING `MeshEditBatch` struct replaces the
        // legacy `beginEditBatch(&rec, …)` / `endEditBatch()` /
        // `abortEditBatch()` trio — `extrudeEdgesByMask` now takes
        // `ref MeshEditBatch ed`, so a handle is the only way to call it, and
        // `pushEditFrame`/`closeEditFrame` are the SAME primitives both
        // spellings drive (mesh.d's own comment on the legacy pair: "the two
        // spellings cannot drift"). The manual
        // `scope(failure) mesh.abortEditBatch();` this replaces is now
        // unconditional and automatic: `MeshEditBatch.~this()` runs the
        // identical pop-without-stamping + `changeBus.batchLeaks` tick on ANY
        // unwind, recording or not (plan §2.2c) — this site no longer needs to
        // spell it.
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Geometry | MeshEditScope.Marks);
        auto mask = currentMask();
        // task 1905 Stage P0-a: catch the return value the kernel already
        // produces (it used to be discarded here) — the `edge_extend.d` twin
        // carries the full note. INSTRUMENT ONLY — `affected` is not read
        // below and decides nothing yet; the degenerate-delta fallback's own
        // rule stays exactly where it was.
        size_t affected = ed.extrudeEdgesByMask(mask, extrude_, width_);
        auto delta = ed.close();

        // After the re-run the mesh is back in the post-extrude state the user
        // was viewing; refresh the display so the GPU buffer reflects it.
        refreshCaches();

        if (!delta.isEmpty) {
            cmd.setDelta(delta, "Edge Extrude");
            recordGestureEdit(cmd, GestureRecordMode.Plain);
            return;
        }

        // THE DEGENERATE-DELTA FALLBACK, and it is RETAINED DELIBERATELY —
        // ruling N-R1, task 1903 Stage N. Until that stage this block was two
        // things at once: the undo hatch's arm AND the answer for a commit
        // whose re-run recorded nothing. Deleting the flag deleted the first
        // reading only. What a zero-delta tool commit OUGHT to do — record a
        // whole-mesh pair as it does here, or refuse — is a change to tool
        // COMMIT semantics and belongs to the session-boundary work (task
        // 1905), not to a commit whose subject is a process-wide flag. So the
        // behaviour is unchanged and the question is written down where the
        // field lives (see `before`'s declaration). `affected` above is now
        // available to that answer but is not yet consulted.
        //
        // MEASURED, SO NOBODY MISTAKES IT FOR A COVERED PATH: with the hatch
        // gone this block has NO witness in either lane. An `assert(false)`
        // planted here at Stage N left `test_undo_tracker_extrude` and
        // `test_edge_extrude_tool` green, i.e. nothing the suite drives reaches
        // it. That is not an oversight in the tests — `deactivate` only commits
        // when the preview already BUILT topology, and the commit re-runs the
        // same kernel on the same restored mesh, so an empty delta here needs
        // the kernel to disagree with itself. It is a defensive arm, and the
        // reason it is retained rather than deleted is the ruling above: what a
        // zero-delta tool commit should do is 1905's decision, and an
        // unreachable branch is the wrong thing to change in a flag-removal
        // commit. Whoever answers that question should delete it or reach it,
        // not leave it as it stands.
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Edge Extrude");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }

    // Category A live-edit cancel — the former RMB body, factored out so both
    // the RMB handler and cancelUncommittedEdit() (undo/redo P0) share one
    // restore path: drop any built topology, restore the original cage, reset
    // params + drag state, and clear the gizmo haul. Records nothing.
    void cancelLiveEdit() {
        before.restore(*mesh);
        refreshCaches();
        extrude_ = 0.0f;
        width_   = 0.0f;
        built    = false;
        dragPart = -1;
        toolHandles.clearHaul();
    }

    // -----------------------------------------------------------------------
    // computeGizmoFrame — anchor + FIXED extrude/width axes from the CURRENT
    // edge selection (empty ⇒ whole mesh). Computed at activate() and whenever
    // the selection changes while idle. The AXES are the fixed part: they are
    // built ONCE here from the ORIGINAL pre-extrude neighbour normals and are
    // never recomputed from the deformed mesh during a drag (only the anchor
    // POSITION follows the live edge, via currentAnchor()).
    //
    //   anchor      = centroid of the selected edges' endpoints.
    //   extrudeAxis = normalized average of `faceNormal` over the faces
    //                 adjacent to the selected edges (the same ridge-lift
    //                 notion the kernel uses).
    //   widthAxis   = a representative in-plane inset direction: the averaged
    //                 per-edge inward dir, each perpendicular to the edge
    //                 tangent and to the extrude axis. Falls back to any axis
    //                 perpendicular to extrudeAxis when degenerate.
    // -----------------------------------------------------------------------
    void computeGizmoFrame() {
        gizmoValid   = false;
        gizmoSelHash = mesh.selectionSignature(EditMode.Edges);
        if (mesh.edges.length == 0) return;

        // L1 funnel (task 0613, S5) — same operand set as currentMask(), so the
        // gizmo is framed on exactly the edges the apply will extrude (see the
        // matching note in tools/edit/poly_extrude.d).
        auto opEdges = mesh.operandEdgeMask();

        Vec3 centSum  = Vec3(0, 0, 0);
        size_t centN  = 0;
        Vec3 normSum  = Vec3(0, 0, 0);
        Vec3 insetSum = Vec3(0, 0, 0);

        foreach (i; 0 .. mesh.edges.length) {
            bool selected = i < opEdges.length && opEdges[i];
            if (!selected) continue;
            uint va = mesh.edges[i][0];
            uint vb = mesh.edges[i][1];
            Vec3 pa = mesh.vertices[va];
            Vec3 pb = mesh.vertices[vb];
            centSum = centSum + pa + pb;
            centN  += 2;

            // Averaged neighbour-polygon normal for this edge (ridge dir).
            Vec3 ne = edgeAveragedNormal(cast(uint)i);
            normSum = normSum + ne;

            // In-plane inset direction for this edge: perpendicular to the
            // edge tangent and lying in the surface (perpendicular to ne).
            //   tangent t = normalize(pb - pa)
            //   inward    = normalize(cross(ne, t))   (in-surface, ⟂ to edge)
            Vec3 t = pb - pa;
            float tl = sqrt(t.x*t.x + t.y*t.y + t.z*t.z);
            if (tl > 1e-6f) {
                t = t / tl;
                Vec3 inward = cross(ne, t);
                float il = sqrt(inward.x*inward.x + inward.y*inward.y + inward.z*inward.z);
                if (il > 1e-6f) insetSum = insetSum + (inward / il);
            }
        }

        if (centN == 0) return;
        anchor = Vec3(centSum.x / centN, centSum.y / centN, centSum.z / centN);
        // Freeze the ORIGINAL pre-extrude centroid. The per-frame gizmo anchor
        // is computed analytically from this base + the extrude VALUE (see
        // draw()), so the handle slides out predictively even when width==0
        // (which makes the kernel a no-op, leaving the live selection put).
        baseAnchor = anchor;

        // Extrude axis = averaged normal; fall back to world +Y if degenerate.
        float nl = sqrt(normSum.x*normSum.x + normSum.y*normSum.y + normSum.z*normSum.z);
        extrudeAxis = (nl > 1e-6f) ? (normSum / nl) : Vec3(0, 1, 0);

        // Width axis = averaged in-plane inset; orthogonalize against the
        // extrude axis and fall back to any perpendicular if degenerate (e.g.
        // per-edge inward dirs cancelled out on a closed loop).
        Vec3 w = insetSum - extrudeAxis * dot(insetSum, extrudeAxis);
        float wl = sqrt(w.x*w.x + w.y*w.y + w.z*w.z);
        if (wl > 1e-6f) {
            widthAxis = w / wl;
        } else {
            // Any vector perpendicular to extrudeAxis.
            Vec3 tmp = (abs(extrudeAxis.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
            Vec3 perp = cross(extrudeAxis, tmp);
            float pl = sqrt(perp.x*perp.x + perp.y*perp.y + perp.z*perp.z);
            widthAxis = (pl > 1e-6f) ? (perp / pl) : Vec3(1, 0, 0);
        }
        gizmoValid = true;
    }

    // Averaged normal of the 1–2 faces adjacent to edge `ei` — the same notion
    // the kernel's per-edge `ne` uses for the ridge-lift direction.
    Vec3 edgeAveragedNormal(uint ei) {
        Vec3 sum = Vec3(0, 0, 0);
        size_t n = 0;
        foreach (fi; mesh.facesAroundEdge(ei)) {
            sum = sum + mesh.faceNormal(fi);
            ++n;
        }
        if (n == 0) return Vec3(0, 1, 0);
        float l = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        return (l > 1e-6f) ? (sum / l) : Vec3(0, 1, 0);
    }
}
