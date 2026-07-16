module tools.sphere;

import mesh;
import math;
import params : Param;
import shader : LitShader;
import tools.primitive_create_tool : SizedRadialCreateTool;
import tools.create_common : currentWorkplaneFrame;

import std.math : sin, cos, acos, PI, abs, sqrt;

// ---------------------------------------------------------------------------
// SphereParams — wire schema for prim.sphere headless invocation.
//
// Phase 6.2 covers the Globe (UV-sphere) mode only; QuadBall and
// Tesselation come in 6.3 / 6.4.
//
// IMPORTANT: For prim.sphere, sizeX/Y/Z are PER-AXIS RADII, not diameters
// as in prim.cube. They are labelled "Radius X/Y/Z".
// ---------------------------------------------------------------------------
struct SphereParams {
    int   method = 0;            // 0=globe, 1=qball, 2=tess
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 0.5f, sizeY = 0.5f, sizeZ = 0.5f;  // radii; defaults give D=1
    int   sides    = 24;         // longitude segments (Globe)
    int   segments = 24;         // latitude segments (Globe)
    int   axis     = 1;          // X=0, Y=1, Z=2 — pole axis (Globe-only)
    int   order    = 2;          // QuadBall / Tesselation subdivision level
}

// ---------------------------------------------------------------------------
// buildSphereGlobeAxisY — UV-sphere with poles along Y.
//
// Topology (sides=S, segments=N): south pole + (N-1) latitude rings of S
// verts + north pole = (N-1)*S + 2 verts. S triangles at the south fan,
// (N-2)*S quads in the middle, S triangles at the north fan.
//
// Winding:
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

    // Degenerate-radii guard (task 0315, mirrors buildTube's outerRadius
    // floor): sizeX/Y/Z are the per-world-axis ellipsoid radii. Any one
    // landing at exactly 0 (e.g. sizeX=0) zeroes that coordinate for every
    // latitude ring, and since cos(theta) is even, side j and (S-j) then
    // land on identical positions — coincident verts / zero-area
    // degenerate quads. Floor each to a small epsilon, sign-preserving.
    float sx = abs(p.sizeX) < 1e-4f ? (p.sizeX < 0.0f ? -1e-4f : 1e-4f) : p.sizeX;
    float sy = abs(p.sizeY) < 1e-4f ? (p.sizeY < 0.0f ? -1e-4f : 1e-4f) : p.sizeY;
    float sz = abs(p.sizeZ) < 1e-4f ? (p.sizeZ < 0.0f ? -1e-4f : 1e-4f) : p.sizeZ;

    uint base = cast(uint)dst.vertices.length;

    dst.addVertex(Vec3(p.cenX, p.cenY - sy, p.cenZ));   // south pole

    foreach (k; 0 .. N - 1) {
        float phi = -PI * 0.5f + PI * cast(float)(k + 1) / cast(float)N;
        float cphi = cos(phi);
        float sphi = sin(phi);
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float ctheta = cos(theta);
            float stheta = sin(theta);
            dst.addVertex(Vec3(
                p.cenX - sx * cphi * stheta,
                p.cenY + sy * sphi,
                p.cenZ - sz * cphi * ctheta));
        }
    }

    dst.addVertex(Vec3(p.cenX, p.cenY + sy, p.cenZ));   // north pole

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
// of the axisY parametrization; both have determinant +1 so winding is
// preserved without face reversal.
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
// buildSphereQuadBall — cube-sphere primitive (`prim.sphere method:qball`).
//
// Topology: each cube face is subdivided into (order+1)² quads, vertices
// shared on edges and corners. For order >= 1, vertices are projected onto
// the unit sphere via radial normalization; for order == 0 the result is
// just a cube (no projection). The whole mesh is then scaled by an
// order-specific empirical factor and finally by per-axis sizes.
//
// Scale factors (size=1 → max coord magnitude) are NOT derivable from a
// clean closed form so we hardcode them. Order beyond the table
// extrapolates via the last entry.
//
// `axis` does not apply to qball. The mesh is symmetric under cube-axis
// permutation, so no rotation is needed.
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

    // Degenerate-radii guard (task 0315): sizeX/Y/Z are the per-world-axis
    // ellipsoid radii applied as a final per-axis scale below. Any one
    // landing at exactly 0 flattens that whole axis, so every pair of
    // projected points mirrored across it (the cube-sphere/icosphere
    // projections are symmetric under that reflection) lands on identical
    // final positions — coincident verts / zero-area degenerate faces.
    // Floor each to a small epsilon, sign-preserving.
    float sizeX = abs(p.sizeX) < 1e-4f ? (p.sizeX < 0.0f ? -1e-4f : 1e-4f) : p.sizeX;
    float sizeY = abs(p.sizeY) < 1e-4f ? (p.sizeY < 0.0f ? -1e-4f : 1e-4f) : p.sizeY;
    float sizeZ = abs(p.sizeZ) < 1e-4f ? (p.sizeZ < 0.0f ? -1e-4f : 1e-4f) : p.sizeZ;

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
        // Empirical scale + per-axis sizing + center offset.
        pos = Vec3(pos.x * scale * sizeX,
                   pos.y * scale * sizeY,
                   pos.z * scale * sizeZ) + cen;
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
// buildSphereTess — icosphere primitive (`prim.sphere method:tess`).
//
// Topology: each of the 20 icosahedron faces is subdivided into (order+1)²
// triangles via a barycentric grid (linear subdivision, NOT the recursive
// 4-split). All grid points are projected radially onto the unit sphere,
// then scaled per-axis.
//   verts = 10·n² + 20·n + 12
//   faces = 20·(n+1)²
//
// Unlike qball, tess always lands on a unit sphere when size=1 — no
// per-order empirical scaling.
//
// `axis` does not apply to tess (Globe-only); we ignore it.
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

    // Degenerate-radii guard (task 0315): sizeX/Y/Z are the per-world-axis
    // ellipsoid radii applied as a final per-axis scale below. Any one
    // landing at exactly 0 flattens that whole axis; the icosphere's
    // reflective symmetry then maps distinct pre-scale points onto
    // identical final positions — coincident verts / zero-area degenerate
    // faces. Floor each to a small epsilon, sign-preserving.
    float sizeX = abs(p.sizeX) < 1e-4f ? (p.sizeX < 0.0f ? -1e-4f : 1e-4f) : p.sizeX;
    float sizeY = abs(p.sizeY) < 1e-4f ? (p.sizeY < 0.0f ? -1e-4f : 1e-4f) : p.sizeY;
    float sizeZ = abs(p.sizeZ) < 1e-4f ? (p.sizeZ < 0.0f ? -1e-4f : 1e-4f) : p.sizeZ;

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
    // order. (LERP+project for interior clusters interior verts toward the
    // icosa-face centroid, blowing up edge-length ratio to >2× at order=3
    // and >4× at order=5.)
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
                Vec3 pos = Vec3(onSphere.x * sizeX,
                                onSphere.y * sizeY,
                                onSphere.z * sizeZ) + cen;
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
// Thin-ish subclass of SizedRadialCreateTool!SphereParams (task 0414, 0407
// sec A.D2 dedup): the shared 5-stage machine (onMouseButtonDown/Up/Motion),
// preview/commit plumbing, mover + size-handle rig, and local<->world
// workplane helpers all live in source/tools/primitive_create_tool.d. What
// sphere adds on top is real: an ellipsoid axis permutation (worldSize/
// setWorldSize), a globe/qball/tess method dispatch, and a STATE-aware
// buildInto (unlike cylinder/cone/capsule's pure builder call) — the
// documented divergences the task 0414 plan's sec 1a called out.
//
// Wire schema follows the conventional `prim.sphere` attributes.
//
// Interaction model (see PrimitiveCreateTool/SizedRadialCreateTool!P docs):
//   Idle -- LMB drag on viewport -> DrawingBase (flat ellipse on plane)
//   DrawingBase -- LMB up -> BaseSet
//   BaseSet -- LMB drag on viewport -> DrawingHeight (extrudes ellipse -> sphere)
//   DrawingHeight -- LMB up -> HeightSet (sphere finalized)
//
// Headless path (applyHeadless) is a FULL override, NOT routed through the
// state-aware buildInto/appendBuildInto (task 0414 plan sec 1a / PRAVKA 1):
// buildInto's volumetric-vs-flat gate reads live interactive state (`state
// >= DrawingHeight || dragUniform`), which is always false headlessly
// (state == Idle at applyHeadless-call time) -- routing through it would
// silently emit a flat ellipse fan instead of a sphere. applyHeadless calls
// buildByMethod() directly, exactly as it did pre-refactor.
// ---------------------------------------------------------------------------
final class SphereTool : SizedRadialCreateTool!SphereParams {
private:
    // Last params_.axis value seen — used by onParamChanged("axis") to compute
    // the cyclic shift that needs to be undone before applying the new one.
    int  axisAtLastSync = 1;

    // When true, the tool presents as "Ellipsoid": globe-builder locked,
    // `method` and `order` params hidden.  Default false = Sphere.
    bool ellipsoidMode_;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader, bool ellipsoidMode = false) {
        super(meshSrc, gpu, litShader);
        this.ellipsoidMode_ = ellipsoidMode;
    }

    override string name() const { return ellipsoidMode_ ? "Ellipsoid" : "Sphere"; }

    override Param[] params() {
        import params : IntEnumEntry;
        // Ellipsoid mode: globe-locked, method and order hidden.
        if (ellipsoidMode_) {
            return [
                Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
                Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
                Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
                Param.float_("sizeX", "Radius X",   &params_.sizeX, 0.5f).min(0.0f),
                Param.float_("sizeY", "Radius Y",   &params_.sizeY, 0.5f).min(0.0f),
                Param.float_("sizeZ", "Radius Z",   &params_.sizeZ, 0.5f).min(0.0f),
                // task 0314: sides/segments feed the latitude-ring loops
                // directly; `.enforceBounds()` makes the declared hint
                // authoritative on the headless JSON path.
                Param.int_("sides",    "Sides",    &params_.sides,    24).min(3).max(256).enforceBounds(),
                Param.int_("segments", "Segments", &params_.segments, 24).min(2).max(256).enforceBounds(),
                Param.intEnum_("axis", "Axis", &params_.axis,
                    [IntEnumEntry(0, "x", "X"),
                     IntEnumEntry(1, "y", "Y"),
                     IntEnumEntry(2, "z", "Z")],
                    1),
            ];
        }
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
            // task 0314: sides/segments feed the latitude-ring loops
            // directly; `.enforceBounds()` makes the declared hint
            // authoritative on the headless JSON path.
            Param.int_("sides",    "Sides",    &params_.sides,    24).min(3).max(256).enforceBounds(),
            Param.int_("segments", "Segments", &params_.segments, 24).min(2).max(256).enforceBounds(),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
            // task 0314: order drives O(order^2) subdivision (qball/tess);
            // `.enforceBounds()` makes the declared hint authoritative on
            // the headless JSON path.
            Param.int_("order", "Subdivision Level", &params_.order, 2).min(0).max(16).enforceBounds(),
        ];
    }

    override bool paramEnabled(string name) const {
        // sides / segments / axis are Globe-only (axis does not apply to
        // QuadBall and Tesselation methods).
        // order is QuadBall/Tesselation-only.
        if (name == "sides" || name == "segments" || name == "axis")
            return params_.method == 0;
        if (name == "order")
            return params_.method != 0;
        return true;
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
        // params_.axis is already the new value — setWorldSize routes
        // through the new permutation.
        setWorldSize(0, wx);
        setWorldSize(1, wy);
        setWorldSize(2, wz);
        axisAtLastSync = params_.axis;
    }

    // Headless FULL override — see the class doc and task 0414 plan sec 1a.
    override bool applyHeadless() {
        frame = currentWorkplaneFrame();
        size_t firstNewVert = mesh.vertices.length;
        if (!buildByMethod(mesh)) return false;
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (isIdle())
            ImGui.TextDisabled("Drag in viewport to draw a circle.");
        else if (isBaseSet())
            ImGui.TextDisabled("Drag again to extrude into a sphere.");
    }

protected:
    // resetSession() (called from activate()/goIdle() per the base): adds
    // the ellipsoid globe-lock + axisAtLastSync capture on top of
    // HandledCreateTool's sizeDragIdx=-1. Order relative to the base
    // activate()'s other resets (state=Idle / meshChanged=false /
    // moverDragAxis=-1 / toolHandles.clearHaul() / previewGpu.init()) does
    // not matter here -- all are independent field writes; none is read
    // back within the same activate() call.
    override void resetSession() {
        super.resetSession();
        if (ellipsoidMode_) params_.method = 0;
        axisAtLastSync = params_.axis;
    }

    // ---- axis-aware world<->orig radius mapping [worldSize/setWorldSize --
    // -----override, task 0414 plan sec 1] -----------------------------------
    //
    // buildSphereGlobe first builds a sphere in the axisY frame, then
    // permutes coordinates: axis=X sends (x,y,z)->(y,z,x); axis=Z sends
    // (x,y,z)->(z,x,y). So the world extent along world axis i comes from
    // the orig-frame size at index (i + offset) % 3, where offset = 1 / 0 / 2
    // for axis = 0 (X) / 1 (Y) / 2 (Z).
    //
    // Without this mapping the radius handles & drag math (all routed
    // through worldSize/setWorldSize in the shared base) would manipulate
    // sizeX when the user dragged a +X handle, but the sphere's actual
    // world X extent comes from sizeY (axis=X) or sizeZ (axis=Z) —
    // visually the handles ended up "controlling the wrong axis".
    override float worldSize(int worldIdx) const {
        final switch (worldAxisToOrig(worldIdx)) {
            case 0: return params_.sizeX;
            case 1: return params_.sizeY;
            case 2: return params_.sizeZ;
        }
    }

    override void setWorldSize(int worldIdx, float v) {
        float a = abs(v);
        final switch (worldAxisToOrig(worldIdx)) {
            case 0: params_.sizeX = a; break;
            case 1: params_.sizeY = a; break;
            case 2: params_.sizeZ = a; break;
        }
    }

    // First click's axis alignment: sphere's Idle-click keeps params_.axis
    // at its (sticky) value -- auto-rotating it to the construction-plane
    // normal would re-permute sizeX/Y/Z meanings (world X = sizeY for
    // axis=X, etc.), pointing the world-axis handles at the wrong sizes
    // after the sphere is committed.
    override void alignAxisOnFirstClick(Vec3 n) {}

    // DrawingHeight non-uniform (second) drag [task 0414 Phase-0 finding]:
    // unlike the cylinder family's box-style anchored-opposite (center
    // shifts, radius = signedH/2), sphere keeps the center FIXED at
    // baseAnchor and writes the FULL |signedH| as the radius -- the sphere
    // extends +-r above and below the disk plane, symmetric about a fixed
    // center. See tests/test_primitive_sphere_interactive.d's "Two-stage
    // construction drag" unittest for the executable pin of this exact
    // behaviour.
    override void applyNonUniformHeightDrag(Vec3 hit) {
        float signedH = dot(hit - heightDragStart, planeNormal);
        float r = abs(signedH);
        params_.cenX = baseAnchor.x;
        params_.cenY = baseAnchor.y;
        params_.cenZ = baseAnchor.z;
        writeSizeOnAxis(planeNormal, r);
    }

    // STATE-aware buildInto (task 0414 plan sec 1a): volumetric as soon as
    // any normal-axis radius is set AND the gesture has committed to 3D
    // (isVolumetricEligible(): state >= DrawingHeight, or Ctrl-uniform mode
    // kicked in at the first click). Serves BOTH the interactive preview
    // (rebuildPreview, inherited from the base) and the interactive commit
    // (appendBuildInto, likewise inherited) -- at deactivate() time `state`
    // is still live (goIdle() runs AFTER the willCommit()-gated
    // appendBuildInto() call), so this reproduces the pre-refactor
    // commitBase()/commitSphere() split exactly. NEVER used by
    // applyHeadless(), which is a full override precisely to avoid this
    // state-dependence (state == Idle headlessly would always pick the
    // flat-ellipse branch).
    override void buildInto(Mesh* dst) {
        bool volumetric = sizeOnAxis(planeNormal) > 1e-9f && isVolumetricEligible();
        if (volumetric)
            buildByMethod(dst);
        else
            buildEllipseBase(dst, ellipsePreviewSides(), center(),
                             planeAxis1, sizeOnAxis(planeAxis1),
                             planeAxis2, sizeOnAxis(planeAxis2));
    }

    override string commitLabel() const { return "Create Sphere"; }

    // Symmetric radius-handle drag (task 0414 plan sec 1): unlike the
    // cylinder family's anchored-opposite applySizeDelta (half the drag,
    // center shifts, flip-through), sphere grows the radius by the FULL
    // delta with the center fixed and clamps at 0 (no flip).
    override void applySizeDelta(int idx, Vec3 delta) {
        // delta is in WORLD; project onto the world image of the local
        // outward axis to get the scalar size change.
        Vec3 outwardWorld = toWorldD(SIZE_AXES[idx]);
        float d = dot(delta, outwardWorld);
        int worldIdx = idx / 2;
        float r = worldSize(worldIdx) + d;
        if (r < 0.0f) r = 0.0f;
        setWorldSize(worldIdx, r);
        rebuildPreview();
    }

private:
    int worldAxisToOrig(int worldIdx) const {
        return worldAxisToOrigWithAxis(params_.axis, worldIdx);
    }

    static int worldAxisToOrigWithAxis(int axisVal, int worldIdx) {
        if (axisVal == 1) return worldIdx;
        if (axisVal == 0) return (worldIdx + 1) % 3;
        return (worldIdx + 2) % 3;
    }

    // Same as worldSize() but with an explicit axis value — used when the
    // current params_.axis has already been mutated and we need to read
    // extents under the previous orientation.
    float worldRadiusUnderAxis(int axisVal, int worldIdx) const {
        final switch (worldAxisToOrigWithAxis(axisVal, worldIdx)) {
            case 0: return params_.sizeX;
            case 1: return params_.sizeY;
            case 2: return params_.sizeZ;
        }
    }

    // Dispatch to the right generator based on params_.method.
    // Returns false if method is unsupported.
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
}
