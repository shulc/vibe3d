module tools.edit.vertex_bevel_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, ToolHandles, HandleState, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import drag : screenAxisDelta, gesturePrevPixel;
import overlay_space : OverlaySpace;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedSimpleToolDoorClient;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_vertex_bevel_activation : PreparedVertexBevelActivationOwner;
import command_history : PreparedHistoryKind;
import prepared_vertex_bevel_param_update : PreparedVertexBevelParamUpdateOwner;
import prepared_tool_effect : PreparedVertexBevelParamEffect,
    PreparedVertexBevelParamKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import core.stdc.string : memcmp;

struct VertexBevelParamProjection {
    bool interactive, active, built;
    float inset;
    bool opEquals(const VertexBevelParamProjection other) const nothrow @nogc {
        return interactive == other.interactive && active == other.active &&
            built == other.built &&
            memcmp(&inset, &other.inset, float.sizeof) == 0;
    }
}

struct PreparedVertexBevelParamImage {
    bool valid, applies, nextBuilt;
    VertexBevelParamProjection expected;
    MeshSnapshot expectedLive, expectedBefore;
    Mesh candidate;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        candidate = Mesh.init; valid = applies = false;
    }
}

struct PreparedVertexBevelActivationImage {
    MeshSnapshot before;
    bool valid, gizmoValid;
    Vec3 anchor, baseAnchor, insetAxis;
    ulong gizmoSelHash;
    void clear() nothrow @nogc { this = PreparedVertexBevelActivationImage.init; }
}

// ---------------------------------------------------------------------------
// VertexBevelTool — interactive Vertex Bevel (factory id `mesh.vertexBevel`,
// task 0360 promotion of the one-shot `mesh.vertexBevel` command).
//
// Grounded in the captured toolcard (private spec tree — not reproduced
// here beyond the geometry/behavior facts already baked into
// mesh_ops.bevel_vertex.bevelVerticesByMask):
//   - ONE attribute (`inset`, world units, default 0.0).
//   - Exactly ONE drawn handle ("Inset"), ACTR-anchored — unlike Polygon
//     Bevel's two handles, only inset is adjustable when beveling
//     vertices.
//   - `inset == 0` AND `inset < 0` are BOTH confirmed byte-exact no-ops
//     (unlike the polygon-inset tool's degenerate-but-real zero-width split) —
//     mesh_ops.bevel_vertex.bevelVerticesByMask already guards `amount < 1e-6f` as a
//     no-op, so this divergence from the polygon-inset tool needed ZERO kernel
//     changes to already be correct.
//   - "Round Level" (extra rounding geometry) is a real, captured, but
//     UNVERIFIED-formula reference option (confirmed to add substantial
//     extra geometry structurally — roughly 2x the vertex count at
//     level=1 on a 4-corner selection; exact rounding profile not
//     derivable from the capture). Deliberately left OUT of this port
//     rather than guessed — it is also not part of the captured
//     handle_map (single handle only), so this is a panel-only gap, not
//     a missing-handle gap.
//   - Multi-adjacent-selection interaction (the exact per-vertex offset
//     law when several mutually-edge-adjacent vertices are beveled
//     together) is an OPEN QUESTION per the toolcard — not independently
//     re-derivable with the capture harness used. This tool ports the
//     single-vertex law byte-exact (see mesh_ops.bevel_vertex.bevelVerticesByMask's own
//     tests) and does not attempt to special-case multi-adjacent
//     selections beyond what the existing kernel already does.
//
// Session lifecycle mirrors EdgeBevelTool (its closest sibling: one
// attribute, ACTR-anchored single handle, topology-creating, generic
// before/after-snapshot undo).
// ---------------------------------------------------------------------------
class VertexBevelTool : Tool, PreparedToolDoorClient {
    mixin PreparedSimpleToolDoorClient!Layer;
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    float inset_ = 0.0f;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 insetAxis;
    ulong gizmoSelHash;

    enum int PART_INSET = 0;
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    float dragBaseInset;

    Arrow       insetArrow;
    ToolHandles toolHandles;

    enum Vec3 INSET_COLOR = schemeColor(SchemeColor.toolWidth);

public:
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu,
            EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        insetArrow  = new Arrow(Vec3(0,0,0), Vec3(0,1,0), INSET_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (insetArrow !is null) insetArrow.destroy();
    }

    override string name() const { return "Vertex Bevel"; }

    override EditMode[] supportedModes() const { return [EditMode.Vertices]; }

    override Param[] params() {
        return [Param.float_("inset", "Inset", &inset_, 0.0f)];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    final PreparedVertexBevelActivationImage buildPreparedActivation(
            out Mesh* source) {
        PreparedVertexBevelActivationImage image;
        source = mesh; if (source is null) return image;
        image.before = MeshSnapshot.capture(*source); image.valid = true;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.insetAxis = insetAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*source, image); return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedVertexBevelActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragPart = -1; inset_ = 0.0f;
        image.before.moveInto(before);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; insetAxis = image.insetAxis;
        gizmoSelHash = image.gizmoSelHash; image.clear();
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.VertexBevel, false);
        scope(failure) context.discard();
        auto owner = PreparedVertexBevelActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareVertexBevelActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.VertexBevel, ok);
    }

    private void reinitSession() {
        built    = false;
        dragPart = -1;
        inset_   = 0.0f;
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built && inset_ != 0.0f)
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built && inset_ != 0.0f;
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
    private VertexBevelParamProjection paramProjection() const nothrow @nogc {
        return VertexBevelParamProjection(interactiveParamEdit, active, built,
            inset_);
    }
    final PreparedVertexBevelParamImage buildPreparedParamUpdate(ref Mesh live) {
        PreparedVertexBevelParamImage image;
        image.valid = true; image.expected = paramProjection();
        image.nextBuilt = built; image.expectedLive = MeshSnapshot.capture(live);
        if (!before.filled) return image;
        Mesh baseline;
        auto baselineShadow = beginPreparedShadow(baseline);
        before.restore(baseline);
        uint baselineFlags, baselineDomains;
        drainPreparedShadowDelivery(baseline, baselineFlags, baselineDomains);
        baselineShadow.close();
        image.expectedBefore = MeshSnapshot.capture(baseline);
        if (!interactiveParamEdit || !active) return image;
        image.applies = true; image.candidate = baseline; baseline = Mesh.init;
        auto shadow = beginPreparedShadow(image.candidate);
        if (inset_ == 0.0f) {
            image.nextBuilt = false;
        } else {
            auto mask = image.candidate.operandVertexMask(EditMode.Vertices);
            auto ed = MeshEditBatch.unrecorded(image.candidate,
                kBevelVertexEditScope);
            const n = ed.bevelVerticesByMask(mask, inset_);
            ed.close(); image.nextBuilt = (n != 0);
        }
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        if (image.deliveryFlags == 0) {
            image.deliveryFlags = baselineFlags;
            image.deliveryDomains = baselineDomains;
        }
        shadow.close(); return image;
    }
    final bool preparedParamUpdateMatches(
            in PreparedVertexBevelParamImage image, ref const Mesh live) const
            nothrow @nogc {
        return image.valid && image.expected == paramProjection() &&
            image.expectedLive.matches(live) &&
            image.expectedBefore.matches(before);
    }
    final void installPreparedParamUpdate(
            ref PreparedVertexBevelParamImage image) nothrow @nogc {
        if (!image.valid) return;
        built = image.nextBuilt; image.clear();
    }
    final PreparedVertexBevelParamEffect prepareParamChanged(
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedVertexBevelParamEffect(
            preparedToolStateOwner, PreparedVertexBevelParamKind.None, false);
        scope(failure) context.discard();
        auto owner = PreparedVertexBevelParamUpdateOwner.prepare(this, layer);
        auto kind = owner is null ? PreparedVertexBevelParamKind.None :
            owner.effectKind;
        bool ok = owner !is null;
        if (ok && owner.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains);
        if (ok) ok = context.prepareVertexBevelParamUpdate(owner);
        if (ok && owner.applies)
            ok = context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedVertexBevelParamEffect(preparedToolStateOwner, kind, ok);
    }
    override void evaluate() {}

    // Headless apply (tool.doApply) — the Post-Mode path a panel numeric
    // edit + Apply button drives. MUST NOT snapshot — ToolDoApplyCommand
    // wraps it with undo.
    override bool applyHeadless() {
        if (*editMode != EditMode.Vertices) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.vertices.length == 0) return false;
        if (inset_ == 0.0f) return true;
        auto mask = currentMask();
        // Task 1903 Stage E4 — the batch opens at the TOOL boundary, for the
        // same reason the command's does. UNRECORDED (plan §9): this tool
        // commits through a whole-mesh `MeshSnapshot` pair, so a recording
        // batch would build an op-log nothing reads. Stage M owns the tool
        // pair-holders.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kBevelVertexEditScope);
            n = ed.bevelVerticesByMask(mask, inset_);
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
        if (*editMode != EditMode.Vertices) return false;
        if (!gizmoValid) return false;

        int hmx, hmy;
        queryMouse(hmx, hmy);
        int part = toolHandles.test(hmx, hmy, cachedVp);

        dragLastMX    = e.x; dragLastMY = e.y;
        dragBaseInset = inset_;

        if (part == PART_INSET) {
            dragPart = PART_INSET;
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
        // The previous pixel comes from the cooked gesture, not from this
        // tool's own pair — same integer subtraction, sourced one level up.
        // `dragLastMX/MY` stay written as the fallback when no gesture is
        // published and as the other half of the debug agreement check.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         dragLastMX, dragLastMY, prevMX, prevMY);
        bool skip;
        // Projected in the space the arm is DRAWN in, and converted back into
        // the LOCAL length the kernel means (task 0645) — one OverlayAxis in
        // both roles, so the arm the pixels are dotted against is the arm on
        // screen and the geometry follows it.
        const auto os = OverlaySpace.ofPrimary();
        const auto ax = os.axis(insetAxis);
        Vec3 delta = screenAxisDelta(e.x, e.y, prevMX, prevMY,
                                     os.pos(anchor), ax.dir, cachedVp, skip);
        if (!skip) {
            float d = ax.toLocal(dot(delta, ax.dir));
            // No clamp to >=0: the captured law says BOTH inset==0 AND
            // inset<0 are no-ops (mesh_ops.bevel_vertex.bevelVerticesByMask already guards
            // `amount < 1e-6f`), so a drag that crosses zero just yields a
            // cleared preview rather than needing to be pinned at zero.
            inset_ = dragBaseInset + d;
            rebuildPreview();
        }
        dragLastMX = e.x;
        dragLastMY = e.y;
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
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Vertices) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor;   // LOCAL, like the kernel

        // ONE overlay space for the pass (task 0645): the arm is positioned in
        // it and `toolHandles.update` below hit-tests this same object, so
        // drawing and hitting cannot land in different spaces.
        const auto os      = OverlaySpace.ofPrimary();
        const auto ax      = os.axis(insetAxis);
        const Vec3 anchorW = os.pos(anchor);

        float armLen = gizmoSize(anchorW, vp, 1.0f);
        insetArrow.start = anchorW + ax.dir * (armLen / 6.0f);
        insetArrow.end   = anchorW + ax.dir * armLen;
        insetArrow.color = INSET_COLOR;

        toolHandles.begin();
        toolHandles.add(insetArrow, PART_INSET);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        insetArrow.draw(shader, vp);
    }

private:
    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandVertexMask(EditMode.Vertices);
    }

    // Anchor = selection centroid; insetAxis = averaged normal of faces
    // incident to the selected vertices (mirrors EdgeBevelTool's
    // width-axis derivation, one level down the element hierarchy).
    void computeGizmoFrame() {
        PreparedVertexBevelActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.insetAxis = insetAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*mesh, image);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; insetAxis = image.insetAxis;
        gizmoSelHash = image.gizmoSelHash;
    }

    private static void computePreparedGizmoFrame(ref Mesh source,
            ref PreparedVertexBevelActivationImage image) {
        image.gizmoValid = false;
        if (source.vertices.length == 0) return;
        bool any = source.hasAnySelectedVertices();
        Vec3 sum = Vec3(0, 0, 0);
        foreach (vi; 0 .. source.vertices.length) {
            if (any && !source.isVertexSelected(vi)) continue;
            foreach (fi; source.facesAroundVertex(cast(uint)vi))
                sum = sum + source.faceNormal(cast(uint)fi);
        }
        image.anchor = source.selectionCentroidVertices();
        float len = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        image.insetAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        image.baseAnchor = image.anchor;
        image.gizmoSelHash = source.selectionSignature(EditMode.Vertices);
        image.gizmoValid = true;
    }

    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        if (inset_ == 0.0f) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        // Task 1903 Stage E4 — one UNRECORDED batch per DRAG FRAME, and
        // unrecorded is not a convenience here: plan §9 is explicit that a
        // recording batch opened per frame would build and throw away a full
        // op-log at 60 Hz. This tool is one of the 16 that keep the plain
        // `before.restore(*mesh)` preview shape rather than
        // `tools/edit/preview_rebuild.d`, so the batch is on the LIVE mesh and
        // the frame's deferred stamp lands at `close()` — one per frame
        // instead of one per split vertex. That is the STAMP; DELIVERIES are
        // a separate count, measured at the E4 review over the 16-frame drag
        // in tests/test_vertex_bevel_handle_drag.d: 4 per frame, down from 10
        // — `before.restore` is 1 and the chamfer inside the batch is 3 (was
        // 9), selection-domain deliveries the batch does not defer. Nothing
        // pins the residual 3; do not read "one per frame" as a delivery.
        size_t n;
        {
            auto ed = MeshEditBatch.unrecorded(*mesh, kBevelVertexEditScope);
            n = ed.bevelVerticesByMask(mask, inset_);
            ed.close();
        }
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext c) {
        bool ok; if (active && built && inset_ != 0 && c !is null && history !is null && gestureFactory !is null && before.filled) { auto cmd=cast(MeshSessionEdit)gestureFactory(); if(cmd !is null){cmd.setSnapshots(before,MeshSnapshot.capture(*mesh),"Vertex Bevel");ok=c.prepare(cmd,PreparedHistoryKind.Plain).accepted;}}
        return PreparedDeactivateEffect(preparedToolStateOwner,PreparedDeactivateKind.VertexBevel,ok);
    }
    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Vertex Bevel");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragPart = -1;
        toolHandles.clearHaul();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }

public:
    version(unittest) final void seedPreparedParamForTest(ref Mesh live,
            bool interactive = true, float inset = 0.2f) {
        interactiveParamEdit = interactive; active = true; built = false;
        inset_ = inset; before = MeshSnapshot.capture(live);
    }
    version(unittest) final void mutatePreparedParamForTest(float value)
            nothrow @nogc { inset_ = value; }
    version(unittest) final bool preparedParamBuiltForTest() const nothrow @nogc {
        return built;
    }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest(ref Mesh oldMesh) {
        active = false; built = true; dragPart = 9; inset_ = 7;
        gizmoValid = false; anchor = Vec3(1,2,3); baseAnchor = Vec3(4,5,6);
        insetAxis = Vec3(7,8,9); gizmoSelHash = 10;
        dragLastMX = 11; dragLastMY = 12; dragBaseInset = 13;
        cachedVp.view[0] = 14; before = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const
            nothrow @nogc {
        return !active && built && dragPart == 9 && inset_ == 7 && !gizmoValid &&
            anchor == Vec3(1,2,3) && baseAnchor == Vec3(4,5,6) &&
            insetAxis == Vec3(7,8,9) && gizmoSelHash == 10 &&
            dragLastMX == 11 && dragLastMY == 12 && dragBaseInset == 13 &&
            cachedVp.view[0] == 14;
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr, bool expectedValid,
            Vec3 expectedAnchor, Vec3 expectedBase, Vec3 expectedAxis,
            ulong expectedHash) const nothrow @nogc {
        return active && !built && dragPart == -1 && inset_ == 0 && before.filled &&
            before.vertices.length == count &&
            (count == 0 || (before.vertices[0] == first && before.vertices.ptr !is livePtr)) &&
            gizmoValid == expectedValid && anchor == expectedAnchor &&
            baseAnchor == expectedBase && insetAxis == expectedAxis &&
            gizmoSelHash == expectedHash && dragLastMX == 11 && dragLastMY == 12 &&
            dragBaseInset == 13 && cachedVp.view[0] == 14;
    }
    version(unittest) final PreparedVertexBevelActivationImage
            preparedFrameForTest(ref Mesh source) const {
        PreparedVertexBevelActivationImage image;
        image.before = MeshSnapshot.capture(source);
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.insetAxis = insetAxis;
        image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(source, image); return image;
    }
}
