// Module unittests for `tools.create.tube`, moved verbatim out of source/tools/create/tube.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.create.tube_test;

import bindbc.sdl;
import operator : VectorStack;
import mesh;
import math;
import params : Param;
import shader : LitShader;
import tools.create.primitive_create_tool : PrimitiveCreateTool;
import tools.create.create_common : snapLocalHit;
import editmode : EditMode;
import snap_render : publishLastSnap;
import std.math : sin, cos, PI, abs, sqrt;
import tools.create.tube;

// ---------------------------------------------------------------------------
// Pure module unittests for buildTube (run by `dub test --config=tests`).
// ---------------------------------------------------------------------------
unittest {  // (a) default → 96 verts / 96 faces (S=24, capped)
    Mesh m;
    TubeParams p;   // defaults: outerRadius=1, innerRadius=0.5, height=2, S=24, cap=true
    buildTube(&m, p);
    assert(m.vertices.length == 96,
        "default tube: expected 96 verts, got " ~ m.vertices.length.stringof);
    assert(m.faces.length == 96,
        "default tube: expected 96 faces, got " ~ m.faces.length.stringof);
}

unittest {  // (b) on-circle radii and axis positions
    import std.math : fabs, sqrt;
    Mesh m;
    TubeParams p;
    p.outerRadius = 2.0f;
    p.innerRadius = 1.0f;
    p.height      = 4.0f;
    p.segments    = 8;
    p.axis        = 1;   // Y
    buildTube(&m, p);
    // outerBottom: verts 0..7  — Y=-2, perp radius=2
    // outerTop:    verts 8..15 — Y=+2, perp radius=2
    // innerBottom: verts 16..23 — Y=-2, perp radius=1
    // innerTop:    verts 24..31 — Y=+2, perp radius=1
    assert(m.vertices.length == 32);
    // Check axis coords and radii for a few verts.
    auto v = m.vertices;
    foreach (j; 0 .. 8) {
        // outerBottom
        assert(fabs(v[j].y + 2.0f) < 1e-4f);
        float rOB = sqrt(v[j].x*v[j].x + v[j].z*v[j].z);
        assert(fabs(rOB - 2.0f) < 1e-4f);
        // outerTop
        assert(fabs(v[8 + j].y - 2.0f) < 1e-4f);
        float rOT = sqrt(v[8+j].x*v[8+j].x + v[8+j].z*v[8+j].z);
        assert(fabs(rOT - 2.0f) < 1e-4f);
        // innerBottom
        assert(fabs(v[16 + j].y + 2.0f) < 1e-4f);
        float rIB = sqrt(v[16+j].x*v[16+j].x + v[16+j].z*v[16+j].z);
        assert(fabs(rIB - 1.0f) < 1e-4f);
        // innerTop
        assert(fabs(v[24 + j].y - 2.0f) < 1e-4f);
        float rIT = sqrt(v[24+j].x*v[24+j].x + v[24+j].z*v[24+j].z);
        assert(fabs(rIT - 1.0f) < 1e-4f);
    }
}

unittest {  // (c) watertight + directed half-edge consistency (capped)
    import std.format : format;
    Mesh m;
    TubeParams p;
    p.segments = 6;
    buildTube(&m, p);

    // Build undirected edge → count map and directed half-edge → count map.
    int[ulong] undirected;
    int[ulong] directed;

    // Encode directed edge (a → b) as ulong.
    static ulong encDir(uint a, uint b) { return (cast(ulong)a << 32) | b; }
    // Encode undirected edge as canonical pair (min, max).
    static ulong encUnd(uint a, uint b) {
        uint lo = a < b ? a : b;
        uint hi = a < b ? b : a;
        return (cast(ulong)lo << 32) | hi;
    }

    foreach (f; m.faces) {
        for (int i = 0; i < cast(int)f.length; ++i) {
            uint a = f[i];
            uint b = f[(i + 1) % cast(int)f.length];
            directed[encDir(a, b)] += 1;
            undirected[encUnd(a, b)] += 1;
        }
    }

    // Every undirected edge must appear in exactly 2 faces (watertight).
    foreach (k, cnt; undirected)
        assert(cnt == 2, format("watertight: undirected edge has count %d (expected 2)", cnt));

    // Every directed half-edge must appear exactly once (consistent orientation).
    foreach (k, cnt; directed)
        assert(cnt == 1, format("consistency: directed half-edge has count %d (expected 1)", cnt));
}

unittest {  // (d) cap=false → 2*S faces, has boundary edges
    Mesh m;
    TubeParams p;
    p.segments = 6;
    p.cap      = false;
    buildTube(&m, p);
    assert(m.faces.length == 12,   // 2*6 faces
        "cap=false: expected 12 faces");
    assert(m.vertices.length == 24, // still 4*6 verts
        "cap=false: expected 24 verts");

    // At least one boundary edge (undirected edge count == 1).
    int[ulong] undirected;
    static ulong encUnd(uint a, uint b) {
        uint lo = a < b ? a : b;
        uint hi = a < b ? b : a;
        return (cast(ulong)lo << 32) | hi;
    }
    foreach (f; m.faces) {
        for (int i = 0; i < cast(int)f.length; ++i) {
            uint a = f[i];
            uint b = f[(i + 1) % cast(int)f.length];
            undirected[encUnd(a, b)] += 1;
        }
    }
    bool hasBoundary = false;
    foreach (k, cnt; undirected)
        if (cnt == 1) { hasBoundary = true; break; }
    assert(hasBoundary, "cap=false: expected at least one boundary edge");
}

unittest {  // (e) per-family normal SIGN — the inside-out guard
    import std.math : fabs, sqrt;
    import std.format : format;

    Mesh m;
    TubeParams p;
    p.segments = 8;
    p.axis     = 1;   // Y
    buildTube(&m, p);

    int S = p.segments;
    // Face families: [0..S) outer wall, [S..2S) inner wall,
    //                [2S..3S) top cap, [3S..4S) bottom cap.

    // Geometric face normal via cross product of diagonals:
    //   n = (v2-v0) × (v3-v1)
    Vec3 faceNormal(int fi) {
        auto f = m.faces[fi];
        Vec3 v0 = m.vertices[f[0]];
        Vec3 v1 = m.vertices[f[1]];
        Vec3 v2 = m.vertices[f[2]];
        Vec3 v3 = m.vertices[f[3]];
        Vec3 d0 = Vec3(v2.x-v0.x, v2.y-v0.y, v2.z-v0.z);
        Vec3 d1 = Vec3(v3.x-v1.x, v3.y-v1.y, v3.z-v1.z);
        return Vec3(d0.y*d1.z - d0.z*d1.y,
                    d0.z*d1.x - d0.x*d1.z,
                    d0.x*d1.y - d0.y*d1.x);
    }

    // axis=Y: axisIdx=1, +axis direction = (0,1,0).
    // Radial direction for a face = (centroid - axis) projected onto XZ plane.
    Vec3 radialDir(Vec3 cen) {
        // Project onto XZ plane (remove Y component).
        float rx = cen.x - p.cenX;
        float rz = cen.z - p.cenZ;
        float len = sqrt(rx*rx + rz*rz);
        if (len < 1e-9f) return Vec3(1, 0, 0);
        return Vec3(rx/len, 0.0f, rz/len);
    }

    // Outer wall faces [0..S): normal dot radialDir > 0 (outward).
    // Tube faces are always ≥3 verts, so m.faceCentroid's unguarded
    // divide-by-length is a safe no-op here.
    foreach (fi; 0 .. S) {
        Vec3 n    = faceNormal(fi);
        Vec3 cen  = m.faceCentroid(cast(uint)fi);
        Vec3 rdir = radialDir(cen);
        float d   = n.x*rdir.x + n.y*rdir.y + n.z*rdir.z;
        assert(d > 0.0f,
            format("outer wall face %d: normal not outward (dot=%f)", fi, d));
    }

    // Inner wall faces [S..2S): normal dot radialDir < 0 (inward).
    foreach (fi; S .. 2*S) {
        Vec3 n    = faceNormal(fi);
        Vec3 cen  = m.faceCentroid(cast(uint)fi);
        Vec3 rdir = radialDir(cen);
        float d   = n.x*rdir.x + n.y*rdir.y + n.z*rdir.z;
        assert(d < 0.0f,
            format("inner wall face %d: normal not inward (dot=%f)", fi, d));
    }

    // Top cap faces [2S..3S): normal dot (0,1,0) > 0 (+Y).
    foreach (fi; 2*S .. 3*S) {
        Vec3 n = faceNormal(fi);
        assert(n.y > 0.0f,
            format("top cap face %d: normal not +axis (ny=%f)", fi, n.y));
    }

    // Bottom cap faces [3S..4S): normal dot (0,1,0) < 0 (-Y).
    foreach (fi; 3*S .. 4*S) {
        Vec3 n = faceNormal(fi);
        assert(n.y < 0.0f,
            format("bottom cap face %d: normal not -axis (ny=%f)", fi, n.y));
    }
}

unittest {  // degenerate-radii contract: inner=0 → clamped to outerRadius*1e-4
    import std.math : fabs;
    Mesh m;
    TubeParams p;
    p.outerRadius = 1.0f;
    p.innerRadius = 0.0f;   // should be clamped to 1e-4
    p.segments    = 6;
    buildTube(&m, p);
    // Inner bottom ring: verts 12..17 (2*S..3*S-1)
    // Perp radius should be outerRadius*1e-4 = 1e-4.
    import std.math : sqrt;
    foreach (j; 0 .. 6) {
        Vec3 v = m.vertices[12 + j];
        float r = sqrt(v.x*v.x + v.z*v.z);
        assert(r > 0.0f, "clamped inner ring must have non-zero radius");
        assert(fabs(r - 1e-4f) < 1e-5f,
            "inner=0 clamped radius mismatch");
    }
}

unittest {  // degenerate-radii: inner >= outer → clamped to outerRadius*(1-1e-4)
    import std.math : fabs, sqrt;
    Mesh m;
    TubeParams p;
    p.outerRadius = 1.0f;
    p.innerRadius = 2.0f;   // > outer → clamp
    p.segments    = 6;
    buildTube(&m, p);
    float expectedInner = 1.0f * (1.0f - 1e-4f);
    foreach (j; 0 .. 6) {
        Vec3 v = m.vertices[12 + j];
        float r = sqrt(v.x*v.x + v.z*v.z);
        assert(fabs(r - expectedInner) < 1e-4f,
            "inner>=outer clamped radius mismatch");
    }
}
