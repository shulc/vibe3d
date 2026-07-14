module tools.radial_array_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import handler : Arrow, BoxHandler, ToolHandles, gizmoSize;
import drag : screenAxisDelta;
import eventlog : queryMouse;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.radial_array_edit : MeshRadialArrayEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

import std.math : sin, cos, atan2, PI;

/// The interactive tool reuses the dedicated MeshRadialArrayEdit record
/// command (a before/after MeshSnapshot pair) — mirroring PolyExtrudeTool's
/// pattern.
alias RadialArrayEditFactory = MeshRadialArrayEdit delegate();

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
// center" gesture) via the same Work Plane projection every other
// click-to-place tool in this codebase uses.
//
// Pixel-level handle geometry is not calibrated against the reference
// (the capture's handle_map note flags this as an explicit TODO, out of
// scope for a Stage-0 spec-extract) — the handles here are functional
// (world-anchored, screen-scaled, correctly hit-tested) but not a pixel
// trace of the reference's rendering.
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
//                  MeshRadialArrayEdit as ONE undo entry.
//
// Headless path: `tool.set mesh.radialArrayTool on; tool.attr
// mesh.radialArrayTool count 4; ...; tool.doApply` drives through
// applyHeadless(); ToolDoApplyCommand wraps it with a snapshot pair for
// undo (applyHeadless MUST NOT snapshot itself).
// ---------------------------------------------------------------------------
class RadialArrayTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory          history;
    RadialArrayEditFactory  factory;

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

    enum Vec3 OFFSET_COLOR = Vec3(0.2f, 0.45f, 1.0f);   // blue — linear haul
    enum Vec3 ANGLE_COLOR  = Vec3(0.9f, 0.75f, 0.15f);  // yellow/gold — angular haul

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
        offsetArrow = new Arrow(Vec3(0, 0, 0), Vec3(0, 1, 0), OFFSET_COLOR);
        angleCube   = new BoxHandler(Vec3(0, 0, 0), ANGLE_COLOR);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        if (offsetArrow !is null) offsetArrow.destroy();
        if (angleCube   !is null) angleCube.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction.
    void setUndoBindings(CommandHistory h, RadialArrayEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Radial Array"; }

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

    public override bool hasUncommittedEdit() const { return active && built; }

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
        Vec3 hit;
        if (screenToWorkPlane(cast(float)e.x, cast(float)e.y, cachedVp, hit)) {
            center_ = hit;
            rebuildPreview();
        }
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || dragPart < 0 || mesh is null) return false;

        if (dragPart == PART_OFFSET) {
            bool skip;
            Vec3 au = axisUnit();
            Vec3 delta = screenAxisDelta(e.x, e.y, lastMX, lastMY, center_, au, cachedVp, skip);
            if (!skip) {
                offset_ += dot(delta, au);
                rebuildPreview();
            }
            lastMX = e.x;
            lastMY = e.y;
            return true;
        }

        if (dragPart == PART_ANGLE) {
            Vec3 au = axisUnit();
            Vec3 originC, dirC, originP, dirP;
            screenPointToRay(cast(float)e.x,     cast(float)e.y,     cachedVp, originC, dirC);
            screenPointToRay(cast(float)lastMX,  cast(float)lastMY,  cachedVp, originP, dirP);
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

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        if (!active || mesh is null) return;

        Vec3  au = axisUnit();
        float sz = gizmoSize(center_, vp, 1.0f);

        offsetArrow.start = center_ + au * (sz / 6.0f);
        offsetArrow.end   = center_ + au * sz;
        offsetArrow.color = OFFSET_COLOR;

        Vec3 refDir  = referenceTangent(axis_);
        Vec3 tangent = rotateAroundAxis(refDir, au, angle_ * PI / 180.0f);
        angleCube.pos   = center_ + tangent * (sz * 0.85f);
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

    // Rodrigues' rotation formula — `axis` is assumed unit length (true for
    // the principal X/Y/Z axes this tool uses).
    static Vec3 rotateAroundAxis(Vec3 v, Vec3 axis, float angleRad) {
        float c = cos(angleRad), s = sin(angleRad);
        return v * c + cross(axis, v) * s + axis * (dot(axis, v) * (1.0f - c));
    }

    bool[] currentMask() {
        bool[] mask = new bool[](mesh.faces.length);
        bool any = false;
        foreach (i, b; mesh.selectedFaces) {
            if (b) { mask[i] = true; any = true; }
        }
        if (!any) foreach (i; 0 .. mesh.faces.length) mask[i] = true;
        return mask;
    }

    void rebuildPreview() {
        if (!active || mesh is null || !before.filled) return;
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
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Radial Array");
        history.record(cmd);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
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
