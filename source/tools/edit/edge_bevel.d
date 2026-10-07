module tools.edit.edge_bevel;
import display_state : DrawPlan;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedNamedGpuParamDoorClient;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import tools.topology_step;
import command : Command;
import mesh;
import mesh_gpu : GpuMesh;
import mesh_ops.edge_bevel : bevelEdgesByMask, kEdgeBevelEditScope;
import math;
import editmode : EditMode;
import params : Param;
import handler : CubicArrow, ToolHandles, HandleState, HandlePart, firstHitPart,
    gizmoSize, gizmoPixelSize, gizmoBoxHalfPx, GIZMO_STROKE_SCALE_SHAFT_PX,
    GIZMO_ALPHA_ARM;
import viewport_scheme : axisColor;
import drag : screenAxisDelta;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import tools.edit.preview_rebuild : PreviewRebuild, PreviewTopologyKey,
    PreviewRebuildCounts;

import std.math : abs, sqrt;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedSimpleToolDoorClient;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_edge_bevel_activation : PreparedEdgeBevelActivationOwner;
import prepared_param_update : PreparedParamUpdateOwner,
    PreparedParamUpdateProducer, PreparedStateParamImage;
import prepared_tool_effect : PreparedEdgeBevelParamEffect,
    PreparedEdgeBevelParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import core.stdc.string : memcmp;

struct PreparedEdgeBevelActivationImage {
    MeshSnapshot before;
    bool valid, gizmoValid;
    Vec3 anchor, baseAnchor, widthAxis, miterAxis;
    ulong gizmoSelHash;
    void clear() nothrow @nogc {
        this = PreparedEdgeBevelActivationImage.init;
    }
}

// S1 (task 20261220): one parameter state and ordered scalar bank retain the
// independent scalar bindings; profile and checkbox fields remain dormant.
// Reviewed descriptor authority: private evidence/10860-edge-bevel/modes-handles-static-20261007.
enum EdgeBevelProfile { round, square, sharp }
private enum EdgeBevelScalar { width, miterOffset }
private enum EdgeBevelBasis { tangent, binormal, normal }

struct EdgeBevelState {
    float width = 0.0f;
    int roundLevel;
    // Mirrors the command's current edge widthMode: false means along-face
    // slide (inset), true requests width conversion. Preview and apply share it.
    bool widthMode;
    EdgeBevelProfile profile;
    float miterOffset = 0.0f;
    bool sharpCorner, maintainCoplanar, materialOverride;
    string materialName;

    bool opEquals(const ref EdgeBevelState other) const nothrow @nogc {
        return memcmp(&width, &other.width, float.sizeof) == 0 &&
            roundLevel == other.roundLevel && widthMode == other.widthMode &&
            profile == other.profile &&
            memcmp(&miterOffset, &other.miterOffset, float.sizeof) == 0 &&
            sharpCorner == other.sharpCorner &&
            maintainCoplanar == other.maintainCoplanar &&
            materialOverride == other.materialOverride &&
            materialName == other.materialName;
    }
}

private struct EdgeBevelScalarDescriptor {
    EdgeBevelScalar binding;
    EdgeBevelBasis basis;
    float start = 0.0f;
    float delta = 0.0f;
}

private struct EdgeBevelHandleBank {
    CubicArrow widthArrow, miterArrow;
    EdgeBevelScalarDescriptor[2] scalars = [
        EdgeBevelScalarDescriptor(EdgeBevelScalar.width, EdgeBevelBasis.normal),
        EdgeBevelScalarDescriptor(EdgeBevelScalar.miterOffset, EdgeBevelBasis.tangent),
    ];

    HandlePart[2] handleParts() {
        return [HandlePart(widthArrow, 0), HandlePart(miterArrow, 1)];
    }
    int firstHit(int mx, int my, const ref Viewport vp) {
        return firstHitPart(mx, my, vp, handleParts());
    }
    void snapshotStarts(const ref EdgeBevelState state) nothrow @nogc {
        scalars[0].start = state.width;
        scalars[1].start = state.miterOffset;
        scalars[0].delta = scalars[1].delta = 0.0f;
    }
}

struct EdgeBevelParamProjection {
    bool interactive, active, built;
    EdgeBevelState state;
    bool opEquals(const EdgeBevelParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built && state == other.state;
    }
}

alias PreparedEdgeBevelParamImage = PreparedStateParamImage!(EdgeBevelParamProjection, PreparedEdgeBevelParamKind);

// ---------------------------------------------------------------------------
// EdgeBevelTool — interactive Edge Bevel (factory id `edge.bevel`).
//
// Topology-creating tool, modelled on PolyExtrudeTool. ToolSession records
// a mesh and attribute image for each completed gesture.
//
// Ordered scalar handles:
//   PART_WIDTH follows the normal; PART_MITER follows the prepared tangent.
//
// Headless: tool.set edge.bevel on; tool.attr edge.bevel width <v>;
//           tool.doApply → applyHeadless(); ToolDoApplyCommand wraps undo.
// ---------------------------------------------------------------------------
class EdgeBevelTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient,
        TopologyStepClient {
    // A recording command through the UI door closes the active operation;
    // completed gestures already belong to ToolSession history.
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, commandClose: CommandClose.uiDoor,
            sessionSteps: true, historyTopologySteps: true,
            // The operation begins at the arm (topology-redo law 1; captured
            // script cell + three UI cells `s01 armed=True`).
            opensAt: OpensAt.arm,
            imageAttrs: ["width", "roundLevel", "widthMode", "miterOffset"],
            haulAttrs: ["width", "roundLevel", "widthMode", "miterOffset"],
            // captured: the tool's activation resets these (topology-redo S6r)
            activationResetAttrs: ["width"],
            // captured: a refire records no new mesh image (topology-redo S7r)
            redoPinsRefireImage: true
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

    // Defaults are ours; profile and checkbox fields remain dormant.
    EdgeBevelState state_;

    bool         active;
    bool         built;
    MeshSnapshot before;
    // The restore-and-rebuild seam (task 1620) — see
    // tools/edit/preview_rebuild.d.
    PreviewRebuild preview_;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 widthAxis;
    Vec3 miterAxis;
    ulong gizmoSelHash;

    enum int PART_WIDTH = 0;
    enum int PART_MITER = 1;
    int   dragPart = -1;
    // One drag has one screen-space origin.  Width is written back as an
    // absolute value from that origin, so replay/coalescing cannot make the
    // result depend on how many motion events SDL delivered.
    int   dragStartMX, dragStartMY;

    EdgeBevelHandleBank handleBank_;
    @property CubicArrow widthArrow() { return handleBank_.widthArrow; }
    @property const(CubicArrow) widthArrow() const { return handleBank_.widthArrow; }
    CubicArrow       replicaArrow_;
    CubicArrow       replicaMiterArrow_;
    // One draw-only frame image is shared by every foreign cell.  The owner
    // publishes its frozen frame here; after a selection change the first
    // replica refreshes it and the remaining replicas plus the owner reuse it.
    PreparedEdgeBevelActivationImage replicaImage_;
    ToolHandles toolHandles;

    enum Vec3 WIDTH_COLOR = axisColor(2);
    enum Vec3 MITER_COLOR = axisColor(0);

public:
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true) {
        interactiveParamEdit = interactive; active = true; built = false;
        state_.width = 0.2f; state_.roundLevel = 1; state_.widthMode = false;
        before = MeshSnapshot.capture(live); preview_.reset();
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { state_.width = value; }
    version(unittest) final bool preparedParamInstalledForTest() const
            nothrow @nogc {
        return built && preview_.counts().fullRebuilds == 1;
    }
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu,
            EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        handleBank_.widthArrow = new CubicArrow(Vec3(0,0,0), Vec3(0,1,0), WIDTH_COLOR);
        handleBank_.miterArrow = new CubicArrow(Vec3(0,0,0), Vec3(0,0,0), MITER_COLOR);
        handleBank_.miterArrow.setVisible(true);
        replicaArrow_ = new CubicArrow(Vec3(0,0,0), Vec3(0,1,0), WIDTH_COLOR);
        replicaMiterArrow_ = new CubicArrow(Vec3(0,0,0), Vec3(1,0,0), MITER_COLOR);
        foreach (h; [handleBank_.widthArrow, handleBank_.miterArrow,
                     replicaArrow_, replicaMiterArrow_]) {
            h.lineWidth = GIZMO_STROKE_SCALE_SHAFT_PX;
            h.alpha = GIZMO_ALPHA_ARM;
            h.doubledShaft = true;
        }
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (widthArrow !is null) widthArrow.destroy();
        if (handleBank_.miterArrow !is null) handleBank_.miterArrow.destroy();
        if (replicaArrow_ !is null) replicaArrow_.destroy();
        if (replicaMiterArrow_ !is null) replicaMiterArrow_.destroy();
    }

    override string name() const { return "Edge Bevel"; }

    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        return [
            Param.float_("width", "Width", &state_.width, 0.0f),
            Param.int_("roundLevel", "Round Level", &state_.roundLevel, 0),
            Param.bool_("widthMode", "Width Mode", &state_.widthMode, false),
            Param.float_("miterOffset", "Miter Offset", &state_.miterOffset, 0.0f).min(0.0f).enforceBounds(),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    final PreparedEdgeBevelActivationImage buildPreparedActivation(
            out Mesh* source) {
        PreparedEdgeBevelActivationImage image;
        source = mesh; if (source is null) return image;
        image.before = MeshSnapshot.capture(*source); image.valid = true;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.widthAxis = widthAxis; image.miterAxis = miterAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*source, image);
        return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedEdgeBevelActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragPart = -1;
        preview_.reset(); image.before.moveInto(before);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; widthAxis = image.widthAxis; miterAxis = image.miterAxis;
        gizmoSelHash = image.gizmoSelHash;
        publishOwnerFrameToReplica();
        image.clear();
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.EdgeBevel, false);
        scope(failure) context.discard();
        auto owner = PreparedEdgeBevelActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareEdgeBevelActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.EdgeBevel, ok);
    }

    private void reinitSession() {
        built    = false;
        dragPart = -1;
        preview_.reset();          // a new clean cage ⇒ a new topology key
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        preview_.reset();          // drop the clean-cage scratch with the session
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && dragPart >= 0 && built && (state_.width != 0.0f || state_.miterOffset != 0.0f);
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    public override void resyncSession() {
        if (!active) return;
        reinitSession();
    }

    mixin SessionCommitHooks;
    mixin TopologyStepClientBody!("Edge Bevel", before);
    mixin GizmoTopologyRebase;
    // A new basis is a new clean cage, so a new topology key.
    final void afterTopologyRebase() { preview_.reset(); }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    private EdgeBevelParamProjection paramProjection() const nothrow @nogc {
        return EdgeBevelParamProjection(interactiveParamEdit, active, built,
            state_);
    }
    final PreparedEdgeBevelParamImage buildPreparedParamUpdate(string, ref const Mesh live) {
        return PreparedEdgeBevelParamImage.prepare(paramProjection(), live);
    }
    final bool preparedParamUpdateMatches(in PreparedEdgeBevelParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.matches(paramProjection(), live);
    }
    final void installPreparedParamUpdate(ref PreparedEdgeBevelParamImage image)
            nothrow @nogc {
        image.clear();
    }
    mixin PreparedParamUpdateProducer!(PreparedParamUpdateOwner!(EdgeBevelTool,
        PreparedEdgeBevelParamImage, PreparedEdgeBevelParamKind), PreparedEdgeBevelParamEffect);
    override void evaluate() {}

    /// Test/diagnostic seam (task 1620): how the preview-rebuild seam split
    /// this session's rebuilds. `fullRebuilds` are the restore-and-rebuild
    /// frames (a real topology change, and the ones that legitimately cost a
    /// subpatch dispatch), `placements` the position-only ones, `keyMisses`
    /// the frames where the declared topology key claimed "unchanged" and the
    /// produced topology disagreed. A correct key never misses — see
    /// tools/edit/preview_rebuild.d.
    public PreviewRebuildCounts previewRebuildCounts() const {
        return preview_.counts();
    }

    override bool applyHeadless() {
        if (*editMode != EditMode.Edges) return false;
        // If a live drag (or an interactive-attr scrub) previously built
        // preview topology, restore the clean cage first so the kernel applies
        // exactly once (idempotent) — same guard the whole topology-tool family
        // carries (poly.bevel / edge.extrude / poly.extrude / vertex.bevel /
        // the polygon inset tool). In the pure headless flow (no drag) `before` == the
        // current mesh, so this is a no-op and ToolDoApplyCommand's pre-snapshot
        // stays clean.
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        // This path rebuilds the live mesh behind the seam's back, so the
        // key it remembers no longer describes what is standing.
        preview_.reset();
        if (mesh.edges.length == 0) return false;
        if (state_.width == 0.0f && state_.miterOffset == 0.0f) return true;
        if (operation(*mesh) == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { closeOwnOperation(false); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Edges) return false;
        if (!gizmoValid) return false;

        int hmx, hmy;
        queryMouse(hmx, hmy);
        int part = toolHandles.test(hmx, hmy, cachedVp);

        dragStartMX   = e.x; dragStartMY = e.y;
        handleBank_.snapshotStarts(state_);

        if (part == PART_WIDTH || part == PART_MITER) {
            sessionStepBegins();
            dragPart = part;
            toolHandles.setHaul(part);
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        sessionStepEnds();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || !gizmoValid) return false;
        bool skip;
        // Projected in the space the arm is DRAWN in, and converted back into
        // the LOCAL length the kernel means (task 0645) — one OverlayAxis in
        // both roles, so the arm the pixels are dotted against is the arm on
        // screen and the geometry follows it.
        const auto os = OverlaySpace.ofPrimary();
        const auto ax = os.axis(dragPart == PART_WIDTH ? widthAxis : miterAxis);
        const Vec3 worldDelta = screenAxisDelta(e.x, e.y, dragStartMX, dragStartMY,
            os.pos(anchor), ax.dir, cachedVp, skip);
        const float delta = ax.toLocal(dot(worldDelta, ax.dir));
        if (!skip) {
            updateScalar(dragPart, delta);
            rebuildPreview();
        }
        return true;
    }

    // Task 20261270: captured ID0/attr1 and ID1/attr7 use independent
    // cumulative press snapshots; raw delta survives the effective zero floor.
    private void updateScalar(int part, float delta) nothrow @nogc {
        handleBank_.scalars[part].delta = delta;
        const float value = handleBank_.scalars[part].start + delta;
        if (part == PART_WIDTH) state_.width = value < 0 ? 0 : value;
        else state_.miterOffset = value < 0 ? 0 : value;
    }

    // Read-only test seams.  The handle registry remains the hit-testing
    // authority; these merely expose its already-drawn state to the HTTP API.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]       = JSONValue("edgeBevel");
        root["width"]      = JSONValue(state_.width);
        root["roundLevel"] = JSONValue(state_.roundLevel);
        root["widthMode"]  = JSONValue(state_.widthMode);
        root["miterOffset"] = JSONValue(state_.miterOffset);
        root["built"]      = JSONValue(built);
        root["dragPart"]   = JSONValue(dragPart);
        return root;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        if (visualOnly) {
            // Visual cells do not run arbitration, but they draw the resident
            // owner's paint state.  This mirrors display state only; the
            // replica remains absent from ToolHandles and cannot become hot.
            replicaArrow_.setState(widthArrow.getState());
            replicaArrow_.setEngaged(widthArrow.isEngaged());
            replicaMiterArrow_.setState(handleBank_.miterArrow.getState());
            replicaMiterArrow_.setEngaged(handleBank_.miterArrow.isEngaged());
            drawReplica(shader, vp);
            return;
        }
        cachedVp = vp;
        if (dragPart < 0 && !built) {
            immutable ulong signature = mesh.selectionSignature(EditMode.Edges);
            if (signature != gizmoSelHash) {
                if (replicaImage_.valid &&
                    replicaImage_.gizmoSelHash == signature)
                    publishGizmoFrame(replicaImage_);
                else
                    computeGizmoFrame();
            }
        }
        if (!gizmoValid) return;

        anchor = baseAnchor;   // LOCAL, like the kernel

        // ONE overlay space for the pass (tasks 0645/6512): the arm is positioned in
        // it and `toolHandles.update` below hit-tests this same object, so
        // drawing and hitting cannot land in different spaces.
        const auto os      = OverlaySpace.ofPrimary();
        const auto ax      = os.axis(widthAxis);
        const Vec3 anchorW = os.pos(anchor);

        float armLen = gizmoSize(anchorW, vp, 1.0f);
        widthArrow.start = anchorW + ax.dir * (armLen / 6.0f);
        widthArrow.end   = anchorW + ax.dir * armLen;
        widthArrow.color = WIDTH_COLOR;
        // Same clamped cube extent as Scale; endpoints remain the drag frame.
        widthArrow.fixedCubeHalf = gizmoPixelSize(anchorW, vp, gizmoBoxHalfPx());
        handleBank_.miterArrow.fixedCubeHalf = widthArrow.fixedCubeHalf;
        const auto miterAx = os.axis(miterAxis);
        handleBank_.miterArrow.start = anchorW + miterAx.dir * (armLen / 6.0f);
        handleBank_.miterArrow.end = anchorW + miterAx.dir * armLen;

        toolHandles.begin();
        auto parts = handleBank_.handleParts();
        toolHandles.add(parts[], 0);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        widthArrow.draw(shader, vp);
        handleBank_.miterArrow.draw(shader, vp);
    }

private:
    // A foreign-cell projection is draw geometry, not owner interaction
    // state. Derive into a local image so a replica cannot replace
    // the viewport, frozen frame, registered arrow, or arbiter used by events.
    private void drawReplica(const ref Shader shader, const ref Viewport vp) {
        PreparedEdgeBevelActivationImage image;
        image.gizmoValid = gizmoValid;
        image.baseAnchor = baseAnchor;
        image.widthAxis = widthAxis; image.miterAxis = miterAxis;
        image.gizmoSelHash = gizmoSelHash;
        if (dragPart < 0 && !built) {
            immutable ulong signature = mesh.selectionSignature(EditMode.Edges);
            ensureReplicaFrame(signature, image);
            image = replicaImage_;
        }
        if (!image.gizmoValid) return;

        const auto os = OverlaySpace.ofPrimary();
        const auto ax = os.axis(image.widthAxis);
        const Vec3 anchorW = os.pos(image.baseAnchor);
        const float armLen = gizmoSize(anchorW, vp, 1.0f);
        replicaArrow_.start = anchorW + ax.dir * (armLen / 6.0f);
        replicaArrow_.end = anchorW + ax.dir * armLen;
        replicaArrow_.color = WIDTH_COLOR;
        replicaArrow_.fixedCubeHalf = gizmoPixelSize(anchorW, vp, gizmoBoxHalfPx());
        replicaMiterArrow_.fixedCubeHalf = replicaArrow_.fixedCubeHalf;
        replicaArrow_.draw(shader, vp);
        const auto miterAx = os.axis(image.miterAxis);
        replicaMiterArrow_.start = anchorW + miterAx.dir * (armLen / 6.0f);
        replicaMiterArrow_.end = anchorW + miterAx.dir * armLen;
        replicaMiterArrow_.draw(shader, vp);
    }

    private void ensureReplicaFrame(ulong signature,
            ref const PreparedEdgeBevelActivationImage ownerImage) {
        // A newly installed tool can reach a visual draw before any explicit
        // cache publication.  Seed from the complete owner image only when it
        // already describes this selection; otherwise derive current geometry.
        if (!replicaImage_.valid && ownerImage.gizmoSelHash == signature) {
            replicaImage_.valid = true;
            replicaImage_.gizmoValid = ownerImage.gizmoValid;
            replicaImage_.anchor = ownerImage.anchor;
            replicaImage_.baseAnchor = ownerImage.baseAnchor;
            replicaImage_.widthAxis = ownerImage.widthAxis;
            replicaImage_.miterAxis = ownerImage.miterAxis;
            replicaImage_.gizmoSelHash = ownerImage.gizmoSelHash;
        }
        if (replicaImage_.valid && replicaImage_.gizmoSelHash == signature)
            return;

        replicaImage_.clear();
        replicaImage_.valid = true;
        replicaImage_.gizmoSelHash = signature;
        computePreparedGizmoFrame(*mesh, replicaImage_);
    }

    void computeGizmoFrame() {
        PreparedEdgeBevelActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.widthAxis = widthAxis; image.miterAxis = miterAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*mesh, image);
        publishGizmoFrame(image);
        publishOwnerFrameToReplica();
    }

    private void publishGizmoFrame(
            ref const PreparedEdgeBevelActivationImage image) {
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; widthAxis = image.widthAxis; miterAxis = image.miterAxis;
        gizmoSelHash = image.gizmoSelHash;
    }

    private void publishOwnerFrameToReplica() nothrow @nogc {
        replicaImage_.clear();
        replicaImage_.valid = true;
        replicaImage_.gizmoValid = gizmoValid;
        replicaImage_.anchor = anchor;
        replicaImage_.baseAnchor = baseAnchor;
        replicaImage_.widthAxis = widthAxis;
        replicaImage_.miterAxis = miterAxis;
        replicaImage_.gizmoSelHash = gizmoSelHash;
    }

    private static void computePreparedGizmoFrame(ref Mesh source,
            ref PreparedEdgeBevelActivationImage image) {
        version(unittest) ++preparedGizmoFrameCallsForTest_;
        image.gizmoValid = false;
        if (source.edges.length == 0) return;
        // Task 20261290: selected-endpoint bounds and the captured edge normal/
        // grouped edge-up producer feed one owner frame; columns 2/0 bind IDs 0/1.
        const mask = source.operandEdgeMask();
        Vec3 low, high;
        Vec3 sum = Vec3(0,0,0);
        bool populated;
        struct Direction { Vec3 axis; float weight; uint count; }
        Direction[] directions;
        foreach (ei, chosen; mask) if (chosen) {
            const auto edge = source.edges[ei];
            foreach (v; edge) {
                const Vec3 point = source.vertices[v];
                if (!populated) { low = high = point; populated = true; }
                else {
                    low = Vec3(point.x < low.x ? point.x : low.x,
                        point.y < low.y ? point.y : low.y, point.z < low.z ? point.z : low.z);
                    high = Vec3(point.x > high.x ? point.x : high.x,
                        point.y > high.y ? point.y : high.y, point.z > high.z ? point.z : high.z);
                }
            }
            uint[] adjacent;
            foreach (fi, ring; source.faces) {
                foreach (i, v; ring) {
                    const uint next = ring[(i + 1) % ring.length];
                    if ((v == edge[0] && next == edge[1]) ||
                        (v == edge[1] && next == edge[0])) {
                        adjacent ~= cast(uint)fi;
                        sum = sum + source.faceNormal(cast(uint)fi);
                        break;
                    }
                }
            }
            // An up direction needs the two-sided representative polygon.
            if (adjacent.length < 2) continue;
            Vec3 direction = source.vertices[edge[1]] - source.vertices[edge[0]];
            const float weight = direction.length;
            if (weight == 0) continue;
            direction = direction * (1 / weight);
            bool grouped;
            foreach (ref group; directions) {
                const float agreement = dot(group.axis, direction);
                if (abs(agreement) <= 0.55f) continue;
                if (agreement < 0) direction = direction * -1;
                group.axis = safeNormalize((group.axis * group.count + direction) * (1.0f / (group.count + 1)));
                group.weight += weight; ++group.count;
                grouped = true; break;
            }
            if (!grouped) directions ~= Direction(direction, weight, 1);
        }
        if (!populated) return;
        image.anchor = (low + high) * 0.5f;
        Vec3 primary = safeNormalize(sum), up = Vec3(0,1,0);
        if (dot(sum, sum) < 0.0001f) primary = Vec3(0,0,1);
        else if (directions.length) {
            size_t best;
            foreach (i; 1 .. directions.length) {
                if (directions[i].weight > directions[best].weight ||
                    (directions[i].weight == directions[best].weight &&
                        abs(directions[i].axis.y) < abs(directions[best].axis.y))) best = i;
            }
            up = directions[best].axis;
            if (up.y < 0) up = up * -1;
            primary = safeNormalize(primary - up * dot(primary, up));
        }
        image.widthAxis = primary;
        image.miterAxis = cross(up, primary);
        image.baseAnchor = image.anchor;
        image.gizmoSelHash = source.selectionSignature(EditMode.Edges);
        image.gizmoValid = true;
    }

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

    // TOPOLOGY KEY (task 1620): the operand mask, `roundLevel` (the ring
    // count), `widthMode` — and the joint zero crossing: both scalars zero
    // builds nothing, so crossing that state makes geometry vanish and reappear
    // while (mask, roundLevel) sits still. `widthMode` only reinterprets the
    // width, but a dropdown changes at human speed: keying it costs an extra
    // rebuild and buys not proving that no width mode collapses a face.
    PreviewTopologyKey previewKey(ref Mesh cage) {
        return PreviewTopologyKey.make(cage.operandEdgeMask(), state_.width == 0.0f && state_.miterOffset == 0.0f,
            state_.roundLevel, state_.widthMode ? 1 : 0, state_.miterOffset > 0 ? 1 : 0);
    }
    // The one operation: preview and scripted apply.
    // Unrecorded — a preview frame records nothing, and the gesture's record
    // is the session's mesh image at release. `target` is the seam's private
    // cage on the placement path and the live mesh on a key change, so the
    // batch lands on the mesh the kernel actually gets. The mask is the L1
    // funnel: the selection, else every VISIBLE edge (tasks 9434, 1903, 0613).
    // Zero width with positive miter offset keeps the selected edge and trims
    // its adjoining faces through the same kernel used by preview and apply.
    size_t operation(ref Mesh target) {
        auto ed = MeshEditBatch.unrecorded(target, kEdgeBevelEditScope);
        const n = ed.bevelEdgesByMask(target.operandEdgeMask(), state_.width,
            state_.roundLevel, state_.widthMode, state_.miterOffset);
        ed.close();
        return n;
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        if (c is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.EdgeBevel, false, false);
        const accepted = c.markNoHistoryInstall();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.EdgeBevel, false, accepted);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        preview_.reset();
        built    = false;
        dragPart = -1;
        toolHandles.clearHaul();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }

public:
    version(unittest) {
        final void updateScalarForTest(int part, float delta) { updateScalar(part, delta); }
        final EdgeBevelState stateForTest() const { return state_; }
        final void stateForTest(EdgeBevelState state) { state_ = state; }
        final HandlePart[2] handlePartsForTest() { return handleBank_.handleParts(); }
        final void snapshotStartsForTest() { handleBank_.snapshotStarts(state_); }
        final float[4] scalarStartsDeltasForTest() const {
            return [handleBank_.scalars[0].start, handleBank_.scalars[1].start,
                handleBank_.scalars[0].delta, handleBank_.scalars[1].delta];
        }
        final int[4] scalarBindingsForTest() const {
            return [cast(int)handleBank_.scalars[0].binding,
                cast(int)handleBank_.scalars[1].binding,
                cast(int)handleBank_.scalars[0].basis,
                cast(int)handleBank_.scalars[1].basis];
        }
        final int firstBankHitForTest(int x, int y, const ref Viewport vp) {
            return handleBank_.firstHit(x, y, vp);
        }
        private static size_t preparedGizmoFrameCallsForTest_;

        private static void appendRaw(T)(ref ubyte[] bytes,
                                         ref const T value) {
            bytes ~= (cast(const(ubyte)*) &value)[0 .. T.sizeof];
        }

        struct EdgeBevelInteractionReadForTest {
            bool gizmoValid;
            Vec3 anchor;
            Vec3 baseAnchor;
            Vec3 widthAxis;
            ulong gizmoSelHash;
            int dragPart;
            bool built;
            int cachedWidth;
            int cachedHeight;
        }

        final EdgeBevelInteractionReadForTest readInteractionForTest() const
                nothrow @nogc {
            return EdgeBevelInteractionReadForTest(gizmoValid, anchor,
                baseAnchor, widthAxis, gizmoSelHash, dragPart, built,
                cachedVp.width, cachedVp.height);
        }

        final const(CubicArrow)[2] replicaArrowForTest(out Vec3 start, out Vec3 end,
                                       out size_t drawId) const {
            start = replicaArrow_.start;
            end = replicaArrow_.end;
            drawId = replicaArrow_.drawIdentity();
            return [replicaArrow_, replicaMiterArrow_];
        }

        final void widthArrowForTest(out Vec3 start, out Vec3 end,
                                     out size_t drawId) const {
            start = widthArrow.start;
            end = widthArrow.end;
            drawId = widthArrow.drawIdentity();
        }

        final void replicaPaintForTest(out Vec3 base, out Vec3 resolved,
                out HandleState state, out bool engaged) const {
            base = replicaArrow_.color;
            resolved = replicaArrow_.resolvedColorForTest(base);
            state = replicaArrow_.getState();
            engaged = replicaArrow_.isEngaged();
        }

        final void widthPaintForTest(out Vec3 base, out Vec3 resolved,
                out HandleState state, out bool engaged) const {
            base = widthArrow.color;
            resolved = widthArrow.resolvedColorForTest(base);
            state = widthArrow.getState();
            engaged = widthArrow.isEngaged();
        }

        final bool previewResetForTest() const nothrow @nogc {
            return preview_.resetForTest();
        }
        final ToolHandles handlesForTest() { return toolHandles; }

        final void resetPreparedGizmoFrameCallsForTest() nothrow @nogc {
            preparedGizmoFrameCallsForTest_ = 0;
        }

        final size_t preparedGizmoFrameCallsForTest() const nothrow @nogc {
            return preparedGizmoFrameCallsForTest_;
        }

        final ubyte[] interactionStateBytesForTest() const {
            ubyte[] bytes;
            appendRaw(bytes, cachedVp.view);
            appendRaw(bytes, cachedVp.proj);
            appendRaw(bytes, cachedVp.width);
            appendRaw(bytes, cachedVp.height);
            appendRaw(bytes, cachedVp.x);
            appendRaw(bytes, cachedVp.y);
            appendRaw(bytes, cachedVp.eye);
            appendRaw(bytes, cachedVp.focus);
            appendRaw(bytes, gizmoValid);
            appendRaw(bytes, anchor);
            appendRaw(bytes, baseAnchor);
            appendRaw(bytes, widthAxis);
            appendRaw(bytes, miterAxis);
            appendRaw(bytes, gizmoSelHash);
            appendRaw(bytes, dragPart);
            appendRaw(bytes, built);
            appendRaw(bytes, active);
            appendRaw(bytes, state_.width);
            appendRaw(bytes, state_.roundLevel);
            appendRaw(bytes, state_.widthMode);
            appendRaw(bytes, dragStartMX);
            appendRaw(bytes, dragStartMY);
            foreach (scalar; handleBank_.scalars) {
                appendRaw(bytes, scalar.binding);
                appendRaw(bytes, scalar.basis);
                appendRaw(bytes, scalar.start);
                appendRaw(bytes, scalar.delta);
            }
            appendRaw(bytes, state_.profile);
            appendRaw(bytes, state_.miterOffset);
            appendRaw(bytes, state_.sharpCorner);
            appendRaw(bytes, state_.maintainCoplanar);
            appendRaw(bytes, state_.materialOverride);
            const size_t materialNameLength = state_.materialName.length;
            appendRaw(bytes, materialNameLength);
            bytes ~= cast(const(ubyte)[])state_.materialName;
            appendRaw(bytes, widthArrow.start);
            appendRaw(bytes, widthArrow.end);
            appendRaw(bytes, widthArrow.color);
            bytes ~= widthArrow.handlerStateBytesForTest();
            appendRaw(bytes, handleBank_.miterArrow.start);
            appendRaw(bytes, handleBank_.miterArrow.end);
            appendRaw(bytes, handleBank_.miterArrow.color);
            bytes ~= handleBank_.miterArrow.handlerStateBytesForTest();
            immutable counts = preview_.counts();
            appendRaw(bytes, counts.fullRebuilds);
            appendRaw(bytes, counts.placements);
            appendRaw(bytes, counts.keyMisses);
            bytes ~= preview_.previewStateBytesForTest();
            appendRaw(bytes, before.filled);
            immutable size_t beforeVertices = before.vertices.length;
            immutable size_t beforeEdges = before.edges.length;
            immutable size_t beforeFaces = before.faces.length;
            immutable ulong beforeVertexHash = cast(ulong) hashOf(before.vertices);
            appendRaw(bytes, beforeVertices);
            appendRaw(bytes, beforeEdges);
            appendRaw(bytes, beforeFaces);
            appendRaw(bytes, beforeVertexHash);
            bytes ~= toolHandles.arbiterStateBytesForTest();
            return bytes;
        }
    }

    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest(ref Mesh oldMesh) {
        active = false; built = true; dragPart = 9; state_.width = 7;
        state_.roundLevel = 3; state_.widthMode = true;
        gizmoValid = false; anchor = Vec3(1,2,3); baseAnchor = Vec3(4,5,6);
        widthAxis = Vec3(7,8,9); gizmoSelHash = 10;
        dragStartMX = 11; dragStartMY = 12; handleBank_.scalars[0].start = 13;
        cachedVp.view[0] = 14; before = MeshSnapshot.capture(oldMesh);
        preview_.seedForTest(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const
            nothrow @nogc {
        return !active && built && dragPart == 9 && state_.width == 7 &&
            state_.roundLevel == 3 && state_.widthMode && !gizmoValid &&
            anchor == Vec3(1,2,3) && baseAnchor == Vec3(4,5,6) &&
            widthAxis == Vec3(7,8,9) && gizmoSelHash == 10 &&
            preview_.dirtyForTest();
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr, bool expectedValid,
            Vec3 expectedAnchor, Vec3 expectedBase, Vec3 expectedAxis,
            ulong expectedHash) const nothrow @nogc {
        return active && !built && dragPart == -1 && state_.width == 7 &&
            state_.roundLevel == 3 && state_.widthMode && before.filled &&
            before.vertices.length == count &&
            (count == 0 || (before.vertices[0] == first &&
                            before.vertices.ptr !is livePtr)) &&
            preview_.resetForTest() && gizmoValid == expectedValid &&
            anchor == expectedAnchor && baseAnchor == expectedBase &&
            widthAxis == expectedAxis && gizmoSelHash == expectedHash &&
            dragStartMX == 11 && dragStartMY == 12 && handleBank_.scalars[0].start == 13 &&
            cachedVp.view[0] == 14;
    }
    version(unittest) final PreparedEdgeBevelActivationImage
            preparedFrameForTest(ref Mesh source) const {
        PreparedEdgeBevelActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.widthAxis = widthAxis; image.miterAxis = miterAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(source, image);
        return image;
    }
}
