module tools.alignment.mirror;
import display_state : DrawPlan;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import std.math : PI;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import params : Param, IntEnumEntry;
import command : Command, CmdFlags;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import editmode : EditMode;
import shader : Shader, LitShader;
import handler : MoveHandler, ToolHandles, Arrow, BoxHandler, gizmoSize, drawThickLinesExt;
import drag : planeDragDelta, screenAxisDelta, gesturePrevPixel;
import eventlog : queryMouse;
import prepared_tool_effect : PreparedToolStateDelta, PreparedToolStateKind,
    PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolParamDoorClient;
import prepared_mirror_activation : PreparedMirrorActivationOwner,
    PreparedMirrorDeactivateOwner;
import document : Layer, primaryModelSpace;
import command_history : PreparedHistoryKind;
import display_sync : refreshDisplay;

version (unittest) import std.conv : to;
private struct MirrorPreparedState {
    bool engaged; bool consumable;
    @disable this(this);
}

struct PreparedMirrorActivationImage {
    bool valid;
    MeshSnapshot baseline;
    bool[] mask;
    MirrorParams params;
    Vec3 left, up;
    void clear() nothrow @nogc {
        valid = false; baseline = MeshSnapshot.init; mask = null;
        params = MirrorParams.init;
        left = up = Vec3.init;
    }
}

struct PreparedMirrorDeactivateImage {
    bool valid;
    bool expectedEngaged, expectedPreviewCache;
    void clear() nothrow @nogc { this = PreparedMirrorDeactivateImage.init; }
}

// ---------------------------------------------------------------------------
// rebuildMirrorPreview — the non-cumulative mirror recompute. Since task 7116
// its target is the DOCUMENT mesh while the tool is engaged (the copy is a
// live edit from the first viewport press, measured law §24); a module
// unittest still drives it against a plain `Mesh`.
//
// `baseSnap.restore(target)` fully overwrites `target` with the pristine base
// EVERY call — the guarantee that N successive calls never accumulate N
// mirrors (`Mesh.mirrorFacesPlane` APPENDS).
//
// The plane (`params_.center`, `toolNormal`) is WORLD-space (gap 190); `space`
// carries it into the mesh's local frame, and the weld distance (a world
// length) is divided by the item's scale. Exact for a similarity item
// transform; under a non-uniform scale the reflection is about the carried
// plane and the weld uses the X-axis scale — a recorded divergence (gap 333).
// ---------------------------------------------------------------------------
size_t rebuildMirrorPreview(const ref MeshSnapshot baseSnap, ref Mesh target,
                            in bool[] baseMask, in MirrorParams params_,
                            in ModelSpace space = ModelSpace.world())
{
    baseSnap.restore(target);
    return mirrorInPlace(target, baseMask, params_, space);
}

/// One mirror of `mask` about the WORLD plane of `params_`, appended to
/// `target` in its own local frame `space`. The one kernel call shared by the
/// live edit and the headless apply.
size_t mirrorInPlace(ref Mesh target, in bool[] mask, in MirrorParams params_,
                     in ModelSpace space)
{
    // World length -> local length: the local image of a world unit vector.
    float weld = params_.mergeVerts
        ? params_.distance * space.toLocalDir(Vec3(1, 0, 0)).length : 0.0f;
    size_t inserted = target.mirrorFacesPlane(mask,
        space.toLocalPoint(params_.center),
        space.toLocalNormal(toolNormal(params_)), weld, params_.invertPolys);
    if (inserted > 0) target.buildLoops();
    return inserted;
}

// ---------------------------------------------------------------------------
// MirrorParams — single source of truth for the Mirror tool (mirrors
// BoxParams, box.d:46). Every handle drag and every panel edit writes into
// this struct; render + handle position + commit derive from it on demand.
//
// v2 (task 0230): the mirror plane is ORIENTED (arbitrary normal), not just
// axis-aligned. `axis` + `angle` together are the single source of truth for
// the plane normal — see `toolNormal(in MirrorParams)` below, a PURE function
// of this struct (NOT a tool-cached field: the free preview path
// `rebuildMirrorPreview` has no MirrorTool instance to read a cached normal
// from). The rotate box (M4) writes ONLY `angle`; `Axis` presets (X/Y/Z) set
// the base direction `angle` rotates away from. `left`/`up` are DERIVED
// readouts (an orthonormal basis of the current normal) recomputed in
// `evaluate()` — read-only in v2 (owner decision (d): editable Left/Up would
// need a 3rd rotate input path, deferred).
//
// `distance`/`mergeVerts`/`invertPolys` are unchanged from v1.
// `mode` stays greyed to Axis (Free-Rotation/Three-Points deferred).
// ---------------------------------------------------------------------------
struct MirrorParams {
    int   axis        = 0;            // 0=X 1=Y 2=Z — base direction `angle` rotates away from
    Vec3  center       = Vec3(0, 0, 0);
    bool  invertPolys  = true;         // -> mirrorFaces flipNormals
    bool  mergeVerts   = true;         // gates the weld pass
    float distance     = 0.001f;       // -> mirrorFaces weld (only when mergeVerts)
    // --- live as of v2 (task 0230): angle drives the rotate box + toolNormal ---
    // Default 180 is the captured reference default (0227 design). Harmless
    // for the mirror OPERATION regardless of value: reflection is invariant
    // under negating the plane normal (v - n*(2*dot(v-c,n)) is unchanged by
    // n -> -n, since both the dot term and the outer factor flip sign), and
    // rotating a fixed axis by exactly 180 degrees about any perpendicular
    // reference axis just negates it — so the DEFAULT axis-aligned geometry
    // is byte-for-byte the same as if angle were 0.
    float angle = 180.0f;
    int   mode  = 0;                   // 0=Axis (only value live; Free-Rotation/Three-Points deferred)
    // --- derived readouts (written by evaluate(), read-only in the panel) ---
    Vec3  left  = Vec3(0, 0, 0);
    Vec3  up    = Vec3(0, 0, 0);
}

// ---------------------------------------------------------------------------
// unitAxis / refAxis / toolNormal — the oriented-plane normal, a PURE
// function of MirrorParams (task 0230, opponent objection #2). No tool field
// caches this; every call site (preview, commit, headless, handle draw)
// recomputes it from `params_` directly.
// ---------------------------------------------------------------------------

/// The Axis preset's base unit direction (before any rotate-box tilt).
Vec3 unitAxis(int axis) pure nothrow @nogc @safe {
    final switch (axis) {
        case 0: return Vec3(1, 0, 0);
        case 1: return Vec3(0, 1, 0);
        case 2: return Vec3(0, 0, 1);
    }
}

/// The FIXED in-plane reference axis the rotate-box single-DOF drag turns
/// `angle` about — perpendicular to `unitAxis(axis)`, constant for the whole
/// gesture (does NOT retarget off the live tilting normal: recomputing it
/// from the current normal mid-drag would reintroduce the documented
/// mid-drag basis-flip/oscillation family from the transform-tool handles).
/// Convention (task 0230 spec): base X -> ref Z; base Y -> ref X; base Z ->
/// ref X. Any fixed, per-axis-perpendicular choice works — this one just
/// needs to stay consistent between draw() and the drag handler.
Vec3 refAxis(int axis) pure nothrow @nogc @safe {
    final switch (axis) {
        case 0: return Vec3(0, 0, 1);   // base X -> ref Z
        case 1: return Vec3(1, 0, 0);   // base Y -> ref X
        case 2: return Vec3(1, 0, 0);   // base Z -> ref X
    }
}

/// The live mirror-plane normal: `R(angle, refAxis(axis)) * unitAxis(axis)`.
/// Single-DOF Axis-mode rotation (task 0230 design §Risk 3) — recommended
/// over a full free-rotation basis since there is no geometry golden to pin
/// the drag->angle transfer (a UX-mapping divergence, not a mesh-geometry
/// one: the reflection itself is deterministic given center+normal).
Vec3 toolNormal(in MirrorParams p) {
    float rad = p.angle * (PI / 180.0f);
    auto  R   = pivotRotationMatrix(Vec3(0, 0, 0), refAxis(p.axis), rad);
    return normalize(transformPoint(R, unitAxis(p.axis)));
}

/// Derived Up/Left readouts (task 0230 M5, owner decision (d): read-only in
/// v2) — an orthonormal basis of the current normal, built from the same
/// fixed `refAxis` the rotate box turns about so the panel's Left/Up track
/// the live plane without a separate stored basis.
Vec3 derivedUp(in MirrorParams p) pure nothrow @nogc @safe { return refAxis(p.axis); }
Vec3 derivedLeft(in MirrorParams p) {
    return normalize(cross(derivedUp(p), toolNormal(p)));
}

// ---------------------------------------------------------------------------
// MirrorTool — interactive tool wrapping Mesh.mirrorFacesPlane (source/mesh.d,
// task 0230). Since task 7116 it is an ordinary live edit of the DOCUMENT mesh
// (the CloneTool shape): nothing is evaluated until the first viewport press;
// from then on every change restores `baseSnap` and mirrors again, drawn by
// the ordinary mesh path; the drop commits base -> current as one step.
//
// v2 (task 0230) = ORIENTED plane (Axis + Angle + Center all live; Left/Up
// derived readouts; Mode greyed to Axis). Two box handles: `mover.centerBox`
// (enlarged — "large box": click-to-place + drag-move the plane center) and
// `rotateBox` (small — drags `angle`, tilting the plane about the fixed
// `refAxis(axis)`), plus a wire-quad + dashed-axis plane visualization.
// ---------------------------------------------------------------------------
class MirrorTool : Tool, PreparedToolDoorClient,
        PreparedToolParamDoorClient {
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
    @property Mesh* mesh() const nothrow @nogc { return meshSrc_(); }
    GpuMesh*  gpu;
    LitShader litShader;

    // params_ is the single source of truth for the mirror plane + options.
    MirrorParams params_;

    // Base state captured at activate() — the pristine mesh + face mask the
    // live edit mirrors from. Mask rule matches the mesh.mirror command:
    // empty face selection ⇒ whole mesh.
    MeshSnapshot baseSnap;
    bool[]       baseMask;

    // Dirty guard (fold #3): property_panel.d calls evaluate() every frame
    // the panel is open, and evaluate() is also called on every handle-drag
    // motion event — without this cache a full snapshot-restore +
    // mirrorFaces + buildLoops + display refresh would run every such call
    // even when nothing changed. Caches the last-evaluated param snapshot;
    // evaluate() early-returns when unchanged.
    bool  havePreviewCache;
    int   cachedAxis;
    Vec3  cachedCenter;
    bool  cachedInvert;
    bool  cachedMerge;
    float cachedDistance;
    float cachedAngle;   // task 0230 M2: normal is derived from axis+angle —
                         // an angle-only edit (rotate-box drag) must also
                         // invalidate the cache, or the preview silently
                         // no-ops on orientation changes.

    // Set ONLY by the first viewport press (either branch of
    // onMouseButtonDown) — a panel/attr write before it only stores the
    // value (capture C3-m s1-s2). Prevents a mirror when the tool
    // is picked and dropped untouched.
    bool engaged;
    // The document mesh currently holds the live copy (a restore from
    // `baseSnap` is owed on cancel, a commit on drop). A flag, not a version
    // key: the identity question is "did WE write it", nothing else.
    bool liveApplied;

    // ----- Center handle (M2) — reuse MoveHandler exactly as BoxTool does
    // (box.d:1857/1896), with the three plane-corner circles AND the three
    // axis arrows hidden (task 0233: reference gizmo is 2 boxes + plane, no
    // arrows) so only the center box remains from MoveHandler. Center MOVE is
    // driven by dragging that (enlarged) center box (planeDragDelta), not the
    // arrows. `mover.centerBoxScale` (handler.d) enlarges it into the
    // reference's "large box"; `mover.arrowsVisible=false` drops the arrows.
    MoveHandler mover;
    // ----- Rotate box (M4) — small BoxHandler, world position derived each
    // frame from `center + toolNormal(params_) * rotateArm(...)`; dragging it
    // writes `params_.angle` only (see onMouseMotion).
    BoxHandler  rotateBox;
    ToolHandles toolHandles;
    int      moverDragAxis = -1;  // 0/1/2 = X/Y/Z arrow, 3 = centerBox, 4 = rotateBox, -1 = none
    int      moverLastMX, moverLastMY;
    Viewport cachedVp;

    // ----- Plane visualization (M4) — a wire quad ⟂ normal + a dashed line
    // along the normal through center, both rebuilt (world-space vertex data
    // re-uploaded) every draw() call — mirrors MoveTool's constraintLineVao
    // pattern (`constraintLineVao` in tools/transform/move.d): lazy VAO init,
    // GL_DYNAMIC_DRAW update.
    GLuint planeQuadVao, planeQuadVbo;
    GLuint axisLineVao,  axisLineVbo;

public:
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0, 0, 0));
        mover.planesVisible = false;
        // Task 0233: drop the X/Y/Z axis arrows entirely — the reference
        // Mirror gizmo is 2 boxes + a plane, no arrows. Center MOVE stays on
        // the (enlarged) center box drag (planeDragDelta). arrowsVisible=false
        // hides them from draw AND hit-test (see MoveHandler.arrowsVisible).
        mover.arrowsVisible = false;
        mover.centerBoxScale = 2.4f;   // "large box" — reads distinctly bigger than rotateBox
        rotateBox = new BoxHandler(Vec3(0, 0, 0), Vec3(0.95f, 0.55f, 0.05f));
        toolHandles = new ToolHandles();
    }

    void destroy() {
        mover.destroy();
        rotateBox.destroy();
        if (planeQuadVao != 0) { glDeleteVertexArrays(1, &planeQuadVao); glDeleteBuffers(1, &planeQuadVbo); }
        if (axisLineVao  != 0) { glDeleteVertexArrays(1, &axisLineVao);  glDeleteBuffers(1, &axisLineVbo); }
    }

    override string name() const { return "Mirror"; }

    override int previewHotPart() const nothrow @nogc {
        return toolHandles.hot;
    }

    override void activate() {
        baseSnap = MeshSnapshot.capture(*mesh);
        baseMask = buildMaskFromSelection();
        engaged  = false;
        liveApplied = false;
        moverDragAxis = -1;
        toolHandles.clearHaul();
        havePreviewCache = false;
        updateReadouts();
    }

    final PreparedMirrorActivationImage buildPreparedActivation(out Mesh* source) {
        PreparedMirrorActivationImage image;
        if (meshSrc_ is null) return image;
        source = meshSrc_();
        if (source is null) return image;
        image.baseline = MeshSnapshot.capture(*source);
        image.mask = source.operandFaceMask();
        image.params = params_;
        image.left = derivedLeft(image.params);
        image.up = derivedUp(image.params);
        image.valid = true;
        return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc {
        return meshSrc_ is null ? null : meshSrc_();
    }
    final bool preparedActivationParamsMatch(in MirrorParams expected) const
            nothrow @nogc {
        return params_.axis == expected.axis && params_.center == expected.center &&
            params_.invertPolys == expected.invertPolys &&
            params_.mergeVerts == expected.mergeVerts &&
            params_.distance == expected.distance && params_.angle == expected.angle &&
            params_.mode == expected.mode && params_.left == expected.left &&
            params_.up == expected.up;
    }
    final void installPreparedActivation(ref PreparedMirrorActivationImage image)
            nothrow @nogc {
        image.baseline.moveInto(baseSnap);
        baseMask = image.mask; image.mask = null;
        params_.left = image.left; params_.up = image.up;
        engaged = false; liveApplied = false;
        moverDragAxis = -1; toolHandles.clearHaul();
        havePreviewCache = false; image.valid = false;
    }
    final PreparedSessionActivateEffect prepareActivate(PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.Mirror, false);
        scope(failure) context.discard();
        auto stateOwner = PreparedMirrorActivationOwner.prepare(this);
        bool ok = stateOwner !is null && context.prepareMirrorActivation(stateOwner);
        ok = ok && context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.Mirror, ok);
    }
    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        return prepareActivate(context).accepted;
    }

    version(unittest) final void seedPreparedActivationForTest() {
        baseMask = [true, false]; engaged = true; liveApplied = true;
        moverDragAxis = 4; havePreviewCache = true; cachedAxis = 99;
        cachedDistance = -1;
    }
    version(unittest) final void setPreparedAxisForTest(int value) nothrow @nogc {
        params_.axis = value;
    }
    version(unittest) final bool preparedActivationInstalledForTest() const {
        return baseSnap.filled && baseMask.length > 0 && !engaged &&
            !liveApplied && moverDragAxis == -1 && !havePreviewCache &&
            params_.left == derivedLeft(params_) && params_.up == derivedUp(params_);
    }
    version(unittest) final size_t preparedMaskSelectedForTest() const nothrow @nogc {
        size_t result;
        foreach (selected; baseMask) if (selected) ++result;
        return result;
    }

    final PreparedMirrorDeactivateImage buildPreparedDeactivateState()
            const nothrow @nogc {
        return PreparedMirrorDeactivateImage(true, engaged, havePreviewCache);
    }
    final bool preparedDeactivateStateMatches(
            in PreparedMirrorDeactivateImage image) const nothrow @nogc {
        return image.valid && engaged == image.expectedEngaged &&
            havePreviewCache == image.expectedPreviewCache;
    }
    final void installPreparedDeactivateState(
            ref PreparedMirrorDeactivateImage image) nothrow @nogc {
        engaged = false; liveApplied = false; havePreviewCache = false;
        image.clear();
    }
    version(unittest) final void seedPreparedDeactivateStateForTest()
            nothrow @nogc {
        engaged = true; havePreviewCache = true;
    }
    /// A live edit as the first press leaves it: base captured from the
    /// CURRENT mesh, engaged, the copy owed. The caller then writes the copy
    /// into the mesh itself (no display in a unit test).
    version(unittest) final void seedLiveEditForTest() {
        baseSnap = MeshSnapshot.capture(*mesh);
        baseMask = buildMaskFromSelection();
        engaged = true; liveApplied = true; havePreviewCache = true;
    }
    version(unittest) final bool preparedDeactivateStateInstalledForTest()
            const nothrow @nogc {
        return !engaged && !liveApplied && !havePreviewCache;
    }
    version(unittest) final void installPreparedDeactivateStateForTest()
            nothrow @nogc {
        engaged = false;
    }
    // The drop commits what the live edit already wrote (the CloneTool
    // shape): base -> current mesh, no second mirror, no mesh image, no
    // upload — the ordinary display path uploaded the copy at the press.
    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context,
            Layer layer) {
        if (context is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.Mirror, false, false);
        scope(failure) context.discard();
        auto stateOwner = PreparedMirrorDeactivateOwner.prepare(this);
        bool ok = stateOwner !is null && layer !is null &&
            &layer.meshRef() is mesh;
        bool historyPrepared;
        if (ok && engaged && liveApplied && history !is null &&
                gestureFactory !is null) {
            auto cmd = cast(MeshSessionEdit)gestureFactory();
            if (cmd !is null) {
                cmd.setSnapshots(baseSnap, MeshSnapshot.capture(*mesh), "Mirror");
                historyPrepared = context.prepare(cmd,
                    PreparedHistoryKind.Plain).accepted;
                ok = historyPrepared;
            } else ok = context.prepareGestureCarrierMismatch();
        }
        if (ok) ok = historyPrepared ? context.markHistoryInstall()
                                     : context.markNoHistoryInstall();
        if (ok) ok = context.prepareMirrorDeactivate(stateOwner);
        if (!ok) context.discard();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Mirror, historyPrepared, ok);
    }
    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer layer,
            ulong, ulong) {
        return prepareDeactivate(context, layer).resourceAccepted;
    }

    override void deactivate() {
        if (engaged && liveApplied) commitMirrorEdit(baseSnap);
        engaged = false;
        liveApplied = false;
        havePreviewCache = false;
    }

    // ----- History-coordination hooks (mirror BoxTool's, box.d:1963-1988) --

    public override bool hasUncommittedEdit() const {
        return engaged && liveApplied;
    }

    // The first Ctrl+Z drops the live copy and keeps the tool armed (owner's
    // law, CLAUDE.md "Undo / redo"); the next press starts a fresh live edit
    // from the same base. The shared cancel-then-drop default is opted out of
    // by the policy datum `keepAliveOnCancel`, as the create family does
    // (slice M4 moved it off the former capability interface).
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = { keepAliveOnCancel: true };
        return policy;
    }

    public override void cancelUncommittedEdit() {
        if (liveApplied) {
            baseSnap.restore(*mesh);
            refreshDisplay(mesh, gpu);
        }
        engaged = false;
        liveApplied = false;
        havePreviewCache = false;
    }

    // External undo/redo moved geometry beneath the tool — re-base against
    // the current mesh; nothing is evaluated until the next press.
    public override void resyncSession() {
        baseSnap = MeshSnapshot.capture(*mesh);
        baseMask = buildMaskFromSelection();
        engaged = false;
        liveApplied = false;
        havePreviewCache = false;
    }

    // ----- Mask (fold #4: interactive commit + applyHeadless must build the
    // SAME mask from LIVE mesh.selectedFaces — empty ⇒ all faces. Identical
    // rule to commands/mesh/mirror.d:74-84.) -------------------------------

    private bool[] buildMaskFromSelection() const {
        // L1 funnel (task 0613, S5): selected faces, else every VISIBLE face.
        return mesh.operandFaceMask();
    }

    // Records through the base seam (task 1905 phase C, group G2). The
    // trigger is NOT moved: this body is still reached from `deactivate()`,
    // which is why the cell's `liveEntryNames` is empty and its `entryNames`
    // only fills at the drop. The edit it closes lives in the
    // DOCUMENT mesh from the first press, so both change-bus channels see the
    // drag — see `tests/test_tool_gesture_g2.d`.
    private void commitMirrorEdit(MeshSnapshot pre) {
        if (history is null || gestureFactory is null) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Mirror");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    // ----- Params / panel (§1.2-1.3 of the impl plan) -----------------------

    override Param[] params() {
        return [
            Param.intEnum_("axis", "Axis", cast(int*)&params_.axis,
                [IntEnumEntry(0, "X", "X"),
                 IntEnumEntry(1, "Y", "Y"),
                 IntEnumEntry(2, "Z", "Z")],
                0),
            Param.vec3_("center", "Center", &params_.center, Vec3(0, 0, 0)),
            Param.bool_("invertPolys", "Invert Polygons", &params_.invertPolys, true),
            Param.bool_("mergeVerts", "Merge Vertices", &params_.mergeVerts, true),
            Param.float_("distance", "Distance", &params_.distance, 0.001f).min(0.0f),
            // --- live as of v2 (task 0230): angle drives the rotate box + toolNormal ---
            Param.float_("angle", "Angle", &params_.angle, 180.0f).angle(),
            // Mode stays greyed to Axis — Free-Rotation/Three-Points deferred.
            Param.intEnum_("mode", "Mode", cast(int*)&params_.mode,
                [IntEnumEntry(0, "axis", "Axis")], 0),
            // Left/Up are DERIVED readouts (written in evaluate()) — read-only
            // in v2 (owner decision (d)): editing them would need a 3rd rotate
            // input path on top of the rotate box's single `angle` DOF.
            Param.vec3_("left", "Left", &params_.left, Vec3(0, 0, 0)).readonly(),
            Param.vec3_("up", "Up", &params_.up, Vec3(0, 0, 0)).readonly(),
        ];
    }

    override bool paramEnabled(string name) const {
        // Mode stays greyed to Axis-only (Free-Rotation/Three-Points deferred).
        if (name == "mode") return false;
        // Distance only matters when merge is on.
        if (name == "distance") return params_.mergeVerts;
        return true;
    }

    override void onParamChanged(string name) {
        auto prepared = prepareParamState(name);
        MirrorPreparedState handle;
        if (validatePreparedState(prepared, handle)) installLegacyPreparedState(handle);
    }

    override bool prepareDoorParamChanged(string name, PreparedRecordContext,
            Layer, ulong, ulong) {
        auto prepared = prepareParamState(name);
        MirrorPreparedState handle;
        if (!validatePreparedState(prepared, handle)) return false;
        installLegacyPreparedState(handle);
        return true;
    }

private:
    PreparedToolStateDelta prepareParamState(string) const nothrow @nogc {
        return PreparedToolStateDelta.boolean(preparedToolStateOwner, true);
    }
    bool validatePreparedState(ref PreparedToolStateDelta prepared,
                               out MirrorPreparedState handle) nothrow @nogc {
        if (prepared.owner != preparedToolStateOwner ||
            prepared.kind != PreparedToolStateKind.Bool) return false;
        handle = MirrorPreparedState(prepared.boolValue, true);
        return true;
    }
    // A parameter write never engages: before the first press
    // the value is only stored; after it, the live copy is owed a rebuild,
    // which the attr path's own evaluate() then performs.
    void installLegacyPreparedState(ref MirrorPreparedState handle) nothrow @nogc {
        if (!handle.consumable) return;
        handle.consumable = false;
        if (engaged) havePreviewCache = false;
    }
public:

    // ----- Headless one-shot (fold #4: builds its OWN mask from the live
    // mesh — ToolHeadlessCommand never calls activate(), so baseMask/baseSnap
    // are never populated on that throwaway instance). ----------------------

    // Refused while a live edit is on the mesh ("the tool is already
    // interactive", capture C3-m s4): the refusal reaches `tool.doApply` as
    // status:error with no record.
    override bool applyHeadless() {
        if (engaged && liveApplied) return false;
        if (mirrorInPlace(*mesh, buildMaskFromSelection(), params_,
                          primaryModelSpace()) == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    // ----- Live edit ---------------------------------------------------------
    //
    // Before the first press only the readouts move. Once engaged, re-apply
    // the copy to the DOCUMENT mesh after a parameter change or handle drag,
    // through the ordinary display refresh. Guarded (fold #3) so the panel's
    // per-frame call and every drag-motion call are cheap no-ops once the
    // params settle.
    override void evaluate() {
        if (!engaged) { updateReadouts(); return; }
        if (havePreviewCache
            && cachedAxis     == params_.axis
            && cachedCenter   == params_.center
            && cachedInvert   == params_.invertPolys
            && cachedMerge    == params_.mergeVerts
            && cachedDistance == params_.distance
            && cachedAngle    == params_.angle)
            return;

        liveApplied = rebuildMirrorPreview(baseSnap, *mesh, baseMask, params_,
                                           primaryModelSpace()) > 0;
        refreshDisplay(mesh, gpu);
        updateReadouts();

        cachedAxis       = params_.axis;
        cachedCenter     = params_.center;
        cachedInvert     = params_.invertPolys;
        cachedMerge      = params_.mergeVerts;
        cachedDistance   = params_.distance;
        cachedAngle      = params_.angle;
        havePreviewCache = true;
    }

    // Derived Left/Up readouts (task 0230 M5) — pure functions of axis+angle.
    private void updateReadouts() {
        params_.left = derivedLeft(params_);
        params_.up   = derivedUp(params_);
    }

    // ----- Center handle (M2) + plane draw (M3) -----------------------------

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        // `visualOnly` is the non-interactive replica draw in an inactive
        // Quad cell (tool.d:132 contract) — skip the cachedVp write and the
        // ToolHandles register/hit cycle there, but still draw the plane +
        // handles so they appear (reprojected) in every cell. The copy itself
        // is document geometry and draws with the mesh.
        if (!visualOnly) cachedVp = vp;

        mover.setPosition(params_.center);
        mover.setOrientation(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));

        // --- Rotate box + plane viz (M4) — derived every frame from
        // toolNormal(params_); computed regardless of `visualOnly` so the
        // plane/handle reprojects correctly in every Quad cell (tool.d:132
        // contract), matching the preview draw above.
        Vec3  curNormal = toolNormal(params_);
        float gs        = gizmoSize(params_.center, vp);
        float arm       = gs * 0.55f;
        rotateBox.pos  = params_.center + curNormal * arm;
        rotateBox.size = gs * 0.03f;

        drawPlaneViz(vp, params_.center, curNormal, gs, shader.program);
        rotateBox.draw(shader, vp);

        if (!visualOnly) {
            toolHandles.begin();
            // Task 0233: only the center box + rotate box are registered — the
            // axis arrows are gone (mover.arrowsVisible=false). moverDragAxis is
            // now only ever 3 (centerBox) or 4 (rotateBox).
            toolHandles.add(mover.centerBox, 13);
            toolHandles.add(rotateBox,       14);
            if (moverDragAxis >= 0)
                toolHandles.setHaul(moverDragAxis == 3 ? 13 : 14);
            else
                toolHandles.setHaul(-1);
            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);
        }

        mover.draw(shader, vp);
    }

    /// Wire quad ⟂ `normal` at `center` + a dashed line along `normal` through
    /// `center` — the mirror-plane visualization (task 0230 M4). Lazy VAO
    /// init + `GL_DYNAMIC_DRAW` re-upload every call, mirroring MoveTool's
    /// `constraintLineVao` pattern (tools/transform/move.d): the geometry (world
    /// positions) changes every frame the plane tilts or moves, so there is no
    /// static VAO to reuse — only the buffer OBJECT is cached.
    private void drawPlaneViz(const ref Viewport vp, Vec3 center, Vec3 normal, float gs,
                              GLuint restoreProgram) {
        immutable Vec3 planeColor = Vec3(0.85f, 0.25f, 0.85f);   // magenta, matches the reference viz

        // In-plane orthonormal basis (⟂ normal) — same construction as
        // handler.d's private `localFrame`, inlined here since that helper
        // isn't exported.
        Vec3 tmp = (normal.x < 0.9f && normal.x > -0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        Vec3 tA  = normalize(cross(normal, tmp));
        Vec3 tB  = cross(normal, tA);

        float qs = gs * 0.9f;
        Vec3 c0 = center + tA * qs + tB * qs;
        Vec3 c1 = center - tA * qs + tB * qs;
        Vec3 c2 = center - tA * qs - tB * qs;
        Vec3 c3 = center + tA * qs - tB * qs;
        float[12] quadData = [
            c0.x, c0.y, c0.z,  c1.x, c1.y, c1.z,
            c2.x, c2.y, c2.z,  c3.x, c3.y, c3.z,
        ];

        if (planeQuadVao == 0) {
            glGenVertexArrays(1, &planeQuadVao);
            glGenBuffers(1, &planeQuadVbo);
            glBindVertexArray(planeQuadVao);
            glBindBuffer(GL_ARRAY_BUFFER, planeQuadVbo);
            glBufferData(GL_ARRAY_BUFFER, quadData.sizeof, quadData.ptr, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glBindVertexArray(0);
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, planeQuadVbo);
            glBufferData(GL_ARRAY_BUFFER, quadData.sizeof, quadData.ptr, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
        }

        // Dashed axis/normal line through center, drawn as a series of short
        // GL_LINES segments (GL 3.3 core has no glLineStipple).
        float dashLen = qs * 0.10f;
        float gapLen  = qs * 0.07f;
        float axisLen = qs * 1.3f;
        float[] axisData;
        for (float t = -axisLen; t < axisLen; t += dashLen + gapLen) {
            float t1 = t + dashLen;
            if (t1 > axisLen) t1 = axisLen;
            Vec3 p0 = center + normal * t;
            Vec3 p1 = center + normal * t1;
            axisData ~= [p0.x, p0.y, p0.z, p1.x, p1.y, p1.z];
        }
        int axisVertCount = cast(int)(axisData.length / 3);

        if (axisLineVao == 0) {
            glGenVertexArrays(1, &axisLineVao);
            glGenBuffers(1, &axisLineVbo);
            glBindVertexArray(axisLineVao);
            glBindBuffer(GL_ARRAY_BUFFER, axisLineVbo);
            glBufferData(GL_ARRAY_BUFFER, axisData.length * float.sizeof, axisData.ptr, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glBindVertexArray(0);
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, axisLineVbo);
            glBufferData(GL_ARRAY_BUFFER, axisData.length * float.sizeof, axisData.ptr, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
        }

        glDisable(GL_DEPTH_TEST);
        // WINDOW PIXELS, both draws. Halved from 1.5f with task 0600's
        // extrusion-unit fix (see shader.thickLineVertexSrc); each still
        // renders the 0.75 px it always did.
        drawThickLinesExt(planeQuadVao, 4, GL_LINE_LOOP, identityMatrix, vp,
                          planeColor, 0.75f, restoreProgram);
        if (axisVertCount > 0)
            drawThickLinesExt(axisLineVao, axisVertCount, GL_LINES, identityMatrix, vp,
                              planeColor, 0.75f, restoreProgram);
        glEnable(GL_DEPTH_TEST);
    }

    // The untouched -> engaged transition: the base the live edit restores to
    // and the face mask it mirrors are taken from the mesh AS IT IS AT THE
    // PRESS, not at arm — a `tool.doApply` or a selection change between arm
    // and the first press must survive into the base.
    // No-op once engaged, so a drag's own steps never move the base.
    private void engage() {
        if (engaged) return;
        baseSnap = MeshSnapshot.capture(*mesh);
        baseMask = buildMaskFromSelection();
        liveApplied = false;
        engaged = true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera

        int hit = moverHitTest(e.x, e.y);
        if (hit < 0) {
            // Click-to-place (task 0230 M3): a viewport click that misses
            // every handle places the plane center under the cursor,
            // projected onto a SCREEN-FACING plane through the CURRENT
            // center — a fresh placement lands at the prior center's depth
            // regardless of the mirror plane's own tilt, mirroring the
            // transform tool's relocate feel. The upstream viewport-input
            // gate (app.d's onMouseButtonDown dispatch, which only reaches a
            // tool for genuine viewport clicks — not cell-widget/camera-chord
            // ones) already filters what gets here; no extra gate is added
            // (opponent objection #4: tools cannot call the nested
            // viewportInputAllowed() app.d helper directly).
            //
            // Behaviour change vs v1 (documented, task 0230 §Risk 4): a
            // no-handle click used to fall through to selection-clear; while
            // Mirror is active it now places the center instead.
            Vec3 origin, dir;
            screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, origin, dir);
            Vec3 planeN = cameraForwardDir(cachedVp);
            Vec3 hitPt;
            if (rayPlaneIntersect(origin, dir, params_.center, planeN, hitPt)) {
                params_.center = hitPt;
                engage();
                evaluate();
                return true;
            }
            return false;
        }
        // A press on a handle is also the first press: the copy appears now,
        // not at the first drag step (C3-m s3).
        moverDragAxis = hit;
        moverLastMX   = e.x;
        moverLastMY   = e.y;
        engage();
        evaluate();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (moverDragAxis < 0) return false;
        moverDragAxis = -1;
        toolHandles.clearHaul();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (moverDragAxis < 0) return false;

        // Both branches below are per-event increments, so both take their
        // previous pixel from the cooked gesture rather than from this tool's
        // own pair. `moverLastMX/MY` stay written: they are the fallback when
        // no gesture is published, and the other half of the debug agreement
        // check inside `gesturePrevPixel`.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         moverLastMX, moverLastMY, prevMX, prevMY);

        if (moverDragAxis == 4) {
            // Rotate box (M4): single-DOF drag along the tangent direction
            // `refAxis(axis) × currentNormal` — the direction the box itself
            // moves along as `angle` increases — converted to an angle delta
            // via arc length / radius (radius = the SAME `arm` used to place
            // the box in draw(), so the pixel/degree ratio matches what's
            // rendered). Reuses `screenAxisDelta` (drag.d) rather than a
            // bespoke projection, consistent with the center handle's reuse
            // of axisDragDelta/planeDragDelta.
            Vec3  curNormal = toolNormal(params_);
            Vec3  rAxis     = refAxis(params_.axis);
            Vec3  tangent   = normalize(cross(rAxis, curNormal));
            float arm       = gizmoSize(params_.center, cachedVp) * 0.55f;
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, prevMX, prevMY,
                                         rotateBox.pos, tangent, cachedVp, skip);
            if (!skip && arm > 1e-6f) {
                float d = dot(delta, tangent);   // signed world length along tangent
                params_.angle += (d / arm) * (180.0f / PI);
                engage();
                evaluate();
            }
            moverLastMX = e.x;
            moverLastMY = e.y;
            return true;
        }

        // Task 0233: with the axis arrows gone, the only remaining center
        // drag is the center box (moverDragAxis == 3) — always a planar drag.
        bool skip;
        Vec3 delta = planeDragDelta(e.x, e.y, prevMX, prevMY,
                                    moverDragAxis, mover.center, cachedVp, skip);
        if (!skip) {
            params_.center += delta;
            engage();
            evaluate();
        }
        moverLastMX = e.x;
        moverLastMY = e.y;
        return true;
    }

    /// Mirrors BoxTool.moverHitTest (box.d:2768) — Arrow.hitTest is
    /// `protected` (see `Handler` in handles/shapes.d), so the
    /// segment-distance test is duplicated here rather than called;
    /// `BoxHandler.hitTest` (handles/shapes.d) is public so centerBox /
    /// rotateBox can be hit-tested directly.
    /// rotateBox is tested FIRST — it is the smaller target and (depending on
    /// camera distance) can sit close to the enlarged centerBox's screen area.
    private int moverHitTest(int mx, int my) {
        if (rotateBox.hitTest(mx, my, cachedVp)) return 4;
        if (mover.centerBox.hitTest(mx, my, cachedVp)) return 3;
        Arrow[3] arrows = [mover.arrowX, mover.arrowY, mover.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, cachedVp, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedVp, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }
}

unittest {
    Mesh owned;
    auto tool = new MirrorTool(() => &owned, null, LitShader.init);
    tool.engaged = false; tool.havePreviewCache = true;
    auto prepared = tool.prepareParamState("axis");
    assert(!tool.engaged);
    assert(prepared.boolValue); // using the original false state instead REDs
    MirrorPreparedState handle;
    assert(tool.validatePreparedState(prepared, handle));
    tool.installLegacyPreparedState(handle);
    // A parameter write before the first press never engages.
    assert(!tool.engaged && tool.havePreviewCache);
    tool.engaged = true;
    assert(tool.validatePreparedState(prepared, handle));
    tool.installLegacyPreparedState(handle);
    // After it: still engaged, and the live copy is owed a rebuild.
    assert(tool.engaged && !tool.havePreviewCache);
}

static assert(!__traits(compiles, { MirrorPreparedState a; MirrorPreparedState b = a; }));

/// Camera forward direction from a Viewport's view matrix (not necessarily
/// unit length — rayPlaneIntersect's t = dot(n,d)/dot(n,dir) is invariant
/// under scaling n, so this is safe to use unnormalized as a plane normal).
/// Not exported from math.d as a reusable helper; inlined here since it's
/// only needed for the click-to-place screen-facing plane (M3).
private Vec3 cameraForwardDir(const ref Viewport vp) pure nothrow @nogc @safe {
    return Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
}
