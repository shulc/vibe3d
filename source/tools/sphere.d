module tools.sphere;

import tool;
import mesh;
import math;
import params : Param;

import std.math : sin, cos, PI, abs;

// ---------------------------------------------------------------------------
// SphereParams — MODO-aligned wire schema for prim.sphere headless invocation.
//
// Field names match cmdhelptools.cfg <hash type="Tool" key="prim.sphere">
// attribute keys verbatim. Phase 6.2 covers the Globe (UV-sphere) mode only;
// QuadBall and Tesselation come in 6.3 / 6.4.
//
// IMPORTANT: For prim.sphere, sizeX/Y/Z are PER-AXIS RADII (verified against
// modo_cl), not diameters as in prim.cube. MODO labels them "Radius X/Y/Z".
// ---------------------------------------------------------------------------
struct SphereParams {
    int   method = 0;            // 0=globe, 1=qball, 2=tess (only Globe in 6.2)
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 0.5f, sizeY = 0.5f, sizeZ = 0.5f;  // radii; defaults give D=1
    int   sides    = 24;         // longitude segments (Globe)
    int   segments = 24;         // latitude segments (Globe)
    int   axis     = 1;          // X=0, Y=1, Z=2 — pole axis
}

// ---------------------------------------------------------------------------
// buildSphereGlobeAxisY — UV-sphere with poles along Y.
//
// Topology (sides=S, segments=N): south pole + (N-1) latitude rings of S
// verts + north pole = (N-1)*S + 2 verts. S triangles at the south fan,
// (N-2)*S quads in the middle, S triangles at the north fan.
//
// Vertex parametrization (axisY):
//   pole_south  = (0, -sizeY, 0)
//   ring k (k = 0 .. N-2):
//     phi_k = -pi/2 + pi*(k+1)/N
//     for j in 0..S-1, theta_j = 2*pi*j/S:
//       v = (-sizeX * cos(phi) * sin(theta),
//             sizeY * sin(phi),
//            -sizeZ * cos(phi) * cos(theta))
//   pole_north  = (0, +sizeY, 0)
//
// MODO winding (verified):
//   south fan tri:  [ring0[j], pole_south, ring0[(j+1)%S]]
//   middle quad:    [ring_{k+1}[j], ring_k[j], ring_k[(j+1)%S], ring_{k+1}[(j+1)%S]]
//   north fan tri:  [ring_{N-2}[j], ring_{N-2}[(j+1)%S], pole_north]
// ---------------------------------------------------------------------------
private void buildSphereGlobeAxisY(Mesh* dst, const ref SphereParams p)
{
    int S = p.sides;
    int N = p.segments;
    if (S < 3) S = 3;
    if (N < 2) N = 2;

    uint base = cast(uint)dst.vertices.length;

    // South pole (index 0 relative to base).
    dst.addVertex(Vec3(p.cenX, p.cenY - p.sizeY, p.cenZ));

    // Latitude rings.
    foreach (k; 0 .. N - 1) {
        float phi = -PI * 0.5f + PI * cast(float)(k + 1) / cast(float)N;
        float cphi = cos(phi);
        float sphi = sin(phi);
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float ctheta = cos(theta);
            float stheta = sin(theta);
            dst.addVertex(Vec3(
                p.cenX - p.sizeX * cphi * stheta,
                p.cenY + p.sizeY * sphi,
                p.cenZ - p.sizeZ * cphi * ctheta));
        }
    }

    // North pole.
    dst.addVertex(Vec3(p.cenX, p.cenY + p.sizeY, p.cenZ));

    uint southPole = base;
    uint northPole = cast(uint)(base + 1 + (N - 1) * S);

    // Index of vertex j on ring k (k in [0, N-2]).
    uint ringV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return cast(uint)(base + 1 + k * S + jm);
    }

    // South fan.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(0, j), southPole, ringV(0, j + 1)]);
    }

    // Middle quad rings.
    foreach (k; 0 .. N - 2) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);
        }
    }

    // North fan.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(N - 2, j), ringV(N - 2, j + 1), northPole]);
    }
}

// ---------------------------------------------------------------------------
// buildSphereGlobe — dispatch on axis. axisX/axisZ are cyclic permutations
// of the axisY parametrization (verified against modo_cl); both have
// determinant +1 so winding is preserved without face reversal.
//
//   axisY: identity
//   axisX: (x, y, z) → (y, z, x)
//   axisZ: (x, y, z) → (z, x, y)
// ---------------------------------------------------------------------------
void buildSphereGlobe(Mesh* dst, const ref SphereParams p)
{
    if (p.axis == 1) {
        buildSphereGlobeAxisY(dst, p);
        return;
    }

    // Build at origin in axisY frame, then permute and translate.
    SphereParams rp = p;
    rp.cenX = 0; rp.cenY = 0; rp.cenZ = 0;

    Mesh tmp;
    buildSphereGlobeAxisY(&tmp, rp);

    Vec3 center = Vec3(p.cenX, p.cenY, p.cenZ);
    foreach (ref v; tmp.vertices) {
        if (p.axis == 0) {
            // axisX: (x, y, z) → (y, z, x)
            v = Vec3(v.y, v.z, v.x) + center;
        } else {
            // axisZ: (x, y, z) → (z, x, y)
            v = Vec3(v.z, v.x, v.y) + center;
        }
    }

    uint base = cast(uint)dst.vertices.length;
    foreach (v; tmp.vertices) dst.addVertex(v);
    foreach (ref f; tmp.faces) {
        uint[] fi;
        fi.length = f.length;
        foreach (i, vi; f) fi[i] = vi + base;
        dst.addFace(fi);
    }
}

// ---------------------------------------------------------------------------
// SphereTool — phase 6.2 headless-only Create-tool for prim.sphere.
//
// Wire schema matches MODO `prim.sphere` cmdhelptools.cfg. Only `method:globe`
// is implemented in 6.2; qball/tess parametrizations come in 6.3/6.4.
//
// Interactive draw (single-drag center+radius) is not yet implemented —
// this tool is exercised through the headless path (HTTP /api/command and
// modo_diff). Activating it via `tool.set` and tweaking attrs in the panel
// works; the model rebuilds via applyHeadless when invoked.
// ---------------------------------------------------------------------------
class SphereTool : Tool {
private:
    Mesh*         mesh;
    GpuMesh*      gpu;
    SphereParams  params_;

public:
    this(Mesh* mesh, GpuMesh* gpu) {
        this.mesh = mesh;
        this.gpu  = gpu;
    }

    override string name() const { return "Sphere"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.intEnum_("method", "Sphere Mode", &params_.method,
                [IntEnumEntry(0, "globe", "Globe"),
                 IntEnumEntry(1, "qball", "QuadBall"),
                 IntEnumEntry(2, "tess",  "Tesselation")],
                0),
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Radius X",   &params_.sizeX, 0.5f).min(0.0f),
            Param.float_("sizeY", "Radius Y",   &params_.sizeY, 0.5f).min(0.0f),
            Param.float_("sizeZ", "Radius Z",   &params_.sizeZ, 0.5f).min(0.0f),
            Param.int_("sides",    "Sides",    &params_.sides,    24).min(3).max(256),
            Param.int_("segments", "Segments", &params_.segments, 24).min(2).max(256),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override bool applyHeadless() {
        // Only Globe is wired up in 6.2.
        if (params_.method != 0) return false;

        Mesh fresh;
        buildSphereGlobe(&fresh, params_);
        fresh.buildLoops();
        fresh.resetSelection();
        *mesh = fresh;
        gpu.upload(*mesh);
        return true;
    }

    override void drawProperties() {
        // Schema panel handles all widgets.
    }
}
