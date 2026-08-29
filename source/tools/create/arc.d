module tools.create.arc;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import tools.create.create_common : currentWorkplaneFrame, WorkplaneFrame, transformPoint;
import editmode : EditMode;

import std.math : sin, cos, PI;

// ---------------------------------------------------------------------------
// ArcParams — wire schema for prim.arc headless invocation.
//
// An arc is an open polyline on a circle of `radius` spanning the angular
// range [startAngle, endAngle] (degrees), lying in the plane perpendicular
// to `axis`.  Result: segments+1 vertices and segments wire edges.
//
// Axis convention: same cyclic-perp as buildCylinder:
//   bIdx = (axis+1)%3,  cIdx = (axis+2)%3.
// Vertex i's position:
//   θ_i = (startAngle + (endAngle-startAngle)·i/segments) · (π/180)
//   pos[axis] = cen[axis]
//   pos[bIdx] = cen[bIdx] + radius·cos(θ_i)
//   pos[cIdx] = cen[cIdx] + radius·sin(θ_i)
//
// Degenerate: startAngle == endAngle → zero sweep → coincident verts /
// zero-length edges.  Counts still hold; documented, not auto-welded.
// ---------------------------------------------------------------------------
struct ArcParams {
    float cenX       = 0.0f;
    float cenY       = 0.0f;
    float cenZ       = 0.0f;
    float radius     = 0.5f;     // circle radius
    float startAngle = 0.0f;     // degrees
    float endAngle   = 180.0f;   // degrees
    int   segments   = 24;       // edge count; vertices = segments + 1
    int   axis       = 1;        // plane normal: X=0, Y=1, Z=2
}

// ---------------------------------------------------------------------------
// buildArc — emit segments+1 vertices and segments wire edges into `dst`.
//
// The caller is responsible for calling dst.buildLoops() afterwards.
// rebuildEdges() must NOT be called instead — it re-derives edges from
// faces only and would drop every wire edge (mesh.d:4498-4504).
// buildLoops() rebuilds the half-edge maps from the existing edges[] and
// so PRESERVES wire edges (mesh.d:6487-6489).
// ---------------------------------------------------------------------------
void buildArc(Mesh* dst, const ref ArcParams p)
{
    int S = p.segments;
    if (S < 1) S = 1;
    // DoS backstop (task 0365 P1): `segments` allocates S+1 verts + S wire
    // edges; the Param's `.max(1024)` hint is UI-only and does not clamp a
    // direct/scripted caller reaching this kernel.
    enum int MAX_ARC_SEGMENTS = 1024;
    if (S > MAX_ARC_SEGMENTS) S = MAX_ARC_SEGMENTS;

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;

    // Cyclic-perp convention (matches buildCylinder, cylinder.d:87-88):
    //   axis=X(0): perp = (Y, Z)
    //   axis=Y(1): perp = (Z, X)
    //   axis=Z(2): perp = (X, Y)
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen = [p.cenX, p.cenY, p.cenZ];

    uint base = cast(uint)dst.vertices.length;

    // Emit S+1 vertices from startAngle to endAngle (inclusive).
    foreach (i; 0 .. S + 1) {
        float t     = cast(float)i / cast(float)S;
        float theta = (p.startAngle + (p.endAngle - p.startAngle) * t)
                      * (PI / 180.0f);
        float bPos = p.radius * cos(theta);
        float cPos = p.radius * sin(theta);
        float[3] pos;
        pos[axisIdx] = cen[axisIdx];
        pos[bIdx]    = cen[bIdx] + bPos;
        pos[cIdx]    = cen[cIdx] + cPos;
        dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
    }

    // Wire edges — open chain, no closing edge.
    foreach (i; 0 .. S)
        dst.addEdge(base + cast(uint)i, base + cast(uint)(i + 1));
}





// ---------------------------------------------------------------------------
// ArcTool — Create-tool for prim.arc.
//
// Interaction model (minimal single-drag like SphereTool's simple variant):
//   Idle ── LMB click ─→ records click anchor as centre + workplane
//   After first click, drag sets radius (screen distance from anchor)
//   LMB up ─→ commits arc into scene mesh (snapshot undo)
//
// Interactive path is minimal by plan design; the headless path is the
// tested contract.
// ---------------------------------------------------------------------------

private enum ArcState { Idle, Drawing }

class ArcTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*       gpu;
    LitShader      litShader;

    ArcParams      params_;

    ArcState       state;
    WorkplaneFrame frame;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
    }

    void destroy() {}

    override string name() const { return "Arc"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",       "Position X",   &params_.cenX,       0.0f),
            Param.float_("cenY",       "Position Y",   &params_.cenY,       0.0f),
            Param.float_("cenZ",       "Position Z",   &params_.cenZ,       0.0f),
            Param.float_("radius",     "Radius",       &params_.radius,     0.5f).min(0.0f),
            Param.float_("startAngle", "Start Angle",  &params_.startAngle, 0.0f),
            Param.float_("endAngle",   "End Angle",    &params_.endAngle,   180.0f),
            // `.enforceBounds()` matches buildArc's internal
            // `MAX_ARC_SEGMENTS` cap — `.min()/.max()` alone are UI-only
            // hints and do not clamp a raw HTTP write.
            Param.int_("segments",     "Segments",     &params_.segments,   24).min(1).max(1024).enforceBounds(),
            Param.intEnum_("axis",     "Axis",         &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override void activate() {
        state = ArcState.Idle;
    }

    override void deactivate() {
        state = ArcState.Idle;
    }

    override void evaluate() {}

    override bool applyHeadless() {
        frame = currentWorkplaneFrame();
        size_t firstNewVert = mesh.vertices.length;
        buildArc(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (state == ArcState.Idle) {
            state = ArcState.Drawing;
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (state == ArcState.Drawing) {
            // Commit: append arc into scene mesh + record undo.
            if (params_.radius > 1e-6f) {
                MeshSnapshot pre = MeshSnapshot.capture(*mesh);
                frame = currentWorkplaneFrame();
                size_t firstNewVert = mesh.vertices.length;
                buildArc(mesh, params_);
                applyFrameToMeshRange(mesh, firstNewVert);
                mesh.buildLoops();
                gpu.upload(*mesh);
                commitArcEdit(pre);
            }
            state = ArcState.Idle;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {}

    override void drawProperties() {
        import ImGui = d_imgui;
        ImGui.TextDisabled("Set params and click in viewport.");
    }

    // ---- History-coordination hooks ----------------------------------------
    public override bool hasUncommittedEdit() const { return false; }
    public override void cancelUncommittedEdit() { state = ArcState.Idle; }
    public override void resyncSession() { state = ArcState.Idle; }

private:
    void applyFrameToMeshRange(Mesh* m, size_t firstIdx) {
        foreach (i; firstIdx .. m.vertices.length)
            m.vertices[i] = transformPoint(frame.toWorld, m.vertices[i]);
    }

    // Commit trigger is mouse-UP, not a standing edit: `hasUncommittedEdit()`
    // is hard `false` here, so this body is reached from the raw handler and
    // never from the session's apply-and-continue hook. The seam does not move
    // that trigger (task 1905 §2) — only the record.
    void commitArcEdit(MeshSnapshot pre) {
        if (history is null || gestureFactory is null) return;
        if (!pre.filled) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Arc");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }
}
