module tools.cylinder;

import mesh;
import math;
import params : Param;
import shader : LitShader;
import tools.primitive_create_tool : SizedRadialCreateTool;

import std.math : sin, cos, PI, abs, sqrt;

// ---------------------------------------------------------------------------
// CylinderParams — wire schema for prim.cylinder headless invocation.
//
// IMPORTANT: For prim.cylinder, sizeX/Y/Z are PER-AXIS RADII, not
// diameters as in prim.cube. The size along the cylinder's axis is the
// half-height (e.g. axis=Y, sizeY=1.0 → cylinder extends y∈[-1, 1],
// total height 2). They are labelled "Radius X/Y/Z".
// ---------------------------------------------------------------------------
struct CylinderParams {
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 1.0f, sizeY = 1.0f, sizeZ = 1.0f;  // radii (default unit cylinder)
    int   sides    = 24;     // verts per ring (default 24)
    int   segments = 1;      // ring count along axis = segments+1 (default 1)
    int   axis     = 1;      // X=0, Y=1, Z=2 — cylinder's main axis
}

// ---------------------------------------------------------------------------
// buildCylinder — emit a closed cylinder into `dst` with a stable
// vertex layout and winding.
//
// Topology (S = sides, N = segments):
//   verts = (N + 1) * S
//   faces = 2 + N * S  (bottom n-gon cap, side quads, top n-gon cap)
//
// Vertex layout: ring k = 0..N along the cylinder axis, each ring contains S
// verts CCW around the axis.
//   ring 0 at axis = -size_axis  (bottom cap)
//   ring N at axis = +size_axis  (top cap)
//
// Winding (axis=Y, perp axes (B,C)=(Z,X) cyclic):
//   ring vertex j: position[B] = -sizeB * cos(2π·j/S)
//                  position[C] = -sizeC * sin(2π·j/S)
//   bottom cap:    [v0, v(S-1), v(S-2), ..., v1]   (reverse → outward normal -axis)
//   side quad k,j: [ring_{k+1}[j], ring_k[j], ring_k[(j+1)%S], ring_{k+1}[(j+1)%S]]
//   top cap:       [v_{N·S}, v_{N·S+1}, ..., v_{N·S+S-1}]  (forward → outward +axis)
//
// Disk degenerate (size_axis = 0): a single S-gon face, winding so the
// outward normal points along +axis (a flip param would invert it
// but we leave that as a follow-up — not in plan-required cases).
//
// axis=X cycles (A,B,C) = (X,Y,Z); axis=Z cycles (A,B,C) = (Z,X,Y).
// ---------------------------------------------------------------------------
void buildCylinder(Mesh* dst, const ref CylinderParams p)
{
    int S = p.sides;
    int N = p.segments;
    if (S < 3) S = 3;
    if (N < 1) N = 1;

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;

    // (axisIdx, bIdx, cIdx) is a cyclic permutation of (0,1,2):
    //   axis=X (0): (X, Y, Z) — perp axes (Y, Z)
    //   axis=Y (1): (Y, Z, X) — perp axes (Z, X)
    //   axis=Z (2): (Z, X, Y) — perp axes (X, Y)
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen  = [p.cenX, p.cenY, p.cenZ];
    float[3] size = [p.sizeX, p.sizeY, p.sizeZ];

    float halfA = size[axisIdx];
    float radB  = size[bIdx];
    float radC  = size[cIdx];

    // Degenerate-radii guard (task 0315, mirrors buildTube's outerRadius
    // floor): radB/radC are the two perpendicular-to-axis radii. Either
    // landing at exactly 0 (e.g. sizeX=0 or sizeZ=0 for the default
    // axis=Y) collapses every ring vertex's radius-scaled coordinate to 0,
    // so side j and S-j land on identical positions (coincident verts /
    // zero-area degenerate quads). Floor each to a small epsilon,
    // sign-preserving. halfA == 0 is NOT guarded here — it is the
    // intentional, already-clean "disk" degenerate case handled below.
    if (abs(radB) < 1e-4f) radB = (radB < 0.0f) ? -1e-4f : 1e-4f;
    if (abs(radC) < 1e-4f) radC = (radC < 0.0f) ? -1e-4f : 1e-4f;

    bool isDisk = abs(halfA) < 1e-9f;

    uint base = cast(uint)dst.vertices.length;

    // Helper: emit a single ring at axisCoord = aPos.
    void emitRing(float aPos) {
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float bPos = -radB * cos(theta);
            float cPos = -radC * sin(theta);
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + aPos;
            pos[bIdx]    = cen[bIdx]    + bPos;
            pos[cIdx]    = cen[cIdx]    + cPos;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    // Disk: single ring + single face.
    if (isDisk) {
        emitRing(0.0f);
        // Face winding so outward normal points +axis (disk case for
        // axis=Y: face = [0,1,2,3]).
        uint[] cap;
        cap.length = S;
        foreach (j; 0 .. S) cap[j] = base + cast(uint)j;
        dst.addFace(cap);
        return;
    }

    // Full cylinder: emit (N+1) rings bottom-to-top.
    foreach (k; 0 .. N + 1) {
        float t = cast(float)k / cast(float)N;
        float aPos = -halfA + 2.0f * halfA * t;
        emitRing(aPos);
    }

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

    // Side strips, ring k → k+1.
    foreach (k; 0 .. N) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);
        }
    }

    // Top cap: ring N forward → outward normal +axis.
    {
        uint[] cap;
        cap.length = S;
        foreach (j; 0 .. S) cap[j] = ringV(N, cast(int)j);
        dst.addFace(cap);
    }
}

// ---------------------------------------------------------------------------
// CylinderTool — Create-tool for prim.cylinder with two-stage interactive
// draw. Thin subclass of SizedRadialCreateTool!CylinderParams (task 0414,
// 0407 sec A.D2 dedup): the state machine, preview/commit plumbing, mover +
// size-handle rig, and local<->world workplane helpers all live in
// source/tools/primitive_create_tool.d, shared with cone/capsule/sphere
// (whose bodies were code-identical to this one pre-refactor, modulo Param
// labels and the builder function).
//
// Interaction model (see PrimitiveCreateTool/SizedRadialCreateTool!P docs):
//   Idle -- LMB drag on viewport -> DrawingBase (flat ellipse on plane;
//                                    axis = world axis of plane normal)
//   DrawingBase -- LMB up -> BaseSet
//   BaseSet -- LMB drag on viewport -> DrawingHeight (extrudes -> cylinder)
//   DrawingHeight -- LMB up -> HeightSet
// ---------------------------------------------------------------------------
final class CylinderTool : SizedRadialCreateTool!CylinderParams {
public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        super(meshSrc, gpu, litShader);
    }

    override string name() const { return "Cylinder"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Radius X",   &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Radius Y",   &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Radius Z",   &params_.sizeZ, 1.0f).min(0.0f),
            // task 0314: sides/segments feed the ring-vertex loops directly
            // (O(sides*segments)); `.enforceBounds()` makes the declared
            // hint authoritative on the headless JSON path.
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
            ImGui.TextDisabled("Drag again to extrude into a cylinder.");
    }

protected:
    override void buildInto(Mesh* dst) { buildCylinder(dst, params_); }
    override string commitLabel() const { return "Create Cylinder"; }
}
