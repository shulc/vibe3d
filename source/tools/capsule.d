module tools.capsule;

import mesh;
import math;
import params : Param;
import shader : LitShader;
import tools.primitive_create_tool : SizedRadialCreateTool;

import std.math : sin, cos, PI, abs, sqrt;

// ---------------------------------------------------------------------------
// CapsuleParams — wire schema for prim.capsule headless invocation.
//
// sizeX/Y/Z are per-axis radii (labelled "Radius X/Y/Z" in the schema,
// same as prim.cylinder).
//
// `endsize` is a *proportional* parameter: the hemisphere endcap consumes
// `endsize · avgPerp` of the axis length, where
// avgPerp = (sizeB + sizeC) / 2 with B, C the two perpendicular axes.
// Clamped so the hemisphere can't exceed sizeA — when endsize·avgPerp ≥
// sizeA the cylinder section collapses to zero height (sphere-equivalent
// shape; the lower and upper equator rings dedup to a single ring and the
// cylinder strips are skipped).
// ---------------------------------------------------------------------------
struct CapsuleParams {
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 1.0f, sizeY = 1.0f, sizeZ = 1.0f;
    int   sides       = 24;     // verts per ring
    int   segments    = 1;      // cylinder segment count (only matters if cylA > 0)
    int   endsegments = 6;      // hemisphere subdivision (≥ 2)
    float endsize     = 1.0f;   // proportion of avgPerp used as hemisphere height
    int   axis        = 1;      // X=0, Y=1, Z=2 — main axis
}

// ---------------------------------------------------------------------------
// buildCapsule — emit a capsule into `dst` with a stable vertex layout
// and winding.
//
// Topology:
//   south pole + lower hemi intermediates (endsegments-1 rings)
//     + lower equator
//     + cylinder intermediates (segments-1 rings, only if cylA > 0)
//     + upper equator (only if cylA > 0; otherwise lower equator IS shared)
//     + upper hemi intermediates (endsegments-1 rings)
//     + north pole
//
//   ring vertex j (axis-relative, axis=Y example):
//     y = level.aCoord
//     z = -sizeZ · level.radScale · cos(2π·j/S)   [B axis]
//     x = -sizeX · level.radScale · sin(2π·j/S)   [C axis]
//
// Winding (axis=Y):
//   south pole tri: [ring(0,j), pole_south, ring(0,j+1)]   outward -axis
//   ring strip k→k+1: [ring(k+1,j), ring(k,j), ring(k,j+1), ring(k+1,j+1)]
//   north pole tri: [ring(last,j), ring(last,j+1), pole_north]   outward +axis
//
// `axis=X` cycles (A,B,C) = (X,Y,Z); `axis=Z` cycles (A,B,C) = (Z,X,Y).
// ---------------------------------------------------------------------------
void buildCapsule(Mesh* dst, const ref CapsuleParams p)
{
    int S  = p.sides;
    int N  = p.segments;
    int Ne = p.endsegments;
    if (S  < 3) S  = 3;
    if (N  < 1) N  = 1;
    if (Ne < 2) Ne = 2;     // need at least pole + equator

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen  = [p.cenX, p.cenY, p.cenZ];
    float[3] size = [p.sizeX, p.sizeY, p.sizeZ];

    float halfA = abs(size[axisIdx]);
    float radB  = size[bIdx];
    float radC  = size[cIdx];

    // Degenerate-radii guard (task 0315, mirrors buildTube's outerRadius
    // floor): radB/radC are the two perpendicular-to-axis radii. Either
    // landing at exactly 0 (e.g. sizeX=0) collapses every ring vertex's
    // radius-scaled coordinate to 0, so side j and S-j land on identical
    // positions (coincident verts / zero-area degenerate faces). Floor
    // each to a small epsilon, sign-preserving.
    if (abs(radB) < 1e-4f) radB = (radB < 0.0f) ? -1e-4f : 1e-4f;
    if (abs(radC) < 1e-4f) radC = (radC < 0.0f) ? -1e-4f : 1e-4f;

    // Hemisphere axial extent: proportion of the average perpendicular
    // radius, clamped so it can't exceed half the total axis length.
    float avgPerp = (abs(radB) + abs(radC)) * 0.5f;
    float hemH    = abs(p.endsize) * avgPerp;
    if (hemH > halfA) hemH = halfA;
    float cylA = halfA - hemH;

    // Build the list of ring "levels": each (axial coord, radius scale).
    // Equator radii are full size{B,C}; intermediate hemisphere rings scale
    // both perpendicular axes by sin(α).
    struct Level { float aCoord; float radScale; }
    Level[] levels;

    // Lower hemisphere intermediates (k = 1 .. Ne-1; pole at k = 0 is emitted
    // as a single vertex, not part of `levels`).
    foreach (k; 1 .. Ne) {
        float alpha = cast(float)k * (PI * 0.5f) / cast(float)Ne;
        levels ~= Level(-cylA - hemH * cos(alpha), sin(alpha));
    }
    // Lower equator (or shared equator when cylA == 0).
    levels ~= Level(-cylA, 1.0f);
    if (cylA > 1e-9f) {
        // Cylinder intermediate rings + upper equator.
        foreach (m; 1 .. N) {
            float t = cast(float)m / cast(float)N;
            levels ~= Level(-cylA + 2.0f * cylA * t, 1.0f);
        }
        levels ~= Level(+cylA, 1.0f);
    }
    // Upper hemisphere intermediates (mirror of lower, ordered low-α at top).
    foreach (k; 1 .. Ne) {
        int kk = Ne - cast(int)k;
        float alpha = cast(float)kk * (PI * 0.5f) / cast(float)Ne;
        levels ~= Level(+cylA + hemH * cos(alpha), sin(alpha));
    }

    uint base = cast(uint)dst.vertices.length;

    // South pole.
    {
        float[3] pos;
        pos[axisIdx] = cen[axisIdx] - halfA;
        pos[bIdx]    = cen[bIdx];
        pos[cIdx]    = cen[cIdx];
        dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
    }
    uint poleSouth = base;

    // Ring vertices.
    foreach (ref lvl; levels) {
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float aPos = lvl.aCoord;
            float bPos = -radB * lvl.radScale * cos(theta);
            float cPos = -radC * lvl.radScale * sin(theta);
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + aPos;
            pos[bIdx]    = cen[bIdx]    + bPos;
            pos[cIdx]    = cen[cIdx]    + cPos;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    // North pole.
    uint poleNorth = base + 1 + cast(uint)(levels.length * S);
    {
        float[3] pos;
        pos[axisIdx] = cen[axisIdx] + halfA;
        pos[bIdx]    = cen[bIdx];
        pos[cIdx]    = cen[cIdx];
        dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
    }

    // Helper: ring vertex by (level index, side index). Wraps j around S.
    uint ringV(int li, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return base + 1 + cast(uint)(li * S + jm);
    }

    // South pole fan: [ring0(j), pole, ring0(j+1)]  → outward -axis.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(0, j), poleSouth, ringV(0, j + 1)]);
    }

    // Ring strips between adjacent levels.
    foreach (li; 0 .. cast(int)levels.length - 1) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(li + 1, j),
                ringV(li,     j),
                ringV(li,     j + 1),
                ringV(li + 1, j + 1)
            ]);
        }
    }

    // North pole fan: [ringLast(j), ringLast(j+1), pole_north]  → outward +axis.
    int last = cast(int)levels.length - 1;
    foreach (j; 0 .. S) {
        dst.addFace([ringV(last, j), ringV(last, j + 1), poleNorth]);
    }
}

// ---------------------------------------------------------------------------
// CapsuleTool — Create-tool for prim.capsule with two-stage interactive
// draw. Thin subclass of SizedRadialCreateTool!CapsuleParams (task 0414,
// 0407 sec A.D2 dedup) — mirrors CylinderTool/ConeTool exactly (its pre-
// refactor body was code-identical to cylinder.d's, modulo Param labels,
// the +2 endsegments/endsize params, and the builder function): Idle ->
// DrawingBase (flat ellipse) -> BaseSet -> DrawingHeight (extrudes ellipse
// -> capsule) -> HeightSet.
// ---------------------------------------------------------------------------
final class CapsuleTool : SizedRadialCreateTool!CapsuleParams {
public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        super(meshSrc, gpu, litShader);
    }

    override string name() const { return "Capsule"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Radius X",   &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Radius Y",   &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Radius Z",   &params_.sizeZ, 1.0f).min(0.0f),
            // task 0314: sides/segments/endsegments feed the ring-vertex
            // loops directly; `.enforceBounds()` makes the declared hint
            // authoritative on the headless JSON path.
            Param.int_("sides",       "Sides",       &params_.sides,       24).min(3).max(256).enforceBounds(),
            Param.int_("segments",    "Segments",    &params_.segments,    1 ).min(1).max(256).enforceBounds(),
            Param.int_("endsegments", "End Segments",&params_.endsegments, 6 ).min(2).max(64).enforceBounds(),
            Param.float_("endsize",   "End Size",    &params_.endsize,     1.0f).min(0.0f),
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
            ImGui.TextDisabled("Drag again to extrude into a capsule.");
    }

protected:
    override void buildInto(Mesh* dst) { buildCapsule(dst, params_); }
    override string commitLabel() const { return "Create Capsule"; }
}
