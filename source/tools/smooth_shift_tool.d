module tools.smooth_shift_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, CubicArrow, ToolHandles, HandleState, gizmoSize;
import drag : screenAxisDelta;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.smooth_shift_edit : MeshSmoothShiftEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : abs, sqrt;

/// The interactive tool reuses the dedicated MeshSmoothShiftEdit record
/// command (a before/after MeshSnapshot pair) — mirroring PolyExtrudeTool /
/// PolyBevelTool's pattern.
alias SmoothShiftEditFactory = MeshSmoothShiftEdit delegate();

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
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory         history;
    SmoothShiftEditFactory factory;

    // Params — captured defaults (task 0358 toolcard, live panel reads):
    // shift=0, scale=1.0 (100%), maxAngle=89.5° (the tool's OWN factory
    // default, confirmed by two independent clean live panel renders — NOT
    // the 1.572542 rad/≈90.115° value, which is presets.cfg's Thicken-preset
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

    enum Vec3 OFFSET_COLOR = Vec3(0.2f, 0.45f, 1.0f);  // blue
    enum Vec3 SCALE_COLOR  = Vec3(0.9f, 0.2f, 0.2f);   // red

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
        offsetArrow = new Arrow(Vec3(0,0,0), Vec3(0,1,0), OFFSET_COLOR);
        scaleArrow  = new CubicArrow(Vec3(0,0,0), Vec3(1,0,0), SCALE_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (offsetArrow !is null) offsetArrow.destroy();
        if (scaleArrow  !is null) scaleArrow.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction.
    void setUndoBindings(CommandHistory h, SmoothShiftEditFactory f) {
        this.history = h;
        this.factory = f;
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
        size_t n = mesh.smoothShiftFacesByMask(mask, shift_, scale_, thicken_);
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
        Vec3 axis = (dragPart == PART_OFFSET) ? offsetAxis : scaleAxis;
        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, dragLastMX, dragLastMY,
                                     anchor, axis, cachedVp, skip);
        if (!skip) {
            float d = dot(delta, axis);
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

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (dragPart < 0 && !built && mesh.selectionSignature(EditMode.Polygons) != gizmoSelHash)
            computeGizmoFrame();
        if (!gizmoValid) return;

        anchor = baseAnchor + offsetAxis * shift_;

        float armLen   = gizmoSize(anchor, vp, 1.0f);
        float cubeHalf = gizmoSize(anchor, vp, 0.03f);
        offsetArrow.start = anchor + offsetAxis * (armLen / 6.0f);
        offsetArrow.end   = anchor + offsetAxis * armLen;
        offsetArrow.color = OFFSET_COLOR;
        scaleArrow.start         = anchor + scaleAxis * (armLen / 7.0f);
        scaleArrow.end           = anchor + scaleAxis * armLen;
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
        if (mesh.nothingSelected(EditMode.Polygons)) {
            auto m = new bool[](mesh.faces.length);
            m[] = true;
            return m;
        }
        return mesh.selectedFaces;
    }

    void computeGizmoFrame() {
        gizmoValid = false;
        if (mesh.faces.length == 0) return;
        Vec3 sum = Vec3(0,0,0);
        bool any = mesh.hasAnySelectedFaces();
        anchor = Vec3(0,0,0);
        int cnt = 0;
        foreach (fi; 0 .. mesh.faces.length) {
            if (any && !mesh.isFaceSelected(fi)) continue;
            sum   = sum + mesh.faceNormal(cast(uint)fi);
            anchor = anchor + mesh.faceCentroid(cast(uint)fi);
            ++cnt;
        }
        if (cnt == 0) return;
        anchor = anchor * (1.0f / cast(float)cnt);
        float len = sqrt(sum.x*sum.x + sum.y*sum.y + sum.z*sum.z);
        offsetAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);
        Vec3 up   = (abs(offsetAxis.y) < 0.9f) ? Vec3(0,1,0) : Vec3(1,0,0);
        Vec3 side = cross(offsetAxis, up);
        float slen = sqrt(side.x*side.x + side.y*side.y + side.z*side.z);
        scaleAxis    = (slen > 1e-6f) ? side * (1.0f/slen) : Vec3(1,0,0);
        baseAnchor   = anchor;
        gizmoSelHash = mesh.selectionSignature(EditMode.Polygons);
        gizmoValid   = true;
    }

    void rebuildPreview() {
        if (!active) return;
        before.restore(*mesh);
        auto mask = currentMask();
        // Deliberately UNCONDITIONAL — see applyHeadless()'s comment.
        size_t n = mesh.smoothShiftFacesByMask(mask, shift_, scale_, thicken_);
        built = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Smooth Shift");
        history.record(cmd);
    }

    void cancelLiveEdit() {
        if (built && before.filled) before.restore(*mesh);
        built    = false;
        dragPart = -1;
        toolHandles.clearHaul();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
