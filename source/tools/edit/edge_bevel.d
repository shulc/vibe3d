module tools.edit.edge_bevel;
import display_state : DrawPlan;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedGpuParamDoorClient;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import mesh_ops.edge_bevel : bevelEdgesByMask, kEdgeBevelEditScope;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, ToolHandles, HandleState, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import drag : screenAxisDelta;
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
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedSimpleToolDoorClient;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_edge_bevel_activation : PreparedEdgeBevelActivationOwner;
import prepared_edge_bevel_param_update : PreparedEdgeBevelParamUpdateOwner;
import prepared_tool_effect : PreparedEdgeBevelParamEffect,
    PreparedEdgeBevelParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import core.stdc.string : memcmp;
import command_history : PreparedHistoryKind;

struct PreparedEdgeBevelActivationImage {
    MeshSnapshot before;
    bool valid, gizmoValid;
    Vec3 anchor, baseAnchor, widthAxis;
    ulong gizmoSelHash;
    void clear() nothrow @nogc {
        this = PreparedEdgeBevelActivationImage.init;
    }
}

struct EdgeBevelParamProjection {
    bool interactive, active, built, widthMode;
    float width;
    int roundLevel;
    bool opEquals(const EdgeBevelParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built && widthMode == other.widthMode &&
            roundLevel == other.roundLevel &&
            memcmp(&width, &other.width, float.sizeof) == 0;
    }
}

struct PreparedEdgeBevelParamImage {
    bool valid, applies, nextBuilt;
    EdgeBevelParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    PreparedPreviewRebuildImage preview;
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        preview.clear(); candidate = Mesh.init; valid = applies = false;
    }
}

// ---------------------------------------------------------------------------
// EdgeBevelTool — interactive Edge Bevel (factory id `edge.bevel`).
//
// Topology-creating tool, modelled on PolyExtrudeTool. One snapshot undo entry
// per gesture (MeshSessionEdit before/after pair, via bevelEditFactory).
//
// Single handle:
//   PART_WIDTH = BLUE Arrow along the averaged adjacent-face normal.
//
// Headless: tool.set edge.bevel on; tool.attr edge.bevel width <v>;
//           tool.doApply → applyHeadless(); ToolDoApplyCommand wraps undo.
// ---------------------------------------------------------------------------
class EdgeBevelTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient {
    // A recording command through the UI door closes the live edit first —
    // `Tool.commitOperation`'s in-place default — and the tool stays armed
    // (slice M2; the C1-h-sel-fam law, captured for Edge Extend and Polygon
    // Bevel and inferred for the rest of the in-place family, R20 gap g5).
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = { commandClose: CommandClose.uiDoor };
        return policy;
    }

    mixin PreparedGpuParamDoorClient;
    mixin PreparedSimpleToolDoorClient!Layer;
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    float width_      = 0.0f;
    int   roundLevel_ = 0;
    // Mirrors the mesh.bevel command's edge `widthMode`: false (default) =
    // `width_` IS the along-face slide (inset); true = `width_` is the true
    // perpendicular bevel width (slide = width/sin(dihedral/2)). Kept in lock-
    // step with the command so tool preview == headless apply.
    bool  widthMode_  = false;

    bool         active;
    bool         built;
    MeshSnapshot before;
    // The restore-and-rebuild seam (task 1620) — see
    // tools/edit/preview_rebuild.d.
    PreviewRebuild preview_;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 widthAxis;
    ulong gizmoSelHash;

    enum int PART_WIDTH = 0;
    int   dragPart = -1;
    // One drag has one screen-space origin.  Width is written back as an
    // absolute value from that origin, so replay/coalescing cannot make the
    // result depend on how many motion events SDL delivered.
    int   dragStartMX, dragStartMY;
    float dragBaseWidth;

    Arrow       widthArrow;
    Arrow       replicaArrow_;
    // One draw-only frame image is shared by every foreign cell.  The owner
    // publishes its frozen frame here; after a selection change the first
    // replica refreshes it and the remaining replicas plus the owner reuse it.
    PreparedEdgeBevelActivationImage replicaImage_;
    ToolHandles toolHandles;

    enum Vec3 WIDTH_COLOR = schemeColor(SchemeColor.toolOffset);

public:
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true) {
        interactiveParamEdit = interactive; active = true; built = false;
        width_ = 0.2f; roundLevel_ = 1; widthMode_ = false;
        before = MeshSnapshot.capture(live); preview_.reset();
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { width_ = value; }
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
        widthArrow  = new Arrow(Vec3(0,0,0), Vec3(0,1,0), WIDTH_COLOR);
        replicaArrow_ = new Arrow(Vec3(0,0,0), Vec3(0,1,0), WIDTH_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (widthArrow !is null) widthArrow.destroy();
        if (replicaArrow_ !is null) replicaArrow_.destroy();
    }

    override string name() const { return "Edge Bevel"; }

    override EditMode[] supportedModes() const { return [EditMode.Edges]; }

    override Param[] params() {
        import mesh : MAX_ROUND_LEVEL;
        return [
            Param.float_("width", "Width", &width_, 0.0f),
            Param.int_("roundLevel", "Round Level", &roundLevel_, 0)
                .min(0).max(MAX_ROUND_LEVEL).enforceBounds(),
            Param.bool_("widthMode", "Width Mode", &widthMode_, false),
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
        image.baseAnchor = baseAnchor; image.widthAxis = widthAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*source, image);
        return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedEdgeBevelActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragPart = -1; width_ = 0.0f;
        preview_.reset(); image.before.moveInto(before);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; widthAxis = image.widthAxis;
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
        width_   = 0.0f;
        preview_.reset();          // a new clean cage ⇒ a new topology key
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && width_ != 0.0f)
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        preview_.reset();          // drop the clean-cage scratch with the session
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && width_ != 0.0f;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

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

    override void onParamChanged(string pname) {
        if (interactiveParamEdit) rebuildPreview();
    }
    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    private EdgeBevelParamProjection paramProjection() const nothrow @nogc {
        return EdgeBevelParamProjection(interactiveParamEdit, active, built,
            widthMode_, width_, roundLevel_);
    }
    final PreparedEdgeBevelParamImage buildPreparedParamUpdate(ref Mesh live) {
        PreparedEdgeBevelParamImage image;
        image.valid = true; image.expected = paramProjection();
        image.nextBuilt = built; image.expectedLive = MeshSnapshot.capture(live);
        // Task 4491 — the same cold-arm hole as PolyBevelTool, and for the
        // same reason: this tool's `preparedParamUpdateMatches` also carries
        // the `preview_.matchesImage` conjunct unconditionally, so an image
        // that skipped `prepareImage` refuses the arm outright. Single call
        // site, above the early return, for the reason spelled out at the
        // sibling site in tools/edit/poly_bevel.d.
        {
            auto cageShadow = beginPreparedShadow(image.preview.nextCage);
            preview_.prepareImage(image.preview);
            uint cageFlags, cageDomains;
            drainPreparedShadowDelivery(image.preview.nextCage, cageFlags,
                cageDomains);
            cageShadow.close();
        }
        if (!before.filled) return image;
        Mesh baseline;
        auto baselineShadow = beginPreparedShadow(baseline);
        before.restore(baseline);
        image.expectedBefore = MeshSnapshot.capture(baseline);
        image.expectedLive.restore(image.candidate);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        baselineShadow.close(); image.deliveryFlags = image.deliveryDomains = 0;
        if (!interactiveParamEdit || !active) return image;
        image.applies = true;
        auto shadow = beginPreparedShadow(image.candidate);
        PreviewRebuild preparedPreview; preparedPreview.loadPreparedNext(image.preview);
        const n = preparedPreview.run(image.candidate, before,
            (ref Mesh cage) => PreviewTopologyKey.make(cage.operandEdgeMask(),
                width_ == 0.0f, roundLevel_, widthMode_ ? 1 : 0),
            (ref Mesh target) {
                if (width_ == 0.0f) return cast(size_t)0;
                auto ed = MeshEditBatch.unrecorded(target, kEdgeBevelEditScope);
                const result = ed.bevelEdgesByMask(target.operandEdgeMask(),
                    width_, roundLevel_, widthMode_);
                ed.close(); return result;
            });
        image.nextBuilt = (n != 0); preparedPreview.savePreparedNext(image.preview);
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(in PreparedEdgeBevelParamImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) && image.expectedBefore.matches(before) &&
            preview_.matchesImage(image.preview);
    }
    final void installPreparedParamUpdate(ref PreparedEdgeBevelParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; preview_.installImage(image.preview); image.clear();
    }
    final PreparedEdgeBevelParamEffect prepareParamChanged(
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedEdgeBevelParamEffect(
            preparedToolStateOwner, PreparedEdgeBevelParamKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedEdgeBevelParamUpdateOwner.prepare(this, layer);
        auto kind = owner is null ? PreparedEdgeBevelParamKind.None : owner.effectKind;
        bool ok = owner !is null;
        if (ok && owner.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains);
        if (ok) ok = context.prepareEdgeBevelParamUpdate(owner);
        if (ok && owner.applies)
            ok = context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedEdgeBevelParamEffect(preparedToolStateOwner, kind, ok);
    }
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
        if (width_ == 0.0f) return true;
        auto mask = currentMask();
        // Task 1903 Stage G — the COMMIT door's batch, opened at the tool
        // boundary (§4.1) and scoped to the kernel call alone. UNRECORDED:
        // this tool undoes through the whole-mesh `before`/`post` snapshot
        // pair `commitEdit` records, so a recording batch would build an
        // op-log nothing reads and `close()` would drop. Stage M owns the
        // flip.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kEdgeBevelEditScope);
            n = ed.bevelEdgesByMask(mask, width_, roundLevel_, widthMode_);
            ed.close();
        }
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Edges) return false;
        if (!gizmoValid) return false;

        int hmx, hmy;
        queryMouse(hmx, hmy);
        int part = toolHandles.test(hmx, hmy, cachedVp);

        dragStartMX   = e.x; dragStartMY = e.y;
        dragBaseWidth = width_;

        if (part == PART_WIDTH) {
            dragPart = PART_WIDTH;
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
        const auto ax = os.axis(widthAxis);
        Vec3 delta = screenAxisDelta(e.x, e.y, dragStartMX, dragStartMY,
                                     os.pos(anchor), ax.dir, cachedVp, skip);
        if (!skip) {
            float d = ax.toLocal(dot(delta, ax.dir));
            width_ = dragBaseWidth + d;
            if (width_ < 0.0f) width_ = 0.0f;
            rebuildPreview();
        }
        return true;
    }

    // Read-only test seams.  The handle registry remains the hit-testing
    // authority; these merely expose its already-drawn state to the HTTP API.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]       = JSONValue("edgeBevel");
        root["width"]      = JSONValue(width_);
        root["roundLevel"] = JSONValue(roundLevel_);
        root["widthMode"]  = JSONValue(widthMode_);
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

        toolHandles.begin();
        toolHandles.add(widthArrow, PART_WIDTH);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        widthArrow.draw(shader, vp);
    }

private:
    // A foreign-cell projection is draw geometry, not owner interaction
    // state. Derive into a local image so a replica cannot replace
    // the viewport, frozen frame, registered arrow, or arbiter used by events.
    private void drawReplica(const ref Shader shader, const ref Viewport vp) {
        PreparedEdgeBevelActivationImage image;
        image.gizmoValid = gizmoValid;
        image.baseAnchor = baseAnchor;
        image.widthAxis = widthAxis;
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
        replicaArrow_.draw(shader, vp);
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
            replicaImage_.gizmoSelHash = ownerImage.gizmoSelHash;
        }
        if (replicaImage_.valid && replicaImage_.gizmoSelHash == signature)
            return;

        replicaImage_.clear();
        replicaImage_.valid = true;
        replicaImage_.gizmoSelHash = signature;
        computePreparedGizmoFrame(*mesh, replicaImage_);
    }

    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandEdgeMask();
    }

    void computeGizmoFrame() {
        PreparedEdgeBevelActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.widthAxis = widthAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*mesh, image);
        publishGizmoFrame(image);
        publishOwnerFrameToReplica();
    }

    private void publishGizmoFrame(
            ref const PreparedEdgeBevelActivationImage image) {
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; widthAxis = image.widthAxis;
        gizmoSelHash = image.gizmoSelHash;
    }

    private void publishOwnerFrameToReplica() nothrow @nogc {
        replicaImage_.clear();
        replicaImage_.valid = true;
        replicaImage_.gizmoValid = gizmoValid;
        replicaImage_.anchor = anchor;
        replicaImage_.baseAnchor = baseAnchor;
        replicaImage_.widthAxis = widthAxis;
        replicaImage_.gizmoSelHash = gizmoSelHash;
    }

    private static void computePreparedGizmoFrame(ref Mesh source,
            ref PreparedEdgeBevelActivationImage image) {
        version(unittest) ++preparedGizmoFrameCallsForTest_;
        image.gizmoValid = false;
        if (source.edges.length == 0) return;
        image.anchor = source.selectionCentroidEdges();
        // widthAxis = averaged normal of adjacent faces of selected edges.
        Vec3 sum = Vec3(0,0,0);
        bool any = source.hasAnySelectedEdges();
        foreach (fi; 0 .. source.faces.length) {
            if (any) {
                bool adj = false;
                auto f = source.faces[fi];
                foreach (k; 0..f.length) {
                    foreach (ei; 0 .. source.edges.length) {
                        if (!source.isEdgeSelected(ei)) continue;
                        uint a = source.edges[ei][0], b = source.edges[ei][1];
                        uint u = f[k], w = f[(k+1)%f.length];
                        if ((a==u&&b==w)||(a==w&&b==u)) { adj = true; break; }
                    }
                    if (adj) break;
                }
                if (adj) sum = sum + source.faceNormal(cast(uint)fi);
            } else {
                sum = sum + source.faceNormal(cast(uint)fi);
            }
        }
        float len = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        image.widthAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        image.baseAnchor = image.anchor;
        image.gizmoSelHash = source.selectionSignature(EditMode.Edges);
        image.gizmoValid = true;
    }

    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        // TOPOLOGY KEY (task 1620): the operand mask, `roundLevel` (which is
        // the bevel's segment count and therefore how many rings exist),
        // `widthMode` — and THE ZERO CROSSING.
        //
        // `width_ == 0` is the kernel-side "build nothing" branch below, and
        // dragging the width down through zero and back makes the bevel
        // geometry disappear and reappear. A key of (mask, roundLevel) alone
        // would not move across either crossing while the topology moved
        // twice, so the degenerate predicate is part of the key rather than a
        // case beside it. `widthMode` only reinterprets the width (a
        // position quantity), but it is a dropdown that changes at human
        // speed: keying it costs an occasional extra full rebuild and buys
        // not having to prove that no width mode can collapse a face.
        size_t n = preview_.run(*mesh, before,
            (ref Mesh cage) => PreviewTopologyKey.make(cage.operandEdgeMask(),
                                                       width_ == 0.0f,
                                                       roundLevel_,
                                                       widthMode_ ? 1 : 0),
            (ref Mesh target) {
                if (width_ == 0.0f) return cast(size_t)0;
                // Task 1903 Stage G — the PER-FRAME PREVIEW's batch, opened
                // INSIDE this kernel lambda rather than by changing
                // `preview_.run`'s delegate signature (plan §9.1 as corrected
                // at Stage F2, памятка 41). `target` IS the private cage on
                // the placement path and IS the live mesh on the key-changed
                // full-rebuild path, so the batch lands on whichever mesh the
                // kernel actually got — both of §9.1's consequences, with no
                // edit to a seam that still serves `mesh_ops/extrude.d`
                // (Stage H).
                //
                // UNRECORDED, and that is §9's whole point: a preview frame
                // must record NOTHING. `changeBus.opLogEntriesRecorded` is
                // the row that says so across every frame;
                // `unbatchedGeometryCommits` is `g_isDocumentMesh`-FILTERED
                // (§3.2 L2), so on a `PreviewRebuild` tool it witnesses the
                // full-rebuild frames only — a weaker statement, and the
                // suite cell says which it is making (памятка 40).
                auto ed = MeshEditBatch.unrecorded(target, kEdgeBevelEditScope);
                immutable size_t nPrev =
                    ed.bevelEdgesByMask(target.operandEdgeMask(),
                                        width_, roundLevel_, widthMode_);
                ed.close();
                return nPrev;
            });
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool ok; if (active && built && width_ != 0 && c !is null && history !is null && gestureFactory !is null && before.filled) { auto cmd=cast(MeshSessionEdit)gestureFactory(); if(cmd !is null){cmd.setSnapshots(before,MeshSnapshot.capture(*mesh),"Edge Bevel");ok=c.prepare(cmd,PreparedHistoryKind.Plain).accepted;}}
        return PreparedDeactivateEffect(preparedToolStateOwner,PreparedDeactivateKind.EdgeBevel,ok);
    }
    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Edge Bevel");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
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

        final void replicaArrowForTest(out Vec3 start, out Vec3 end,
                                       out size_t drawId) const {
            start = replicaArrow_.start;
            end = replicaArrow_.end;
            drawId = replicaArrow_.drawIdentity();
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
            appendRaw(bytes, gizmoSelHash);
            appendRaw(bytes, dragPart);
            appendRaw(bytes, built);
            appendRaw(bytes, active);
            appendRaw(bytes, width_);
            appendRaw(bytes, roundLevel_);
            appendRaw(bytes, widthMode_);
            appendRaw(bytes, dragStartMX);
            appendRaw(bytes, dragStartMY);
            appendRaw(bytes, dragBaseWidth);
            appendRaw(bytes, widthArrow.start);
            appendRaw(bytes, widthArrow.end);
            appendRaw(bytes, widthArrow.color);
            bytes ~= widthArrow.handlerStateBytesForTest();
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
        active = false; built = true; dragPart = 9; width_ = 7;
        roundLevel_ = 3; widthMode_ = true;
        gizmoValid = false; anchor = Vec3(1,2,3); baseAnchor = Vec3(4,5,6);
        widthAxis = Vec3(7,8,9); gizmoSelHash = 10;
        dragStartMX = 11; dragStartMY = 12; dragBaseWidth = 13;
        cachedVp.view[0] = 14; before = MeshSnapshot.capture(oldMesh);
        preview_.seedForTest(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const
            nothrow @nogc {
        return !active && built && dragPart == 9 && width_ == 7 &&
            roundLevel_ == 3 && widthMode_ && !gizmoValid &&
            anchor == Vec3(1,2,3) && baseAnchor == Vec3(4,5,6) &&
            widthAxis == Vec3(7,8,9) && gizmoSelHash == 10 &&
            preview_.dirtyForTest();
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr, bool expectedValid,
            Vec3 expectedAnchor, Vec3 expectedBase, Vec3 expectedAxis,
            ulong expectedHash) const nothrow @nogc {
        return active && !built && dragPart == -1 && width_ == 0 &&
            roundLevel_ == 3 && widthMode_ && before.filled &&
            before.vertices.length == count &&
            (count == 0 || (before.vertices[0] == first &&
                            before.vertices.ptr !is livePtr)) &&
            preview_.resetForTest() && gizmoValid == expectedValid &&
            anchor == expectedAnchor && baseAnchor == expectedBase &&
            widthAxis == expectedAxis && gizmoSelHash == expectedHash &&
            dragStartMX == 11 && dragStartMY == 12 && dragBaseWidth == 13 &&
            cachedVp.view[0] == 14;
    }
    version(unittest) final PreparedEdgeBevelActivationImage
            preparedFrameForTest(ref Mesh source) const {
        PreparedEdgeBevelActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.widthAxis = widthAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(source, image);
        return image;
    }
}
