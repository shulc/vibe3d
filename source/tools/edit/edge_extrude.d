module tools.edit.edge_extrude;
import display_state : DrawPlan;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedNamedGpuParamDoorClient;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedSimpleToolDoorClient;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_edge_extrude_activation : PreparedEdgeExtrudeActivationOwner;
import prepared_param_update : PreparedParamUpdateOwner,
    PreparedParamUpdateProducer, DefaultParamEffectKind;
import prepared_tool_effect : PreparedEdgeExtrudeParamEffect,
    PreparedEdgeExtrudeParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import mesh_gpu : GpuMesh;
import core.stdc.string : memcmp;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import tools.topology_step;
import command : Command;
import mesh;
import mesh_ops.extrude;
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
import tools.edit.preview_rebuild : PreviewRebuild, PreviewTopologyKey,
    PreviewRebuildCounts, PreparedPreviewRebuildImage;

import std.math : abs, sqrt;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;

struct PreparedEdgeExtrudeActivationImage {
    MeshSnapshot before;
    bool valid, gizmoValid;
    Vec3 anchor, baseAnchor, extrudeAxis, widthAxis;
    ulong gizmoSelHash;
    void clear() nothrow @nogc { this = PreparedEdgeExtrudeActivationImage.init; }
}

struct EdgeExtrudeParamProjection {
    bool interactive, active, built;
    float extrude, width;
    bool opEquals(const EdgeExtrudeParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built &&
            memcmp(&extrude, &other.extrude, float.sizeof) == 0 &&
            memcmp(&width, &other.width, float.sizeof) == 0;
    }
}

struct PreparedEdgeExtrudeParamImage {
    mixin DefaultParamEffectKind!PreparedEdgeExtrudeParamKind;
    bool valid, applies, nextBuilt;
    EdgeExtrudeParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    PreparedPreviewRebuildImage preview;
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        preview.clear(); candidate = Mesh.init; valid = applies = false;
    }
}

// Task 7990: the Edge session records each completed drag, Middle clone and
// interactive parameter edit as its own full-mesh MeshSessionEdit row. The
// command also owns attrs and the preview basis so history navigation can
// restore a fresh tool instance. `before` below is only the current kernel
// basis: every motion restores it and re-runs that operation once. Prepared
// and ordinary close write no cumulative carrier. Evidence: W2 plan and
// tests/test_edge_extrude_handle_drag.d.
// ---------------------------------------------------------------------------
// EdgeExtrudeTool — interactive Edge Extrude (factory id `edge.extrude`).
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
class EdgeExtrudeTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient,
        TopologyStepClient {
    // The UI recording door closes the current operation while preserving
    // its already-recorded rows; the tool remains armed after the command.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true,
            commandClose: CommandClose.uiDoor,
            sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.arm,
            imageAttrs: ["extrude", "width"],
            haulAttrs: ["extrude", "width"],
            // captured: the tool's activation resets these (topology-redo S6r)
            activationResetAttrs: ["extrude", "width"]
        };
        return policy;
    }

    mixin PreparedNamedGpuParamDoorClient;
    mixin PreparedSimpleToolDoorClient!Layer;
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
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
    /// Current operation's preview basis (geometry and selection). The
    /// completed step pairs and their bases belong to CommandHistory.
    MeshSnapshot  before;
    PreviewRebuild preview_;       // the restore-and-rebuild seam (preview_rebuild.d)
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
    int   dragButton_;
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
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu,
            EditMode* editMode, LitShader litShader) {
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

    final PreparedEdgeExtrudeActivationImage buildPreparedActivation(
            out Mesh* source) {
        PreparedEdgeExtrudeActivationImage image;
        source = mesh; if (source is null) return image;
        image.before = MeshSnapshot.capture(*source); image.valid = true;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.extrudeAxis = extrudeAxis;
        image.widthAxis = widthAxis; image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*source, image); return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedEdgeExtrudeActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragPart = -1;
        preview_.reset(); image.before.moveInto(before);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;
        widthAxis = image.widthAxis; gizmoSelHash = image.gizmoSelHash;
        image.clear();
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.EdgeExtrude, false);
        scope(failure) context.discard();
        auto owner = PreparedEdgeExtrudeActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareEdgeExtrudeActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.EdgeExtrude, ok);
    }

    // (Re)initialise the edit session against the CURRENT mesh — shared by
    // activate() and resyncSession() (undo/redo migration P1) so the two can't
    // drift. Deliberately does NOT set `active` (resyncSession keeps the tool
    // active; activate() owns the flag): re-snapshots the cage + selection,
    // clears any built preview (the attributes are the session's: the activation
    // reset, topology-redo S6r), and re-derives the gizmo/edge-selection
    // frame. Re-capturing `before` here is the selection-index liveness fix —
    // after a topology-changing undo the stored edge selection is re-derived
    // live from the now-current mesh (Objection 5).
    private void reinitSession() {
        built    = false;
        dragPart = -1;
        preview_.reset();          // a new clean cage ⇒ a new topology key
        // Snapshot the cage + selection at the start of the session. The
        // per-drag revert+reapply restores from here; the commit pairs it
        // with the final `after`.
        before = MeshSnapshot.capture(*mesh);
        // Build the gizmo anchor + axes from the original pre-extrude
        // selection so the handles stay put across the drag.
        computeGizmoFrame();
    }

    override void deactivate() {
        // Completed steps already live in CommandHistory.
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        preview_.reset();          // drop the clean-cage scratch with the session
        toolHandles.clearHaul();
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // This exact predicate is also deactivate's commit gate. Task 0388;
    // edge_extrude_tool_test.d.
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

    mixin SessionCommitHooks;
    mixin TopologyStepClientBody!("Edge Extrude", before);
    mixin GizmoTopologyRebase;
    final void afterTopologyRebase() { preview_.reset(); }

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
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    private EdgeExtrudeParamProjection paramProjection() const nothrow @nogc {
        return EdgeExtrudeParamProjection(interactiveParamEdit, active, built,
            extrude_, width_);
    }
    final PreparedEdgeExtrudeParamImage buildPreparedParamUpdate(string, ref Mesh live) {
        PreparedEdgeExtrudeParamImage image;
        image.valid = true; image.expected = paramProjection();
        image.nextBuilt = built; image.expectedLive = MeshSnapshot.capture(live);
        // Above the early return: the preview conjunct below is unconditional
        // (the cold-arm hole, task 4491).
        preview_.prepareImageShadowed(image.preview);
        if (!before.filled) return image;
        image.expectedBefore = before;
        if (!interactiveParamEdit || !active) return image;
        image.applies = true;
        auto shadow = beginPreparedShadow(image.candidate);
        image.expectedLive.restore(image.candidate);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        image.deliveryFlags = image.deliveryDomains = 0;
        image.nextBuilt = PreviewRebuild.runPrepared(image.preview,
            image.candidate, before,
            &previewKey, &operation) != 0;
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(in PreparedEdgeExtrudeParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) && image.expectedBefore.matches(before) &&
            preview_.matchesImage(image.preview);
    }
    final void installPreparedParamUpdate(ref PreparedEdgeExtrudeParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; preview_.installImage(image.preview); image.clear();
    }
    /// The preview seam's counters (read by the churn test).
    public PreviewRebuildCounts previewRebuildCounts() const {
        return preview_.counts();
    }
    mixin PreparedParamUpdateProducer!(PreparedParamUpdateOwner!(EdgeExtrudeTool,
        PreparedEdgeExtrudeParamImage, PreparedEdgeExtrudeParamKind), PreparedEdgeExtrudeParamEffect);
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
        preview_.reset();   // the live mesh is rebuilt behind the seam's back
        if (mesh.edges.length == 0) return false;
        if (extrude_ == 0.0f && width_ == 0.0f) return true;   // no-op success
        if (operation(*mesh) == 0) return false;
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
            closeOwnOperation(false);
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT && e.button != SDL_BUTTON_MIDDLE) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & KMOD_ALT) return false;
        if (e.button == SDL_BUTTON_MIDDLE && (mods & (KMOD_SHIFT | KMOD_CTRL)))
            return false;
        if (*editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0 || !gizmoValid) return false;

        const bool boundary = e.button == SDL_BUTTON_MIDDLE || (mods & KMOD_SHIFT);
        sessionStepBegins(e.button == SDL_BUTTON_MIDDLE ? PressKind.middle
            : boundary ? PressKind.shift : PressKind.plain);
        if (boundary) {
            before = MeshSnapshot.capture(*mesh);
            if (e.button != SDL_BUTTON_MIDDLE)
                extrude_ = width_ = 0.0f;
            computeGizmoFrame();
            rebuildPreview();
        }

        // Ask the arbiter which handle (if any) the click landed on.
        int part = toolHandles.test(e.x, e.y, cachedVp);

        dragLastMX      = e.x;
        dragLastMY      = e.y;
        dragStartMX     = e.x;
        dragStartMY     = e.y;
        dragBaseExtrude = extrude_;
        dragBaseWidth   = width_;
        freeLockAxis    = 0;   // fresh latch for any new free drag
        dragButton_ = e.button;

        if (boundary) {
            dragPart = PART_FREE;
            return true;
        }

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
        if (e.button != dragButton_) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        sessionStepEnds();
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

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
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
    // Rebuild from the clean cage through the seam: a key change restores the
    // live mesh and re-runs; an unchanged key transplants positions only.
    void rebuildPreview() {
        if (!active) return;
        if (previewGated()) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        built = preview_.run(*mesh, before, &previewKey, &operation) != 0;
        refreshCaches();
    }

    // The topology key: the operand mask, the kernel's `width < 1e-6` no-op
    // and its `|extrude| < 1e-6` ridge reuse (fewer vertices). A width past a
    // rim edge's length saturates per the cage's geometry; that costs a key
    // miss, never a wrong mesh (header of tools/edit/preview_rebuild.d).
    PreviewTopologyKey previewKey(ref Mesh cage) {
        return PreviewTopologyKey.make(cage.operandEdgeMask(), width_ < 1e-6f,
            abs(extrude_) < 1e-6f);
    }
    // The one operation (task 9433): preview, prepared image and scripted
    // apply. Unrecorded — a preview frame records nothing, and the scripted
    // apply's snapshot pair belongs to `ToolDoApplyCommand`. The mask is the
    // L1 funnel (task 0613): the selection, else every VISIBLE edge.
    size_t operation(ref Mesh target) {
        auto mask = target.operandEdgeMask();
        auto ed = MeshEditBatch.unrecorded(target, kExtrudeEditScope);
        const n = ed.extrudeEdgesByMask(mask, extrude_, width_);
        ed.close();
        return n;
    }

    // All applied images have already been handed to history at
    // their step boundary. A prepared switch installs no cumulative carrier.
    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context) {
        if (context is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.EdgeExtrude,
            false, false);
        const accepted = context.markNoHistoryInstall();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.EdgeExtrude, false, accepted);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }

    // Category A live-edit cancel — the former RMB body, factored out so both
    // the RMB handler and cancelUncommittedEdit() (undo/redo P0) share one
    // restore path: drop any built topology, restore the original cage, reset
    // params + drag state, and clear the gizmo haul. Records nothing.
    void cancelLiveEdit() {
        if (dragPart < 0) return; // completed images belong to history
        before.restore(*mesh);
        preview_.reset();
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
        PreparedEdgeExtrudeActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.extrudeAxis = extrudeAxis;
        image.widthAxis = widthAxis; image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*mesh, image);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;
        widthAxis = image.widthAxis; gizmoSelHash = image.gizmoSelHash;
    }

    private static void computePreparedGizmoFrame(ref Mesh source,
            ref PreparedEdgeExtrudeActivationImage image) {
        image.gizmoValid = false;
        image.gizmoSelHash = source.selectionSignature(EditMode.Edges);
        if (source.edges.length == 0) return;

        // L1 funnel (task 0613, S5) — same operand set as `operation`, so the
        // gizmo is framed on exactly the edges the apply will extrude (see the
        // matching note in tools/edit/poly_extrude.d).
        auto opEdges = source.operandEdgeMask();

        Vec3 centSum  = Vec3(0, 0, 0);
        size_t centN  = 0;
        Vec3 normSum  = Vec3(0, 0, 0);
        Vec3 insetSum = Vec3(0, 0, 0);

        foreach (i; 0 .. source.edges.length) {
            bool selected = i < opEdges.length && opEdges[i];
            if (!selected) continue;
            uint va = source.edges[i][0];
            uint vb = source.edges[i][1];
            Vec3 pa = source.vertices[va];
            Vec3 pb = source.vertices[vb];
            centSum = centSum + pa + pb;
            centN  += 2;

            // Averaged neighbour-polygon normal for this edge (ridge dir).
            Vec3 ne = preparedEdgeAveragedNormal(source, cast(uint)i);
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
        image.anchor = Vec3(centSum.x / centN, centSum.y / centN, centSum.z / centN);
        // Freeze the ORIGINAL pre-extrude centroid. The per-frame gizmo anchor
        // is computed analytically from this base + the extrude VALUE (see
        // draw()), so the handle slides out predictively even when width==0
        // (which makes the kernel a no-op, leaving the live selection put).
        image.baseAnchor = image.anchor;

        // Extrude axis = averaged normal; fall back to world +Y if degenerate.
        float nl = sqrt(normSum.x*normSum.x + normSum.y*normSum.y + normSum.z*normSum.z);
        image.extrudeAxis = (nl > 1e-6f) ? (normSum / nl) : Vec3(0, 1, 0);

        // Width axis = averaged in-plane inset; orthogonalize against the
        // extrude axis and fall back to any perpendicular if degenerate (e.g.
        // per-edge inward dirs cancelled out on a closed loop).
        Vec3 w = insetSum - image.extrudeAxis * dot(insetSum, image.extrudeAxis);
        float wl = sqrt(w.x*w.x + w.y*w.y + w.z*w.z);
        if (wl > 1e-6f) {
            image.widthAxis = w / wl;
        } else {
            // Any vector perpendicular to extrudeAxis.
            Vec3 tmp = (abs(image.extrudeAxis.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
            Vec3 perp = cross(image.extrudeAxis, tmp);
            float pl = sqrt(perp.x*perp.x + perp.y*perp.y + perp.z*perp.z);
            image.widthAxis = (pl > 1e-6f) ? (perp / pl) : Vec3(1, 0, 0);
        }
        image.gizmoValid = true;
    }

    // Averaged normal of the 1–2 faces adjacent to edge `ei` — the same notion
    // the kernel's per-edge `ne` uses for the ridge-lift direction.
    Vec3 edgeAveragedNormal(uint ei) {
        return preparedEdgeAveragedNormal(*mesh, ei);
    }
    private static Vec3 preparedEdgeAveragedNormal(ref Mesh source, uint ei) {
        Vec3 sum = Vec3(0, 0, 0);
        size_t n = 0;
        foreach (fi; source.facesAroundEdge(ei)) {
            sum = sum + source.faceNormal(fi);
            ++n;
        }
        if (n == 0) return Vec3(0, 1, 0);
        float l = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        return (l > 1e-6f) ? (sum / l) : Vec3(0, 1, 0);
    }

public:
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true) {
        interactiveParamEdit = interactive; active = true; built = false;
        extrude_ = 0.5f; width_ = 0.1f; before = MeshSnapshot.capture(live);
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { extrude_ = value; }
    version(unittest) final bool preparedParamBuiltForTest() const nothrow @nogc {
        return built;
    }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest(ref Mesh oldMesh) {
        active = false; built = true; dragPart = 9; extrude_ = 7; width_ = 8;
        gizmoValid = false; anchor = Vec3(1,2,3); baseAnchor = Vec3(4,5,6);
        extrudeAxis = Vec3(7,8,9); widthAxis = Vec3(10,11,12);
        gizmoSelHash = 13; dragLastMX = 14; dragLastMY = 15;
        dragStartMX = 16; dragStartMY = 17; dragBaseExtrude = 18;
        dragBaseWidth = 19; freeLockAxis = 2; cachedVp.view[0] = 20;
        before = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const
            nothrow @nogc {
        return !active && built && dragPart == 9 && extrude_ == 7 && width_ == 8 &&
            !gizmoValid && anchor == Vec3(1,2,3) && baseAnchor == Vec3(4,5,6) &&
            extrudeAxis == Vec3(7,8,9) && widthAxis == Vec3(10,11,12) &&
            gizmoSelHash == 13 && dragLastMX == 14 && dragLastMY == 15 &&
            dragStartMX == 16 && dragStartMY == 17 && dragBaseExtrude == 18 &&
            dragBaseWidth == 19 && freeLockAxis == 2 && cachedVp.view[0] == 20;
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr, bool expectedValid,
            Vec3 expectedAnchor, Vec3 expectedBase, Vec3 expectedExtrude,
            Vec3 expectedWidth, ulong expectedHash) const nothrow @nogc {
        return active && !built && dragPart == -1 && extrude_ == 7 && width_ == 8 &&
            before.filled && before.vertices.length == count &&
            (count == 0 || (before.vertices[0] == first && before.vertices.ptr !is livePtr)) &&
            gizmoValid == expectedValid && anchor == expectedAnchor &&
            baseAnchor == expectedBase && extrudeAxis == expectedExtrude &&
            widthAxis == expectedWidth && gizmoSelHash == expectedHash &&
            dragLastMX == 14 && dragLastMY == 15 && dragStartMX == 16 &&
            dragStartMY == 17 && dragBaseExtrude == 18 && dragBaseWidth == 19 &&
            freeLockAxis == 2 && cachedVp.view[0] == 20;
    }
    version(unittest) final PreparedEdgeExtrudeActivationImage
            preparedFrameForTest(ref Mesh source) const {
        PreparedEdgeExtrudeActivationImage image;
        image.before = MeshSnapshot.capture(source);
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.extrudeAxis = extrudeAxis;
        image.widthAxis = widthAxis; image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(source, image); return image;
    }
}

unittest { // P1.0b.3d identity preview must not prepare history.
    import view : View;
    import mesh_gpu : GpuMesh;
    import record_observer_hub : RecordObserverHub;
    Mesh m; GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto view = new View(0, 0, 1, 1);
    auto history = new CommandHistory(); auto hub = new RecordObserverHub();
    hub.setMacroActive(true);
    auto tool = new EdgeExtrudeTool(() => &m, &gpu, &mode, LitShader.init);
    tool.setGestureBindings(history, () => new MeshSessionEdit(&m, view, mode,
        "test.edgeExtrude", "edge extrude"));
    tool.active = true; tool.built = true; tool.before = MeshSnapshot.capture(m);
    tool.extrude_ = 0; tool.width_ = 0;
    auto context = new PreparedRecordContext(history, hub);
    auto effect = tool.prepareDeactivate(context);
    assert(!effect.historyAccepted);
    assert(context.validate()); context.install();
    size_t modelDepth, uiDepth; context.installedDepths(modelDepth, uiDepth);
    assert(modelDepth == 0 && uiDepth == 0 && hub.macroLength == 0);
}
