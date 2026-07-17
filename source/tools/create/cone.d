module tools.create.cone;

import mesh;
import math;
import params : Param;
import shader : LitShader;
import tools.create.primitive_create_tool : SizedRadialCreateTool;

import std.math : sin, cos, PI, abs, sqrt;

// ---------------------------------------------------------------------------
// ConeParams — wire schema for prim.cone headless invocation.
//
// Same schema as prim.cylinder — sizeX/Y/Z are per-axis half-extents
// (default sizeX=Y=Z=1 → bounds [-1, 1]). The cone tapers linearly along
// its main axis; the cap at the negative end is a full ellipse, the
// positive end is a single apex vertex. Frustum (truncated cone) is not
// supported — no radiusTop parameter.
// ---------------------------------------------------------------------------
struct ConeParams {
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 1.0f, sizeY = 1.0f, sizeZ = 1.0f;
    int   sides    = 24;     // verts per ring (default 24)
    int   segments = 1;      // ring count = segments; +1 apex vertex
    int   axis     = 1;      // X=0, Y=1, Z=2 — main axis (apex on +axis side)
}

// ---------------------------------------------------------------------------
// buildCone — emit a closed cone into `dst` with a stable vertex
// layout and winding.
//
// Topology (S = sides, N = segments):
//   verts = N·S + 1                      (N rings + 1 apex)
//   faces = 1 + N·S                      (cap + (N-1)·S quads + S apex tris)
//
// Vertex layout (axis=Y example):
//   ring k = 0..N-1 at axisCoord = -sizeA + 2·sizeA·(k/N)
//     with linear taper: radius(k) = (1 − k/N) · sizeB,C
//   apex at axisCoord = +sizeA, on the axis line
//
// Winding (axis=Y, perp axes (B,C)=(Z,X) cyclic — same as cylinder):
//   ring vertex j: position[B] = -sizeB·(1 − k/N) · cos(2π·j/S)
//                  position[C] = -sizeC·(1 − k/N) · sin(2π·j/S)
//   bottom cap: [v0, v(S-1), ..., v1]                       outward -axis
//   strip k→k+1 (for k < N-1):
//     [ring(k+1,j), ring(k,j), ring(k,(j+1)%S), ring(k+1,(j+1)%S)]
//   apex fan (k = N-1):
//     [ring(N-1,j), ring(N-1,(j+1)%S), apex]
//
// axis=X cycles (A,B,C)=(X,Y,Z); axis=Z cycles (A,B,C)=(Z,X,Y).
// ---------------------------------------------------------------------------
void buildCone(Mesh* dst, const ref ConeParams p)
{
    int S = p.sides;
    int N = p.segments;
    if (S < 3) S = 3;
    if (N < 1) N = 1;

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen  = [p.cenX, p.cenY, p.cenZ];
    float[3] size = [p.sizeX, p.sizeY, p.sizeZ];

    float halfA = size[axisIdx];
    float radB  = size[bIdx];
    float radC  = size[cIdx];

    // Degenerate-radii guard (task 0315, mirrors buildTube's outerRadius
    // floor): radB/radC are the two perpendicular-to-axis radii — the base
    // ring's ellipse extents. Either landing at exactly 0 (e.g. sizeX=0 or
    // sizeZ=0 for the default axis=Y) collapses that ring's radius-scaled
    // coordinate to 0 for every side vertex, so vertices at side j and S-j
    // land on identical positions (coincident verts / zero-area degenerate
    // triangles). Floor each to a small epsilon, sign-preserving.
    if (abs(radB) < 1e-4f) radB = (radB < 0.0f) ? -1e-4f : 1e-4f;
    if (abs(radC) < 1e-4f) radC = (radC < 0.0f) ? -1e-4f : 1e-4f;

    uint base = cast(uint)dst.vertices.length;

    // Emit a ring at parametric t ∈ [0, 1) along the axis. Radius scales
    // linearly from full at t=0 to 0 at t=1.
    void emitRing(float t) {
        float aPos = -halfA + 2.0f * halfA * t;
        float scale = 1.0f - t;
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float bPos = -radB * scale * cos(theta);
            float cPos = -radC * scale * sin(theta);
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + aPos;
            pos[bIdx]    = cen[bIdx]    + bPos;
            pos[cIdx]    = cen[cIdx]    + cPos;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    foreach (k; 0 .. N) {
        float t = cast(float)k / cast(float)N;
        emitRing(t);
    }

    // Apex vertex on the +axis end.
    {
        float[3] apex;
        apex[axisIdx] = cen[axisIdx] + halfA;
        apex[bIdx]    = cen[bIdx];
        apex[cIdx]    = cen[cIdx];
        dst.addVertex(Vec3(apex[0], apex[1], apex[2]));
    }

    uint apexV = base + cast(uint)(N * S);

    uint ringV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return base + cast(uint)(k * S + jm);
    }

    // Bottom cap: ring 0 reversed → outward normal -axis.
    {
        uint[] cap;
        cap.length = S;
        cap[0] = ringV(0, 0);
        foreach (i; 1 .. S) cap[i] = ringV(0, S - cast(int)i);
        dst.addFace(cap);
    }

    // Quad strips between adjacent rings.
    foreach (k; 0 .. N - 1) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);
        }
    }

    // Apex fan (last ring → apex), all triangles.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(N - 1, j), ringV(N - 1, j + 1), apexV]);
    }
}

// ---------------------------------------------------------------------------
// ConeTool — Create-tool for prim.cone with two-stage interactive draw.
// Thin subclass of SizedRadialCreateTool!ConeParams (task 0414, 0407 sec
// A.D2 dedup) — mirrors CylinderTool exactly (its pre-refactor body was
// code-identical to cylinder.d's, modulo Param labels and the builder
// function): Idle -> DrawingBase (flat ellipse) -> BaseSet -> DrawingHeight
// (extrudes ellipse -> cone) -> HeightSet.
// ---------------------------------------------------------------------------
final class ConeTool : SizedRadialCreateTool!ConeParams {
public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        super(meshSrc, gpu, litShader);
    }

    override string name() const { return "Cone"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Size X",     &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Size Y",     &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Size Z",     &params_.sizeZ, 1.0f).min(0.0f),
            // task 0314: sides/segments feed the ring-vertex loops directly
            // (O(sides*segments)); `.enforceBounds()` makes the declared
            // hint authoritative on the headless JSON path, same fix as
            // prim.cube's segmentsR.
            Param.int_("sides",    "Sides",    &params_.sides,    24).min(3).max(256).enforceBounds(),
            Param.int_("segments", "Segments", &params_.segments, 1 ).min(1).max(256).enforceBounds(),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (isIdle())
            ImGui.TextDisabled("Drag in viewport to draw a base ellipse.");
        else if (isBaseSet())
            ImGui.TextDisabled("Drag again to extrude into a cone.");
    }

protected:
    override void buildInto(Mesh* dst) { buildCone(dst, params_); }
    override string commitLabel() const { return "Create Cone"; }
}
