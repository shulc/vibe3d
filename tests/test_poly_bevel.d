// Tests for mesh.bevel (Polygon Bevel: inset + shift) in Polygons mode.
//
// Cube vertex layout (from makeCube):
//   0:(-0.5,-0.5,-0.5)  1:(0.5,-0.5,-0.5)  2:(0.5,0.5,-0.5)  3:(-0.5,0.5,-0.5)
//   4:(-0.5,-0.5, 0.5)  5:(0.5,-0.5, 0.5)  6:(0.5,0.5, 0.5)  7:(-0.5,0.5, 0.5)
// Cube faces:
//   0:[0,3,2,1]  1:[4,5,6,7]  2:[0,4,7,3]  3:[1,2,6,5]  4:[3,7,6,2]  5:[0,1,5,4]
// Top face (+Y): face 4, centroid (0,0.5,0).
// bevel(inset=0.1,shift=0.2) → cap corners at (±0.4, 0.7, ±0.4).
// bevel(inset=0  ,shift=0.2) → cap corners at (±0.5, 0.7, ±0.5).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// --- HTTP helpers ------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(cast(string)post("http://localhost:8080/api/command", body));
}

void postCommand(string body) {
    auto r = postCommandRaw(body);
    assert(r["status"].str == "ok", "/api/command failed: " ~ body ~ " → " ~ r.toString);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue postRedo() { return parseJSON(post("http://localhost:8080/api/redo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }

// --- geometry helpers --------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

double len3(V3 a) { return sqrt(a.x*a.x + a.y*a.y + a.z*a.z); }
V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
V3 add3(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }

int countAt(JSONValue m, V3 p, double tol=1e-4) {
    int n = 0;
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) ++n;
    return n;
}

V3 faceCentroid(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    V3 c = V3(0, 0, 0);
    foreach (k; 0 .. idx.length) c = add3(c, vert(m, cast(size_t)idx[k].integer));
    return V3(c.x / idx.length, c.y / idx.length, c.z / idx.length);
}

int faceWithCentroid(JSONValue m, V3 target, double tol=0.05) {
    foreach (fi; 0 .. m["faces"].array.length) {
        auto c = faceCentroid(m, m["faces"].array[fi]);
        if (len3(sub3(c, target)) < tol) return cast(int)fi;
    }
    return -1;
}

int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

int[] orphanVerts(JSONValue m) {
    bool[] referenced;
    referenced.length = cast(size_t)m["vertexCount"].integer;
    foreach (f; m["faces"].array)
        foreach (c; f.array) {
            auto vi = cast(size_t)c.integer;
            if (vi < referenced.length) referenced[vi] = true;
        }
    int[] orph;
    foreach (i; 0 .. referenced.length) if (!referenced[i]) orph ~= cast(int)i;
    return orph;
}

bool isHoleFree(JSONValue m) {
    int[ulong] undirected;
    int[ulong] directed;
    foreach (f; m["faces"].array) {
        auto idx = f.array;
        auto n   = idx.length;
        foreach (k; 0 .. n) {
            ulong a = cast(ulong)idx[k].integer;
            ulong b = cast(ulong)idx[(k + 1) % n].integer;
            ulong lo = a < b ? a : b, hi = a < b ? b : a;
            undirected[(lo << 32) | hi] += 1;
            directed[(a << 32) | b] += 1;
        }
    }
    foreach (_, c; undirected) if (c > 2) return false;
    foreach (_, c; directed)   if (c > 1) return false;
    return true;
}

bool noCoincidentVerts(JSONValue m, double tol=1e-4) {
    auto n = m["vertices"].array.length;
    foreach (i; 0 .. n)
        foreach (j; i + 1 .. n)
            if (len3(sub3(vert(m, i), vert(m, j))) < tol) return false;
    return true;
}

// Newell polygon area (matches atlas/fuzz_invariants.py's degenerate-face check).
double faceArea(JSONValue m, JSONValue faceArr) {
    auto n = faceNormal(m, faceArr); // reuses the Newell-sum vector below
    return len3(n) * 0.5;
}
V3 faceNormal(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    auto n   = idx.length;
    V3 nm = V3(0, 0, 0);
    foreach (k; 0 .. n) {
        auto vi = vert(m, cast(size_t)idx[k].integer);
        auto vj = vert(m, cast(size_t)idx[(k + 1) % n].integer);
        nm.x += (vi.y - vj.y) * (vi.z + vj.z);
        nm.y += (vi.z - vj.z) * (vi.x + vj.x);
        nm.z += (vi.x - vj.x) * (vi.y + vj.y);
    }
    return nm;
}

bool noDegenerateFaces(JSONValue m, double areaEps=1e-6) {
    foreach (f; m["faces"].array) {
        // <3 distinct corner indices, or near-zero area.
        bool[long] distinct;
        foreach (c; f.array) distinct[c.integer] = true;
        if (distinct.length < 3) return false;
        if (faceArea(m, f) < areaEps) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Test A — inset=0.1 shift=0.2 on top face → 12v/10f, inner corners at
//           (±0.4,0.7,±0.4), cap centroid (0,0.7,0) selected.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["faceCount"].integer   == 6);

    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "A: top face (+Y) not found");
    postSelect("polygons", [topFi]);

    postCommand(`{"id":"mesh.bevel","params":{"inset":0.1,"shift":0.2}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 12,
        "A: expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 10,
        "A: expected 10 faces, got " ~ m["faceCount"].integer.to!string);

    auto fv = fvDist(m);
    assert(fv == [4: 10], "A: expected all-quad {4:10}, got " ~ fv.to!string);

    // Inner corners at y=0.7 (shifted by 0.2 from y=0.5), x/z ±0.4.
    foreach (x; [-0.4, 0.4])
        foreach (z; [-0.4, 0.4]) {
            int n = countAt(m, V3(x, 0.7, z));
            assert(n == 1, "A: inner corner (" ~ x.to!string ~ ",0.7," ~ z.to!string ~ ") expected 1, got " ~ n.to!string);
        }

    // Cap face should be selected and centered at (0,0.7,0).
    auto sel = getSelection();
    assert(sel["selectedFaces"].array.length == 1,
        "A: expected 1 selected face (cap), got " ~ sel["selectedFaces"].array.length.to!string);
    int capFi = cast(int)sel["selectedFaces"].array[0].integer;
    auto capC = faceCentroid(m, m["faces"].array[capFi]);
    assert(abs(capC.x) < 1e-3 && abs(capC.y - 0.7) < 1e-3 && abs(capC.z) < 1e-3,
        "A: cap centroid should be (0,0.7,0), got " ~ capC.x.to!string ~ "," ~ capC.y.to!string ~ "," ~ capC.z.to!string);

    assert(orphanVerts(m).length == 0, "A: orphan verts");
    assert(isHoleFree(m),              "A: not hole-free");
    assert(noCoincidentVerts(m),       "A: coincident verts");
}

// ---------------------------------------------------------------------------
// Test B — undo restores 8v/6f; redo re-applies 12v/10f.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "B: top face not found");
    postSelect("polygons", [topFi]);
    postCommand(`{"id":"mesh.bevel","params":{"inset":0.1,"shift":0.2}}`);

    auto u = postUndo();
    assert(u["status"].str == "ok", "B: undo failed: " ~ u.toString);
    auto ma = getModel();
    assert(ma["vertexCount"].integer == 8,  "B: undo verts expected 8");
    assert(ma["faceCount"].integer   == 6,  "B: undo faces expected 6");

    auto r = postRedo();
    assert(r["status"].str == "ok", "B: redo failed: " ~ r.toString);
    auto mb = getModel();
    assert(mb["vertexCount"].integer == 12, "B: redo verts expected 12");
    assert(mb["faceCount"].integer   == 10, "B: redo faces expected 10");
}

// ---------------------------------------------------------------------------
// Test C — inset=0, shift=0 → status:error, mesh unchanged.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    postSelect("polygons", [topFi]);

    auto r = postCommandRaw(`{"id":"mesh.bevel","params":{"inset":0.0,"shift":0.0}}`);
    assert(r["status"].str == "error", "C: expected error for no-op params, got " ~ r["status"].str);
    auto m = getModel();
    assert(m["vertexCount"].integer == 8, "C: mesh should be unchanged (8 verts)");
    assert(m["faceCount"].integer   == 6, "C: mesh should be unchanged (6 faces)");
}

// ---------------------------------------------------------------------------
// Test D — shift-only: inset=0, shift=0.2 → cap corners at (±0.5,0.7,±0.5).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "D: top face not found");
    postSelect("polygons", [topFi]);

    postCommand(`{"id":"mesh.bevel","params":{"inset":0.0,"shift":0.2}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 12, "D: expected 12 verts");
    assert(m["faceCount"].integer   == 10, "D: expected 10 faces");

    // Cap corners at (±0.5, 0.7, ±0.5) — same footprint as original face,
    // just lifted by shift.
    foreach (x; [-0.5, 0.5])
        foreach (z; [-0.5, 0.5]) {
            int n = countAt(m, V3(x, 0.7, z));
            assert(n == 1, "D: shift-only corner (" ~ x.to!string ~ ",0.7," ~ z.to!string ~ ") expected 1, got " ~ n.to!string);
        }
}

// ---------------------------------------------------------------------------
// Test E — overshoot guard (task 0304, fuzz-found): inset at/beyond the
//          top face's inradius (0.5) must never produce coincident verts
//          or degenerate (zero-area) faces. Before the fix, inset=0.5
//          collapsed all 4 cap corners onto the centroid (0,0.5,0) and
//          inset=1.0 (2x inradius) landed them on the diagonally-opposite
//          existing corner — both silently reported status:"ok".
// ---------------------------------------------------------------------------

unittest {
    // E1 — inset == inradius exactly (the primary repro).
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "E1: top face not found");
    postSelect("polygons", [topFi]);

    auto r = postCommandRaw(`{"id":"mesh.bevel","params":{"inset":0.5,"shift":0.0}}`);
    auto m = getModel();
    // Either the overshoot guard clamps it (status ok, geometry changed) or it
    // is an honest no-op (status error, mesh unchanged) — never a corrupted mesh.
    if (r["status"].str == "ok") {
        assert(noCoincidentVerts(m),  "E1: coincident verts at inset==inradius");
        assert(noDegenerateFaces(m),  "E1: degenerate face at inset==inradius");
        assert(isHoleFree(m),         "E1: not hole-free at inset==inradius");
        assert(orphanVerts(m).length == 0, "E1: orphan verts at inset==inradius");
    } else {
        assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
            "E1: no-op must leave mesh unchanged");
    }

    // E2 — inset == 2x inradius (the "lands on the diagonal corner" repro).
    resetCube();
    auto before2 = getModel();
    int topFi2 = faceWithCentroid(before2, V3(0, 0.5, 0));
    assert(topFi2 >= 0, "E2: top face not found");
    postSelect("polygons", [topFi2]);

    auto r2 = postCommandRaw(`{"id":"mesh.bevel","params":{"inset":1.0,"shift":0.0}}`);
    auto m2 = getModel();
    if (r2["status"].str == "ok") {
        assert(noCoincidentVerts(m2), "E2: coincident verts at inset==2x inradius");
        assert(noDegenerateFaces(m2), "E2: degenerate face at inset==2x inradius");
        assert(isHoleFree(m2),        "E2: not hole-free at inset==2x inradius");
        assert(orphanVerts(m2).length == 0, "E2: orphan verts at inset==2x inradius");
    } else {
        assert(m2["vertexCount"].integer == 8 && m2["faceCount"].integer == 6,
            "E2: no-op must leave mesh unchanged");
    }

    // E3 — sanity: a normal small inset must be completely unaffected by
    // the overshoot guard (no clamping should kick in below the inradius).
    resetCube();
    auto before3 = getModel();
    int topFi3 = faceWithCentroid(before3, V3(0, 0.5, 0));
    postSelect("polygons", [topFi3]);
    postCommand(`{"id":"mesh.bevel","params":{"inset":0.1,"shift":0.0}}`);
    auto m3 = getModel();
    assert(m3["vertexCount"].integer == 12, "E3: normal inset must be unaffected by the guard");
    assert(m3["faceCount"].integer   == 10, "E3: normal inset must be unaffected by the guard");
    foreach (x; [-0.4, 0.4])
        foreach (z; [-0.4, 0.4])
            assert(countAt(m3, V3(x, 0.5, z)) == 1,
                "E3: expected untouched inner corner (" ~ x.to!string ~ ",0.5," ~ z.to!string ~ ")");
}
