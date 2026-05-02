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
private void buildRoundedCubeAxisY(Mesh* dst, const ref BoxParams p)
{
    import std.conv : to;
    import std.typecons : Tuple, tuple;

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
// ---------------------------------------------------------------------------
void buildCuboidParametric(Mesh* dst, const ref BoxParams p)
{
    import std.typecons : Tuple, tuple;

    // Rounded cube path: radius > epsilon → delegate to rounded generator.
    // Plane mode (any size = 0) ignores radius — flat face always sharp.
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

    // Plane mode detection — any zero-size axis collapses to a single face.
    if (abs(p.sizeY) < 1e-9f) {
        // XZ plane at cenY
        Vec3 c = Vec3(p.cenX, p.cenY, p.cenZ);
        Vec3 a = Vec3(p.sizeX * 0.5f, 0.0f, 0.0f);
        Vec3 b = Vec3(0.0f, 0.0f, p.sizeZ * 0.5f);
        uint v0 = dst.addVertex(c - a - b);
        uint v1 = dst.addVertex(c + a - b);
        uint v2 = dst.addVertex(c + a + b);
        uint v3 = dst.addVertex(c - a + b);
        // Winding: outward normal is +Y for XZ plane.
        // Cross((v1-v0),(v3-v0)) = cross(+2a, +2b) = 4*(a×b).
        // a=(sx,0,0), b=(0,0,sz): a×b = (0*sz-0*0, 0*0-sx*sz, sx*0-0*0)
        //   = (0, -sx*sz, 0) → points -Y.
        // So v0,v1,v2,v3 gives -Y normal; reverse to v0,v3,v2,v1 for +Y.
        dst.addFace([v0, v3, v2, v1]);
        return;
    }
    if (abs(p.sizeX) < 1e-9f) {
        // YZ plane at cenX
        Vec3 c = Vec3(p.cenX, p.cenY, p.cenZ);
        Vec3 a = Vec3(0.0f, p.sizeY * 0.5f, 0.0f);
        Vec3 b = Vec3(0.0f, 0.0f, p.sizeZ * 0.5f);
        uint v0 = dst.addVertex(c - a - b);
        uint v1 = dst.addVertex(c + a - b);
        uint v2 = dst.addVertex(c + a + b);
        uint v3 = dst.addVertex(c - a + b);
        // a=(0,sy,0), b=(0,0,sz): a×b=(sy*sz-0,0-0,0-0)=(sy*sz,0,0) → +X.
        // Cross((v1-v0),(v3-v0)) = cross(+2a,+2b) → +X. OK as-is.
        dst.addFace([v0, v1, v2, v3]);
        return;
    }
    if (abs(p.sizeZ) < 1e-9f) {
        // XY plane at cenZ
        Vec3 c = Vec3(p.cenX, p.cenY, p.cenZ);
        Vec3 a = Vec3(p.sizeX * 0.5f, 0.0f, 0.0f);
        Vec3 b = Vec3(0.0f, p.sizeY * 0.5f, 0.0f);
        uint v0 = dst.addVertex(c - a - b);
        uint v1 = dst.addVertex(c + a - b);
        uint v2 = dst.addVertex(c + a + b);
        uint v3 = dst.addVertex(c - a + b);
        // a=(sx,0,0), b=(0,sy,0): a×b=(0,0,sx*sy) → +Z.
        dst.addFace([v0, v1, v2, v3]);
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
            Param.intEnum_("axis", "Axis", cast(int*)&params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
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
        computeBaseCorners();
        // Capture the indices addVertex returns — the dst mesh may already
        // have geometry (preview or scene), so we cannot assume verts 0..3.
        uint[4] vi;
        foreach (i, c; baseCorners) vi[i] = m.addVertex(c);
        Vec3 n     = cross(baseCorners[1] - baseCorners[0],
                           baseCorners[2] - baseCorners[0]);
        Vec3 toEye = cachedVp.eye - baseCentroid();
        if (dot(n, toEye) >= 0)
            m.addFace([vi[0], vi[1], vi[2], vi[3]]);
        else
            m.addFace([vi[0], vi[3], vi[2], vi[1]]);
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
