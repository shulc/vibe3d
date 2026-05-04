module tools.sphere;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import handler : MoveHandler, BoxHandler, gizmoSize;
import drag : axisDragDelta, planeDragDelta, screenAxisDelta;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import tools.create_common : pickWorkplane, BuildPlane;

import std.math : sin, cos, acos, PI, abs, sqrt;

// Reuses the generic snapshot-pair edit factory used by BoxTool / BevelTool.
alias SphereEditFactory = MeshBevelEdit delegate();

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
    int   method = 0;            // 0=globe, 1=qball, 2=tess
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 0.5f, sizeY = 0.5f, sizeZ = 0.5f;  // radii; defaults give D=1
    int   sides    = 24;         // longitude segments (Globe)
    int   segments = 24;         // latitude segments (Globe)
    int   axis     = 1;          // X=0, Y=1, Z=2 — pole axis (Globe-only in MODO)
    int   order    = 2;          // QuadBall / Tesselation subdivision level
}

// ---------------------------------------------------------------------------
// buildSphereGlobeAxisY — UV-sphere with poles along Y.
//
// Topology (sides=S, segments=N): south pole + (N-1) latitude rings of S
// verts + north pole = (N-1)*S + 2 verts. S triangles at the south fan,
// (N-2)*S quads in the middle, S triangles at the north fan.
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

    dst.addVertex(Vec3(p.cenX, p.cenY - p.sizeY, p.cenZ));   // south pole

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

    dst.addVertex(Vec3(p.cenX, p.cenY + p.sizeY, p.cenZ));   // north pole

    uint southPole = base;
    uint northPole = cast(uint)(base + 1 + (N - 1) * S);

    uint ringV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return cast(uint)(base + 1 + k * S + jm);
    }

    foreach (j; 0 .. S)
        dst.addFace([ringV(0, j), southPole, ringV(0, j + 1)]);

    foreach (k; 0 .. N - 2)
        foreach (j; 0 .. S)
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);

    foreach (j; 0 .. S)
        dst.addFace([ringV(N - 2, j), ringV(N - 2, j + 1), northPole]);
}

// ---------------------------------------------------------------------------
// buildSphereGlobe — dispatch on axis. axisX/axisZ are cyclic permutations
// of the axisY parametrization (verified against modo_cl); both have
// determinant +1 so winding is preserved without face reversal.
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

    SphereParams rp = p;
    rp.cenX = 0; rp.cenY = 0; rp.cenZ = 0;

    Mesh tmp;
    buildSphereGlobeAxisY(&tmp, rp);

    Vec3 center = Vec3(p.cenX, p.cenY, p.cenZ);
    foreach (ref v; tmp.vertices) {
        if (p.axis == 0)
            v = Vec3(v.y, v.z, v.x) + center;
        else
            v = Vec3(v.z, v.x, v.y) + center;
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
// buildSphereQuadBall — cube-sphere primitive (MODO `prim.sphere method:qball`).
//
// Topology: each cube face is subdivided into (order+1)² quads, vertices
// shared on edges and corners. For order >= 1, vertices are projected onto
// the unit sphere via radial normalization; for order == 0 the result is
// just a cube (no projection). The whole mesh is then scaled by an
// order-specific MODO empirical factor and finally by per-axis sizes.
//
// MODO scale factors (size=1 → max coord magnitude). Verified against
// modo_cl — these are NOT derivable from a clean closed form so we
// hardcode them. Order beyond the table extrapolates via the last entry.
//
// `axis` does not apply to qball (MODO refuses `tool.attr axis` while
// method=qball). The mesh is symmetric under cube-axis permutation, so
// no rotation is needed.
// ---------------------------------------------------------------------------
private static immutable float[] QBALL_SCALE = [
    1.30924f, 1.24533f, 1.14025f, 1.08108f,
    1.05485f, 1.03842f, 1.02881f, 1.02249f,
];

void buildSphereQuadBall(Mesh* dst, const ref SphereParams p)
{
    int n = p.order;
    if (n < 0) n = 0;

    int nseg = n + 1;          // segments per cube edge
    int nv1d = n + 2;          // verts along one cube edge

    float scale = (n < cast(int)QBALL_SCALE.length)
        ? QBALL_SCALE[n] : QBALL_SCALE[$ - 1];

    // 6 cube faces. For each: origin (corner i=j=0), u-axis, v-axis.
    // Choose u/v so u × v = outward normal — quads wound [00,10,11,01]
    // then carry the right-handed outward normal automatically.
    static immutable Vec3[3][6] FACES = [
        // +X: origin (1,-1,-1), u=+Y, v=+Z   (Y × Z = +X)
        [Vec3( 1, -1, -1), Vec3(0, 1, 0), Vec3(0, 0, 1)],
        // -X: origin (-1,-1,-1), u=+Z, v=+Y  (Z × Y = -X)
        [Vec3(-1, -1, -1), Vec3(0, 0, 1), Vec3(0, 1, 0)],
        // +Y: origin (-1, 1,-1), u=+Z, v=+X  (Z × X = +Y)
        [Vec3(-1,  1, -1), Vec3(0, 0, 1), Vec3(1, 0, 0)],
        // -Y: origin (-1,-1,-1), u=+X, v=+Z  (X × Z = -Y)
        [Vec3(-1, -1, -1), Vec3(1, 0, 0), Vec3(0, 0, 1)],
        // +Z: origin (-1,-1, 1), u=+X, v=+Y  (X × Y = +Z)
        [Vec3(-1, -1,  1), Vec3(1, 0, 0), Vec3(0, 1, 0)],
        // -Z: origin (-1,-1,-1), u=+Y, v=+X  (Y × X = -Z)
        [Vec3(-1, -1, -1), Vec3(0, 1, 0), Vec3(1, 0, 0)],
    ];

    // Dedupe vertices by quantized cube position (before projection).
    // Shared edges/corners produce identical pre-projection positions
    // across adjacent faces — round to a fine grid to look them up.
    uint[ulong] lookup;
    Vec3 cen = Vec3(p.cenX, p.cenY, p.cenZ);
    enum float QUANT = 1e6f;

    ulong key3(Vec3 q) {
        // Pack (i,j,k) of rounded grid coords into a single 64-bit hash.
        long ix = cast(long)(q.x * QUANT + (q.x >= 0 ? 0.5f : -0.5f));
        long iy = cast(long)(q.y * QUANT + (q.y >= 0 ? 0.5f : -0.5f));
        long iz = cast(long)(q.z * QUANT + (q.z >= 0 ? 0.5f : -0.5f));
        // Mix into a 64-bit hash — simple FNV-style.
        ulong h = 14695981039346656037UL;
        h = (h ^ cast(ulong)ix) * 1099511628211UL;
        h = (h ^ cast(ulong)iy) * 1099511628211UL;
        h = (h ^ cast(ulong)iz) * 1099511628211UL;
        return h;
    }

    uint addOrFind(Vec3 cubePos) {
        ulong k = key3(cubePos);
        if (auto p_idx = k in lookup) return *p_idx;
        // Project to unit sphere (only for order >= 1; order 0 keeps cube).
        Vec3 pos = cubePos;
        if (n >= 1) {
            float r = sqrt(pos.x*pos.x + pos.y*pos.y + pos.z*pos.z);
            if (r > 1e-9f) pos = pos / r;
        }
        // MODO scale + per-axis sizing + center offset.
        pos = Vec3(pos.x * scale * p.sizeX,
                   pos.y * scale * p.sizeY,
                   pos.z * scale * p.sizeZ) + cen;
        uint idx = dst.addVertex(pos);
        lookup[k] = idx;
        return idx;
    }

    foreach (ref face; FACES) {
        Vec3 origin = face[0];
        Vec3 ua     = face[1];
        Vec3 va     = face[2];
        // Pre-fill grid of vertex indices for this face.
        uint[][] grid;
        grid.length = nv1d;
        foreach (i; 0 .. nv1d) {
            grid[i].length = nv1d;
            foreach (j; 0 .. nv1d) {
                float u = 2.0f * cast(float)i / cast(float)nseg;
                float v = 2.0f * cast(float)j / cast(float)nseg;
                Vec3 cubePos = origin + ua * u + va * v;
                grid[i][j] = addOrFind(cubePos);
            }
        }
        // Emit (nseg)² quads. Winding [00,10,11,01] gives outward normal.
        foreach (i; 0 .. nseg)
            foreach (j; 0 .. nseg)
                dst.addFace([grid[i][j], grid[i + 1][j],
                             grid[i + 1][j + 1], grid[i][j + 1]]);
    }
}

// ---------------------------------------------------------------------------
// buildSphereTess — icosphere primitive (MODO `prim.sphere method:tess`).
//
// Topology: each of the 20 icosahedron faces is subdivided into (order+1)²
// triangles via a barycentric grid (NOT the recursive 4-split — MODO uses
// linear subdivision). All grid points are projected radially onto the
// unit sphere, then scaled per-axis.
//   verts = 10·n² + 20·n + 12
//   faces = 20·(n+1)²
//
// Unlike qball, MODO's tess always lands on a unit sphere when size=1 — no
// per-order empirical scaling.
//
// `axis` is rejected by MODO for tess (Globe-only); we ignore it too.
// ---------------------------------------------------------------------------

// 12 icosahedron vertices on the unit sphere, ordered CCW around each pole.
//   v0          : north pole
//   v1..v5      : upper ring at y=+1/√5, theta = 18° + 72°·k
//   v6          : south pole
//   v7..v11     : lower ring at y=-1/√5, theta = 54° + 72°·k
private void icosahedronVerts(out Vec3[12] verts) {
    import std.math : sqrt;
    enum float invSqrt5 = 0.447213595499957939f;   // 1/sqrt(5)
    enum float ringR    = 0.894427190999915878f;   // 2/sqrt(5)
    verts[0] = Vec3(0,  1, 0);
    foreach (k; 0 .. 5) {
        float theta = (18.0f + 72.0f * cast(float)k) * (PI / 180.0f);
        verts[1 + k] = Vec3(ringR * cos(theta), invSqrt5, ringR * sin(theta));
    }
    verts[6] = Vec3(0, -1, 0);
    foreach (k; 0 .. 5) {
        float theta = (54.0f + 72.0f * cast(float)k) * (PI / 180.0f);
        verts[7 + k] = Vec3(ringR * cos(theta), -invSqrt5, ringR * sin(theta));
    }
}

// 20 icosahedron faces, all wound CCW outward.
//   north fan (5 tris)         — apex at v0
//   south fan (5 tris)         — apex at v6
//   belt down-pointing  (5)    — base on upper edge, vertex on lower ring
//   belt up-pointing    (5)    — base on lower edge, vertex on upper ring
private static immutable int[3][20] ICOSA_FACES = [
    // North fan: [upper(k), v0, upper((k+1)%5)]
    [1, 0, 2], [2, 0, 3], [3, 0, 4], [4, 0, 5], [5, 0, 1],
    // South fan: [v6, lower(k), lower((k+1)%5)]
    [6, 7, 8], [6, 8, 9], [6, 9, 10], [6, 10, 11], [6, 11, 7],
    // Belt down-pointing: [upper(k), upper((k+1)%5), lower(k)]
    [1, 2, 7], [2, 3, 8], [3, 4, 9], [4, 5, 10], [5, 1, 11],
    // Belt up-pointing:   [lower(k), upper((k+1)%5), lower((k+1)%5)]
    [7, 2, 8], [8, 3, 9], [9, 4, 10], [10, 5, 11], [11, 1, 7],
];

void buildSphereTess(Mesh* dst, const ref SphereParams p)
{
    int n = p.order;
    if (n < 0) n = 0;
    int S = n + 1;     // subdivisions per edge

    Vec3[12] base;
    icosahedronVerts(base);

    Vec3 cen = Vec3(p.cenX, p.cenY, p.cenZ);

    // Dedupe shared boundary verts. Adjacent base faces produce identical
    // pre-projection interpolated points along their shared edge — collapse
    // them by integer-quantized 3-tuple so the icosphere stays a closed
    // manifold.
    static struct Key3 { long x, y, z; }
    uint[Key3] lookup;
    enum float QUANT = 1e5f;
    Key3 makeKey(Vec3 q) {
        return Key3(
            cast(long)(q.x * QUANT + (q.x >= 0 ? 0.5f : -0.5f)),
            cast(long)(q.y * QUANT + (q.y >= 0 ? 0.5f : -0.5f)),
            cast(long)(q.z * QUANT + (q.z >= 0 ? 0.5f : -0.5f)));
    }

    // SLERP between two unit vectors. Both endpoints assumed unit length.
    Vec3 slerp(Vec3 a, Vec3 b, float t) {
        float d = a.x*b.x + a.y*b.y + a.z*b.z;
        if (d >  1.0f) d =  1.0f;
        if (d < -1.0f) d = -1.0f;
        float omega = acos(d);
        float so    = sin(omega);
        if (so < 1e-6f) return a;
        return a * (sin((1.0f - t) * omega) / so)
             + b * (sin(t * omega) / so);
    }

    // For each base face, generate the (S+1)-row grid and emit S²
    // sub-triangles preserving the base CCW winding. Spherical barycentric
    // subdivision via SLERP-of-SLERP gives near-uniform edge lengths at any
    // order. (LERP+project for interior — MODO's choice — clusters interior
    // verts toward the icosa-face centroid, blowing up edge-length ratio
    // to >2× at order=3 and >4× at order=5.)
    //   row parameter ρ = (i + j) / S       — 0 at V0, 1 along V1-V2 edge
    //   L = SLERP(V0, V1, ρ), R = SLERP(V0, V2, ρ) — endpoints of the row
    //   point at column j: SLERP(L, R, j / (i + j))
    // Adjacent base-faces produce identical points along shared edges
    // because slerp(a, b, t) == slerp(b, a, 1−t).
    foreach (ref face; ICOSA_FACES) {
        Vec3 V0 = base[face[0]];
        Vec3 V1 = base[face[1]];
        Vec3 V2 = base[face[2]];

        uint[][] grid;
        grid.length = S + 1;
        foreach (i; 0 .. S + 1) {
            grid[i].length = S + 1 - i;
            foreach (j; 0 .. S + 1 - i) {
                int k_ = S - i - j;
                Vec3 onSphere;
                if (k_ == S) {
                    onSphere = V0;
                } else {
                    int rowLen = S - k_;       // i + j
                    float rho  = cast(float)rowLen / cast(float)S;
                    Vec3 L = slerp(V0, V1, rho);
                    Vec3 R = slerp(V0, V2, rho);
                    float beta = cast(float)j / cast(float)rowLen;
                    onSphere = slerp(L, R, beta);
                }
                Key3 key = makeKey(onSphere);
                if (auto idx = key in lookup) {
                    grid[i][j] = *idx;
                    continue;
                }
                Vec3 pos = Vec3(onSphere.x * p.sizeX,
                                onSphere.y * p.sizeY,
                                onSphere.z * p.sizeZ) + cen;
                uint vi = dst.addVertex(pos);
                lookup[key] = vi;
                grid[i][j] = vi;
            }
        }

        // Up-pointing sub-triangle for each (i, j) with i+j ≤ S-1.
        // Down-pointing sub-triangle for each (i, j) with i+j ≤ S-2.
        foreach (i; 0 .. S) {
            foreach (j; 0 .. S - i) {
                dst.addFace([grid[i][j], grid[i + 1][j], grid[i][j + 1]]);
                if (i + j < S - 1)
                    dst.addFace([grid[i + 1][j + 1], grid[i][j + 1], grid[i + 1][j]]);
            }
        }
    }
}

// Flat ellipse preview for the DrawingBase phase: a single n-gon centered
// at cen, laid in the plane spanned by axis1/axis2 with explicit per-axis
// radii r1/r2. Caller is responsible for resolving radii from params_
// (taking the axis permutation into account).
private void buildEllipseBase(Mesh* dst, int sides,
                              Vec3 cen,
                              Vec3 axis1, float r1,
                              Vec3 axis2, float r2)
{
    int S = sides;
    if (S < 3) S = 3;

    uint[] ring;
    ring.length = S;
    foreach (j; 0 .. S) {
        float theta = 2.0f * PI * cast(float)j / cast(float)S;
        Vec3 v = cen + axis1 * (r1 * cos(theta))
                     + axis2 * (r2 * sin(theta));
        ring[j] = dst.addVertex(v);
    }
    dst.addFace(ring);
}

// ---------------------------------------------------------------------------
// SphereTool — Create-tool for prim.sphere with two-stage interactive draw.
//
// Wire schema matches MODO `prim.sphere` cmdhelptools.cfg. Only `method:globe`
// is implemented; qball/tess parametrizations come in 6.3/6.4.
//
// Interaction model (mirrors BoxTool):
//   Idle ── LMB drag on viewport ─→ DrawingBase (flat ellipse on plane)
//   DrawingBase ── LMB up ─→ BaseSet
//   BaseSet ── LMB drag on viewport ─→ DrawingHeight (extrudes ellipse → sphere)
//   DrawingHeight ── LMB up ─→ HeightSet (sphere finalized)
//
// During interactive states the actual scene mesh is untouched; only
// previewMesh is rebuilt each frame from params_. The committed sphere
// lands in the scene mesh at deactivate(), wrapped in a snapshot pair
// for undo.
//
// Headless path (applyHeadless) bypasses the state machine and replaces
// the scene mesh directly from current params_.
// ---------------------------------------------------------------------------

private enum SphereState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class SphereTool : Tool {
private:
    Mesh*              mesh;
    GpuMesh*           gpu;
    LitShader          litShader;

    SphereParams       params_;
    CommandHistory     history;
    SphereEditFactory  factory;

    // Last params_.axis value seen — used by onParamChanged("axis") to compute
    // the cyclic shift that needs to be undone before applying the new one.
    int                axisAtLastSync = 1;

    SphereState        state;
    Mesh               previewMesh;
    GpuMesh            previewGpu;
    bool               meshChanged;

    // Construction-plane frame chosen at first click and locked for the
    // whole interaction.
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;

    // Drag anchors — only valid for the matching state(s).
    Vec3 startPoint;       // DrawingBase: first click on plane
    Vec3 currentPoint;     // DrawingBase: current mouse hit on plane
    Vec3 hpOrigin;         // DrawingHeight: ray-plane origin
    Vec3 hpn;              // DrawingHeight: ray-plane normal (camera-facing)
    Vec3 heightDragStart;  // DrawingHeight: world hit at second LMB press
    Vec3 baseAnchor;       // DrawingHeight: sphere center captured at start

    // Sticky modifier captured at LMB-down: Ctrl held at first click forces
    // an equal-radius circle during DrawingBase; Ctrl held at second click
    // forces all three world radii equal during DrawingHeight.
    bool dragUniform;

    Viewport cachedVp;

    // Move gizmo (axis-only).
    MoveHandler mover;
    int         moverDragAxis = -1;
    int         moverLastMX, moverLastMY;

    // Six radius handles on the sphere surface — outward axes:
    //   0:+X  1:-X  2:+Y  3:-Y  4:+Z  5:-Z
    BoxHandler[6] radH;
    int           radDragIdx    = -1;
    int           radHoveredIdx = -1;
    int           radLastMX, radLastMY;

    static immutable Vec3[6] RAD_AXES = [
        Vec3( 1, 0, 0), Vec3(-1, 0, 0),
        Vec3( 0, 1, 0), Vec3( 0,-1, 0),
        Vec3( 0, 0, 1), Vec3( 0, 0,-1),
    ];

public:
    this(Mesh* mesh, GpuMesh* gpu, LitShader litShader) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0, 0, 0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        foreach (i; 0 .. 6) {
            Vec3 col = (i < 2) ? Vec3(0.9f, 0.2f, 0.2f)
                     : (i < 4) ? Vec3(0.2f, 0.9f, 0.2f)
                               : Vec3(0.2f, 0.2f, 0.9f);
            radH[i] = new BoxHandler(Vec3(0, 0, 0), col);
        }
    }

    void destroy() {
        mover.destroy();
        foreach (h; radH) h.destroy();
    }

    void setUndoBindings(CommandHistory history, SphereEditFactory factory) {
        this.history = history;
        this.factory = factory;
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
            Param.int_("order", "Subdivision Level", &params_.order, 2).min(0).max(16),
        ];
    }

    override bool paramEnabled(string name) const {
        // sides / segments / axis are Globe-only (axis is rejected by MODO
        // for QuadBall and Tesselation methods).
        // order is QuadBall/Tesselation-only.
        if (name == "sides" || name == "segments" || name == "axis")
            return params_.method == 0;
        if (name == "order")
            return params_.method != 0;
        return true;
    }

    override void activate() {
        state          = SphereState.Idle;
        meshChanged    = false;
        moverDragAxis  = -1;
        radDragIdx     = -1;
        axisAtLastSync = params_.axis;
        previewGpu.init();
    }

    override void onParamChanged(string name) {
        if (name != "axis") return;
        if (params_.axis == axisAtLastSync) return;

        // Re-permute sizeX/Y/Z so the sphere's WORLD extents along X/Y/Z are
        // unchanged across the axis switch — only the topology orientation
        // (where the poles point) rotates. Without this, the cyclic
        // permutation in buildSphereGlobe would visibly shuffle the radii
        // (sizeX→world Y for axis=Z, etc.).
        int oldAxis = axisAtLastSync;
        // Snapshot old-frame world radii before any writes.
        float wx = worldRadiusUnderAxis(oldAxis, 0);
        float wy = worldRadiusUnderAxis(oldAxis, 1);
        float wz = worldRadiusUnderAxis(oldAxis, 2);
        // params_.axis is already the new value — setWorldRadius routes
        // through the new permutation.
        setWorldRadius(0, wx);
        setWorldRadius(1, wy);
        setWorldRadius(2, wz);
        axisAtLastSync = params_.axis;
    }

    override void deactivate() {
        bool willCommit = (state == SphereState.BaseSet)
                       || (state >= SphereState.DrawingHeight
                           && currentHeight() > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == SphereState.BaseSet)
            commitBase();
        else if (state >= SphereState.DrawingHeight && currentHeight() > 1e-5f)
            commitSphere();
        state = SphereState.Idle;
        previewGpu.destroy();

        if (willCommit) commitSphereEdit(pre);
    }

    override void evaluate() {
        // Slider tweak in the property panel — re-render preview if we have
        // an active interactive state. After commit (HeightSet → deactivate),
        // the scene mesh is the authority and the panel can't tweak further.
        if (state == SphereState.Idle) return;
        rebuildPreview();
    }

    override bool applyHeadless() {
        // Append into the scene mesh (same convention as the interactive
        // commitSphere). Replacing would wipe any geometry the user already
        // has — this hits scripted paths like the Ctrl-click Unit Sphere
        // shortcut where the user expects the new sphere to be added, not
        // to replace the scene.
        if (params_.method == 0)      buildSphereGlobe(mesh, params_);
        else if (params_.method == 1) buildSphereQuadBall(mesh, params_);
        else if (params_.method == 2) buildSphereTess(mesh, params_);
        else                          return false;
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != SphereState.Idle) {
            state = SphereState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        // Alt / Shift remain reserved for camera. Ctrl is consumed by this
        // tool to mean "constrain the drag to a uniform sphere".
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        bool ctrlAtClick = (mods & KMOD_CTRL) != 0;

        // Radius handles take priority once a base/sphere exists.
        if (state >= SphereState.BaseSet) {
            foreach (i; 0 .. 6) {
                if (radH[i].hitTest(e.x, e.y, cachedVp)) {
                    radDragIdx = cast(int)i;
                    radLastMX  = e.x;
                    radLastMY  = e.y;
                    return true;
                }
            }
            int hit = moverHitTest(e.x, e.y);
            if (hit >= 0) {
                moverDragAxis = hit;
                moverLastMX   = e.x;
                moverLastMY   = e.y;
                return true;
            }
        }

        if (state == SphereState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            // Keep params_.axis at its default (Y). Auto-rotating it to the
            // construction-plane normal would re-permute sizeX/Y/Z meanings
            // (world X = sizeY for axis=X, etc.) which makes the world-axis
            // handles point at the wrong sizes after the sphere is committed.
            params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
            // Ctrl at the first click jumps straight into a 3D uniform sphere
            // (center = click point, drag = radius applied to all three world
            // axes), skipping the flat ellipse phase entirely. LMB-up then
            // commits as if the height drag had also completed.
            dragUniform = ctrlAtClick;
            state = SphereState.DrawingBase;
            uploadPreview();
            return true;
        }

        if (state == SphereState.BaseSet) {
            // Ctrl at the second click keeps the existing sphere center and
            // re-drives ALL three world radii from the cursor's distance to
            // that center. Drag in/out grows or shrinks the sphere uniformly;
            // the in-plane ellipse from the first drag is replaced.
            if (ctrlAtClick) {
                baseAnchor = sphereCenter();
                Vec3 hit;
                if (!rayPlaneIntersect(cachedVp.eye,
                                       screenRay(e.x, e.y, cachedVp),
                                       baseAnchor, planeNormal, hit))
                    return false;
                Vec3  d = hit - baseAnchor;
                float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                setWorldRadius(0, r);
                setWorldRadius(1, r);
                setWorldRadius(2, r);
                dragUniform = true;
                state = SphereState.DrawingHeight;
                uploadPreview();
                return true;
            }
            // Plane-normal radius is already 0; second drag adds it.
            setupHeightPlane();
            baseAnchor = sphereCenter();
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            dragUniform = false;
            state = SphereState.DrawingHeight;
            uploadPreview();
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (radDragIdx >= 0)    { radDragIdx = -1;    return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }

        if (state == SphereState.DrawingBase) {
            // Ctrl-uniform mode: the drag fully defined a 3D sphere on its
            // own — reject only zero-radius drags, then jump straight to
            // the finalized state (skip the BaseSet → DrawingHeight stage).
            if (dragUniform) {
                if (!(sizeOnAxis(planeAxis1) > 1e-5f)) {
                    state = SphereState.Idle;
                    return true;
                }
                state = SphereState.HeightSet;
                uploadPreview();
                return true;
            }
            // Normal ellipse-then-extrude flow: reject degenerate ellipses
            // (one radius collapsed) and otherwise wait for the second drag.
            float r1 = sizeOnAxis(planeAxis1);
            float r2 = sizeOnAxis(planeAxis2);
            if (!(r1 > 1e-5f) || !(r2 > 1e-5f)) {
                state = SphereState.Idle;
                return true;
            }
            state = SphereState.BaseSet;
            uploadPreview();
            return true;
        }
        if (state == SphereState.DrawingHeight) {
            state = SphereState.HeightSet;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (radDragIdx >= 0) {
            Vec3 outward = RAD_AXES[radDragIdx];
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, radLastMX, radLastMY,
                                         radH[radDragIdx].pos, outward,
                                         cachedVp, skip);
            if (!skip) applyRadiusDelta(radDragIdx, delta);
            radLastMX = e.x; radLastMY = e.y;
            return true;
        }
        if (moverDragAxis >= 0) {
            bool skip;
            Vec3 delta = moverDragAxis <= 2
                ? axisDragDelta (e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover, cachedVp, skip)
                : planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover.center, cachedVp, skip);
            if (!skip) {
                params_.cenX += delta.x;
                params_.cenY += delta.y;
                params_.cenZ += delta.z;
                rebuildPreview();
            }
            moverLastMX = e.x; moverLastMY = e.y;
            return true;
        }

        if (state == SphereState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                currentPoint = hit;
                if (dragUniform) syncParamsFromUniformDrag();
                else             syncParamsFromBaseDrag();
                uploadPreview();
            }
            return true;
        }
        if (state == SphereState.DrawingHeight) {
            // Ctrl-uniform: project the cursor onto the construction plane
            // through the sphere center; cursor distance from baseAnchor
            // becomes the new radius along all three world axes. Center
            // stays put (Ctrl-second-click never moves it).
            if (dragUniform) {
                Vec3 hit;
                if (rayPlaneIntersect(cachedVp.eye,
                                      screenRay(e.x, e.y, cachedVp),
                                      baseAnchor, planeNormal, hit))
                {
                    Vec3  d = hit - baseAnchor;
                    float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                    params_.cenX = baseAnchor.x;
                    params_.cenY = baseAnchor.y;
                    params_.cenZ = baseAnchor.z;
                    setWorldRadius(0, r);
                    setWorldRadius(1, r);
                    setWorldRadius(2, r);
                    uploadPreview();
                }
                return true;
            }
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                // Sphere center stays at baseAnchor; only the radius along
                // planeNormal grows symmetrically as the user drags. Drag
                // distance projected on normal == radius (sphere extends
                // ±r above and below the disk plane).
                float signedH = dot(hit - heightDragStart, planeNormal);
                float r = abs(signedH);
                params_.cenX = baseAnchor.x;
                params_.cenY = baseAnchor.y;
                params_.cenZ = baseAnchor.z;
                writeSizeOnAxis(planeNormal, r);
                uploadPreview();
            }
            return true;
        }
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == SphereState.Idle) return;

        immutable float[16] identity = identityMatrix;
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

        // Solid faces of preview.
        glUseProgram(litShader.program);
        glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
        glUniform3f(litShader.locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
        glUniform1f(litShader.locAmbient,  0.20f);
        glUniform1f(litShader.locSpecStr,  0.25f);
        glUniform1f(litShader.locSpecPow,  32.0f);
        previewGpu.drawFaces(litShader);

        // Wireframe.
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        previewGpu.drawEdges(shader.locColor, -1, []);

        // Handles only show once base is finalized.
        if (state >= SphereState.BaseSet) {
            updateRadHandlers(vp);
            mover.setPosition(sphereCenter());
            radHoveredIdx = -1;
            bool radBusy = radDragIdx >= 0;
            foreach (i; 0 .. 6) {
                radH[i].setForceHovered(radDragIdx == cast(int)i);
                radH[i].setHoverBlocked(radBusy && radDragIdx != cast(int)i);
                radH[i].draw(shader, vp);
                if (radH[i].isHovered()) radHoveredIdx = cast(int)i;
            }
            mover.arrowX.setForceHovered(moverDragAxis == 0);
            mover.arrowY.setForceHovered(moverDragAxis == 1);
            mover.arrowZ.setForceHovered(moverDragAxis == 2);
            mover.centerBox.setForceHovered(moverDragAxis == 3);
            bool radPriority = radDragIdx >= 0 || radHoveredIdx >= 0;
            mover.arrowX.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 0));
            mover.arrowY.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 1));
            mover.arrowZ.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 2));
            mover.centerBox.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 3));
            mover.draw(shader, vp);
        }
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (state == SphereState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw a circle.");
        else if (state == SphereState.BaseSet)
            ImGui.TextDisabled("Drag again to extrude into a sphere.");
    }

private:
    // -----------------------------------------------------------------------
    // Helpers — params_ is the single source of truth.
    // -----------------------------------------------------------------------

    Vec3 sphereCenter() const { return Vec3(params_.cenX, params_.cenY, params_.cenZ); }

    // ---- axis-aware world↔orig radius mapping ----
    //
    // buildSphereGlobe first builds a sphere in the axisY frame, then
    // permutes coordinates: axis=X sends (x,y,z)→(y,z,x); axis=Z sends
    // (x,y,z)→(z,x,y). So the world extent along world axis i comes from
    // the orig-frame size at index (i + offset) % 3, where offset = 1 / 0 / 2
    // for axis = 0 (X) / 1 (Y) / 2 (Z).
    //
    // Without this mapping the radius handles & drag math would manipulate
    // sizeX when the user dragged a +X handle, but the sphere's actual world
    // X extent comes from sizeY (axis=X) or sizeZ (axis=Z) — visually the
    // handles ended up "controlling the wrong axis".
    int worldAxisToOrig(int worldIdx) const {
        return worldAxisToOrigWithAxis(params_.axis, worldIdx);
    }

    static int worldAxisToOrigWithAxis(int axisVal, int worldIdx) {
        if (axisVal == 1) return worldIdx;
        if (axisVal == 0) return (worldIdx + 1) % 3;
        return (worldIdx + 2) % 3;
    }

    float worldRadius(int worldIdx) const {
        final switch (worldAxisToOrig(worldIdx)) {
            case 0: return params_.sizeX;
            case 1: return params_.sizeY;
            case 2: return params_.sizeZ;
        }
    }

    // Same as worldRadius() but with an explicit axis value — used when the
    // current params_.axis has already been mutated and we need to read
    // extents under the previous orientation.
    float worldRadiusUnderAxis(int axisVal, int worldIdx) const {
        final switch (worldAxisToOrigWithAxis(axisVal, worldIdx)) {
            case 0: return params_.sizeX;
            case 1: return params_.sizeY;
            case 2: return params_.sizeZ;
        }
    }

    void setWorldRadius(int worldIdx, float v) {
        float a = abs(v);
        final switch (worldAxisToOrig(worldIdx)) {
            case 0: params_.sizeX = a; break;
            case 1: params_.sizeY = a; break;
            case 2: params_.sizeZ = a; break;
        }
    }

    static int worldAxisIdxOf(Vec3 v) {
        if (abs(v.x) > 0.5f) return 0;
        if (abs(v.y) > 0.5f) return 1;
        return 2;
    }

    float sizeOnAxis(Vec3 axisVec) const {
        return worldRadius(worldAxisIdxOf(axisVec));
    }

    void writeSizeOnAxis(Vec3 axisVec, float radius) {
        setWorldRadius(worldAxisIdxOf(axisVec), radius);
    }

    float currentHeight() const { return sizeOnAxis(planeNormal) * 2.0f; }

    void choosePlane(const ref Viewport vp) {
        auto bp = pickWorkplane(vp);
        planeNormal = bp.normal;
        planeAxis1  = bp.axis1;
        planeAxis2  = bp.axis2;
    }

    // Update params_ from startPoint/currentPoint while drawing the base.
    // First click anchors the sphere center; the cursor traces a point on
    // the ellipse perimeter, so each in-plane radius equals the absolute
    // projection of the drag onto that plane axis (no /2). Plane-normal
    // radius stays 0 (flat ellipse).
    void syncParamsFromBaseDrag() {
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
        writeSizeOnAxis(planeAxis1, abs(d1));
        writeSizeOnAxis(planeAxis2, abs(d2));
    }

    // Ctrl-at-first-click shortcut: center stays at the click point, and the
    // distance from start to current on the construction plane becomes the
    // radius along all three world axes — fully volumetric uniform sphere
    // in one drag.
    void syncParamsFromUniformDrag() {
        Vec3  d = currentPoint - startPoint;
        float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        setWorldRadius(0, r);
        setWorldRadius(1, r);
        setWorldRadius(2, r);
    }

    void setupHeightPlane() {
        hpOrigin = sphereCenter();
        Vec3 toCamera = cachedVp.eye - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    void rebuildPreview() {
        previewMesh.clear();
        // Volumetric preview as soon as any normal-axis radius is set, OR
        // when Ctrl-uniform mode kicked in at the first click (in which
        // case all three radii are equal and the sphere is 3D from frame 1).
        bool volumetric = sizeOnAxis(planeNormal) > 1e-9f
                       && (state >= SphereState.DrawingHeight || dragUniform);
        if (volumetric)
            buildByMethod(&previewMesh);
        else
            buildEllipseBase(&previewMesh, ellipsePreviewSides(), sphereCenter(),
                             planeAxis1, sizeOnAxis(planeAxis1),
                             planeAxis2, sizeOnAxis(planeAxis2));
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    // Both commit helpers APPEND into the scene mesh — same convention as
    // BoxTool.commitBase / commitCuboid. Replacing would wipe any existing
    // geometry the user already built.
    void commitBase() {
        buildEllipseBase(mesh, ellipsePreviewSides(), sphereCenter(),
                         planeAxis1, sizeOnAxis(planeAxis1),
                         planeAxis2, sizeOnAxis(planeAxis2));
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitSphere() {
        buildByMethod(mesh);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    // Dispatch to the right generator based on params_.method.
    // Returns false if method is unsupported (e.g. Tesselation in 6.3 phase).
    bool buildByMethod(Mesh* dst) {
        switch (params_.method) {
            case 0: buildSphereGlobe(dst, params_);    return true;
            case 1: buildSphereQuadBall(dst, params_); return true;
            case 2: buildSphereTess(dst, params_);     return true;
            default:                                   return false;
        }
    }

    // Sides count for the flat ellipse preview. Globe uses `sides`; QuadBall /
    // Tesselation don't have an analogous concept, so just pick a reasonable
    // default.
    int ellipsePreviewSides() const {
        if (params_.method == 0) return params_.sides;
        return 24;
    }

    void commitSphereEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Sphere");
        history.record(cmd);
    }

    void updateRadHandlers(const ref Viewport vp) {
        Vec3 cen = sphereCenter();
        float rx = worldRadius(0);
        float ry = worldRadius(1);
        float rz = worldRadius(2);
        Vec3[6] pts = [
            cen + Vec3( rx, 0, 0), cen + Vec3(-rx, 0, 0),
            cen + Vec3(0,  ry, 0), cen + Vec3(0, -ry, 0),
            cen + Vec3(0, 0,  rz), cen + Vec3(0, 0, -rz),
        ];
        foreach (i; 0 .. 6) {
            radH[i].pos  = pts[i];
            radH[i].size = gizmoSize(pts[i], vp, 0.04f);
        }
    }

    void applyRadiusDelta(int idx, Vec3 delta) {
        Vec3 axisDir = RAD_AXES[idx];
        float d = delta.x * axisDir.x + delta.y * axisDir.y + delta.z * axisDir.z;
        int worldIdx = idx / 2;
        float r = worldRadius(worldIdx) + d;
        if (r < 0.0f) r = 0.0f;
        setWorldRadius(worldIdx, r);
        rebuildPreview();
    }

    int moverHitTest(int mx, int my) {
        import handler : Arrow;
        if (mover.centerBox.hitTest(mx, my, cachedVp)) return 3;
        Arrow[3] arrows = [mover.arrowX, mover.arrowY, mover.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, cachedVp, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedVp, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }
}
