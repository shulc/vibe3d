module tools.deform.smooth_shift_tool;

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

import std.math : abs, sqrt;
import std.json : JSONValue;
import perf_probe : g_perf, Cat;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_smooth_shift_activation : PreparedSmoothShiftActivationOwner;
import command_history : PreparedHistoryKind;

struct PreparedSmoothShiftActivationImage {
    MeshSnapshot before;
    bool valid, gizmoValid;
    Vec3 anchor, baseAnchor, offsetAxis, scaleAxis;
    ulong gizmoSelHash;
    void clear() nothrow @nogc {
        this = PreparedSmoothShiftActivationImage.init;
    }
}

// ---------------------------------------------------------------------------
// SmoothShiftTool — interactive Smooth Shift + Thicken (factory id
// `mesh.smoothShiftTool`, task 0358).
//
// The reference editor's "Thicken" toolbar button is confirmed (task 0358
// toolcard, static + runtime-binding-level) to be the SAME tool as Smooth
// Shift, activated with its `thicken` attribute forced on — not a separate
// tool class. This one tool implements both, matching that binding: the
// Thicken button (config/buttons.yaml) sets thicken=1 on THIS tool.
//
// Modelled on PolyBevelTool (2 handles, snapshot-undo topology session), with
// one deliberate divergence: the reference always builds the full (possibly
// degenerate) extrude topology even at shift=0 (see Mesh.smoothShiftFacesByMask's
// doc comment and the frozen "base_noop" fixture), so — unlike PolyExtrudeTool/
// PolyBevelTool's "identity params ⇒ skip the kernel" shortcut — this tool's
// applyHeadless()/rebuildPreview() run the kernel UNCONDITIONALLY whenever the
// selection is non-empty and has a boundary. A plain activate()→deactivate()
// with no drag and no param edit still commits nothing (reinitSession() does
// not build a preview — the EdgeExtendTool/PolyBevelTool template), so merely
// opening and closing the tool stays a no-op for undo purposes.
//
// Two handles:
//   PART_OFFSET = BLUE Arrow along the region's averaged smoothed normal
//                 (`shift`).
//   PART_SCALE  = RED CubicArrow along an in-plane axis (`scale`, additive
//                 1:1 world-unit drag about the default 1.0 — the reference
//                 editor's own handle-haul law for Scale was not captured
//                 live (toolcard: "Not independently RFB-drag-captured this
//                 session"), so this mirrors the established Inset-handle
//                 convention (PolyBevelTool) rather than an unconfirmed law).
//
// `maxAngle` and `sharp` are stored/panel-exposed (5-attr order: shift,
// scale, maxAngle, thicken, sharp — matches the captured reference panel
// layout) but do not affect geometry — see the kernel's doc comment. Both
// are confirmed-live crease-related attrs (maxAngle = the crease-detection
// threshold; sharp = a checkbox toggling crease-corner rounding behaviour)
// whose GEOMETRIC EFFECT the reference capture could not empirically pin
// down: every captured multi-face selection was fully coplanar (no actual
// crease angle to act on), so sharp=0 vs sharp=1 produced byte-identical
// output there. Wiring both through as inert stored attrs is therefore a
// deliberate, documented gap — not a guess dressed up as a confirmed law.
//
// Headless: tool.set mesh.smoothShiftTool on; tool.attr mesh.smoothShiftTool
// shift/scale/maxAngle/thicken/sharp <v>; tool.doApply → applyHeadless();
// ToolDoApplyCommand wraps it with a snapshot pair for undo (applyHeadless
// MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class SmoothShiftTool : Tool {
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;


    // Params — captured defaults (task 0358 toolcard, live panel reads):
    // shift=0, scale=1.0 (100%), maxAngle=89.5° (the tool's OWN factory
    // default, confirmed by two independent clean live panel renders — NOT
    // the 1.572542 rad/≈90.115° value, which is the reference's Thicken preset
    // OVERRIDE applied only when entered via the Thicken button; see
    // mesh.thickenTool in config/tool_presets.yaml), thicken=off,
    // sharp=unchecked/false (a checkbox, confirmed live — an earlier float
    // guess was corrected after the panel actually rendered).
    float shift_    = 0.0f;
    float scale_    = 1.0f;
    float maxAngle_ = 89.5f;   // degrees, matching vibe3d's RX/RY/RZ angle-param convention
    bool  thicken_  = false;
    bool  sharp_    = false;

    bool         active;
    bool         built;
    MeshSnapshot before;
    Viewport     cachedVp;

    bool gizmoValid;
    Vec3 anchor;
    Vec3 baseAnchor;
    Vec3 offsetAxis;
    Vec3 scaleAxis;
    ulong gizmoSelHash;

    enum int PART_OFFSET = 0;
    enum int PART_SCALE  = 1;
    int   dragPart = -1;
    int   dragLastMX, dragLastMY;
    float dragBaseShift, dragBaseScale;

    // Floor for scale: prevents a drag from collapsing the cap footprint
    // through zero (inverted/degenerate faces), mirroring PolyBevelTool's
    // `if (inset_ < 0.0f) inset_ = 0.0f;` floor.
    enum float SCALE_MIN = 0.01f;

    Arrow      offsetArrow;
    CubicArrow scaleArrow;
    ToolHandles toolHandles;

    enum Vec3 OFFSET_COLOR = schemeColor(SchemeColor.toolOffset);
    enum Vec3 SCALE_COLOR  = schemeColor(SchemeColor.toolWidth);

public:
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu,
            EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        offsetArrow = new Arrow(Vec3(0,0,0), Vec3(0,1,0), OFFSET_COLOR);
        scaleArrow  = new CubicArrow(Vec3(0,0,0), Vec3(1,0,0), SCALE_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (offsetArrow !is null) offsetArrow.destroy();
        if (scaleArrow  !is null) scaleArrow.destroy();
    }

    override string name() const { return "Smooth Shift"; }

    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        // Order matches the captured reference panel exactly: shift, scale,
        // maxAngle, thicken, sharp.
        return [
            Param.float_("shift",    "Offset",                &shift_,    0.0f),
            Param.float_("scale",    "Scale",                  &scale_,    1.0f),
            Param.float_("maxAngle", "Max. Smoothing Angle",   &maxAngle_, 89.5f).angle(),
            Param.bool_ ("thicken",  "Thicken",                &thicken_,  false),
            Param.bool_ ("sharp",    "Sharp",                  &sharp_,    false),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    final PreparedSmoothShiftActivationImage buildPreparedActivation(
            out Mesh* source) {
        PreparedSmoothShiftActivationImage image;
        source = mesh; if (source is null) return image;
        image.before = MeshSnapshot.capture(*source); image.valid = true;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.offsetAxis = offsetAxis;
        image.scaleAxis = scaleAxis; image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*source, image);
        return image;
    }
    final Mesh* preparedActivationMesh() nothrow @nogc { return meshSrc_(); }
    final void installPreparedActivation(
            ref PreparedSmoothShiftActivationImage image) nothrow @nogc {
        if (!image.valid) return;
        active = true; built = false; dragPart = -1;
        image.before.moveInto(before);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; offsetAxis = image.offsetAxis;
        scaleAxis = image.scaleAxis; gizmoSelHash = image.gizmoSelHash;
        image.clear();
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.SmoothShift, false);
        scope(failure) context.discard();
        auto owner = PreparedSmoothShiftActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareSmoothShiftActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.SmoothShift, ok);
    }

    // (Re)initialise the edit session against the CURRENT mesh — shared by
    // activate() and resyncSession(). Does NOT build a preview (the
    // EdgeExtendTool/PolyBevelTool template): the headless tool.doApply path
    // goes through activate()→applyHeadless(), and ToolDoApplyCommand
    // captures its pre-snapshot BEFORE applyHeadless runs. Building a preview
    // on activate would poison that pre-snapshot.
    //
    // Deliberately does NOT touch shift_/scale_/maxAngle_/thicken_/sharp_
    // (review fix, task 0358): those 5 Param-backed fields are owned by a
    // strict layering — ctor default < preset YAML `attrs:` < sticky user
    // default < live user edit — established BEFORE activate() ever runs
    // (reg.toolFactories[id]() builds a fresh instance and applies the
    // preset's attrs; activateToolById() then applies sticky defaults; only
    // THEN does setActiveTool() call activate()). A prior version reset all
    // 5 fields to hardcoded defaults here, which unconditionally clobbered
    // that layering on every activation — silently discarding a preset's
    // forced attr. Concretely: `mesh.thickenTool` (config/tool_presets.yaml)
    // forces thicken=true via applyToolAttrs() at factory time, but this
    // reset ran afterward (from activate()) and stomped it back to false,
    // making the Thicken button behave identically to plain Smooth Shift
    // (proven live: preset path built 10 faces instead of 11). Session
    // bookkeeping (built/dragPart/before/gizmo) is genuinely per-activation
    // transient state and belongs here; the 5 attrs are not.
    private void reinitSession() {
        built    = false;
        dragPart = -1;
        before   = MeshSnapshot.capture(*mesh);
        computeGizmoFrame();
    }

    override void deactivate() {
        if (active && built)
            commitEdit();
        active     = false;
        built      = false;
        dragPart   = -1;
        gizmoValid = false;
        toolHandles.clearHaul();
    }

    public override bool hasUncommittedEdit() const {
        return active && built;
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
    override void evaluate() {}

    override bool applyHeadless() {
        if (*editMode != EditMode.Polygons) return false;
        if (built && before.filled) {
            before.restore(*mesh);
            built = false;
        }
        if (mesh.faces.length == 0) return false;
        auto mask = currentMask();
        // Deliberately UNCONDITIONAL — unlike PolyExtrudeTool/PolyBevelTool,
        // the reference does not short-circuit shift==0 (see the kernel's
        // doc comment + the frozen "base_noop" fixture).
        // task 1903 Stage H: smoothShiftFacesByMask takes `ref MeshEditBatch`
        // now. `commitEdit` below undoes via a MeshSnapshot pair, not the
        // op-log, so the batch is unrecorded.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.smoothShiftFacesByMask(mask, shift_, scale_, thicken_);
        ed.close();
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
        if (*editMode != EditMode.Polygons) return false;
        if (!gizmoValid) return false;

        int hmx, hmy;
        queryMouse(hmx, hmy);
        int part = toolHandles.test(hmx, hmy, cachedVp);

        dragLastMX    = e.x; dragLastMY = e.y;
        dragBaseShift = shift_;
        dragBaseScale = scale_;

        if (part == PART_OFFSET || part == PART_SCALE) {
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
        Vec3 axis = (dragPart == PART_OFFSET) ? offsetAxis : scaleAxis;
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
            float d = ax.toLocal(dot(delta, ax.dir));
            if (dragPart == PART_OFFSET) {
                shift_ = dragBaseShift + d;
            } else {
                scale_ = dragBaseScale + d;
                if (scale_ < SCALE_MIN) scale_ = SCALE_MIN;
            }
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
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Polygons) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor + offsetAxis * shift_;   // LOCAL, like the kernel

        // ONE overlay space for the pass (task 0645): both arms are positioned
        // in it and `toolHandles.update` below hit-tests these same objects, so
        // drawing and hitting cannot land in different spaces.
        const auto os       = OverlaySpace.ofPrimary();
        const auto offsetAx = os.axis(offsetAxis);
        const auto scaleAx  = os.axis(scaleAxis);
        const Vec3 anchorW  = os.pos(anchor);

        float armLen   = gizmoSize(anchorW, vp, 1.0f);
        float cubeHalf = gizmoSize(anchorW, vp, 0.03f);
        offsetArrow.start = anchorW + offsetAx.dir * (armLen / 6.0f);
        offsetArrow.end   = anchorW + offsetAx.dir * armLen;
        offsetArrow.color = OFFSET_COLOR;
        scaleArrow.start         = anchorW + scaleAx.dir * (armLen / 7.0f);
        scaleArrow.end           = anchorW + scaleAx.dir * armLen;
        scaleArrow.fixedCubeHalf = cubeHalf;
        scaleArrow.color         = SCALE_COLOR;

        toolHandles.begin();
        toolHandles.add(offsetArrow, PART_OFFSET);
        toolHandles.add(scaleArrow, PART_SCALE);
        if (dragPart >= 0) toolHandles.setHaul(dragPart);
        else               toolHandles.setHaul(-1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);

        offsetArrow.draw(shader, vp);
        scaleArrow.draw(shader, vp);
    }

private:
    bool[] currentMask() {
        // L1 funnel (task 0613, S5): the selection, else every VISIBLE element.
        return mesh.operandFaceMask();
    }

    void computeGizmoFrame() {
        PreparedSmoothShiftActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.offsetAxis = offsetAxis;
        image.scaleAxis = scaleAxis; image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(*mesh, image);
        gizmoValid = image.gizmoValid; anchor = image.anchor;
        baseAnchor = image.baseAnchor; offsetAxis = image.offsetAxis;
        scaleAxis = image.scaleAxis; gizmoSelHash = image.gizmoSelHash;
    }

    private static void computePreparedGizmoFrame(ref Mesh source,
            ref PreparedSmoothShiftActivationImage image) {
        image.gizmoValid = false;
        if (source.faces.length == 0) return;
        Vec3 sum = Vec3(0,0,0);
        bool any = source.hasAnySelectedFaces();
        image.anchor = Vec3(0,0,0);
        int cnt = 0;
        foreach (fi; 0 .. source.faces.length) {
            if (any && !source.isFaceSelected(fi)) continue;
            sum = sum + source.faceNormal(cast(uint)fi);
            image.anchor = image.anchor + source.faceCentroid(cast(uint)fi);
            ++cnt;
        }
        if (cnt == 0) return;
        image.anchor = image.anchor * (1.0f / cast(float)cnt);
        float len = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        image.offsetAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        Vec3 up = (abs(image.offsetAxis.y) < 0.9f) ?
            Vec3(0,1,0) : Vec3(1,0,0);
        Vec3 side = cross(image.offsetAxis, up);
        float slen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
        image.scaleAxis = (slen > 1e-6f) ?
            side * (1.0f/slen) : Vec3(1,0,0);
        image.baseAnchor = image.anchor;
        image.gizmoSelHash = source.selectionSignature(EditMode.Polygons);
        image.gizmoValid = true;
    }

    void rebuildPreview() {
        if (!active) return;
        // Perf (task 1370) — AFTER the guard(s) above, never on the first
        // line: an early-out must record no sample, or `count` tallies
        // refusals as work. See Cat.toolPreview for the decomposition.
        auto zPreview = g_perf.scope_(Cat.toolPreview);
        before.restore(*mesh);
        auto mask = currentMask();
        // Deliberately UNCONDITIONAL — see applyHeadless()'s comment.
        // task 1903 Stage H: unrecorded — the per-drag-frame preview rerun.
        auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
        size_t n = ed.smoothShiftFacesByMask(mask, shift_, scale_, thicken_);
        ed.close();
        built = (n != 0);
        refreshCaches();
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context) {
        bool accepted;
        if (active && built && context !is null && history !is null && gestureFactory !is null && before.filled) {
            auto cmd = cast(MeshSessionEdit) gestureFactory();
            if (cmd !is null) { cmd.setSnapshots(before, MeshSnapshot.capture(*mesh), "Smooth Shift"); accepted = context.prepare(cmd, PreparedHistoryKind.Plain).accepted; }
        }
        return PreparedDeactivateEffect(preparedToolStateOwner, PreparedDeactivateKind.SmoothShift, accepted);
    }

    void commitEdit() {
        if (history is null || gestureFactory is null) return;
        if (!before.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Smooth Shift");
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
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest(
            ref Mesh oldMesh) {
        active = false; built = true; dragPart = 9;
        shift_ = 2; scale_ = 3; maxAngle_ = 4; thicken_ = true; sharp_ = true;
        gizmoValid = false; anchor = Vec3(1,2,3); baseAnchor = Vec3(4,5,6);
        offsetAxis = Vec3(7,8,9); scaleAxis = Vec3(10,11,12);
        gizmoSelHash = 13; dragLastMX = 14; dragLastMY = 15;
        dragBaseShift = 16; dragBaseScale = 17; cachedVp.view[0] = 18;
        before = MeshSnapshot.capture(oldMesh);
    }
    version(unittest) final bool preparedActivationDirtyForTest() const
            nothrow @nogc {
        return !active && built && dragPart == 9 &&
            shift_ == 2 && scale_ == 3 && maxAngle_ == 4 && thicken_ && sharp_ &&
            !gizmoValid && anchor == Vec3(1,2,3) &&
            baseAnchor == Vec3(4,5,6) && offsetAxis == Vec3(7,8,9) &&
            scaleAxis == Vec3(10,11,12) && gizmoSelHash == 13;
    }
    version(unittest) final bool preparedActivationForTest(size_t count,
            Vec3 first, const Vec3* livePtr, bool expectedValid,
            Vec3 expectedAnchor, Vec3 expectedBase, Vec3 expectedOffset,
            Vec3 expectedScale, ulong expectedHash) const nothrow @nogc {
        return active && !built && dragPart == -1 && before.filled &&
            before.vertices.length == count &&
            (count == 0 || (before.vertices[0] == first &&
                            before.vertices.ptr !is livePtr)) &&
            gizmoValid == expectedValid && anchor == expectedAnchor &&
            baseAnchor == expectedBase && offsetAxis == expectedOffset &&
            scaleAxis == expectedScale && gizmoSelHash == expectedHash &&
            shift_ == 2 && scale_ == 3 && maxAngle_ == 4 && thicken_ && sharp_ &&
            dragLastMX == 14 && dragLastMY == 15 &&
            dragBaseShift == 16 && dragBaseScale == 17 && cachedVp.view[0] == 18;
    }
    version(unittest) final PreparedSmoothShiftActivationImage
            preparedFrameForTest(ref Mesh source) const {
        PreparedSmoothShiftActivationImage image;
        image.gizmoValid = gizmoValid; image.anchor = anchor;
        image.baseAnchor = baseAnchor; image.offsetAxis = offsetAxis;
        image.scaleAxis = scaleAxis; image.gizmoSelHash = gizmoSelHash;
        computePreparedGizmoFrame(source, image);
        return image;
    }
}
