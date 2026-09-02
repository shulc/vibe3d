module tools.alignment.radial_array_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, BoxHandler, ToolHandles, gizmoSize;
import viewport_scheme : schemeColor, SchemeColor;
import overlay_space : OverlaySpace;
import drag : screenAxisDelta, gesturePrevPixel;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import command : Command;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;
import tools.create.create_common : screenToConstructionPlane;

import std.math : sin, cos, atan2, PI;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import prepared_tool_effect : PreparedRadialArrayEffect, PreparedRadialArrayKind;
import prepared_radial_array_transition : PreparedRadialArrayTransitionOwner;
import command_history : PreparedHistoryKind;
import document : Layer;
import mesh_gpu : GpuUploadOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import core.stdc.string : memcmp;

enum PreparedRadialArrayTransitionKind : ubyte { Activate, Param, Deactivate }
struct RadialArrayParamProjection {
    int count;
    string axis;
    Vec3 center;
    float angle, offset, weld;
    bool opEquals(const RadialArrayParamProjection other) const nothrow @nogc {
        bool sameBytes(T)(ref const T a, ref const T b) nothrow @nogc {
            return memcmp(&a, &b, T.sizeof) == 0;
        }
        return count == other.count && axis == other.axis &&
            sameBytes(center, other.center) && sameBytes(angle, other.angle) &&
            sameBytes(offset, other.offset) && sameBytes(weld, other.weld);
    }
}
struct RadialArrayTransitionImage {
    MeshSnapshot before;
    MeshSnapshot expectedLive, expectedBefore;
    Mesh candidate;
    RadialArrayParamProjection expectedParams;
    PreparedRadialArrayTransitionKind kind;
    bool active, built, clearHaul, valid, applies;
    bool expectedActive, expectedBuilt;
    int dragPart;
    uint deliveryFlags, deliveryDomains;
    void clear() nothrow @nogc { this = RadialArrayTransitionImage.init; }
}

// ---------------------------------------------------------------------------
// RadialArrayTool — interactive port of the reference editor's "Radial
// Array" duplicate preset (factory id `mesh.radialArrayTool`).
//
// The reference behavior is a two-stage generator+effector combo (a helix
// path generator driving a clone effector) — see
// the captured spec for the attribute surface and
// defaults. vibe3d already has the matching kernel
// (`Mesh.radialArrayFaces`, shared verbatim with the one-shot
// `mesh.radial_array` command) and its own same-mesh clone-insertion
// architecture, which the capture confirmed is the correct model — no
// kernel or structural rework, just an interactive session wrapped around
// the existing kernel.
//
// Params (captured defaults):
//   count  (int)    — 24. Total array elements, including the source.
//   axis   (enum)   — Y. Principal axis only (X/Y/Z); the reference's
//                     arbitrary-axis-vector handles (SDK 100/101) have no
//                     destination here — vibe3d's kernel is
//                     principal-axis-only (documented on
//                     Mesh.radialArrayFaces itself), so that handle is out
//                     of scope by construction, not merely deferred.
//   center (vec3)   — origin. Reference default is the scene origin
//                     "before any placement click" — NOT a selection
//                     centroid.
//   angle  (float)  — 0 degrees. "End Angle"; the reference also exposes a
//                     Start Angle, but vibe3d's kernel only takes one
//                     total-sweep angle (Start implicitly 0) — documented
//                     gap (see the captured missing-options list).
//   offset (float)  — 0. TOTAL span across the array (reference "Offset"
//                     semantics, MEASURED from the frozen parity capture —
//                     see below), not a fixed per-clone step.
//   weld   (float)  — 0 (merge off). 0 = no weld, matching the reference's
//                     Merge-Vertices-off default; >0 folds coincident verts
//                     the same way the one-shot command's `weld` does.
//
// Offset law (the corrected finding from the frozen capture's
// before/after parity case):
// `Offset` is a TOTAL span divided evenly across the (count-1) point-to-
// point intervals, NOT a fixed step multiplied by clone index. This tool
// converts it once per rebuild into the per-step translate the kernel
// actually wants: `extraShift = axisUnit * (offset / (count-1))`.
//
// Gizmo-haul surface: the reference's own SDK handle map (the capture notes
// handle_map) declares handles ONLY for the axis vector (100/101, out of
// scope above) and the Start/End Angle ring (103/104, "a blue cube handle"
// per the reference help text) — Count and Offset have NO reference
// viewport handle, they are panel-only fields even in the reference tool.
// This tool matches that surface exactly:
//   PART_ANGLE  — a cube handle orbiting the array axis at the current End
//                 Angle (matching the reference's own described cube
//                 handle); dragging it tangentially sweeps `angle`.
//   PART_OFFSET — vibe3d ADDS an axis-arrow handle for `offset` (the
//                 reference has none) since Offset already has a clean
//                 1-D world-axis meaning here and a haul handle costs
//                 nothing extra; this is a pure UX superset, not a
//                 divergence in generated geometry.
// A plain click that misses both handles repositions `center` (the
// reference's own "click again away from the handles to reposition the
// center" gesture) via the same construction-plane projection every other
// click-to-place tool in this codebase uses.
//
// Pixel-level handle geometry is not calibrated against the reference
// (the capture's handle_map note flags this as an explicit TODO, out of
// scope for a Stage-0 spec-extract) — the handles here are functional
// (world-anchored, screen-scaled, correctly hit-tested) but not a pixel
// trace of the reference's rendering.
//
// WHICH SPACE EVERY PARAMETER LIVES IN (task 0660).
//
// The kernel this tool drives, `Mesh.radialArrayFaces`, pivots the LAYER'S OWN
// stored vertex coordinates: it rotates `vertices[vid]` about `axisVec` through
// `center`, then adds `step * extraShift`. Nothing in it knows about the item
// transform. So all four generated quantities — `center_`, the axis, `offset_`
// and `angle_` — are LAYER-space readings, and that is the meaning the panel
// fields carry (identical to the one-shot `mesh.radial_array` command, which
// shares this kernel verbatim).
//
// Every GESTURE that writes one of them, on the other hand, resolves in WORLD
// space: the construction plane is a world plane (task 0661 — it follows the
// view, but it is world either way), `screenAxisDelta` returns a world
// displacement, a cursor ray is a world ray. And every OVERLAY that reads one
// of them is world too — `gizmoSize`, `Handler.draw`, `Handler.hitTest`.
//
// The centre used to cross that line unconverted: the off-handle click wrote
// the construction plane's WORLD hit straight into `center_`, so on a layer
// with a non-identity item transform the array was built around that point's
// image under the IDENTITY matrix, not around the point that was clicked. The
// conversion at every crossing is `source/overlay_space.d` — one `OverlaySpace`
// per event/frame, used for the handle that is drawn AND for the gain of the
// drag that handle drives, which is task 0645's law and the reason a
// half-conversion here is worse than none.
//
// Session model (matches PolyExtrudeTool):
//   activate()   — snapshot cage+selection; reset params to the captured
//                  defaults above; nothing is generated yet (matches the
//                  reference's own "enter values ... click Apply to
//                  generate the array" flow — a fresh activation at
//                  angle=0/offset=0 is a literal no-op, so this tool does
//                  not burn cycles building a degenerate stacked-duplicate
//                  preview nobody asked for).
//   drag / panel edit — restore cage, re-run radialArrayFaces(mask, ...)
//                  with the live params. Per-tick re-evaluate, same law
//                  EdgeExtendTool / PolyExtrudeTool use for topology-
//                  creating previews.
//   deactivate() — if a non-empty preview was built: commit
//                  MeshSessionEdit as ONE undo entry.
//
// Headless path: `tool.set mesh.radialArrayTool on; tool.attr
// mesh.radialArrayTool count 4; ...; tool.doApply` drives through
// applyHeadless(); ToolDoApplyCommand wraps it with a snapshot pair for
// undo (applyHeadless MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class RadialArrayTool : Tool, PreparedToolDoorClient {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;


    // Parameters — captured defaults (see the captured spec).
    int    count_  = 24;
    string axis_   = "Y";
    Vec3   center_ = Vec3(0, 0, 0);
    float  angle_  = 0.0f;   // degrees — End Angle (Start implicitly 0)
    float  offset_ = 0.0f;   // world units — TOTAL span (reference semantics)
    float  weld_   = 0.0f;   // 0 = merge off (captured default)

    // Interactive session state.
    bool          active;
    bool          built;
    MeshSnapshot  before;
    Viewport      cachedVp;

    // Drag state.
    enum int PART_OFFSET = 0;
    enum int PART_ANGLE  = 1;
    int  dragPart = -1;
    int  lastMX, lastMY;

    Arrow       offsetArrow;
    BoxHandler  angleCube;
    ToolHandles toolHandles;

    enum Vec3 OFFSET_COLOR = schemeColor(SchemeColor.toolOffset);
    enum Vec3 ANGLE_COLOR  = schemeColor(SchemeColor.toolAngle);

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        offsetArrow = new Arrow(Vec3(0, 0, 0), Vec3(0, 1, 0), OFFSET_COLOR);
        angleCube   = new BoxHandler(Vec3(0, 0, 0), ANGLE_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (offsetArrow !is null) offsetArrow.destroy();
        if (angleCube   !is null) angleCube.destroy();
    }

    override string name() const { return "Radial Array"; }

    final bool ownsPreparedMesh(const Mesh* candidate) const {
        return candidate !is null && mesh !is null && candidate is mesh;
    }

    final RadialArrayTransitionImage buildPreparedActivationImage(ref Mesh source) {
        RadialArrayTransitionImage image;
        image.before = MeshSnapshot.capture(source);
        image.kind = PreparedRadialArrayTransitionKind.Activate;
        image.active = true; image.built = false; image.dragPart = -1;
        image.clearHaul = true; image.valid = true; return image;
    }
    final RadialArrayTransitionImage buildPreparedDeactivateImage() nothrow @nogc {
        RadialArrayTransitionImage image;
        image.kind = PreparedRadialArrayTransitionKind.Deactivate;
        image.active = false; image.built = false; image.dragPart = -1;
        image.clearHaul = true; image.valid = true; return image;
    }
    final RadialArrayTransitionImage buildPreparedParamImage(ref Mesh live) {
        RadialArrayTransitionImage image;
        image.kind = PreparedRadialArrayTransitionKind.Param;
        image.valid = true; image.expectedActive = active;
        image.expectedBuilt = built; image.active = active;
        image.built = built; image.dragPart = dragPart;
        image.expectedParams = paramProjection();
        image.expectedParams.axis = axis_.dup;
        image.expectedLive = MeshSnapshot.capture(live);
        if (!before.filled) return image;
        Mesh baseline;
        auto baselineShadow = beginPreparedShadow(baseline);
        before.restore(baseline);
        drainPreparedShadowDelivery(baseline, image.deliveryFlags,
            image.deliveryDomains);
        baselineShadow.close();
        image.expectedBefore = MeshSnapshot.capture(baseline);
        image.deliveryFlags = image.deliveryDomains = 0;
        if (!interactiveParamEdit || !active) return image;
        image.applies = true; image.candidate = baseline; baseline = Mesh.init;
        auto shadow = beginPreparedShadow(image.candidate);
        if (count_ <= 1) image.built = false;
        else {
            auto mask = image.candidate.operandFaceMask();
            Vec3 extraShift = axisUnit() *
                (offset_ / cast(float)(count_ - 1));
            size_t n = image.candidate.radialArrayFaces(mask, count_, axisChar(),
                center_, angle_ * PI / 180.0f, extraShift, weld_);
            image.built = n != 0;
        }
        drainPreparedShadowDelivery(image.candidate, image.deliveryFlags,
            image.deliveryDomains);
        shadow.close(); return image;
    }
    final bool preparedParamMatches(in RadialArrayTransitionImage image,
            ref const Mesh live) const nothrow @nogc {
        return image.valid && image.kind == PreparedRadialArrayTransitionKind.Param &&
            active == image.expectedActive && built == image.expectedBuilt &&
            image.expectedParams == paramProjection() &&
            image.expectedLive.matches(live) &&
            (!before.filled || image.expectedBefore.matches(before));
    }
    final void installPreparedTransition(ref RadialArrayTransitionImage image)
            nothrow @nogc {
        if (!image.valid) return;
        if (image.kind == PreparedRadialArrayTransitionKind.Activate)
            image.before.moveInto(before);
        active = image.active; built = image.built; dragPart = image.dragPart;
        if (image.clearHaul) toolHandles.clearHaul(); image.clear();
    }
    version(unittest) void seedPreparedTransitionForTest() {
        active = false; built = true; dragPart = 4; toolHandles.setHaul(3);
    }
    version(unittest) void seedPreparedBuiltTransitionForTest(ref Mesh source) {
        before = MeshSnapshot.capture(source); active = true; built = true;
        dragPart = 4; toolHandles.setHaul(3);
    }
    version(unittest) void seedPreparedParamForTest(ref Mesh source,
            bool interactive) {
        before = MeshSnapshot.capture(source); active = true; built = false;
        dragPart = -1; interactiveParamEdit = interactive;
        count_ = 4; angle_ = 90; offset_ = 2; weld_ = 0;
    }
    version(unittest) void mutatePreparedParamForTest(float value)
            nothrow @nogc { angle_ = value; }
    version(unittest) bool preparedParamStateForTest(bool expectedBuilt)
            const nothrow @nogc { return active && built == expectedBuilt; }
    version(unittest) bool preparedBuiltSeedUnchangedForTest() const
            nothrow @nogc {
        return active && built && dragPart == 4 &&
            toolHandles.haulForPreparedTest() == 3 && before.filled;
    }
    version(unittest) void bindPreparedHistoryOnlyForTest(CommandHistory value) {
        history = value; gestureFactory = null;
    }
    version(unittest) void bindPreparedFactoryOnlyForTest(Command delegate() value) {
        history = null; gestureFactory = value;
    }
    version(unittest) bool preparedTransitionForTest(bool expectedActive)
            const nothrow @nogc {
        return active == expectedActive && !built && dragPart == -1 &&
            toolHandles.haulForPreparedTest() == -1 &&
            (!expectedActive || before.filled);
    }
    version(unittest) bool preparedSnapshotForTest(size_t vertices,
            size_t edges, size_t faces, Vec3 first, const Mesh* live) const
            nothrow @nogc {
        return before.filled && before.vertices.length == vertices &&
            before.edges.length == edges && before.faces.length == faces &&
            before.vertices.length != 0 && before.vertices[0] == first &&
            (live is null || before.vertices.ptr !is live.vertices.ptr);
    }

    override Param[] params() {
        return [
            // `.max(256).enforceBounds()` matches the project convention for
            // any generator-tool Count/Sides Param whose evaluate() drives an
            // O(count) mesh-allocating kernel (sphere/cylinder/cone/capsule's
            // sides/segments) — `.min()`/`.max()` alone are UI-only hints; a
            // raw `tool.attr mesh.radialArrayTool count 100000000` over HTTP
            // writes straight through injectParamsInto without
            // `.enforceBounds()`. Mesh.radialArrayFaces also clamps
            // internally (defense-in-depth for the shared kernel — see its
            // doc comment) so this bound and that one agree at 256.
            Param.int_  ("count",  "Count",           &count_,  24).min(1).max(256).enforceBounds(),
            Param.enum_ ("axis",   "Axis",             &axis_,
                         [["X","X"], ["Y","Y"], ["Z","Z"]], "Y"),
            // LAYER coordinates — the space `Mesh.radialArrayFaces` pivots in
            // (see the class doc comment). The off-handle click converts the
            // construction plane's world hit into this space before writing it.
            Param.vec3_ ("center", "Center",           &center_, Vec3(0, 0, 0)),
            Param.float_("angle",  "End Angle (deg)",  &angle_,  0.0f),
            Param.float_("offset", "Offset",           &offset_, 0.0f),
            Param.float_("weld",   "Weld Distance",    &weld_,   0.0f).min(0.0f),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    // Task 0393: only session/gesture state resets here — count_/axis_/
    // center_/angle_/offset_/weld_ are STICKY tool-defaults, already
    // restored onto these fields by applyStickyToolDefaults()
    // (tool_presets.d, called from app.d activateToolById) BEFORE
    // activate() runs. Resetting them here would clobber that restore. A
    // brand-new (never-activated) tool still gets the captured defaults
    // above (24/"Y"/origin/0/0/0) straight from the field initializers.
    private void reinitSession() {
        built     = false;
        dragPart  = -1;
        before    = MeshSnapshot.capture(*mesh);
        toolHandles.clearHaul();
    }

    override void deactivate() {
        if (active && built) commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        toolHandles.clearHaul();
    }

    final PreparedRadialArrayEffect prepareActivate(PreparedRecordContext context) {
        if (context is null)
            return PreparedRadialArrayEffect(preparedToolStateOwner,
                PreparedRadialArrayKind.Activate, false);
        scope(failure) context.discard();
        auto live = mesh;
        auto transition = live !is null
            ? PreparedRadialArrayTransitionOwner.activation(this, *live) : null;
        bool ok = transition !is null &&
            context.prepareRadialArrayTransition(transition) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedRadialArrayEffect(preparedToolStateOwner,
            PreparedRadialArrayKind.Activate, ok);
    }
    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        return prepareActivate(context).accepted;
    }

    final PreparedRadialArrayEffect prepareSessionDeactivate(
            PreparedRecordContext context) {
        if (context is null)
            return PreparedRadialArrayEffect(preparedToolStateOwner,
                PreparedRadialArrayKind.Deactivate, false);
        scope(failure) context.discard();
        auto live = mesh;
        if (live is null) {
            context.discard();
            return PreparedRadialArrayEffect(preparedToolStateOwner,
                PreparedRadialArrayKind.Deactivate, false);
        }
        bool ok = true, historyPrepared;
        if (active && built && history !is null && gestureFactory !is null &&
            before.filled) {
            auto cmd = cast(MeshSessionEdit) gestureFactory();
            if (cmd !is null && cmd.meshPtr() is live) {
                cmd.setSnapshots(before, MeshSnapshot.capture(*live), "Radial Array");
                historyPrepared = context.prepare(cmd,
                    PreparedHistoryKind.Plain).accepted;
                ok = historyPrepared;
            } else ok = context.prepareGestureCarrierMismatch();
        }
        if (ok) ok = historyPrepared ? context.markHistoryInstall()
                                     : context.markNoHistoryInstall();
        auto transition = ok
            ? PreparedRadialArrayTransitionOwner.deactivation(this) : null;
        ok = transition !is null &&
            context.prepareRadialArrayTransition(transition);
        if (!ok) context.discard();
        return PreparedRadialArrayEffect(preparedToolStateOwner,
            PreparedRadialArrayKind.Deactivate, ok);
    }
    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer,
            ulong, ulong) {
        return prepareSessionDeactivate(context).accepted;
    }

    public override bool hasUncommittedEdit() const { return active && built; }

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
    final PreparedRadialArrayEffect prepareParamChanged(
            PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        if (context is null) return PreparedRadialArrayEffect(
            preparedToolStateOwner, PreparedRadialArrayKind.Param, false);
        scope(failure) context.discard();
        auto transition = PreparedRadialArrayTransitionOwner.param(this, layer);
        bool ok = transition !is null;
        if (ok && transition.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, transition.candidate,
                    transition.deliveryFlags, transition.deliveryDomains);
        if (ok) ok = context.prepareRadialArrayTransition(transition);
        if (ok && transition.applies)
            ok = context.prepareUpload(uploadOwner, transition.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedRadialArrayEffect(preparedToolStateOwner,
            PreparedRadialArrayKind.Param, ok);
    }
    override void evaluate() {}

    override bool applyHeadless() {
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.faces.length == 0) return false;
        if (count_ <= 1) return true;   // identity is a clean no-op
        auto mask = currentMask();
        Vec3 extraShift = axisUnit() * (offset_ / cast(float)(count_ - 1));
        size_t n = mesh.radialArrayFaces(mask, count_, axisChar(), center_,
                                         angle_ * PI / 180.0f, extraShift, weld_);
        if (n == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || mesh is null) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            cancelLiveEdit();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        int part = toolHandles.test(e.x, e.y, cachedVp);
        lastMX = e.x;
        lastMY = e.y;

        if (part == PART_OFFSET || part == PART_ANGLE) {
            dragPart = part;
            toolHandles.setHaul(part);
            return true;
        }

        // Off-handle click: reposition the rotation center (reference
        // gesture "reposition-center" — see the class doc comment).
        //
        // The plane FOLLOWS THE VIEW and the projection cannot refuse (task
        // 0661). This was `if (screenToWorkPlane(...)) { center_ = hit; }`
        // against the fixed world floor: in Front / Back / Left / Right the
        // ray is parallel to that floor, so the call returned false and the
        // missing `else` turned it into "the centre stayed put" — a click the
        // user made and the tool never registered.
        //
        // That construction plane is a WORLD construct however it is oriented,
        // so the point it returns is a WORLD point — and `center_` is read by
        // `Mesh.radialArrayFaces`, which pivots the layer's own stored
        // coordinates. Writing it in unconverted built the array around its
        // image under the identity matrix (task 0660). `toLocalPos` is the
        // exact inverse of the `pos()` the same object uses to place the
        // handles in `draw()`, so the point the user clicked and the point the
        // copies turn about are one point.
        center_ = OverlaySpace.ofPrimary().toLocalPos(
                      screenToConstructionPlane(cast(float)e.x, cast(float)e.y,
                                                cachedVp));
        rebuildPreview();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || mesh is null) return false;

        // Both branches below are per-event increments — the offset arrow
        // projects the pixel delta onto the axis, the angle handle differences
        // two ray/plane hits taken at the previous and current pixel — so both
        // take their previous pixel from the cooked gesture rather than from
        // this tool's own pair. `lastMX/MY` stay written as the fallback when
        // no gesture is published and as the other half of the debug agreement
        // check.
        import toolpipe.packets : GesturePacket;
        int prevMX, prevMY;
        gesturePrevPixel(vts.get!GesturePacket(), e.x, e.y,
                         lastMX, lastMY, prevMX, prevMY);

        // ONE overlay space per event (task 0645/0660). Both branches below are
        // per-event increments — previous pixel to current pixel — so there is
        // no gesture-long plane to freeze the matrix against the way
        // `ArrayTool` must; re-resolving per event matches `PolyExtrudeTool`.
        const auto os = OverlaySpace.ofPrimary();

        if (dragPart == PART_OFFSET) {
            bool skip;
            // The arm is DRAWN along the local axis lifted through the item
            // matrix, and `offset_` is the LOCAL span the kernel spreads over
            // `count-1` steps. One `OverlayAxis` in both roles: `ax.dir` is the
            // arm the pixels are dotted against, `ax.toLocal` turns the world
            // length that produced back into the length the kernel means, so
            // the geometry follows the arm on screen.
            const auto ax = os.axis(axisUnit());
            Vec3 delta = screenAxisDelta(e.x, e.y, prevMX, prevMY,
                                         os.pos(center_), ax.dir, cachedVp, skip);
            if (!skip) {
                offset_ += ax.toLocal(dot(delta, ax.dir));
                rebuildPreview();
            }
            lastMX = e.x;
            lastMY = e.y;
            return true;
        }

        if (dragPart == PART_ANGLE) {
            Vec3 au = axisUnit();
            // `angle_` is the sweep the kernel applies about the LOCAL
            // principal axis, and under a non-uniform item scale a local
            // rotation is not a world rotation at all — there is no world angle
            // to convert back. So the two cursor rays are carried into layer
            // space and the ENTIRE measurement happens there, against a plane
            // whose point (`center_`) and normal (`au`) are already local.
            //
            // `screenPointToLocalRay` is task 0619's law as one call: build the
            // ray from the UN-composed world viewport, then `toLocalPoint` the
            // origin and `toLocalDir` the direction, leaving the direction
            // un-normalised. At identity it is byte-identical to the
            // `screenPointToRay` pair this replaced.
            const ModelSpace rayMs = os.rayModelSpace();
            Vec3 originC, dirC, originP, dirP;
            screenPointToLocalRay(cast(float)e.x,    cast(float)e.y,    cachedVp, rayMs, originC, dirC);
            screenPointToLocalRay(cast(float)prevMX, cast(float)prevMY, cachedVp, rayMs, originP, dirP);
            Vec3 hitC, hitP;
            if (rayPlaneIntersect(originC, dirC, center_, au, hitC) &&
                rayPlaneIntersect(originP, dirP, center_, au, hitP)) {
                Vec3 vC = hitC - center_;
                Vec3 vP = hitP - center_;
                float lc = vC.length, lp = vP.length;
                // Incremental per-event angle (same style as the linear
                // per-event axisDragDelta/screenAxisDelta above); a camera
                // near-edge-on to the rotation plane degrades this the same
                // way it degrades any incremental ring drag — pixel-level
                // gizmo robustness is out of scope here (see class doc
                // comment).
                if (lc > 1e-5f && lp > 1e-5f) {
                    float sinA = dot(cross(vP, vC), au);
                    float cosA = dot(vP, vC);
                    float dAngle = atan2(sinA, cosA);
                    angle_ += dAngle * 180.0f / PI;
                    rebuildPreview();
                }
            }
            lastMX = e.x;
            lastMY = e.y;
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

    // Read-only test seam (task 0645's pattern) — GET /api/tool/handles. The
    // registry stays the hit-testing authority; this only exposes its
    // already-drawn state, and that state is the ONLY place a handle's SPACE is
    // observable from outside the process.
    public override JSONValue toolHandlesJson() const {
        return toolHandles is null ? JSONValue(null) : toolHandles.toJson(cachedVp);
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (!active || mesh is null) return;

        // ONE overlay space for the pass (task 0645): both handles are placed
        // through it and `toolHandles.update` below hit-tests these same
        // objects, so drawing and hitting cannot land in different spaces.
        const auto os      = OverlaySpace.ofPrimary();
        const Vec3 au      = axisUnit();
        const auto ax      = os.axis(au);
        const Vec3 centerW = os.pos(center_);

        float sz = gizmoSize(centerW, vp, 1.0f);

        offsetArrow.start = centerW + ax.dir * (sz / 6.0f);
        offsetArrow.end   = centerW + ax.dir * sz;
        offsetArrow.color = OFFSET_COLOR;

        // The dial reads the LOCAL sweep, so its tangent is built in layer
        // space and then lifted; its RADIUS stays a world, screen-constant
        // length from `gizmoSize`. Same split as the arrow above — direction
        // from the item matrix, length from the view — which is what keeps the
        // cube a constant pixel size on a scaled layer instead of tracing the
        // ellipse the local circle is drawn as.
        Vec3 refDir   = referenceTangent(axis_);
        // `au` is unit (normalised by the caller) — `rotateAboutAxis`'s contract.
        Vec3 tangentL = rotateAboutAxis(refDir, au, angle_ * PI / 180.0f);
        Vec3 tangentW = os.axis(tangentL).dir;
        angleCube.pos   = centerW + tangentW * (sz * 0.85f);
        angleCube.size  = sz * 0.06f;
        angleCube.color = ANGLE_COLOR;

        toolHandles.begin();
        toolHandles.add(offsetArrow, PART_OFFSET);
        toolHandles.add(angleCube,   PART_ANGLE);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        offsetArrow.draw(shader, vp);
        angleCube.draw(shader, vp);
    }

private:
    RadialArrayParamProjection paramProjection() const nothrow @nogc {
        return RadialArrayParamProjection(count_, axis_, center_, angle_,
            offset_, weld_);
    }
    char axisChar() const {
        if (axis_ == "X") return 'X';
        if (axis_ == "Z") return 'Z';
        return 'Y';
    }

    Vec3 axisUnit() const {
        if (axis_ == "X") return Vec3(1, 0, 0);
        if (axis_ == "Z") return Vec3(0, 0, 1);
        return Vec3(0, 1, 0);
    }

    // Fixed "zero angle" tangent per principal axis — purely a visual
    // reference for the angle-cube dial; it need not (and does not) match
    // the actual source selection's own angular position, matching the
    // reference's own dial-not-a-preview-pointer semantics.
    static Vec3 referenceTangent(string axis) {
        if (axis == "X") return Vec3(0, 1, 0);
        if (axis == "Z") return Vec3(1, 0, 0);
        return Vec3(0, 0, 1);
    }

    bool[] currentMask() {
        // L1 funnel (task 0613, S5): selected faces, else every VISIBLE face.
        return mesh.operandFaceMask();
    }

    void rebuildPreview() {
        if (!active || mesh is null || !before.filled) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        if (count_ <= 1) {
            built = false;
            refreshCaches();
            return;
        }
        auto mask = currentMask();
        Vec3 extraShift = axisUnit() * (offset_ / cast(float)(count_ - 1));
        size_t n = mesh.radialArrayFaces(mask, count_, axisChar(), center_,
                                         angle_ * PI / 180.0f, extraShift, weld_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Radial Array");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu);
    }

    void cancelLiveEdit() {
        if (before.filled) before.restore(*mesh);
        refreshCaches();
        angle_   = 0.0f;
        offset_  = 0.0f;
        built    = false;
        dragPart = -1;
        toolHandles.clearHaul();
    }
}
