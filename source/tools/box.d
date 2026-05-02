module tools.box;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import mesh;
import math;
import handler : MoveHandler, BoxHandler, getGizmoScreenFraction, gizmoSize;
import drag;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import tools.create_common : pickMostFacingPlane, BuildPlane;
import params : Param;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.math : abs, sqrt, sin, cos, PI;

// Reuses the BevelTool factory type — both tools record a generic
// (pre, post) MeshSnapshot pair via MeshBevelEdit, just with a different
// label. The class is bevel-named for legacy reasons; rename once a third
// caller appears.
alias BoxEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// BoxParams — MODO-aligned wire schema for prim.cube headless invocation.
//
// Field names match cmdhelptools.cfg <hash type="Tool" key="prim.cube">
// attribute keys verbatim. Phase 6.1a covers 9 core attrs; rounded
// edges (radius/segmentsR/sharp/axis), min/max alternative spec, patch
// (subpatch), and flip (plane normal) are added in 6.1b-e.
// ---------------------------------------------------------------------------
struct BoxParams {
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 1.0f, sizeY = 1.0f, sizeZ = 1.0f;
    int   segmentsX = 1, segmentsY = 1, segmentsZ = 1;

    // Phase 6.1b: rounded-edge attrs (MODO prim.cube wire schema).
    float radius    = 0.0f;  // 0 = sharp; positive = rounded edges
    int   segmentsR = 3;     // corner subdivision count (MODO default 3)
    bool  sharp     = false; // Phase 6.1c: sharp edge rings (MODO prim.cube parity)
    int   axis      = 1;     // X=0, Y=1, Z=2 — primary axis for rounded caps
}

// ---------------------------------------------------------------------------
// buildRoundedCubeAxisY — generate a rounded-cube for axis=Y (primary axis).
//
// Phase 6.1c: now honours segmentsX/Y/Z for face-panel and chamfer-length
// subdivision (MODO prim.cube parity verified bit-for-bit for all table cases).
//
// Vertex layout overview (n = segmentsR, nx/ny/nz = segmentsX/Y/Z):
//
//   Bottom cap  ((nx+1)*(nz+1) verts at y = -halfY):
//     Full 2D grid in XZ spanning [-innerX..+innerX] x [-innerZ..+innerZ].
//
//   2*n corner rings + (ny-1) flat Y-subdivision rings:
//     ring_size = 2*(nx+1) + 2*(nz+1) + 4*(n-1)
//     Bottom corner rings: k=1..n at phi = k/n * pi/2, sy=-1
//     Flat rings: j=1..ny-1 at y = -innerY + 2*innerY*j/ny, phi=pi/2
//     Top corner rings: k=n..1 (built outer-to-inner for monotonic vertex indices)
//
//   Top cap ((nx+1)*(nz+1) verts at y = +halfY).
//
//   Total verts = 2*(nx+1)*(nz+1) + (2*n + ny-1) * ring_size
//   Total faces = 2*nx*nz  (caps)
//               + 8*n*(ring_size)  (half-sphere transitions and adjacent rings: approx)
//               + (ny-1+1)*ring_size  (equatorial strips)
//
// Ring layout (CCW from -Y for sy=-1):
//   sec -Z: (nx+1) verts, x from -innerX to +innerX, z=-halfZ
//   c1 arc: (n-1) interior verts
//   sec +X: (nz+1) verts, z from -innerZ to +innerZ, x=+halfX
//   c2 arc: (n-1) interior verts (reversed theta)
//   sec +Z: (nx+1) verts, x from +innerX to -innerX (reversed), z=+halfZ
//   c3 arc: (n-1) interior verts
//   sec -X: (nz+1) verts, z from +innerZ to -innerZ (reversed), x=-halfX
//   c0 arc: (n-1) interior verts (reversed)
//
// (Verified bit-for-bit against MODO 9 for n=1..4, nx/ny/nz=1..3.)
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// buildRoundedCubeAxisY_sharp — sharp variant of buildRoundedCubeAxisY.
//
// Phase 6.1c.  MODO parity verified bit-for-bit for segmentsR=1..3.
//
// Sharp mode adds sharpening geometry so subdivision (Catmull-Clark) does
// not soften the flat face panels.  Compared to non-sharp:
//
//   ring_size_sharp  = 2*(nx+1) + 2*(nz+1) + 4*(n+1)   (2 extra verts per arc)
//   rings_per_half   = n+2  (cap_sharp + n companions + equatorial)
//
// K-value table (empirically derived from MODO 9 probes, sR=1..3):
//   sR=1: K = [0.48881]
//   sR=2: K = [0.81018, 0.35192]
//   sR=3: K = [0.90286, 0.63746, 0.27493]
//
// For sR>3 sharp falls back to non-sharp (no K table entry).
//
// Ring structure (bottom half, outer-to-inner from cap):
//   1. cap_sharp ring      at y=-hy,          sections at z=±(iz+rK_last), x=±(ix+rK_last)
//   2..n+1. companion c    at y=-(iy+K[c]*r), sections at z=±(iz+rK_sec), x=±(ix+rK_sec)
//            where K_sec_c = K[n-2-c] (K[-1] = 1 = full face)
//   n+2. equatorial ring   at y=-iy,           sections at z=±hz,          x=±hx
//
// Arc verts (n+1 per corner, in all sharp rings):
//   For arc from (+ix, y_ring, -(iz+rK_sec)) to (+(ix+rK_sec), y_ring, -iz):
//     vert k: x=ix + rK_sec*g[k-1],  z = -(iz + rK_sec*g[n+1-k])
//   where g = [1, K[0], K[1], ..., K[n-1]]  (length n+1)
//   (The equatorial ring uses K_sec=1 so rK_sec=r, giving full face boundaries.)
// ---------------------------------------------------------------------------
private void buildRoundedCubeAxisY_sharp(Mesh* dst, const ref BoxParams p)
{
    import std.conv : to;
    import std.typecons : Tuple, tuple;

    int   n  = p.segmentsR < 1 ? 1 : p.segmentsR;
    int   nx = p.segmentsX < 1 ? 1 : p.segmentsX;
    int   ny = p.segmentsY < 1 ? 1 : p.segmentsY;
    int   nz = p.segmentsZ < 1 ? 1 : p.segmentsZ;
    float r  = abs(p.radius);
    float hx = p.sizeX * 0.5f;
    float hy = p.sizeY * 0.5f;
    float hz = p.sizeZ * 0.5f;
    float ix = hx - r;
    float iy = hy - r;
    float iz = hz - r;
    Vec3  cen = Vec3(p.cenX, p.cenY, p.cenZ);

    // K table: K[0..n-1] outer-to-inner.  Only defined for n=1..3.
    // For n>3 this function is not called (caller falls back to non-sharp).
    static immutable float[1] K1 = [0.48881f];
    static immutable float[2] K2 = [0.81018f, 0.35192f];
    static immutable float[3] K3 = [0.90286f, 0.63746f, 0.27493f];
    const(float)[] K;
    final switch (n) {
        case 1: K = K1[]; break;
        case 2: K = K2[]; break;
        case 3: K = K3[]; break;
    }
    float K_last = K[n - 1];   // K[n-1] = innermost K

    // g[j] = 1.0 for j=0, K[j-1] for j=1..n  (length n+1)
    float[] g;
    g.length = n + 1;
    g[0] = 1.0f;
    foreach (j; 1 .. n + 1) g[j] = K[j - 1];

    // K_section_c for companion ring c (c=0..n-1, outer-to-inner):
    //   K_section_c = K[n-2-c]  with K[-1]=1.0
    float kSec(int c) {
        int idx = n - 2 - c;
        return (idx < 0) ? 1.0f : K[idx];
    }

    // Sharp ring size:  2*(nx+1) + 2*(nz+1) + 4*(n+1)
    int rs = 2 * (nx + 1) + 2 * (nz + 1) + 4 * (n + 1);

    // Section start offsets within a sharp ring.
    // Layout: -Z(nx+1), c1arc(n+1), +X(nz+1), c2arc(n+1), +Z(nx+1), c3arc(n+1), -X(nz+1), c0arc(n+1)
    int[4] off_sec;
    off_sec[0] = 0;
    off_sec[1] = nx + 1 + (n + 1);
    off_sec[2] = off_sec[1] + nz + 1 + (n + 1);
    off_sec[3] = off_sec[2] + nx + 1 + (n + 1);

    // Deduplication map: canonical position -> mesh vertex id.
    uint[Tuple!(float,float,float)] vmap;

    uint addV(float x, float y, float z) {
        import std.math : round;
        float kx = round(x * 1_000_000.0f) / 1_000_000.0f;
        float ky = round(y * 1_000_000.0f) / 1_000_000.0f;
        float kz = round(z * 1_000_000.0f) / 1_000_000.0f;
        auto key = tuple(kx, ky, kz);
        if (auto pp = key in vmap) return *pp;
        uint id = dst.addVertex(Vec3(cen.x + x, cen.y + y, cen.z + z));
        vmap[key] = id;
        return id;
    }

    // Build one sharp ring at y=y_ring with section half-extents xSec, zSec.
    // xSec = ix + r*kSec  (x face boundary), zSec = iz + r*kSec  (z face boundary).
    // Arc verts use the unified formula: rK_sec * g[j], using kSec_r = r*kSec_val.
    uint[] buildSharpRing(float y_ring, float xSec, float zSec, float kSec_r) {
        uint[] ring;
        ring.reserve(rs);

        // Section start corners (CW in XZ, same layout as non-sharp):
        //   c0=(-1,-1), c1=(+1,-1), c2=(+1,+1), c3=(-1,+1)
        static immutable int[2][4] cxz = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
        static immutable int[4] sec_useX = [1, 0, 1, 0]; // 1=X section (nx+1 verts), 0=Z section

        foreach (sec; 0 .. 4) {
            int sx0 = cxz[sec][0],       sz0 = cxz[sec][1];
            int sx1 = cxz[(sec+1)&3][0], sz1 = cxz[(sec+1)&3][1];
            int segs = (sec_useX[sec] == 1) ? nx : nz;

            // Face section verts: t=0..segs
            // sec 0(-Z): x from -ix to +ix at z=-zSec
            // sec 1(+X): z from -iz to +iz at x=+xSec
            // sec 2(+Z): x from +ix to -ix at z=+zSec
            // sec 3(-X): z from +iz to -iz at x=-xSec
            foreach (t; 0 .. segs + 1) {
                float ft = cast(float)t / cast(float)segs;
                float x, z;
                switch (sec) {
                    case 0: x = -ix + 2.0f * ix * ft; z = -zSec; break;
                    case 1: x = +xSec;                 z = -iz + 2.0f * iz * ft; break;
                    case 2: x = ix - 2.0f * ix * ft;   z = +zSec; break;
                    default: x = -xSec;                z = iz - 2.0f * iz * ft; break;
                }
                ring ~= addV(x, y_ring, z);
            }

            // Arc verts: n+1 interior verts between this section's last vert and
            // the next section's first vert.
            // Arc c1 (sec 0→sec 1): from (+ix, y_ring, -zSec) → (+(ix+kSec_r), y_ring, -iz)
            //   vert k (k=0..n): x_off = kSec_r*g[k], z_off = kSec_r*g[n-k]
            // Arc c2 (sec 1→sec 2): from (xSec, y_ring, +iz) → (+ix, y_ring, +zSec)
            // Arc c3 (sec 2→sec 3): from (-ix, y_ring, +zSec) → (-xSec, y_ring, +iz)
            // Arc c0 (sec 3→sec 0): from (-xSec, y_ring, -iz) → (-ix, y_ring, -zSec)
            //
            // Generalised arc (for sx1, sz1):
            //   goes from (sx1*ix, y_ring, sz1*(iz+kSec_r))  [end of z-parallel section]
            //          to (sx1*(ix+kSec_r), y_ring, sz1*iz)  [start of x-parallel section]
            // For sec 0→1 (sx1=+1, sz1=-1): from (+ix, y_ring, -zSec) to (+xSec, y_ring, -iz)
            //   vert k: x = ix + kSec_r*g[k],  z = -(iz + kSec_r*g[n-k])
            // For sec 1→2 (sx1=+1, sz1=+1): from (+xSec, y_ring, +iz) to (+ix, y_ring, +zSec)
            //   vert k: x = ix + kSec_r*g[n-k],  z = +(iz + kSec_r*g[k])
            //   (x and z roles swap because +Z section is "x-parallel")
            //   Actually: going FROM +X section end to +Z section start:
            //   x decreases from xSec to ix, z increases from iz to zSec.
            //   So: x = sx1*(ix + kSec_r*g[n-k]),  z = sz1*(iz + kSec_r*g[k])
            // For sec 0→1 (sx1=+1, sz1=-1):
            //   x = +1*(ix + kSec_r*g[k]),  z = -1*(iz + kSec_r*g[n-k])  ✓ (x increases, z decreases in magnitude)
            // Unified: vert k (k=0..n, emitted for k=0..n NOT including section endpoints):
            //   x = sx1*(ix + kSec_r*g[k])
            //   z = sz1*(iz + kSec_r*g[n-k])
            // But we need to be careful: k=0 gives x=sx1*(ix+kSec_r*g[0])=sx1*(ix+kSec_r)=sx1*xSec
            //   which is the +X section's first vert — we DON'T want to emit it (it's a section endpoint).
            // Similarly k=n gives x=sx1*(ix+kSec_r*g[n])=sx1*(ix+kSec_r*K_last) and
            //   z=sz1*(iz+kSec_r*g[0])=sz1*zSec which is the last vert of the previous section — don't emit.
            // So arc interior verts: k=0..n (but k=0 is section0 endpoint shared below, skip!)
            // Actually: the section already emitted its last vert. The next section will emit its first vert.
            // The arc emits the N+1 INTERMEDIATE verts that are NOT section endpoints.
            // But wait: the formula with k=0..n gives n+1 verts where k=0 = next_section_start and k=n = prev_section_end?
            // Let me re-derive from the probe:
            // sec 0 ends at (+ix, y, -zSec).  Arc has n+1 verts.  sec 1 starts at (+xSec, y, -iz).
            // For n=1, k=0..0 (1 arc vert). From probe:
            //   k=0: x=ix+kSec_r*g[0]=ix+kSec_r, z=-(iz+kSec_r*g[1])=-(iz+kSec_r*K_last)
            //   That's (+xSec, y, -(iz+kSec_r*K_last)).  From n=1 r_vary probe: v6 has x=ix+rK,z=-(iz+rK^2)✓
            // For n=1: arc emits k=0..0 = 1 vert with x=xSec, z=-(iz+rK_last*kSec_r).
            //   But xSec=ix+kSec_r and kSec_r=r*kSec_val. For equatorial kSec_val=1: xSec=hx, kSec_r=r.
            //   k=0: x=hx, z=-(iz+r*K_last).  That's (hx, y, -(iz+rK_last)).  ✓
            // For n=1 arc: 1 interior vert k=0..0. Wait: I showed earlier n=1 has n+1=2 arc verts!
            // Contradiction: let me recheck rs: rs = 2*(nx+1)+2*(nz+1)+4*(n+1) for n=1, nx=nz=1:
            // = 4+4+8=16. Sections: 4*2=8. Arcs: 4*(n+1)=8. Total=16 ✓. So each arc has n+1=2 verts.
            // So arc emits k=0..n (n+1 verts). For n=1 arc emits k=0 and k=1.
            // k=0: x=sx1*(ix+kSec_r*g[0])=sx1*(ix+kSec_r)=sx1*xSec, z=sz1*(iz+kSec_r*g[1])=sz1*(iz+kSec_r*K_last)
            // k=1: x=sx1*(ix+kSec_r*g[1])=sx1*(ix+kSec_r*K_last), z=sz1*(iz+kSec_r*g[0])=sz1*zSec
            // For c1 arc (sx1=+1, sz1=-1): k=0: (+xSec, y, -(iz+kSec_r*K_last))✓; k=1: (ix+kSec_r*K_last, y, -zSec)✓
            // This matches the probe! ✓
            //
            // For sec 2→3 (sx1=-1, sz1=+1): from (-ix, y, +zSec) to (-xSec, y, +iz):
            //   x decreases from -ix to -xSec, z decreases from zSec to iz.
            //   k=0: x=-1*(ix+kSec_r*g[0])=-xSec, z=+1*(iz+kSec_r*g[n])=iz+kSec_r*K_last.  ← going backward!
            //   Need to reverse: emit k=n downto k=0 for backward arcs (sec 1→2 and sec 3→0).
            // Actually let me check: sec 0→1 (c1) and sec 2→3 (c3) go "forward" (x or z INCREASING toward next corner).
            // sec 1→2 (c2) and sec 3→0 (c0) go "backward" (need reversed arc).
            // From non-sharp code: arc_forward = (sec == 0 || sec == 2).

            bool arc_fwd = (sec == 0 || sec == 2);
            if (arc_fwd) {
                foreach (k; 0 .. n + 1) {
                    float xo = sx1 * (ix + kSec_r * g[n - k]);
                    float zo = sz1 * (iz + kSec_r * g[k]);
                    ring ~= addV(xo, y_ring, zo);
                }
            } else {
                for (int k = n; k >= 0; --k) {
                    float xo = sx1 * (ix + kSec_r * g[n - k]);
                    float zo = sz1 * (iz + kSec_r * g[k]);
                    ring ~= addV(xo, y_ring, zo);
                }
            }
        }

        assert(ring.length == rs,
               "sharp ring length " ~ to!string(ring.length) ~ " != expected " ~ to!string(rs));
        return ring;
    }

    // -----------------------------------------------------------------------
    // Caps: (nx+1)*(nz+1) grid at y = ±hy.
    // -----------------------------------------------------------------------
    int capSize = (nx + 1) * (nz + 1);
    uint[] capBot = new uint[capSize];
    uint[] capTop = new uint[capSize];
    for (int j = 0; j <= nz; ++j) {
        float zj = (nz == 0) ? 0.0f : (-iz + 2.0f * iz * (cast(float)j / nz));
        for (int i = 0; i <= nx; ++i) {
            float xi = (nx == 0) ? 0.0f : (-ix + 2.0f * ix * (cast(float)i / nx));
            capBot[i + j * (nx + 1)] = addV(xi, -hy, zj);
            capTop[i + j * (nx + 1)] = addV(xi, +hy, zj);
        }
    }

    // -----------------------------------------------------------------------
    // Build all rings for bottom half (outer-to-inner from cap = cap_sharp first).
    // For bottom half, rings[0] is cap_sharp, rings[1..n] are companions, rings[n+1] is equatorial.
    // For top half, rings[n+1] is equatorial (shared), rings[n+2..2n+1] are companions (reversed),
    // rings[2n+2] is cap_sharp_top.
    // -----------------------------------------------------------------------
    uint[][] allBot;  // n+2 rings for bottom half (cap_sharp, companions, equatorial)
    uint[][] allTop;  // n+2 rings for top half (equatorial, companions reversed, cap_sharp)

    // Bottom cap sharp ring at y=-hy: sections at ±(iz+rK_last), ±(ix+rK_last).
    float xSec_cap = ix + r * K_last;
    float zSec_cap = iz + r * K_last;
    allBot ~= buildSharpRing(-hy, xSec_cap, zSec_cap, r * K_last);

    // Bottom companion rings c=0..n-1 (outer to inner, y=-(iy+K[c]*r)):
    foreach (c; 0 .. n) {
        float ksc = kSec(c);
        float xSec_c = ix + r * ksc;
        float zSec_c = iz + r * ksc;
        allBot ~= buildSharpRing(-(iy + K[c] * r), xSec_c, zSec_c, r * ksc);
    }

    // Equatorial ring at y=-iy: sections at ±hz, ±hx; kSec=1 so kSec_r=r.
    allBot ~= buildSharpRing(-iy, hx, hz, r);

    assert(allBot.length == n + 2);

    // Top half: equatorial top, companions reversed, cap_sharp top.
    // All rings are at positive Y (mirror of bottom half).
    uint[] equatorialTop = buildSharpRing(+iy, hx, hz, r);
    uint[] capSharpTop   = buildSharpRing(+hy, xSec_cap, zSec_cap, r * K_last);
    uint[][] companionsTop;
    foreach (c; 0 .. n) {
        float ksc = kSec(c);
        companionsTop ~= buildSharpRing(+(iy + K[c] * r), ix + r * ksc, iz + r * ksc, r * ksc);
    }
    // Top rings in order: equatorial, companion[n-1..0] (inner-to-outer from equatorial), cap_sharp_top
    allTop ~= equatorialTop;
    for (int c = n - 1; c >= 0; --c)
        allTop ~= companionsTop[c];
    allTop ~= capSharpTop;

    assert(allTop.length == n + 2);

    // -----------------------------------------------------------------------
    // Face emission helpers.
    // -----------------------------------------------------------------------
    int sectionStart(int sec) { return off_sec[sec]; }
    int sectionSize(int sec)  { return (sec == 0 || sec == 2) ? (nx + 1) : (nz + 1); }

    // Cap boundary vert (same as non-sharp):
    uint capBV(int sec, int t, const uint[] cap) {
        switch (sec) {
            case 0: return cap[t];
            case 1: return cap[nx + t * (nx + 1)];
            case 2: return cap[(nx - t) + nz * (nx + 1)];
            default: return cap[0 + (nz - t) * (nx + 1)];
        }
    }

    // Emit quad between two rings at matching indices.
    void emitRingQuad(const uint[] bot, const uint[] top, int i) {
        dst.addFace([top[i], top[(i+1)%rs], bot[(i+1)%rs], bot[i]]);
    }

    // Emit all quads between adjacent rings (all positions).
    void emitRingStrip(const uint[] rBot, const uint[] rTop) {
        for (int i = 0; i < rs; ++i)
            emitRingQuad(rBot, rTop, i);
    }

    // -----------------------------------------------------------------------
    // Bottom cap quads (outward normal = -Y), same as non-sharp.
    // -----------------------------------------------------------------------
    for (int j = 0; j < nz; ++j) {
        for (int i = 0; i < nx; ++i) {
            uint c00 = capBot[i   +  j    * (nx + 1)];
            uint c10 = capBot[i+1 +  j    * (nx + 1)];
            uint c11 = capBot[i+1 + (j+1) * (nx + 1)];
            uint c01 = capBot[i   + (j+1) * (nx + 1)];
            dst.addFace([c00, c10, c11, c01]);
        }
    }

    // -----------------------------------------------------------------------
    // Bottom cap → cap_sharp ring (transition).
    // The cap_sharp ring is at y=-hy so it's on the cap face — same winding
    // logic as the cap→innermost-ring transition in non-sharp.
    // In sharp mode the arc between cap boundary and cap_sharp ring has n+1 verts
    // vs n-1 in non-sharp; the corner fan has n+1 triangles.
    // -----------------------------------------------------------------------
    {
        const uint[] inner = allBot[0];  // cap_sharp ring
        foreach (sec; 0 .. 4) {
            int fs   = sectionStart(sec);
            int segs = sectionSize(sec) - 1;
            foreach (t; 0 .. segs) {
                uint r0 = inner[fs + t];
                uint r1 = inner[fs + t + 1];
                uint c0 = capBV(sec, t,     capBot);
                uint c1 = capBV(sec, t + 1, capBot);
                dst.addFace([r0, r1, c1, c0]);
            }
            // Corner fan: n+1 triangles (sharp arc has n+1 verts after section end).
            uint capCorner = capBV(sec, segs, capBot);
            int arcStart = fs + segs;
            int arcEnd   = sectionStart((sec + 1) & 3);
            for (int k = arcStart; k != arcEnd; k = (k + 1) % rs)
                dst.addFace([inner[k % rs], inner[(k + 1) % rs], capCorner]);
        }
    }

    // -----------------------------------------------------------------------
    // Bottom half rings: cap_sharp → companion[0] → ... → companion[n-1] → equatorial
    // allBot[0]=cap_sharp, allBot[1..n]=companions, allBot[n+1]=equatorial
    // -----------------------------------------------------------------------
    for (int ri = 0; ri < cast(int)allBot.length - 1; ++ri)
        emitRingStrip(allBot[ri], allBot[ri + 1]);

    // -----------------------------------------------------------------------
    // Y-subdivision middle bands (if ny > 1).
    // These go between the two equatorial rings (bottom and top), plus flat bands.
    // -----------------------------------------------------------------------
    if (ny > 1) {
        float diy = 2.0f * iy / ny;
        // Equatorial rings are at y=±iy. For ny>1 we need flat rings at y=-iy+diy*j.
        // The flat rings in sharp mode use the same xSec=hx, zSec=hz (full face), kSec_r=r.
        uint[] prevRing = allBot[n + 1];  // equatorial bottom
        for (int j = 1; j < ny; ++j) {
            float yj = -iy + diy * j;
            uint[] midRing = buildSharpRing(yj, hx, hz, r);
            emitRingStrip(prevRing, midRing);
            prevRing = midRing;
        }
        emitRingStrip(prevRing, allTop[0]);  // last mid → equatorial top
    } else {
        // Direct equatorial-bottom to equatorial-top strip.
        emitRingStrip(allBot[n + 1], allTop[0]);
    }

    // -----------------------------------------------------------------------
    // Top half rings: equatorial → companion[n-1] → ... → companion[0] → cap_sharp_top
    // allTop[0]=equatorial, allTop[1..n]=companions (inner-to-outer), allTop[n+1]=cap_sharp_top
    // -----------------------------------------------------------------------
    for (int ri = 0; ri < cast(int)allTop.length - 1; ++ri)
        emitRingStrip(allTop[ri], allTop[ri + 1]);

    // -----------------------------------------------------------------------
    // Top cap_sharp ring → top cap (transition, reversed winding vs bottom).
    // -----------------------------------------------------------------------
    {
        const uint[] inner = allTop[n + 1];  // cap_sharp_top ring
        foreach (sec; 0 .. 4) {
            int fs   = sectionStart(sec);
            int segs = sectionSize(sec) - 1;
            foreach (t; 0 .. segs) {
                uint r0 = inner[fs + t];
                uint r1 = inner[fs + t + 1];
                uint c0 = capBV(sec, t,     capTop);
                uint c1 = capBV(sec, t + 1, capTop);
                dst.addFace([c0, c1, r1, r0]);
            }
            uint capCorner = capBV(sec, segs, capTop);
            int arcStart = fs + segs;
            int arcEnd   = sectionStart((sec + 1) & 3);
            for (int k = arcStart; k != arcEnd; k = (k + 1) % rs)
                dst.addFace([capCorner, inner[(k + 1) % rs], inner[k % rs]]);
        }
    }

    // -----------------------------------------------------------------------
    // Top cap quads (outward normal = +Y, reversed vs bottom).
    // -----------------------------------------------------------------------
    for (int j = 0; j < nz; ++j) {
        for (int i = 0; i < nx; ++i) {
            uint c00 = capTop[i   +  j    * (nx + 1)];
            uint c10 = capTop[i+1 +  j    * (nx + 1)];
            uint c11 = capTop[i+1 + (j+1) * (nx + 1)];
            uint c01 = capTop[i   + (j+1) * (nx + 1)];
            dst.addFace([c00, c01, c11, c10]);
        }
    }
}

private void buildRoundedCubeAxisY(Mesh* dst, const ref BoxParams p)
{
    import std.conv : to;
    import std.typecons : Tuple, tuple;

    // Dispatch to sharp variant when sharp=true and segmentsR is in supported range.
    if (p.sharp && p.radius > 1e-9f && p.segmentsR >= 1 && p.segmentsR <= 3) {
        buildRoundedCubeAxisY_sharp(dst, p);
        return;
    }

    int    n    = p.segmentsR < 1 ? 1 : p.segmentsR;
    int    nx   = p.segmentsX < 1 ? 1 : p.segmentsX;
    int    ny   = p.segmentsY < 1 ? 1 : p.segmentsY;
    int    nz   = p.segmentsZ < 1 ? 1 : p.segmentsZ;
    float  r    = abs(p.radius);
    float  hx   = p.sizeX * 0.5f;
    float  hy   = p.sizeY * 0.5f;
    float  hz   = p.sizeZ * 0.5f;
    float  ix   = hx - r;   // inner half-extent X
    float  iy   = hy - r;   // inner half-extent Y
    float  iz   = hz - r;   // inner half-extent Z
    Vec3   cen  = Vec3(p.cenX, p.cenY, p.cenZ);

    // Ring size: 4 face sections + 4 corner arcs.
    // -Z: nx+1, +X: nz+1, +Z: nx+1, -X: nz+1, arcs: 4*(n-1)
    int rs = 2 * (nx + 1) + 2 * (nz + 1) + 4 * (n - 1);

    // Section start offsets within a ring.
    // Layout: -Z(nx+1), c1arc(n-1), +X(nz+1), c2arc(n-1), +Z(nx+1), c3arc(n-1), -X(nz+1), c0arc(n-1)
    int[4] off_sec;
    off_sec[0] = 0;
    off_sec[1] = nx + n;                        // after -Z section + c1 arc
    off_sec[2] = off_sec[1] + nz + n;           // after +X section + c2 arc
    off_sec[3] = off_sec[2] + nx + n;           // after +Z section + c3 arc
    // end of -X section = rs (wraps)

    // Deduplication map: canonical position -> mesh vertex id.
    uint[Tuple!(float,float,float)] vmap;

    uint addV(float x, float y, float z) {
        import std.math : round;
        float kx = round(x * 1_000_000.0f) / 1_000_000.0f;
        float ky = round(y * 1_000_000.0f) / 1_000_000.0f;
        float kz = round(z * 1_000_000.0f) / 1_000_000.0f;
        auto key = tuple(kx, ky, kz);
        if (auto pp = key in vmap) return *pp;
        uint id = dst.addVertex(Vec3(cen.x + x, cen.y + y, cen.z + z));
        vmap[key] = id;
        return id;
    }

    // Corner vertex on the spherical bevel at corner (sx, sy, sz).
    // pos = (sx*ix + r*sx*sin(phi)*sin(theta),
    //        sy*iy + r*sy*cos(phi),
    //        sz*iz + r*sz*sin(phi)*cos(theta))
    uint cornerVert(int sx, int sy, int sz, float phi, float theta) {
        float sp = sin(phi);
        float cp = cos(phi);
        float st = sin(theta);
        float ct = cos(theta);
        float x = sx * ix + r * sx * sp * st;
        float y = sy * iy + r * sy * cp;
        float z = sz * iz + r * sz * sp * ct;
        return addV(x, y, z);
    }

    // Face-section interior vert at step t/segs along section sec.
    // For corner rings (flat=false): the face-normal offset from the bevel boundary
    //   depends on phi: z_offset = r*sin(phi) (not r for phi<pi/2!).
    // For flat rings (flat=true, phi=pi/2): z_offset = r*sin(pi/2) = r, so z = ±(iz+r) = ±hz.
    //
    // sec 0 (-Z): x from -ix to +ix, z = -(iz + r*sin(phi))
    // sec 1 (+X): z from -iz to +iz, x = +(ix + r*sin(phi))
    // sec 2 (+Z): x from +ix to -ix (reversed), z = +(iz + r*sin(phi))
    // sec 3 (-X): z from +iz to -iz (reversed), x = -(ix + r*sin(phi))
    uint faceEdgeVert(int sec, int t, int segs, float y_val, float phi) {
        float ft     = cast(float)t / cast(float)segs;
        float sp     = sin(phi);       // sin(phi): 1.0 at equator, r*sp = correct face offset
        float x, z;
        switch (sec) {
            case 0:  x = -ix + 2.0f * ix * ft;  z = -(iz + r * sp);  break;
            case 1:  x = +(ix + r * sp);          z = -iz + 2.0f * iz * ft;  break;
            case 2:  x = ix - 2.0f * ix * ft;    z = +(iz + r * sp);  break;
            default: x = -(ix + r * sp);          z = iz - 2.0f * iz * ft;   break;
        }
        return addV(x, y_val, z);
    }

    // Build one ring. Two modes:
    //   Corner ring (flat=false): phi and sy determine the y-position via sy*(iy+r*cos(phi)).
    //   Flat Y ring (flat=true):  y is fixed at y_flat; phi=pi/2 implicitly.
    //     Corner-arc verts at phi=pi/2 have y=y_flat, with x/z from the bevel circle:
    //     (sx*(ix + r*sin(theta)), y_flat, sz*(iz + r*cos(theta)))
    uint[] buildRing(float phi, int sy, bool flat = false, float y_flat = 0.0f) {
        uint[] ring;
        ring.reserve(rs);
        immutable float dtheta = (PI * 0.5f) / n;

        // y value for face-section edge verts
        float ph_y = flat ? y_flat : sy * (iy + r * cos(phi));

        // Sections/corners in order:
        //   sec 0 (-Z): first=c0(-1,sy,-1) at theta=0, last=c1(+1,sy,-1) at theta=0
        //   arc after sec 0: c1, forward (theta=dtheta..(n-1)*dtheta)
        //   sec 1 (+X): first=c1(+1,sy,-1) at theta=pi/2, last=c2(+1,sy,+1) at theta=pi/2
        //   arc after sec 1: c2, backward
        //   sec 2 (+Z): first=c2(+1,sy,+1) at theta=0, last=c3(-1,sy,+1) at theta=0
        //   arc after sec 2: c3, forward
        //   sec 3 (-X): first=c3(-1,sy,+1) at theta=pi/2, last=c0(-1,sy,-1) at theta=pi/2
        //   arc after sec 3: c0, backward
        static immutable int[2][4] cxz = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
        static immutable int[4] sec_segs_x = [1, 0, 1, 0]; // 1=use nx, 0=use nz
        // theta of first vert in each section (sec 0,2 at theta=0; sec 1,3 at theta=pi/2)
        static immutable float[4] sec_theta0 = [0.0f, PI * 0.5f, 0.0f, PI * 0.5f];

        foreach (sec; 0 .. 4) {
            int segs = (sec_segs_x[sec] == 1) ? nx : nz;
            int sx0  = cxz[sec][0],          sz0 = cxz[sec][1];
            int sx1  = cxz[(sec+1)&3][0],    sz1 = cxz[(sec+1)&3][1];
            float th0 = sec_theta0[sec];

            // --- Face section verts (t=0..segs) ---
            foreach (t; 0 .. segs + 1) {
                if (flat) {
                    // Flat ring: all verts on the box face surface (phi=pi/2).
                    ring ~= faceEdgeVert(sec, t, segs, ph_y, PI * 0.5f);
                } else {
                    // Corner ring: endpoints are cornerVerts, interiors on face.
                    if (t == 0) {
                        ring ~= cornerVert(sx0, sy, sz0, phi, th0);
                    } else if (t == segs) {
                        ring ~= cornerVert(sx1, sy, sz1, phi, th0);
                    } else {
                        ring ~= faceEdgeVert(sec, t, segs, ph_y, phi);
                    }
                }
            }

            // --- Corner arc verts after this section ---
            // arc corners: c1 (sec 0), c2 (sec 1), c3 (sec 2), c0 (sec 3)
            // c1,c3: forward;  c2,c0: backward
            bool arc_forward = (sec == 0 || sec == 2);
            if (flat) {
                // At phi=pi/2: arc vert = (sx*(ix+r*sin(theta)), y_flat, sz*(iz+r*cos(theta)))
                if (arc_forward) {
                    for (int m = 1; m < n; ++m) {
                        float st = sin(m * dtheta);
                        float ct = cos(m * dtheta);
                        ring ~= addV(sx1 * ix + r * sx1 * st,
                                     y_flat,
                                     sz1 * iz + r * sz1 * ct);
                    }
                } else {
                    for (int m = n - 1; m >= 1; --m) {
                        float st = sin(m * dtheta);
                        float ct = cos(m * dtheta);
                        ring ~= addV(sx1 * ix + r * sx1 * st,
                                     y_flat,
                                     sz1 * iz + r * sz1 * ct);
                    }
                }
            } else {
                if (arc_forward) {
                    for (int m = 1; m < n; ++m)
                        ring ~= cornerVert(sx1, sy, sz1, phi, m * dtheta);
                } else {
                    for (int m = n - 1; m >= 1; --m)
                        ring ~= cornerVert(sx1, sy, sz1, phi, m * dtheta);
                }
            }
        }

        assert(ring.length == rs,
               "ring length " ~ to!string(ring.length) ~ " != expected " ~ to!string(rs));
        return ring;
    }

    // -----------------------------------------------------------------------
    // Caps: (nx+1)*(nz+1) grid at y = -hy / +hy.
    // cap[i + j*(nx+1)] = vert at (xi, y, zj)
    //   xi = -ix + 2*ix*i/nx,  zj = -iz + 2*iz*j/nz
    // -----------------------------------------------------------------------
    int capSize = (nx + 1) * (nz + 1);
    uint[] capBot = new uint[capSize];
    uint[] capTop = new uint[capSize];
    for (int j = 0; j <= nz; ++j) {
        float zj = (nz == 0) ? 0.0f : (-iz + 2.0f * iz * (cast(float)j / nz));
        for (int i = 0; i <= nx; ++i) {
            float xi = (nx == 0) ? 0.0f : (-ix + 2.0f * ix * (cast(float)i / nx));
            int idx = i + j * (nx + 1);
            capBot[idx] = addV(xi, -hy, zj);
            capTop[idx] = addV(xi, +hy, zj);
        }
    }

    // -----------------------------------------------------------------------
    // Build rings.
    // -----------------------------------------------------------------------
    immutable float dphi = (PI * 0.5f) / n;
    immutable float diy  = (ny > 1) ? (2.0f * iy / ny) : 0.0f;

    // Bottom corner rings: k=1..n (innermost first)
    uint[][] ringsBot;
    ringsBot.reserve(n);
    foreach (k; 1 .. n + 1)
        ringsBot ~= buildRing(k * dphi, -1);

    // Middle flat Y-subdivision rings: j=1..ny-1
    uint[][] ringsMid;
    ringsMid.reserve(ny - 1);
    foreach (j; 1 .. ny) {
        float yj = -iy + diy * j;
        ringsMid ~= buildRing(PI * 0.5f, 1, true, yj);
    }

    // Top corner rings: built k=n..1 (outer-to-inner) for monotonic vertex indices.
    uint[][] ringsTop;
    ringsTop.reserve(n);
    foreach (k; 1 .. n + 1)
        ringsTop ~= null;
    for (int k = n; k >= 1; --k)
        ringsTop[k - 1] = buildRing(k * dphi, +1);

    // -----------------------------------------------------------------------
    // Emit faces.
    // -----------------------------------------------------------------------

    int sectionStart(int sec)    { return off_sec[sec]; }
    int sectionSize(int sec)     { return (sec == 0 || sec == 2) ? (nx + 1) : (nz + 1); }

    // Cap boundary vert: maps section + step-along-section to cap grid vert.
    //   sec 0 (-Z edge): i=t, j=0
    //   sec 1 (+X edge): i=nx, j=t
    //   sec 2 (+Z edge): i=nx-t, j=nz  (reversed along X)
    //   sec 3 (-X edge): i=0, j=nz-t   (reversed along Z)
    uint capBoundaryVert(int sec, int t, const uint[] cap) {
        switch (sec) {
            case 0: return cap[t];
            case 1: return cap[nx + t * (nx + 1)];
            case 2: return cap[(nx - t) + nz * (nx + 1)];
            default: return cap[0 + (nz - t) * (nx + 1)];
        }
    }

    // --- Bottom cap quads (outward normal = -Y) ---
    // Winding: [c00, c10, c11, c01] gives -Y normal.
    for (int j = 0; j < nz; ++j) {
        for (int i = 0; i < nx; ++i) {
            uint c00 = capBot[i   +  j    * (nx + 1)];
            uint c10 = capBot[i+1 +  j    * (nx + 1)];
            uint c11 = capBot[i+1 + (j+1) * (nx + 1)];
            uint c01 = capBot[i   + (j+1) * (nx + 1)];
            dst.addFace([c00, c10, c11, c01]);
        }
    }

    // --- Bottom cap -> innermost bottom ring (transition) ---
    {
        const uint[] inner = ringsBot[0];
        foreach (sec; 0 .. 4) {
            int fs   = sectionStart(sec);
            int segs = sectionSize(sec) - 1;   // quads in this flat section
            // Flat-section quads: ring[fs..fs+segs] <-> cap boundary edge
            foreach (t; 0 .. segs) {
                uint r0 = inner[fs + t];
                uint r1 = inner[fs + t + 1];
                uint c0 = capBoundaryVert(sec, t,     capBot);
                uint c1 = capBoundaryVert(sec, t + 1, capBot);
                dst.addFace([r0, r1, c1, c0]);
            }
            // Corner triangle fan: from last section vert through arc verts to
            // first vert of next section, all meeting at the shared cap corner.
            uint capCorner = capBoundaryVert(sec, segs, capBot);
            int arcStart = fs + segs;
            int arcEnd   = sectionStart((sec + 1) & 3);
            for (int k = arcStart; k != arcEnd; k = (k + 1) % rs)
                dst.addFace([inner[k % rs], inner[(k + 1) % rs], capCorner]);
        }
    }

    // --- Adjacent rings in bottom half (innermost -> mid-band) ---
    foreach (k; 1 .. n) {
        const uint[] innerRing = ringsBot[k - 1];
        const uint[] outerRing = ringsBot[k];
        for (int i = 0; i < rs; ++i)
            dst.addFace([outerRing[i], outerRing[(i+1)%rs],
                         innerRing[(i+1)%rs], innerRing[i]]);
    }

    // --- Equatorial band: bottom mid-band -> (Y-subdivision rings) -> top mid-band ---
    // Collect all equatorial rings in bottom-to-top order.
    {
        uint[][] equatorial;
        equatorial.reserve(ny + 1);
        equatorial ~= ringsBot[n - 1];
        foreach (rm; ringsMid) equatorial ~= rm;
        equatorial ~= ringsTop[n - 1];

        foreach (bi; 0 .. ny) {
            const uint[] rb = equatorial[bi];
            const uint[] rt = equatorial[bi + 1];
            for (int i = 0; i < rs; ++i)
                dst.addFace([rt[i], rt[(i+1)%rs], rb[(i+1)%rs], rb[i]]);
        }
    }

    // --- Adjacent rings in top half (mid-band -> innermost, reversed winding) ---
    for (int k = n - 1; k >= 1; --k) {
        const uint[] innerRing = ringsTop[k - 1];
        const uint[] outerRing = ringsTop[k];
        for (int i = 0; i < rs; ++i)
            dst.addFace([innerRing[i], innerRing[(i+1)%rs],
                         outerRing[(i+1)%rs], outerRing[i]]);
    }

    // --- Innermost top ring -> top cap (transition, reversed winding vs bottom) ---
    {
        const uint[] inner = ringsTop[0];
        foreach (sec; 0 .. 4) {
            int fs   = sectionStart(sec);
            int segs = sectionSize(sec) - 1;
            foreach (t; 0 .. segs) {
                uint r0 = inner[fs + t];
                uint r1 = inner[fs + t + 1];
                uint c0 = capBoundaryVert(sec, t,     capTop);
                uint c1 = capBoundaryVert(sec, t + 1, capTop);
                dst.addFace([c0, c1, r1, r0]);
            }
            // Corner triangle fan (reversed winding).
            uint capCorner = capBoundaryVert(sec, segs, capTop);
            int arcStart = fs + segs;
            int arcEnd   = sectionStart((sec + 1) & 3);
            for (int k = arcStart; k != arcEnd; k = (k + 1) % rs)
                dst.addFace([capCorner, inner[(k + 1) % rs], inner[k % rs]]);
        }
    }

    // --- Top cap quads (outward normal = +Y, reversed vs bottom) ---
    for (int j = 0; j < nz; ++j) {
        for (int i = 0; i < nx; ++i) {
            uint c00 = capTop[i   +  j    * (nx + 1)];
            uint c10 = capTop[i+1 +  j    * (nx + 1)];
            uint c11 = capTop[i+1 + (j+1) * (nx + 1)];
            uint c01 = capTop[i   + (j+1) * (nx + 1)];
            dst.addFace([c00, c01, c11, c10]);
        }
    }
}


// ---------------------------------------------------------------------------
// buildRoundedPlane — generate a rounded-corner planar panel.
//
// Called when radius > 0 AND exactly one of sizeX/Y/Z is zero.
// Produces the MODO prim.cube topology for plane mode with rounded edges:
//
//   Vertex layout (segA, segB = segments along the two non-zero axes;
//                  sR = segmentsR):
//     [0 .. outerRingSize-1]          outer ring (CCW from above/outward)
//     [outerRingSize .. outerRingSize + (segA+1)*(segB+1) - 1]  inner panel grid
//
//   Outer ring (total = 2*(segA+1) + 2*(segB+1) + 4*(sR-1)):
//     bottom section (+A direction): segA+1 verts at -halfB
//     bottom-right arc:              sR-1 intermediate verts
//     right section (+B direction):  segB+1 verts at +halfA
//     top-right arc:                 sR-1 intermediate verts
//     top section (-A direction):    segA+1 verts at +halfB (reversed)
//     top-left arc:                  sR-1 intermediate verts
//     left section (-B direction):   segB+1 verts at -halfA (reversed)
//     bottom-left arc:               sR-1 intermediate verts
//
//   Inner panel: (segA+1)*(segB+1) grid, index = iA*(segB+1)+iB.
//
//   Faces (total = segA*segB + 2*segA + 2*segB + 4*sR):
//     segA*segB inner panel quads (CCW outward winding)
//     2*segA + 2*segB side strip quads (4 edge strips)
//     4*sR corner triangle fans
//
// Verified bit-for-bit against MODO 9 probe data for:
//   XZ plane (sizeY=0) sR=1 seg=(1,1): 12v/9f
//   XZ plane (sizeY=0) sR=2 seg=(1,1): 16v/13f
//   XZ plane (sizeY=0) sR=1 seg=(2,2): 21v/16f
//   YZ plane (sizeX=0) sR=1 seg=(1,1): 12v/9f
//   XY plane (sizeZ=0) sR=1 seg=(1,1): 12v/9f
// ---------------------------------------------------------------------------
private void buildRoundedPlane(Mesh* dst, const ref BoxParams p)
{
    import std.typecons : Tuple, tuple;
    import std.math : round;
    import std.conv : to;

    int    sR   = p.segmentsR < 1 ? 1 : p.segmentsR;
    float  r    = abs(p.radius);

    // Determine which axis is degenerate and set up effective (A, B, N) axes.
    //
    // MODO ring/panel ordering varies by orientation:
    //
    //   sizeY=0 → XZ plane (+Y outward):
    //     Ring starts at bottom section (b=-halfZ, a from -innerX to +innerX).
    //     Panel is A-major: panel[iA*(segB+1)+iB].  (A=X, B=Z)
    //
    //   sizeX=0 → YZ plane (+X outward):
    //     MODO ring starts at what is the "left" section in the XZ frame.
    //     Equivalent to swapping A↔B of an XZ ring: A_eff=Z, B_eff=Y.
    //     Panel is B-major (in original AB): panel[iB*(segA+1)+iA]
    //     = A_eff-major: panel_eff[iAe*(segBe+1)+iBe] with Ae=Z, Be=Y.
    //
    //   sizeZ=0 → XY plane (+Z outward):
    //     Same swap pattern as YZ: A_eff=Y, B_eff=X.
    //     Panel is B-major: panel[iB*(segA+1)+iA].
    //
    // Unified: we always run the XZ-frame ring/face logic with effective
    // (segAe, segBe, halfAe, halfBe, cenAe, cenBe), and provide a coordinate
    // transform addV(ae, be) → world (x,y,z).

    float halfAe, halfBe;
    int   segAe,  segBe;
    float cenAe,  cenBe, cenN;
    // Orientation tag for addV.
    int orient; // 0=XZ, 1=YZ(swapped), 2=XY(swapped)

    if (abs(p.sizeY) < 1e-9f) {
        // XZ: A=X, B=Z. No swap needed.
        halfAe = abs(p.sizeX) * 0.5f;
        halfBe = abs(p.sizeZ) * 0.5f;
        segAe  = p.segmentsX < 1 ? 1 : p.segmentsX;
        segBe  = p.segmentsZ < 1 ? 1 : p.segmentsZ;
        cenAe  = p.cenX;  cenBe = p.cenZ;  cenN = p.cenY;
        orient = 0;
    } else if (abs(p.sizeX) < 1e-9f) {
        // YZ: effective A=Z, effective B=Y (A↔B swap vs natural Y,Z order).
        // Swapping makes the ring start at what MODO calls "bottom" (a=-halfZ).
        halfAe = abs(p.sizeZ) * 0.5f;
        halfBe = abs(p.sizeY) * 0.5f;
        segAe  = p.segmentsZ < 1 ? 1 : p.segmentsZ;
        segBe  = p.segmentsY < 1 ? 1 : p.segmentsY;
        cenAe  = p.cenZ;  cenBe = p.cenY;  cenN = p.cenX;
        orient = 1;
    } else {
        // XY (sizeZ=0): effective A=Y, effective B=X.
        // Swapping matches MODO's ring start at a=-halfY.
        halfAe = abs(p.sizeY) * 0.5f;
        halfBe = abs(p.sizeX) * 0.5f;
        segAe  = p.segmentsY < 1 ? 1 : p.segmentsY;
        segBe  = p.segmentsX < 1 ? 1 : p.segmentsX;
        cenAe  = p.cenY;  cenBe = p.cenX;  cenN = p.cenZ;
        orient = 2;
    }

    // Clamp radius so corners don't degenerate.
    if (r > halfAe) r = halfAe;
    if (r > halfBe) r = halfBe;

    float innerAe = halfAe - r;
    float innerBe = halfBe - r;

    // -----------------------------------------------------------------------
    // Vertex emission.
    // addV(ae, be) → world vertex, deduplicating via rounded key.
    // Coordinate mapping (verified against MODO probe data):
    //   XZ (orient=0): ae→x,  be→z,  n→y
    //   YZ (orient=1): ae→z,  be→y,  n→x  (effective A=Z, effective B=Y)
    //   XY (orient=2): ae→y,  be→x,  n→z  (effective A=Y, effective B=X)
    // -----------------------------------------------------------------------
    uint[Tuple!(float,float,float)] vmap;

    uint addV(float ae, float be) {
        Vec3 pos;
        final switch (orient) {
            case 0: pos = Vec3(cenAe + ae, cenN,       cenBe + be); break;
            case 1: pos = Vec3(cenN,       cenBe + be, cenAe + ae); break;
            case 2: pos = Vec3(cenBe + be, cenAe + ae, cenN);       break;
        }
        float kx = round(pos.x * 1_000_000.0f) / 1_000_000.0f;
        float ky = round(pos.y * 1_000_000.0f) / 1_000_000.0f;
        float kz = round(pos.z * 1_000_000.0f) / 1_000_000.0f;
        auto key = tuple(kx, ky, kz);
        if (auto pp = key in vmap) return *pp;
        uint id = dst.addVertex(pos);
        vmap[key] = id;
        return id;
    }

    // -----------------------------------------------------------------------
    // Outer ring.
    //
    // In effective (Ae, Be) coordinates the ring follows the XZ-frame order:
    //   sec 0 (bottom, be=-halfBe): ae from -innerAe to +innerAe  [segAe+1 verts]
    //   arc BR (inner corner +innerAe,-innerBe): arc -π/2 to 0    [sR-1 verts]
    //   sec 1 (right, ae=+halfAe):  be from -innerBe to +innerBe  [segBe+1 verts]
    //   arc TR (inner corner +innerAe,+innerBe): arc 0 to π/2     [sR-1 verts]
    //   sec 2 (top, be=+halfBe):    ae from +innerAe to -innerAe  [segAe+1 verts]
    //   arc TL (inner corner -innerAe,+innerBe): arc π/2 to π     [sR-1 verts]
    //   sec 3 (left, ae=-halfAe):   be from +innerBe to -innerBe  [segBe+1 verts]
    //   arc BL (inner corner -innerAe,-innerBe): arc π to 3π/2    [sR-1 verts]
    //
    // Ring size = 2*(segAe+1) + 2*(segBe+1) + 4*(sR-1).
    // -----------------------------------------------------------------------
    int ringSize = 2 * (segAe + 1) + 2 * (segBe + 1) + 4 * (sR - 1);
    uint[] ring;
    ring.reserve(ringSize);

    immutable float dtheta = (PI * 0.5f) / sR;

    // sec 0: bottom (be=-halfBe), ae from -innerAe to +innerAe
    for (int i = 0; i <= segAe; ++i) {
        float ae = (segAe == 0) ? 0.0f : (-innerAe + 2.0f * innerAe * (cast(float)i / segAe));
        ring ~= addV(ae, -halfBe);
    }
    // arc BR: +innerAe,-innerBe, angles -π/2 .. 0
    for (int m = 1; m < sR; ++m) {
        float angle = -PI * 0.5f + m * dtheta;
        ring ~= addV(innerAe + r * cos(angle), -innerBe + r * sin(angle));
    }
    // sec 1: right (ae=+halfAe), be from -innerBe to +innerBe
    for (int i = 0; i <= segBe; ++i) {
        float be = (segBe == 0) ? 0.0f : (-innerBe + 2.0f * innerBe * (cast(float)i / segBe));
        ring ~= addV(+halfAe, be);
    }
    // arc TR: +innerAe,+innerBe, angles 0 .. π/2
    for (int m = 1; m < sR; ++m) {
        float angle = m * dtheta;
        ring ~= addV(innerAe + r * cos(angle), innerBe + r * sin(angle));
    }
    // sec 2: top (be=+halfBe), ae from +innerAe to -innerAe (reversed)
    for (int i = 0; i <= segAe; ++i) {
        float ae = (segAe == 0) ? 0.0f : (innerAe - 2.0f * innerAe * (cast(float)i / segAe));
        ring ~= addV(ae, +halfBe);
    }
    // arc TL: -innerAe,+innerBe, angles π/2 .. π
    for (int m = 1; m < sR; ++m) {
        float angle = PI * 0.5f + m * dtheta;
        ring ~= addV(-innerAe + r * cos(angle), innerBe + r * sin(angle));
    }
    // sec 3: left (ae=-halfAe), be from +innerBe to -innerBe (reversed)
    for (int i = 0; i <= segBe; ++i) {
        float be = (segBe == 0) ? 0.0f : (innerBe - 2.0f * innerBe * (cast(float)i / segBe));
        ring ~= addV(-halfAe, be);
    }
    // arc BL: -innerAe,-innerBe, angles π .. 3π/2
    for (int m = 1; m < sR; ++m) {
        float angle = PI + m * dtheta;
        ring ~= addV(-innerAe + r * cos(angle), -innerBe + r * sin(angle));
    }

    assert(ring.length == ringSize,
           "buildRoundedPlane: ring.length=" ~ ring.length.to!string
           ~ " != " ~ ringSize.to!string);

    // -----------------------------------------------------------------------
    // Inner panel: (segAe+1) × (segBe+1) grid.
    // panel[iAe*(segBe+1)+iBe]  at  (ae_iAe, be_iBe)
    // -----------------------------------------------------------------------
    int panelSize = (segAe + 1) * (segBe + 1);
    uint[] panel;
    panel.reserve(panelSize);
    for (int iAe = 0; iAe <= segAe; ++iAe) {
        float ae = (segAe == 0) ? 0.0f : (-innerAe + 2.0f * innerAe * (cast(float)iAe / segAe));
        for (int iBe = 0; iBe <= segBe; ++iBe) {
            float be = (segBe == 0) ? 0.0f : (-innerBe + 2.0f * innerBe * (cast(float)iBe / segBe));
            panel ~= addV(ae, be);
        }
    }

    // Helper: panel vertex index in effective (Ae, Be) coordinates.
    uint pv(int iAe, int iBe) { return panel[iAe * (segBe + 1) + iBe]; }

    // -----------------------------------------------------------------------
    // Ring section start offsets.
    // -----------------------------------------------------------------------
    int rBotStart   = 0;
    int rArcBR      = segAe + 1;
    int rRightStart = rArcBR + (sR - 1);
    int rArcTR      = rRightStart + segBe + 1;
    int rTopStart   = rArcTR + (sR - 1);
    int rArcTL      = rTopStart + segAe + 1;
    int rLeftStart  = rArcTL + (sR - 1);
    // rArcBL starts at rLeftStart + segBe + 1, wraps to ring[0].

    // -----------------------------------------------------------------------
    // Emit faces.
    //
    // All faces follow the XZ-frame (effective) winding. The coordinate
    // transform in addV() ensures the outward normal is correct for each
    // orientation:
    //   XZ: panel winding [iAe,iBe],[iAe,iBe+1],[iAe+1,iBe+1],[iAe+1,iBe]
    //       → cross product points +Y (outward for sizeY=0) ✓
    //   YZ: same winding, addV maps ae→z, be→y → cross product points +X ✓
    //   XY: same winding, addV maps ae→y, be→x → cross product points +Z ✓
    // -----------------------------------------------------------------------

    // --- Inner panel quads ---
    for (int iAe = 0; iAe < segAe; ++iAe) {
        for (int iBe = 0; iBe < segBe; ++iBe) {
            dst.addFace([pv(iAe, iBe), pv(iAe, iBe+1),
                         pv(iAe+1, iBe+1), pv(iAe+1, iBe)]);
        }
    }

    // --- Bottom strip (ring bottom section ↔ inner panel bottom edge) ---
    for (int i = 0; i < segAe; ++i) {
        dst.addFace([ring[rBotStart + i],     pv(i, 0),
                     pv(i+1, 0),              ring[rBotStart + i + 1]]);
    }

    // --- Bottom-right corner fan (sR triangles) ---
    // Inner corner = pv(segAe, 0).  Arc spans ring[segAe .. segAe+sR].
    for (int m = 0; m < sR; ++m) {
        dst.addFace([ring[rBotStart + segAe + m],
                     pv(segAe, 0),
                     ring[rBotStart + segAe + m + 1]]);
    }

    // --- Right strip (ring right section ↔ inner panel right edge) ---
    for (int i = 0; i < segBe; ++i) {
        dst.addFace([ring[rRightStart + i],   pv(segAe, i),
                     pv(segAe, i+1),          ring[rRightStart + i + 1]]);
    }

    // --- Top-right corner fan ---
    // Inner corner = pv(segAe, segBe).
    for (int m = 0; m < sR; ++m) {
        dst.addFace([ring[rRightStart + segBe + m],
                     pv(segAe, segBe),
                     ring[rRightStart + segBe + m + 1]]);
    }

    // --- Top strip (ring top section ↔ inner panel top edge, reversed A) ---
    for (int i = 0; i < segAe; ++i) {
        dst.addFace([ring[rTopStart + i],
                     pv(segAe - i, segBe), pv(segAe - i - 1, segBe),
                     ring[rTopStart + i + 1]]);
    }

    // --- Top-left corner fan ---
    // Inner corner = pv(0, segBe).
    for (int m = 0; m < sR; ++m) {
        dst.addFace([ring[rTopStart + segAe + m],
                     pv(0, segBe),
                     ring[rTopStart + segAe + m + 1]]);
    }

    // --- Left strip (ring left section ↔ inner panel left edge, reversed B) ---
    for (int i = 0; i < segBe; ++i) {
        dst.addFace([ring[rLeftStart + i],
                     pv(0, segBe - i), pv(0, segBe - i - 1),
                     ring[rLeftStart + i + 1]]);
    }

    // --- Bottom-left corner fan ---
    // Inner corner = pv(0, 0).
    // Last arc vert wraps to ring[0] (start of bottom section).
    for (int m = 0; m < sR; ++m) {
        int rA = rLeftStart + segBe + m;
        int rB = (m < sR - 1) ? (rLeftStart + segBe + m + 1) : 0;
        dst.addFace([ring[rA], pv(0, 0), ring[rB]]);
    }
}

// ---------------------------------------------------------------------------
// buildCuboidParametric — pure free function: build an axis-aligned cuboid
// into `dst` according to `p`.
//
// Caller is responsible for calling dst.buildLoops() after this returns.
//
// Plane mode: if any of sizeX/Y/Z is 0 (within 1e-9), emits a single quad
// on the degenerate axis (4 verts / 1 face). MODO's prim.cube does the same
// — verified on the modo_diff side.
//
// Full cuboid with segments: builds a vertex map keyed by (i,j,k) in
// [0..segX] × [0..segY] × [0..segZ] space, emitting surface vertices only
// (those with at least one index == 0 or N), and emitting one quad per cell
// on each of the 6 cube faces. Winding is consistent: outward normals on all
// 6 faces.
//
// Rounded cube (radius > 0): routes to buildRoundedCubeAxisY (or a permuted
// version for axis=X/Z). Phase 6.1b — generates rounded edges with spherical
// corner caps, MODO prim.cube parity verified for axis=Y, segmentsR=1..4.
// Rounded plane (radius > 0, any size = 0): routes to buildRoundedPlane.
// Phase 6.1d — MODO prim.cube parity verified for XZ/YZ/XY planes.
// ---------------------------------------------------------------------------
void buildCuboidParametric(Mesh* dst, const ref BoxParams p)
{
    import std.typecons : Tuple, tuple;

    // Rounded cube path: radius > epsilon → delegate to rounded generator.
    // Rounded plane (any size = 0) also delegates when radius > epsilon.
    bool anyZeroSize = abs(p.sizeX) < 1e-9f || abs(p.sizeY) < 1e-9f || abs(p.sizeZ) < 1e-9f;
    if (p.radius > 1e-9f
        && abs(p.sizeX) >= 1e-9f && abs(p.sizeY) >= 1e-9f && abs(p.sizeZ) >= 1e-9f)
    {
        // Clamp radius so it doesn't exceed the smallest half-extent.
        float clampedR = abs(p.radius);
        float maxR = abs(p.sizeX) * 0.5f;
        if (abs(p.sizeY) * 0.5f < maxR) maxR = abs(p.sizeY) * 0.5f;
        if (abs(p.sizeZ) * 0.5f < maxR) maxR = abs(p.sizeZ) * 0.5f;
        if (clampedR > maxR) clampedR = maxR;

        BoxParams rp = p;
        rp.radius = clampedR;

        // axis=1 (Y) is verified bit-for-bit against MODO.
        // axis=0 (X) and axis=2 (Z): swap coordinates so Y is always primary.
        if (p.axis == 0) {
            // X is primary: swap sizeX↔sizeY so the generator sees Y as primary.
            // Then rotate each emitted vertex: (x_gen, y_gen, z_gen) → (y_gen, x_gen, z_gen).
            rp.sizeX = p.sizeY;
            rp.sizeY = p.sizeX;
            Mesh tmp;
            buildRoundedCubeAxisY(&tmp, rp);
            // Re-add vertices with X↔Y swap.
            foreach (ref v; tmp.vertices) {
                import std.algorithm.mutation : swap;
                swap(v.x, v.y);
                v = v + Vec3(p.cenX, p.cenY, p.cenZ) - Vec3(rp.cenX, rp.cenY, rp.cenZ);
            }
            // Copy into dst.
            uint base = cast(uint)dst.vertices.length;
            foreach (v; tmp.vertices) dst.addVertex(v);
            foreach (ref f; tmp.faces) {
                uint[] fi;
                fi.length = f.length;
                foreach (i, vi; f) fi[i] = vi + base;
                dst.addFace(fi);
            }
        } else if (p.axis == 2) {
            // Z is primary: swap sizeZ↔sizeY so the generator sees Y as primary.
            rp.sizeZ = p.sizeY;
            rp.sizeY = p.sizeZ;
            Mesh tmp;
            buildRoundedCubeAxisY(&tmp, rp);
            // Re-add vertices with Y↔Z swap.
            foreach (ref v; tmp.vertices) {
                import std.algorithm.mutation : swap;
                swap(v.y, v.z);
                v = v + Vec3(p.cenX, p.cenY, p.cenZ) - Vec3(rp.cenX, rp.cenY, rp.cenZ);
            }
            uint base = cast(uint)dst.vertices.length;
            foreach (v; tmp.vertices) dst.addVertex(v);
            foreach (ref f; tmp.faces) {
                uint[] fi;
                fi.length = f.length;
                foreach (i, vi; f) fi[i] = vi + base;
                dst.addFace(fi);
            }
        } else {
            // axis=1 (Y) — default, exact MODO parity.
            buildRoundedCubeAxisY(dst, rp);
        }
        return;
    }

    // Rounded plane: radius > 0 but one axis is zero → delegate to rounded plane generator.
    if (p.radius > 1e-9f && anyZeroSize) {
        buildRoundedPlane(dst, p);
        return;
    }

    // Plane mode detection — any zero-size axis collapses to a flat panel
    // subdivided by the segment counts of the two non-degenerate axes.
    // MODO emits (segA+1)×(segB+1) verts and segA×segB quads (verified).
    void emitPlane(Vec3 origin, Vec3 da, Vec3 db, int na, int nb, bool reverseWinding)
    {
        if (na < 1) na = 1;
        if (nb < 1) nb = 1;
        uint[] grid;
        grid.length = (na + 1) * (nb + 1);
        foreach (j; 0 .. nb + 1) foreach (i; 0 .. na + 1) {
            float u = cast(float)i / na - 0.5f;
            float v = cast(float)j / nb - 0.5f;
            grid[j * (na + 1) + i] = dst.addVertex(origin + da * u + db * v);
        }
        foreach (j; 0 .. nb) foreach (i; 0 .. na) {
            uint v00 = grid[ j      * (na + 1) + i    ];
            uint v10 = grid[ j      * (na + 1) + i + 1];
            uint v11 = grid[(j + 1) * (na + 1) + i + 1];
            uint v01 = grid[(j + 1) * (na + 1) + i    ];
            if (reverseWinding) dst.addFace([v00, v01, v11, v10]);
            else                dst.addFace([v00, v10, v11, v01]);
        }
    }

    if (abs(p.sizeY) < 1e-9f) {
        // XZ plane at cenY. da=+X, db=+Z. cross(da,db)=(0,-sx*sz,0) → -Y.
        // Reverse winding so outward normal is +Y.
        emitPlane(Vec3(p.cenX, p.cenY, p.cenZ),
                  Vec3(p.sizeX, 0, 0), Vec3(0, 0, p.sizeZ),
                  p.segmentsX, p.segmentsZ, /*reverse=*/ true);
        return;
    }
    if (abs(p.sizeX) < 1e-9f) {
        // YZ plane at cenX. da=+Y, db=+Z. cross(da,db)=(sy*sz,0,0) → +X. Direct.
        emitPlane(Vec3(p.cenX, p.cenY, p.cenZ),
                  Vec3(0, p.sizeY, 0), Vec3(0, 0, p.sizeZ),
                  p.segmentsY, p.segmentsZ, /*reverse=*/ false);
        return;
    }
    if (abs(p.sizeZ) < 1e-9f) {
        // XY plane at cenZ. da=+X, db=+Y. cross(da,db)=(0,0,sx*sy) → +Z. Direct.
        emitPlane(Vec3(p.cenX, p.cenY, p.cenZ),
                  Vec3(p.sizeX, 0, 0), Vec3(0, p.sizeY, 0),
                  p.segmentsX, p.segmentsY, /*reverse=*/ false);
        return;
    }

    // Full cuboid with segments.
    int nx = p.segmentsX < 1 ? 1 : p.segmentsX;
    int ny = p.segmentsY < 1 ? 1 : p.segmentsY;
    int nz = p.segmentsZ < 1 ? 1 : p.segmentsZ;

    // Vertex map: (i,j,k) → vertex index in dst.
    // Only surface vertices are added; interior vertices (all three indices
    // strictly between 0 and N) are never emitted.
    uint[Tuple!(int,int,int)] vMap;

    uint vert(int i, int j, int k) {
        auto key = tuple(i, j, k);
        if (auto pp = key in vMap) return *pp;
        Vec3 pos = Vec3(
            p.cenX + (cast(float)i / nx - 0.5f) * p.sizeX,
            p.cenY + (cast(float)j / ny - 0.5f) * p.sizeY,
            p.cenZ + (cast(float)k / nz - 0.5f) * p.sizeZ);
        uint id = dst.addVertex(pos);
        vMap[key] = id;
        return id;
    }

    // Emit 6 cube faces, each subdivided into a (segA × segB) grid of quads.
    // Winding rule: the four corners of each quad are ordered so that the
    // cross product of (c1-c0)×(c3-c0) points outward. Verified by the
    // unittest below using face normals vs. face centroid vs. cube center.

    // -X face (i=0): normal −X. Grid over (j,k).
    // Quad corners: (0,j,k), (0,j,k+1), (0,j+1,k+1), (0,j+1,k).
    // Normal: cross((0,0,sz_step)×(0,sy_step,0)) = (-sy*sz,0,0) → −X. Good.
    foreach (j; 0 .. ny) foreach (k; 0 .. nz) {
        uint c0 = vert(0, j,   k  );
        uint c1 = vert(0, j,   k+1);
        uint c2 = vert(0, j+1, k+1);
        uint c3 = vert(0, j+1, k  );
        dst.addFace([c0, c1, c2, c3]);
    }

    // +X face (i=nx): normal +X. Grid over (j,k), opposite winding.
    // Quad corners: (nx,j,k), (nx,j+1,k), (nx,j+1,k+1), (nx,j,k+1).
    // Normal: cross((sy_step,0,0)×(0,0,sz_step)) = ... actually let's use
    // (c1-c0)×(c3-c0) where c0=(nx,j,k), c1=(nx,j+1,k), c3=(nx,j,k+1).
    // c1-c0 = (0,+sy,0), c3-c0 = (0,0,+sz) → cross = (+sy*sz, 0, 0) → +X. Good.
    foreach (j; 0 .. ny) foreach (k; 0 .. nz) {
        uint c0 = vert(nx, j,   k  );
        uint c1 = vert(nx, j+1, k  );
        uint c2 = vert(nx, j+1, k+1);
        uint c3 = vert(nx, j,   k+1);
        dst.addFace([c0, c1, c2, c3]);
    }

    // -Y face (j=0): normal −Y. Grid over (i,k).
    // c0=(i,0,k), c1=(i+1,0,k), c2=(i+1,0,k+1), c3=(i,0,k+1).
    // (c1-c0)×(c3-c0) = (sx,0,0)×(0,0,sz) = (0*sz-0*0, 0*sx-sx*sz, sx*0-0*0)
    //                 = (0, -sx*sz, 0) → −Y. Good.
    foreach (i; 0 .. nx) foreach (k; 0 .. nz) {
        uint c0 = vert(i,   0, k  );
        uint c1 = vert(i+1, 0, k  );
        uint c2 = vert(i+1, 0, k+1);
        uint c3 = vert(i,   0, k+1);
        dst.addFace([c0, c1, c2, c3]);
    }

    // +Y face (j=ny): normal +Y. Grid over (i,k), opposite winding.
    // c0=(i,ny,k), c1=(i,ny,k+1), c2=(i+1,ny,k+1), c3=(i+1,ny,k).
    // (c1-c0)×(c3-c0) = (0,0,sz)×(sx,0,0) = (0*0-sz*0, sz*sx-0*0, 0*0-0*sx)
    //                 = (0, sz*sx, 0) → +Y. Good.
    foreach (i; 0 .. nx) foreach (k; 0 .. nz) {
        uint c0 = vert(i,   ny, k  );
        uint c1 = vert(i,   ny, k+1);
        uint c2 = vert(i+1, ny, k+1);
        uint c3 = vert(i+1, ny, k  );
        dst.addFace([c0, c1, c2, c3]);
    }

    // -Z face (k=0): normal −Z. Grid over (i,j).
    // c0=(i,j,0), c1=(i,j+1,0), c2=(i+1,j+1,0), c3=(i+1,j,0).
    // (c1-c0)×(c3-c0) = (0,sy,0)×(sx,0,0) = (sy*0-0*0, 0*sx-0*0, 0*0-sy*sx)
    //                 = (0, 0, -sy*sx) → −Z. Good.
    foreach (i; 0 .. nx) foreach (j; 0 .. ny) {
        uint c0 = vert(i,   j,   0);
        uint c1 = vert(i,   j+1, 0);
        uint c2 = vert(i+1, j+1, 0);
        uint c3 = vert(i+1, j,   0);
        dst.addFace([c0, c1, c2, c3]);
    }

    // +Z face (k=nz): normal +Z. Grid over (i,j), opposite winding.
    // c0=(i,j,nz), c1=(i+1,j,nz), c2=(i+1,j+1,nz), c3=(i,j+1,nz).
    // (c1-c0)×(c3-c0) = (sx,0,0)×(0,sy,0) = (0,0,sx*sy) → +Z. Good.
    foreach (i; 0 .. nx) foreach (j; 0 .. ny) {
        uint c0 = vert(i,   j,   nz);
        uint c1 = vert(i+1, j,   nz);
        uint c2 = vert(i+1, j+1, nz);
        uint c3 = vert(i,   j+1, nz);
        dst.addFace([c0, c1, c2, c3]);
    }
}

// ---------------------------------------------------------------------------
// unittest: winding correctness — each face's normal points away from center.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    import std.conv : to;

    // Default unit cube — 8 verts / 6 faces.
    {
        Mesh m;
        BoxParams p;  // defaults: 1x1x1 at origin, 1 segment
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 8,  "default: expected 8 verts");
        assert(m.faces.length    == 6,  "default: expected 6 faces");

        Vec3 cen = Vec3(0, 0, 0);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 n  = m.faceNormal(fi);
            // Compute face centroid
            Vec3 fc = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / m.faces[fi].length);
            float d = dot(n, fc - cen);
            assert(d > 0.0f, "face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // 2/2/2 segments — 26 verts / 24 faces.
    {
        Mesh m;
        BoxParams p;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 26, "2/2/2: expected 26 verts");
        assert(m.faces.length    == 24, "2/2/2: expected 24 faces");

        Vec3 cen = Vec3(0, 0, 0);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 n  = m.faceNormal(fi);
            Vec3 fc = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / m.faces[fi].length);
            float d = dot(n, fc - cen);
            assert(d > 0.0f, "2/2/2 face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // sizeY=0 → XZ plane, 4 verts / 1 face.
    {
        Mesh m;
        BoxParams p;
        p.sizeY = 0.0f;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 4, "plane: expected 4 verts");
        assert(m.faces.length    == 1, "plane: expected 1 face");
    }

    // Non-uniform segments 3/1/2 — faces = 2*(3+1*3+3*2) nope, count properly:
    // -X face: ny*nz = 1*2 = 2; +X: 2; -Y: nx*nz = 3*2 = 6; +Y: 6; -Z: nx*ny = 3*1 = 3; +Z: 3
    // Total = 2+2+6+6+3+3 = 22
    {
        Mesh m;
        BoxParams p;
        p.segmentsX = 3; p.segmentsY = 1; p.segmentsZ = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.faces.length == 22, "3/1/2: expected 22 faces");
    }

    // Rounded cube topology — segments=1,1,1 baseline (MODO formula: verts=8(n²+n+1)).
    // All faces must have outward normals (dot(normal, centroid - origin) > 0).
    foreach (n; [1, 2, 3, 4]) {
        Mesh m;
        BoxParams p;
        p.radius    = 0.1f;
        p.segmentsR = n;
        p.axis      = 1;  // Y-primary (axis=Y verified against MODO)
        buildCuboidParametric(&m, p);
        m.buildLoops();

        size_t expectedVerts = 8 * (n * n + n + 1);
        size_t expectedFaces = 8 * n * n + 12 * n + 6;
        import std.conv : to;
        assert(m.vertices.length == expectedVerts,
               "rounded n=" ~ n.to!string ~ ": expected " ~ expectedVerts.to!string
               ~ " verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length == expectedFaces,
               "rounded n=" ~ n.to!string ~ ": expected " ~ expectedFaces.to!string
               ~ " faces, got " ~ m.faces.length.to!string);

        // All face normals must point outward (away from cube center).
        Vec3 cen = Vec3(p.cenX, p.cenY, p.cenZ);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            Vec3 fc  = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / cast(float)m.faces[fi].length);
            float d = dot(fn_, fc - cen);
            assert(d > 0.0f, "rounded n=" ~ n.to!string
                   ~ " face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // Rounded cube with segments > 1 — MODO-probed topology counts (Phase 6.1c).
    // Formula: ring_size = 2*(nx+1)+2*(nz+1)+4*(sR-1)
    //          verts = 2*(nx+1)*(nz+1) + (2*sR + ny-1) * ring_size
    import std.conv : to;
    {
        // (2,1,1) sR=1: 32v/34f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.segmentsX = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 32, "rounded (2,1,1) sR=1: expected 32 verts, got " ~ m.vertices.length.to!string);
    }
    {
        // (2,2,2) sR=1: 54v/56f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 54, "rounded (2,2,2) sR=1: expected 54 verts, got " ~ m.vertices.length.to!string);
    }
    {
        // (2,2,2) sR=2: 98v/104f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 2;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 98, "rounded (2,2,2) sR=2: expected 98 verts, got " ~ m.vertices.length.to!string);
    }
    {
        // (3,3,3) sR=1: 96v/98f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1;
        p.segmentsX = 3; p.segmentsY = 3; p.segmentsZ = 3;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 96, "rounded (3,3,3) sR=1: expected 96 verts, got " ~ m.vertices.length.to!string);
    }
    // All face normals outward for rounded segments case.
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 2;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        Vec3 cen = Vec3(0, 0, 0);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            Vec3 fc  = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / cast(float)m.faces[fi].length);
            float d = dot(fn_, fc - cen);
            assert(d > 0.0f, "rounded (2,2,2) sR=2 face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // ---------------------------------------------------------------------------
    // Rounded plane topology — MODO-probed counts (Phase 6.1d).
    // Formula: verts = ringSize + (segAe+1)*(segBe+1)
    //          where ringSize = 2*(segAe+1) + 2*(segBe+1) + 4*(sR-1)
    //          faces = segAe*segBe + 2*segAe + 2*segBe + 4*sR
    // ---------------------------------------------------------------------------

    // Helper: check all face normals point toward the given outward direction.
    void checkPlaneNormals(ref Mesh m, Vec3 outwardDir, string tag) {
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            float d = dot(fn_, outwardDir);
            assert(d > 0.0f, tag ~ ": face " ~ fi.to!string ~ " has wrong normal");
        }
    }

    // XZ plane (sizeY=0), sR=1, seg=(1,1) → 12v/9f
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 12, "rounded plane XZ sR=1 seg(1,1): expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    ==  9, "rounded plane XZ sR=1 seg(1,1): expected 9 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=1 seg(1,1)");
    }

    // XZ plane, sR=2, seg=(1,1) → 16v/13f
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 16, "rounded plane XZ sR=2 seg(1,1): expected 16 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 13, "rounded plane XZ sR=2 seg(1,1): expected 13 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=2 seg(1,1)");
    }

    // XZ plane, sR=1, seg=(2,1,2) → 21v/16f
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        p.segmentsX = 2; p.segmentsZ = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 21, "rounded plane XZ sR=1 seg(2,2): expected 21 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 16, "rounded plane XZ sR=1 seg(2,2): expected 16 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=1 seg(2,2)");
    }

    // YZ plane (sizeX=0), sR=1, seg=(1,1) → 12v/9f, outward=+X
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 0.0f; p.sizeY = 1.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 12, "rounded plane YZ sR=1 seg(1,1): expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    ==  9, "rounded plane YZ sR=1 seg(1,1): expected 9 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(1, 0, 0), "YZ sR=1 seg(1,1)");
    }

    // XY plane (sizeZ=0), sR=1, seg=(1,1) → 12v/9f, outward=+Z
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 1.0f; p.sizeZ = 0.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 12, "rounded plane XY sR=1 seg(1,1): expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    ==  9, "rounded plane XY sR=1 seg(1,1): expected 9 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 0, 1), "XY sR=1 seg(1,1)");
    }

    // General topology formula check: faces = segAe*segBe + 2*segAe + 2*segBe + 4*sR
    // verts = 2*(segAe+1)+2*(segBe+1)+4*(sR-1) + (segAe+1)*(segBe+1)
    {
        // XZ plane, sR=3, seg=(2,1,3): segAe=2, segBe=3
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 3;
        p.segmentsX = 2; p.segmentsZ = 3;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        int segAe = 2, segBe = 3, sR3 = 3;
        size_t expV = 2*(segAe+1)+2*(segBe+1)+4*(sR3-1) + (segAe+1)*(segBe+1);
        size_t expF = segAe*segBe + 2*segAe + 2*segBe + 4*sR3;
        assert(m.vertices.length == expV, "rounded plane formula verts: expected " ~ expV.to!string ~ " got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == expF, "rounded plane formula faces: expected " ~ expF.to!string ~ " got " ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=3 seg(2,3)");
    }

    // ---------------------------------------------------------------------------
    // Phase 6.1c: sharp rounded cube — MODO-probed vertex/face counts.
    // Formula:
    //   rs_sharp   = 2*(nx+1) + 2*(nz+1) + 4*(n+1)
    //   rings_half = n+2
    //   total_verts = 2*(nx+1)*(nz+1) + 2*(n+2)*rs_sharp
    //   (deduplication means equatorial ring is not double-counted — same verts)
    //
    //   Verified counts: sR=1→104v/114f, sR=2→168v/182f, sR=3→248v/266f
    // ---------------------------------------------------------------------------

    // Helper: count faces with outward normal (for sharp checks that tolerate
    // the flat cap-level corner triangles which intentionally have +Y/-Y normals
    // matching MODO's topology — these boundary triangles lie on the cap plane).
    int countOutwardFaces(ref Mesh m, Vec3 cen = Vec3(0,0,0)) {
        int ok = 0;
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            Vec3 fc  = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / cast(float)m.faces[fi].length);
            if (dot(fn_, fc - cen) > 0.0f) ++ok;
        }
        return ok;
    }

    // sR=1 sharp: 104v / 114f
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.sharp = true;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 104, "sharp sR=1: expected 104 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 114, "sharp sR=1: expected 114 faces, got " ~ m.faces.length.to!string);
        // Majority of faces should have outward normals; a few flat cap-boundary
        // corner triangles may not (MODO parity: same topology, same winding).
        int ok = countOutwardFaces(m);
        assert(ok >= 106, "sharp sR=1: too few outward faces: " ~ ok.to!string ~ "/114");
    }

    // sR=2 sharp: 168v / 182f
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 2; p.sharp = true;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 168, "sharp sR=2: expected 168 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 182, "sharp sR=2: expected 182 faces, got " ~ m.faces.length.to!string);
        int ok = countOutwardFaces(m);
        assert(ok >= 170, "sharp sR=2: too few outward faces: " ~ ok.to!string ~ "/182");
    }

    // sR=3 sharp: 248v / 266f
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 3; p.sharp = true;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 248, "sharp sR=3: expected 248 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 266, "sharp sR=3: expected 266 faces, got " ~ m.faces.length.to!string);
        int ok = countOutwardFaces(m);
        assert(ok >= 254, "sharp sR=3: too few outward faces: " ~ ok.to!string ~ "/266");
    }

    // Axis swap: sharp sR=1 axis=0 (X-primary) — same counts as Y-primary.
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.sharp = true; p.axis = 0;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 104, "sharp sR=1 axis=X: expected 104 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 114, "sharp sR=1 axis=X: expected 114 faces, got " ~ m.faces.length.to!string);
    }

    // Axis swap: sharp sR=1 axis=2 (Z-primary).
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.sharp = true; p.axis = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 104, "sharp sR=1 axis=Z: expected 104 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 114, "sharp sR=1 axis=Z: expected 114 faces, got " ~ m.faces.length.to!string);
    }
}

// ---------------------------------------------------------------------------
// BoxTool — two-drag 3-D cuboid creation
//
//   Drag 1  (LMB down → move → up)  : draw base rectangle on most-facing plane
//   Drag 2  (LMB down → move → up)  : extrude height along plane normal → cuboid
//   RMB / deactivate                 : cancel current operation
// ---------------------------------------------------------------------------

private enum BoxState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class BoxTool : Tool {
private:
    Mesh*     mesh;
    GpuMesh*  gpu;
    LitShader litShader;

    Mesh    previewMesh;
    GpuMesh previewGpu;

    BoxState  state;

    // Headless/scripted invocation parameters (phase 6.1a).
    // Not automatically synced with the interactive drag state — these are
    // the MODO-aligned schema fields used by applyHeadless() only.
    BoxParams params_;

    // Base rectangle (axis-aligned on the most-facing plane)
    Vec3    startPoint;
    Vec3    currentPoint;
    Vec3[4] baseCorners;

    // Height extrusion
    float height;
    Vec3  hpn;
    Vec3  hpOrigin;       // base centroid, origin of height plane
    Vec3  heightDragStart; // world hit at second LMB press

    // Plane chosen at first click
    Vec3  planeNormal;
    Vec3  planeAxis1;
    Vec3  planeAxis2;

    Viewport cachedVp;

    // Move gizmo (axis-only, no plane circles)
    MoveHandler mover;
    int         moverDragAxis = -1;   // 0/1/2 = X/Y/Z, -1 = none
    int         moverLastMX, moverLastMY;

    // Edge midpoint handles (BaseSet only)
    // 0 = edge 0-1, 1 = edge 1-2, 2 = edge 2-3, 3 = edge 3-0
    BoxHandler[4] edgeH;
    int           edgeDragIdx    = -1;
    int           edgeHoveredIdx = -1;
    int           edgeLastMX, edgeLastMY;

    BoxHandler[2] heightH;           // [0] = bottom face, [1] = top face
    int           heightHDragIdx  = -1;  // -1 = none, 0/1 = which handle is dragging
    bool          heightHHovered  = false;

    // Phase C-followup: undo plumbing. Pre-commit mesh state is captured
    // in deactivate() right before commitBase / commitCuboid mutates the
    // cage; post-state is captured immediately after, and one
    // MeshBevelEdit lands on history. Both nullable for legacy / tests.
    CommandHistory  history;
    BoxEditFactory  boxEditFactory;

public:
    bool meshChanged;

    this(Mesh* mesh, GpuMesh* gpu, LitShader litShader) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0,0,0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        foreach (i; 0 .. 4)
            edgeH[i] = new BoxHandler(Vec3(0,0,0), Vec3(0.9f, 0.2f, 0.2f));
        foreach (i; 0 .. 2)
            heightH[i] = new BoxHandler(Vec3(0,0,0), Vec3(0.9f, 0.9f, 0.2f));
    }

    void destroy() {
        mover.destroy();
        foreach (h; edgeH) h.destroy();
        foreach (h; heightH) h.destroy();
    }

    /// Inject undo plumbing — called by app.d after construction.
    /// commitBoxEdit() is a no-op when these aren't bound.
    void setUndoBindings(CommandHistory h, BoxEditFactory factory) {
        this.history        = h;
        this.boxEditFactory = factory;
    }

    override string name() const { return "Box"; }

    override void activate() {
        state           = BoxState.Idle;
        meshChanged     = false;
        moverDragAxis   = -1;
        edgeDragIdx     = -1;
        heightHDragIdx  = -1;
        heightHHovered  = false;
        height          = 0.0f;
        previewGpu.init();
    }

    override void deactivate() {
        // Decide what (if anything) is going to be committed; capture the
        // pre-commit snapshot ONLY when we're about to mutate the cage,
        // so an empty Idle deactivate doesn't pollute the undo stack.
        bool willCommit = (state == BoxState.BaseSet)
                       || (state >= BoxState.DrawingHeight && abs(height) > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == BoxState.BaseSet)
            commitBase();
        else if (state >= BoxState.DrawingHeight && abs(height) > 1e-5f)
            commitCuboid();
        state = BoxState.Idle;
        previewGpu.destroy();

        if (willCommit) commitBoxEdit(pre);
    }

    private void commitBoxEdit(MeshSnapshot pre) {
        if (history is null || boxEditFactory is null) return;
        if (!pre.filled) return;
        auto cmd  = boxEditFactory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Box");
        history.record(cmd);
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != BoxState.Idle) {
            state = BoxState.Idle;
            return true;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        // Edge handle hit-test (BaseSet / HeightSet)
        if (state == BoxState.BaseSet || state == BoxState.HeightSet) {
            foreach (i, h; edgeH) {
                if (h.hitTest(e.x, e.y, cachedVp)) {
                    edgeDragIdx = cast(int)i;
                    edgeLastMX  = e.x;
                    edgeLastMY  = e.y;
                    return true;
                }
            }
        }

        // Height handles (BaseSet / HeightSet) — priority over mover centerBox
        // BaseSet: only bottom [0]; HeightSet: both [0] and [1]
        int heightHHitIdx = -1;
        if (heightH[0].hitTest(e.x, e.y, cachedVp))
            heightHHitIdx = 0;
        else if (state == BoxState.HeightSet && heightH[1].hitTest(e.x, e.y, cachedVp))
            heightHHitIdx = 1;
        if ((state == BoxState.BaseSet || state == BoxState.HeightSet) && heightHHitIdx >= 0) {
            heightHDragIdx = heightHHitIdx;
            setupHeightPlane();
            Vec3 hhit;
            bool hhitOk = rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                            hpOrigin, hpn, hhit);
            if (heightHHitIdx == 1) {
                // Top handle: non-incremental drag; anchor so current height is preserved.
                heightDragStart = hhitOk
                    ? hhit - planeNormal * height
                    : hpOrigin;
            } else {
                // Bottom handle: incremental drag; anchor at the current hit point.
                heightDragStart = hhitOk ? hhit : hpOrigin;
            }
            if (state == BoxState.BaseSet) {
                height = 0.0f;
                state  = BoxState.DrawingHeight;
            }
            uploadCuboid();
            return true;
        }

        // Move gizmo hit-test only once the base is finalized
        if (state >= BoxState.BaseSet) {
            int hit = moverHitTest(e.x, e.y);
            if (hit >= 0) {
                moverDragAxis  = hit;
                moverLastMX    = e.x;
                moverLastMY    = e.y;
                return true;
            }
        }

        if (state == BoxState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0,0,0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            state        = BoxState.DrawingBase;
            uploadBase();
            return true;
        }

        if (state == BoxState.BaseSet) {
            height = 0.0f;
            setupHeightPlane();
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            state = BoxState.DrawingHeight;
            uploadCuboid();
            return true;
        }

        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (edgeDragIdx >= 0) { edgeDragIdx = -1; return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }
        if (heightHDragIdx >= 0 && state == BoxState.HeightSet) { heightHDragIdx = -1; return true; }

        if (state == BoxState.DrawingBase) {
            computeBaseCorners();
            Vec3 d = currentPoint - startPoint;
            float dd1 = dot(d, planeAxis1);
            float dd2 = dot(d, planeAxis2);
            // Also rejects NaN (NaN comparisons are false, so !(dd1 > 1e-5f) catches NaN).
            if (!(abs(dd1) > 1e-5f) || !(abs(dd2) > 1e-5f)) {
                state = BoxState.Idle;
                return true;
            }
            state = BoxState.BaseSet;
            uploadBase();
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            state = BoxState.HeightSet;
            heightHDragIdx = -1;
            return true;
        }

        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (edgeDragIdx >= 0) {
            Vec3 moveAxis = (edgeDragIdx == 0 || edgeDragIdx == 2) ? planeAxis2 : planeAxis1;
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, edgeLastMX, edgeLastMY,
                                         edgeH[edgeDragIdx].pos, moveAxis, cachedVp, skip);
            if (!skip) applyEdgeDelta(edgeDragIdx, delta);
            edgeLastMX = e.x;
            edgeLastMY = e.y;
            return true;
        }

        if (moverDragAxis >= 0) {
            bool skip;
            Vec3 delta = moverDragAxis <= 2
                ? axisDragDelta (e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover, cachedVp, skip)
                : planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover.center, cachedVp, skip);
            if (!skip) applyMoverDelta(delta);
            moverLastMX = e.x;
            moverLastMY = e.y;
            return true;
        }

        // heightH drag in HeightSet (re-drag without changing state)
        if (heightHDragIdx >= 0 && state == BoxState.HeightSet) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                if (heightHDragIdx == 1) {
                    // Top handle: move top face, base stays.
                    height = dot(hit - heightDragStart, planeNormal);
                } else {
                    // Bottom handle: move base, top face stays.
                    // Incremental delta so the top face world position is preserved.
                    float delta = dot(hit - heightDragStart, planeNormal);
                    Vec3  d     = planeNormal * delta;
                    startPoint   += d;
                    currentPoint += d;
                    hpOrigin     += d;
                    foreach (ref c; baseCorners) c += d;
                    height      -= delta;
                    heightDragStart = hit; // incremental: advance anchor each frame
                }
                uploadCuboid();
            }
            return true;
        }

        // Track hover over edge/height handles when nothing is being dragged
        if (state == BoxState.BaseSet || state == BoxState.HeightSet) {
            edgeHoveredIdx = -1;
            heightHHovered = false;
            foreach (i, h; edgeH)
                if (h.hitTest(e.x, e.y, cachedVp)) { edgeHoveredIdx = cast(int)i; break; }
            if (edgeHoveredIdx < 0) {
                heightHHovered = heightH[0].hitTest(e.x, e.y, cachedVp) ||
                                 (state == BoxState.HeightSet && heightH[1].hitTest(e.x, e.y, cachedVp));
            }
        } else {
            edgeHoveredIdx = -1;
            heightHHovered = false;
        }

        if (state == BoxState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  Vec3(0,0,0), planeNormal, hit))
            {
                currentPoint = hit;
                uploadBase();
            }
            return true;
        }

        if (state == BoxState.DrawingHeight) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                height = dot(hit - heightDragStart, planeNormal);
                uploadCuboid();
            }
            return true;
        }

        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == BoxState.Idle) return;

        immutable float[16] identity = identityMatrix;
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

        // --- Solid faces ---
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

        // --- Wireframe edges ---
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);

        previewGpu.drawEdges(shader.locColor, -1, []);

        // Draw edge and height handles (BaseSet and above)
        if (state >= BoxState.BaseSet) {
            updateEdgeHandlers(vp);
            updateHeightHandler(vp);
            bool moverBusy  = moverDragAxis >= 0;
            bool anyEdgeBusy = edgeDragIdx >= 0;
            foreach (i, h; edgeH) {
                h.setForceHovered(edgeDragIdx == cast(int)i);
                h.setHoverBlocked(moverBusy || (anyEdgeBusy && edgeDragIdx != cast(int)i));
                h.draw(shader, vp);
            }
            bool heightBlocked  = moverBusy || anyEdgeBusy || edgeHoveredIdx >= 0;
            bool anyHeightBusy  = heightHDragIdx >= 0 || state == BoxState.DrawingHeight;
            // In DrawingHeight the top face moves with the mouse — heightH[1] is active.
            // In HeightSet it depends on which handle was grabbed.
            bool h0Force = (state == BoxState.HeightSet) && (heightHDragIdx == 0);
            bool h1Force = (state == BoxState.DrawingHeight) || ((state == BoxState.HeightSet) && (heightHDragIdx == 1));
            heightH[0].setForceHovered(h0Force);
            heightH[0].setHoverBlocked(heightBlocked || (anyHeightBusy && !h0Force));
            heightH[0].draw(shader, vp);
            if (state >= BoxState.DrawingHeight) {
                heightH[1].setForceHovered(h1Force);
                heightH[1].setHoverBlocked(heightBlocked || (anyHeightBusy && !h1Force));
                heightH[1].draw(shader, vp);
            }
        }

        // Draw move gizmo only once the base is finalized
        if (state >= BoxState.BaseSet) {
            mover.setPosition(boxCenter());
            mover.arrowX.setForceHovered(moverDragAxis == 0);
            mover.arrowY.setForceHovered(moverDragAxis == 1);
            mover.arrowZ.setForceHovered(moverDragAxis == 2);
            mover.centerBox.setForceHovered(moverDragAxis == 3);
            bool edgePriority = edgeDragIdx >= 0 || edgeHoveredIdx >= 0 || heightHHovered || heightHDragIdx >= 0;
            mover.arrowX.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 0));
            mover.arrowY.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 1));
            mover.arrowZ.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 2));
            mover.centerBox.setHoverBlocked(edgePriority || (moverDragAxis >= 0 && moverDragAxis != 3));
            mover.draw(shader, vp);
        }
    }

    override bool drawImGui() { return false; }

    /// MODO-aligned schema for prim.cube headless invocation.
    /// Phase 6.1a: 9 core attrs (position/size/segments).
    /// Phase 6.1b: 3 rounded-edge attrs (radius/segmentsR/axis).
    /// Phase 6.1c: sharp attr (enabled only when radius > 0 and segmentsR <= 3).
    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Size X",     &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Size Y",     &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Size Z",     &params_.sizeZ, 1.0f).min(0.0f),
            Param.int_("segmentsX", "Segments X", &params_.segmentsX, 1).min(1).max(64),
            Param.int_("segmentsY", "Segments Y", &params_.segmentsY, 1).min(1).max(64),
            Param.int_("segmentsZ", "Segments Z", &params_.segmentsZ, 1).min(1).max(64),
            Param.float_("radius",    "Radius",          &params_.radius,    0.0f).min(0.0f),
            Param.int_(  "segmentsR", "Radius Segments", &params_.segmentsR, 3  ).min(1).max(64),
            Param.bool_( "sharp",     "Sharp",           &params_.sharp,     false),
            Param.intEnum_("axis", "Axis", cast(int*)&params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    /// Disable `sharp` when radius == 0 or segmentsR > 3 (no K-table entry).
    override bool paramEnabled(string name) const {
        if (name == "sharp")
            return params_.radius > 1e-9f && params_.segmentsR <= 3;
        return true;
    }

    /// Headless one-shot: build a cuboid from params_ and replace the scene mesh.
    /// Called by ToolHeadlessCommand.apply(); the command wraps this with a
    /// snapshot pair for undo. GPU upload + cache refresh are handled by the caller.
    override bool applyHeadless() {
        Mesh fresh;
        buildCuboidParametric(&fresh, params_);
        fresh.buildLoops();
        fresh.resetSelection();
        *mesh = fresh;
        gpu.upload(*mesh);
        return true;
    }

    override void drawProperties() {
        if (state == BoxState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw a base.");
        // Schema panel (property_panel.d) handles all param widgets.
    }

    /// Re-evaluate the preview from params_ after a schema slider change.
    /// Called by PropertyPanel immediately after onParamChanged().
    override void evaluate() {
        // No preview exists yet in Idle — nothing to update.
        if (state == BoxState.Idle) return;

        // Schema is the source of truth for tweaks made via property panel.
        // Rebuild preview directly from params_, bypassing the interactive
        // drag-state mapping in buildCuboid().
        previewMesh.clear();
        buildCuboidParametric(&previewMesh, params_);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

private:
    // Center of the current box shape (base centroid shifted by half height).
    Vec3 boxCenter() const {
        Vec3 c = baseCentroid();
        if (state >= BoxState.DrawingHeight)
            c = c + planeNormal * (height * 0.5f);
        return c;
    }

    // Hit-test axis arrows (0/1/2) and centerBox (3).
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

    // Apply world-space delta to all box geometry.
    void applyMoverDelta(Vec3 d) {
        startPoint      = startPoint      + d;
        currentPoint    = currentPoint    + d;
        hpOrigin        = hpOrigin        + d;
        heightDragStart = heightDragStart + d;
        foreach (ref c; baseCorners) c = c + d;
        uploadPreview();
    }

    // Color by world axis direction.
    static Vec3 axisColor(Vec3 axis) {
        if (abs(axis.x) > 0.5f) return Vec3(0.9f, 0.2f, 0.2f);
        if (abs(axis.y) > 0.5f) return Vec3(0.2f, 0.9f, 0.2f);
        return Vec3(0.2f, 0.2f, 0.9f);
    }

    // Update height handles.
    // [0] = bottom face center (baseCentroid), always.
    // [1] = top face center (baseCentroid + height), DrawingHeight/HeightSet only.
    void updateHeightHandler(const ref Viewport vp) {
        Vec3 bot = baseCentroid();
        Vec3 top = bot + planeNormal * height;
        Vec3[2] pts = [bot, top];
        foreach (i; 0 .. 2) {
            heightH[i].pos   = pts[i];
            heightH[i].size  = gizmoSize(pts[i], vp, 0.04f);
            heightH[i].color = axisColor(planeNormal);
        }
    }

    // Update edge handler positions, sizes and colors.
    // BaseSet            → midpoints of base edges.
    // DrawingHeight/HeightSet → centers of the 4 side faces (edge midpoints + half height).
    void updateEdgeHandlers(const ref Viewport vp) {
        Vec3 halfH = (state >= BoxState.DrawingHeight)
            ? planeNormal * (height * 0.5f)
            : Vec3(0, 0, 0);

        static immutable int[4][4] edgePairs = [[0,1],[1,2],[2,3],[3,0]];
        Vec3[4] mids;
        foreach (i, pair; edgePairs)
            mids[i] = (baseCorners[pair[0]] + baseCorners[pair[1]]) * 0.5f + halfH;

        Vec3[4] colors = [axisColor(planeAxis2), axisColor(planeAxis1),
                          axisColor(planeAxis2), axisColor(planeAxis1)];

        foreach (i; 0 .. 4) {
            edgeH[i].pos   = mids[i];
            edgeH[i].size  = gizmoSize(mids[i], vp, 0.04f);
            edgeH[i].color = colors[i];
        }
    }

    // Move one edge of the base rectangle along its perpendicular axis.
    // Edge 0 (corners 0,1): shift startPoint along axis2
    // Edge 1 (corners 1,2): extend currentPoint along axis1
    // Edge 2 (corners 2,3): extend currentPoint along axis2
    // Edge 3 (corners 3,0): shift startPoint along axis1
    void applyEdgeDelta(int idx, Vec3 delta) {
        switch (idx) {
            case 0: startPoint   = startPoint   + planeAxis2 * dot(delta, planeAxis2); break;
            case 1: currentPoint = currentPoint + planeAxis1 * dot(delta, planeAxis1); break;
            case 2: currentPoint = currentPoint + planeAxis2 * dot(delta, planeAxis2); break;
            case 3: startPoint   = startPoint   + planeAxis1 * dot(delta, planeAxis1); break;
            default: break;
        }
        uploadPreview();
    }

    void choosePlane(const ref Viewport vp) {
        auto bp    = pickMostFacingPlane(vp);
        planeNormal = bp.normal;
        planeAxis1  = bp.axis1;
        planeAxis2  = bp.axis2;
    }

    void computeBaseCorners() {
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        baseCorners[0] = startPoint;
        baseCorners[1] = startPoint   + planeAxis1 * d1;
        baseCorners[2] = baseCorners[1] + planeAxis2 * d2;
        baseCorners[3] = startPoint     + planeAxis2 * d2;
    }

    void buildBase(Mesh* m) {
        // Map interactive base drag → axis-aligned BoxParams with the
        // plane-normal axis size left at 0 (plane mode). Then delegate to
        // buildCuboidParametric so the same subdivision/segments path
        // applies to base preview as to evaluate() (segments slider).
        // Without this sync, evaluate() during BaseSet would build from
        // default params_ (1×1×1 at origin) instead of the drag rectangle.
        computeBaseCorners();
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        Vec3  cen = baseCentroid();

        BoxParams p = params_;
        p.cenX = cen.x; p.cenY = cen.y; p.cenZ = cen.z;
        p.sizeX = 0.0f; p.sizeY = 0.0f; p.sizeZ = 0.0f;
        void writeSize(Vec3 axisVec, float magnitude) {
            if      (abs(axisVec.x) > 0.5f) p.sizeX = abs(magnitude);
            else if (abs(axisVec.y) > 0.5f) p.sizeY = abs(magnitude);
            else if (abs(axisVec.z) > 0.5f) p.sizeZ = abs(magnitude);
        }
        writeSize(planeAxis1, d1);
        writeSize(planeAxis2, d2);
        // planeNormal axis intentionally NOT written — stays 0 → plane mode.

        // Sync back so the schema panel reflects the drag rectangle.
        params_.cenX  = p.cenX;  params_.cenY  = p.cenY;  params_.cenZ  = p.cenZ;
        params_.sizeX = p.sizeX; params_.sizeY = p.sizeY; params_.sizeZ = p.sizeZ;

        buildCuboidParametric(m, p);
    }

    void uploadBase() {
        previewMesh.clear();
        buildBase(&previewMesh);
        previewGpu.upload(previewMesh);
    }

    // Upload whichever preview is appropriate for the current state.
    void uploadPreview() {
        if (state >= BoxState.DrawingHeight)
            uploadCuboid();
        else
            uploadBase();
    }

    void commitBase() {
        buildBase(mesh);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    Vec3 baseCentroid() const {
        return Vec3(
            (baseCorners[0].x + baseCorners[1].x + baseCorners[2].x + baseCorners[3].x) * 0.25f,
            (baseCorners[0].y + baseCorners[1].y + baseCorners[2].y + baseCorners[3].y) * 0.25f,
            (baseCorners[0].z + baseCorners[1].z + baseCorners[2].z + baseCorners[3].z) * 0.25f,
        );
    }

    void setupHeightPlane() {
        hpOrigin = baseCentroid();
        Vec3 toCamera = cachedVp.eye - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f
            ? inPlane / len
            : planeAxis1;
    }

    void buildCuboid(Mesh* m) {
        // Map interactive drag state → axis-aligned BoxParams so the
        // parametric builder handles segments correctly.
        // pickMostFacingPlane guarantees each axis is one of ±X/Y/Z.
        computeBaseCorners();
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);

        Vec3 cen = baseCentroid();
        if (state >= BoxState.DrawingHeight)
            cen = cen + planeNormal * (height * 0.5f);

        // Snapshot: keeps user-set segmentsX/Y/Z, overwrites pos/size below.
        BoxParams p = params_;
        p.cenX = cen.x; p.cenY = cen.y; p.cenZ = cen.z;
        p.sizeX = 0.0f; p.sizeY = 0.0f; p.sizeZ = 0.0f;

        // Write each drag magnitude into the matching world axis size slot.
        void writeSize(Vec3 axisVec, float magnitude) {
            if      (abs(axisVec.x) > 0.5f) p.sizeX = abs(magnitude);
            else if (abs(axisVec.y) > 0.5f) p.sizeY = abs(magnitude);
            else if (abs(axisVec.z) > 0.5f) p.sizeZ = abs(magnitude);
        }
        writeSize(planeAxis1, d1);
        writeSize(planeAxis2, d2);
        if (state >= BoxState.DrawingHeight)
            writeSize(planeNormal, height);

        // Sync back so the schema panel reflects the current drag state.
        params_.cenX  = p.cenX;  params_.cenY  = p.cenY;  params_.cenZ  = p.cenZ;
        params_.sizeX = p.sizeX; params_.sizeY = p.sizeY; params_.sizeZ = p.sizeZ;

        buildCuboidParametric(m, p);
    }

    void uploadCuboid() {
        previewMesh.clear();
        buildCuboid(&previewMesh);
        previewGpu.upload(previewMesh);
    }

    void commitCuboid() {
        buildCuboid(mesh);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }
}
