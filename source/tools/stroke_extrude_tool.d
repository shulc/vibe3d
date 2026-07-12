module tools.stroke_extrude_tool;

import bindbc.sdl;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.stroke_extrude_edit : MeshStrokeExtrudeEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

alias StrokeExtrudeEditFactory = MeshStrokeExtrudeEdit delegate();

// ---------------------------------------------------------------------------
// StrokeExtrudeTool — interactive port of the reference editor's "Sketch
// Extrude" (task 0323, factory id `tool.strokeExtrude`). BASIC/captured
// scope only, per the owner-approved Stage-2 target: reproduce the ONE
// measured case (a straight-drag stroke on a cube's top face) and flag the
// rest as TODO rather than invent it. This header documents what is
// CAPTURED-EXACT vs. a DOCUMENTED DEFAULT.
//
// Gesture: press LMB in the viewport while >= 1 polygon is already
// selected (the reference precondition — "select a polygon, and then click
// the tool"; this tool does not pick one for you, matching that — a click
// with nothing selected is a plain no-op, event not consumed). The press
// anchors the path at the average face-centroid of the current selection.
// Every subsequent mouse-motion event ray-casts the CURRENT cursor onto a
// plane anchored at the last COMMITTED path point, oriented to the
// camera's view direction — this is the toolcard's OWN stated hypothesis
// for the reference mechanism (behavior_law_measured.finding_2: "the path
// is NOT axis-locked ... each new point's world position is resolved via a
// camera-relative ray-cast, most likely onto a plane anchored through the
// previous point, oriented to the view"), not a verified formula — flagged
// DOCUMENTED DEFAULT / TODO. A new path point commits once the accumulated
// screen-pixel distance since the last commit reaches the `prec` param
// (CAPTURED attr, default 30px — the exact px:span ratio is UNRESOLVED:
// toolcard finding_3 measured 16 spans for a naive 6-span prediction at
// prec=30/180px net drag; this tool uses a literal 1:1 reading of the
// documented "creates a new span every N pixels" prose as its DEFAULT, NOT
// the measured law). Release commits the final path (appending the live
// tip if it moved); RMB or deactivate-without-a-built-stroke cancels.
//
// NOT implemented — explicit task-0323 non-goals for this pass, TODO, not
// invented: curved/multi-direction path capture beyond the one measured
// straight case, non-default Scale/Spin modulation, the Profile-browser
// width modulation, Edit Path / Delete Knot / Uniform Spans / Straight /
// Delete Path modes, and the 5 non-primary curve gestures (curve_reset /
// curve_move_constrained / curve_move_branch_constrained / curve_delete /
// curve_delete_branch).
//
// Session model (mirrors RadialArrayTool / PolyExtrudeTool):
//   activate()   — snapshot the cage; reset session state (no drawing yet).
//   drag         — restore-and-rerun Mesh.extrudeAlongPath against the
//                    live sampled path (same restore+rerun-from-clean-cage
//                    law RadialArrayTool/PolyExtrudeTool use for
//                    topology-creating previews).
//   deactivate() — if a built stroke is pending: commit
//                    MeshStrokeExtrudeEdit as ONE undo entry.
//
// Headless path: NONE, faithfully. The toolcard's own
// `gesture_model.no_headless_path` finding is unambiguous: none of the
// reference's 14 named tool.attr are path-point coordinates, and
// activating the tool + `tool.doApply` with zero interaction is a
// bit-exact no-op there. `applyHeadless()` here reproduces that finding
// exactly — it always returns false. The headlessly-testable surface for
// this operation is the one-shot `mesh.strokeExtrude` command instead
// (explicit path-point list param), which this tool's own commit path
// also drives (via the kernel, wrapped in the record-flavor
// MeshStrokeExtrudeEdit rather than the one-shot command itself).
// ---------------------------------------------------------------------------
class StrokeExtrudeTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory           history;
    StrokeExtrudeEditFactory factory;

    // Params — captured defaults (see class doc comment).
    bool alignToPath_ = true;   // reference "Align to Path", default ON
    int  precisionPx_ = 30;     // reference "Precision" (px/span), default 30

    // Interactive session state.
    bool         active;
    bool         drawing_;
    bool         built_;
    MeshSnapshot before;
    bool[]       mask_;          // selected-face mask, captured at gesture start
    Vec3[]       pathPoints_;    // committed path points (index 0 = anchor)
    Vec3         liveTip_;       // in-progress, not-yet-committed tip
    float        lastScreenX_ = 0.0f, lastScreenY_ = 0.0f;
    Viewport     cachedVp;

    // DoS guard mirrors Mesh.extrudeAlongPath's own backstop (defense in
    // depth for the shared kernel — an unbounded drag must not explode
    // geometry).
    enum size_t maxSpans = 4096;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void destroy() {}

    /// Inject undo plumbing — called by app.d after construction.
    void setUndoBindings(CommandHistory h, StrokeExtrudeEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Stroke Extrude"; }

    // Reference precondition: operates on a polygon selection only.
    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [
            Param.bool_("alignToPath", "Align to Path", &alignToPath_, true),
            Param.int_ ("prec", "Precision", &precisionPx_, 30).min(1).max(1000).enforceBounds(),
        ];
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        drawing_ = false;
        built_   = false;
        mask_    = null;
        pathPoints_.length = 0;
        before   = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        if (active && built_) commitEdit();
        active   = false;
        drawing_ = false;
        built_   = false;
    }

    public override bool hasUncommittedEdit() const { return active && built_; }
    public override void cancelUncommittedEdit() { cancelLiveEdit(); }
    public override void resyncSession() { if (active) reinitSession(); }

    // Captured finding (gesture_model.no_headless_path): no numeric
    // tool.attr can drive geometry for this tool on the reference — see
    // class doc comment. Faithful port of that no-op; use the one-shot
    // `mesh.strokeExtrude` command for a headlessly-testable path.
    override bool applyHeadless() { return false; }
    override void evaluate() {}

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || mesh is null) return false;
        if (e.button == SDL_BUTTON_RIGHT) {
            if (drawing_) cancelLiveEdit();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (drawing_) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        auto m = selectedFaceMask();
        if (m is null) return false;   // reference precondition: pre-select a polygon

        mask_ = m;
        Vec3 anchor = maskFaceCentroid(mask_);
        pathPoints_.length = 0;
        pathPoints_ ~= anchor;
        liveTip_     = anchor;
        lastScreenX_ = cast(float)e.x;
        lastScreenY_ = cast(float)e.y;
        drawing_     = true;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !drawing_ || mesh is null) return false;

        // Camera-facing plane anchored at the last COMMITTED path point —
        // documented default, see class doc comment (finding_2).
        Vec3 origin, dir;
        screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, origin, dir);
        Vec3 camForward = Vec3(-cachedVp.view[2], -cachedVp.view[6], -cachedVp.view[10]);
        Vec3 hit;
        if (rayPlaneIntersect(origin, dir, pathPoints_[$ - 1], camForward, hit)) {
            liveTip_ = hit;

            // Precision threshold (captured attr `prec`) — see class doc
            // comment for the finding_3 caveat on the exact px:span ratio.
            float dx = cast(float)e.x - lastScreenX_;
            float dy = cast(float)e.y - lastScreenY_;
            if (dx * dx + dy * dy >= cast(float)(precisionPx_ * precisionPx_)
                && pathPoints_.length <= maxSpans) {
                pathPoints_ ~= hit;
                lastScreenX_ = cast(float)e.x;
                lastScreenY_ = cast(float)e.y;
            }
        }
        applyPath(pathPoints_ ~ [liveTip_]);
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !drawing_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        drawing_ = false;

        Vec3 d = liveTip_ - pathPoints_[$ - 1];
        if (d.x * d.x + d.y * d.y + d.z * d.z > 1e-9f)
            pathPoints_ ~= liveTip_;

        applyPath(pathPoints_);
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // The extruded bands ARE the live preview (mutated directly onto
        // the mesh by applyPath, same law RadialArrayTool uses) — no
        // separate overlay geometry needed.
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (!active) return;
        if (!drawing_)
            ImGui.TextDisabled("Select a polygon, then click-drag in the viewport to draw the extrude path.");
        else
            ImGui.TextDisabled("Drawing path... release to commit.");
    }

private:
    bool[] selectedFaceMask() {
        bool[] m = new bool[](mesh.faces.length);
        bool   any = false;
        foreach (i, b; mesh.selectedFaces) if (b) { m[i] = true; any = true; }
        return any ? m : null;
    }

    Vec3 maskFaceCentroid(in bool[] m) {
        Vec3   sum = Vec3(0, 0, 0);
        size_t n   = 0;
        foreach (fi; 0 .. mesh.faces.length) {
            if (fi >= m.length || !m[fi]) continue;
            sum = sum + mesh.faceCentroid(cast(uint)fi);
            ++n;
        }
        return n > 0 ? sum * (1.0f / cast(float)n) : Vec3(0, 0, 0);
    }

    void applyPath(const(Vec3)[] path) {
        if (!before.filled) return;
        before.restore(*mesh);
        if (path.length < 2 || mask_ is null) {
            built_ = false;
            refreshCaches();
            return;
        }
        size_t n = mesh.extrudeAlongPath(mask_, path, alignToPath_);
        built_ = (n != 0);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null) return;
        if (!before.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before, post, "Stroke Extrude");
        history.record(cmd);
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }

    void cancelLiveEdit() {
        if (before.filled) before.restore(*mesh);
        refreshCaches();
        drawing_ = false;
        built_   = false;
        mask_    = null;
        pathPoints_.length = 0;
    }
}
