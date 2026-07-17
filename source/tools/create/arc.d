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

// Reuses the generic snapshot-pair edit factory (same convention as
// CylinderTool / SphereTool).
alias ArcEditFactory = MeshSessionEdit delegate();

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
// Pure module unittests — run under `dub test --config=modeling`.
// ---------------------------------------------------------------------------
unittest { // basic counts and on-circle geometry (axis=Y default)
    import std.math : fabs, sqrt, atan2;

    Mesh m;
    ArcParams p;
    p.radius     = 0.5f;
    p.startAngle = 0.0f;
    p.endAngle   = 180.0f;
    p.segments   = 24;
    p.axis       = 1;
    buildArc(&m, p);

    assert(m.vertices.length == 25,
        "expected 25 verts, got " ~ m.vertices.length.stringof);
    assert(m.edges.length == 24,
        "expected 24 edges, got " ~ m.edges.length.stringof);
    assert(m.faces.length == 0,
        "expected 0 faces, got " ~ m.faces.length.stringof);

    // All verts at radius 0.5 from centre in the bIdx/cIdx plane;
    // axisIdx coord = cen[axis] = 0.
    foreach (v; m.vertices) {
        float[3] vf = [v.x, v.y, v.z];
        assert(fabs(vf[1]) < 1e-5f,
            "vert off axis plane (Y != 0): " ~ vf[1].stringof);
        float r = sqrt(vf[2] * vf[2] + vf[0] * vf[0]);
        assert(fabs(r - 0.5f) < 1e-4f,
            "vert not on radius: " ~ r.stringof);
    }

    // First vert at startAngle=0°, last at endAngle=180°.
    // axis=Y(1) → bIdx=2(Z), cIdx=0(X).
    // At θ=0: bPos=radius*cos(0)=0.5, cPos=radius*sin(0)=0 → Z=0.5, X=0.
    assert(fabs(m.vertices[0].z - 0.5f) < 1e-4f, "first vert b-coord wrong");
    assert(fabs(m.vertices[0].x - 0.0f) < 1e-4f, "first vert c-coord wrong");
    // At θ=180°: bPos=radius*cos(π)=-0.5, cPos=0 → Z=-0.5, X=0.
    assert(fabs(m.vertices[24].z - (-0.5f)) < 1e-4f, "last vert b-coord wrong");
    assert(fabs(m.vertices[24].x - 0.0f)   < 1e-4f, "last vert c-coord wrong");
}

unittest { // segments=1 → 2 verts, 1 edge (minimum)
    Mesh m;
    ArcParams p;
    p.segments   = 1;
    p.radius     = 1.0f;
    p.startAngle = 0.0f;
    p.endAngle   = 90.0f;
    p.axis       = 1;
    buildArc(&m, p);
    assert(m.vertices.length == 2,
        "segments=1: expected 2 verts");
    assert(m.edges.length == 1,
        "segments=1: expected 1 edge");
    assert(m.faces.length == 0,
        "segments=1: expected 0 faces");
}

unittest { // non-Y axis (axis=X and axis=Z keep correct plane coord)
    import std.math : fabs, sqrt;

    foreach (ax; [0, 2]) {
        Mesh m;
        ArcParams p;
        p.radius     = 1.0f;
        p.startAngle = 0.0f;
        p.endAngle   = 180.0f;
        p.segments   = 8;
        p.axis       = ax;
        buildArc(&m, p);
        assert(m.vertices.length == 9,
            "axis=" ~ ax.stringof ~ ": expected 9 verts");
        assert(m.edges.length == 8,
            "axis=" ~ ax.stringof ~ ": expected 8 edges");
        assert(m.faces.length == 0,
            "axis=" ~ ax.stringof ~ ": expected 0 faces");
        // All verts lie on the radius in the perp plane; axis coord = 0.
        foreach (v; m.vertices) {
            float[3] vf = [v.x, v.y, v.z];
            assert(fabs(vf[ax]) < 1e-5f,
                "axis=" ~ ax.stringof ~ ": vert axis coord != 0");
            int bIdx2 = (ax + 1) % 3;
            int cIdx2 = (ax + 2) % 3;
            float r = sqrt(vf[bIdx2] * vf[bIdx2] + vf[cIdx2] * vf[cIdx2]);
            assert(fabs(r - 1.0f) < 1e-4f,
                "axis=" ~ ax.stringof ~ ": vert off unit circle");
        }
    }
}

unittest { // off-centre: every vert has axis coord == cen[axis]
    import std.math : fabs, sqrt;

    Mesh m;
    ArcParams p;
    p.cenX       = 1.0f;
    p.cenY       = 2.0f;
    p.cenZ       = -3.0f;
    p.radius     = 0.5f;
    p.startAngle = 0.0f;
    p.endAngle   = 90.0f;
    p.segments   = 4;
    p.axis       = 1;   // Y is the plane normal; Y coord of all verts = cenY
    buildArc(&m, p);
    foreach (v; m.vertices) {
        import std.math : fabs;
        assert(fabs(v.y - 2.0f) < 1e-5f,
            "off-centre: vert Y != cenY=2, got " ~ v.y.stringof);
        float dx = v.x - 1.0f;
        float dz = v.z - (-3.0f);
        float r = sqrt(dx * dx + dz * dz);
        assert(fabs(r - 0.5f) < 1e-4f,
            "off-centre: vert not on radius=0.5");
    }
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
    CommandHistory history;
    ArcEditFactory factory;

    ArcState       state;
    WorkplaneFrame frame;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
    }

    void destroy() {}

    void setUndoBindings(CommandHistory history, ArcEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

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

    override bool drawImGui() { return false; }

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

    void commitArcEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Arc");
        history.record(cmd);
    }
}
