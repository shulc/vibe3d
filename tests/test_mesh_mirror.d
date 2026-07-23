// Tests for mesh.mirror (PR-2 of doc/duplicate_plan.md). Symmetric
// duplicate across an axis-aligned plane: clones the selected faces
// (or the whole mesh if no selection), reflects the cloned verts,
// reverses winding when flip_normals is on, and optionally welds
// coincident seam verts (which also drops the doubled seam polygon).
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;

import mesh : Mesh;
import math : Vec3;

void main() {}

// Helpers ------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

// `empty=true` clears the mesh entirely instead of seeding the default
// cube — used with postLoadMesh to inject custom test geometry.
void postReset(bool empty) {
    string path = empty ? "http://localhost:8080/api/reset?empty=true"
                         : "http://localhost:8080/api/reset";
    auto resp = post(path, "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post("http://localhost:8080/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/load-mesh failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(post("http://localhost:8080/api/command", body));
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }
JSONValue postUndo()     { return parseJSON(post("http://localhost:8080/api/undo", "")); }

bool approxEq(double a, double b, double eps = 1e-5) {
    return abs(a - b) < eps;
}

double[3] vToArr(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// Return true if any cloned vert in `verts[origLen .. $]` is at `target`.
bool clonedHasPosition(JSONValue m, size_t origLen, double[3] target) {
    auto verts = m["vertices"].array;
    foreach (i; origLen .. verts.length) {
        auto a = vToArr(verts[i]);
        if (approxEq(a[0], target[0]) && approxEq(a[1], target[1])
                                      && approxEq(a[2], target[2]))
            return true;
    }
    return false;
}

// Every undirected edge must be shared by at most 2 faces for the mesh to
// be manifold. Task 0306 bug A: a coplanar seam face survived the weld
// dedup as a lone internal "membrane", so each of its 4 boundary edges
// ended up shared by 3 faces instead of 2.
void assertManifold(JSONValue m, string ctx) {
    int[string] faceCountByEdge;
    foreach (f; m["faces"].array) {
        auto verts = f.array;
        size_t n = verts.length;
        foreach (i; 0 .. n) {
            long a = verts[i].integer;
            long b = verts[(i + 1) % n].integer;
            string key = a < b ? (a.to!string ~ "," ~ b.to!string)
                                : (b.to!string ~ "," ~ a.to!string);
            faceCountByEdge[key] = faceCountByEdge.get(key, 0) + 1;
        }
    }
    foreach (key, count; faceCountByEdge) {
        assert(count <= 2, ctx ~ ": edge (" ~ key ~ ") used by "
            ~ count.to!string ~ " faces — non-manifold");
    }
}

// Full-parity membrane oracle. When a masked face lies ENTIRELY on the
// mirror plane it doesn't move under reflection, so its winding-reversed
// clone lands on the exact same verts: a degenerate on-plane membrane. The
// reference editor keeps BOTH copies (the doubled membrane ships verbatim),
// so exactly one vertex SET ends up claimed by two coincident faces. Assert
// that doubled seam face is present — the whole point of the parity fix.
// (This is deliberately non-manifold: the membrane makes each of its seam
// edges shared by more than two faces, which is why assertManifold is NOT
// applied to the on-plane weld-seam cases below.)
void assertMembranePresent(JSONValue m, string ctx) {
    import std.algorithm.sorting : sort;
    int[string] setCount;
    foreach (f; m["faces"].array) {
        long[] vs;
        foreach (v; f.array) vs ~= v.integer;
        sort(vs);
        string key;
        foreach (i, v; vs) { if (i > 0) key ~= ","; key ~= v.to!string; }
        setCount[key] = setCount.get(key, 0) + 1;
    }
    size_t doubled = 0;
    foreach (key, count; setCount) if (count >= 2) ++doubled;
    assert(doubled >= 1, ctx ~ ": expected a doubled on-plane membrane face "
        ~ "(one vertex set claimed by 2 coincident faces), found none");
}

// Task 0306's systemic gap: a weld/mirror op that cascades to an empty
// document must not silently report success over 0v/0f.
void assertNonEmpty(JSONValue m, string ctx) {
    assert(m["vertexCount"].integer > 0, ctx ~ ": mesh has 0 vertices");
    assert(m["faceCount"].integer > 0,   ctx ~ ": mesh has 0 faces");
}

// ---------------------------------------------------------------------------
// Whole-mesh mirror, axis X, no weld — empty selection ⇒ act on all faces
// ---------------------------------------------------------------------------

unittest { // mirror whole cube across plane x=1 (center=(1,0,0)): cloned
           // verts land at x = 2 - x_orig ∈ {1.5, 2.5}; no overlap with
           // original ⇒ 16 verts, 12 faces, 24 edges.
    resetCube();

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[1,0,0],"weld":0,"flip_normals":true
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 24,
        "edges: expected 24, got "  ~ m["edgeCount"].integer.to!string);

    // The 8 cloned verts must be exactly the reflections of v0..v7:
    //   (-0.5,*,*) → (2.5,*,*) and (+0.5,*,*) → (1.5,*,*).
    foreach (xo; [-0.5, 0.5]) {
        foreach (y; [-0.5, 0.5])
        foreach (z; [-0.5, 0.5]) {
            double[3] tgt = [2.0 - xo, y, z];
            assert(clonedHasPosition(m, 8, tgt),
                "cloned vert missing at (" ~ tgt[0].to!string ~ "," ~
                tgt[1].to!string ~ "," ~ tgt[2].to!string ~ ")");
        }
    }
}

// ---------------------------------------------------------------------------
// Whole-mesh mirror with weld — FULL PARITY: the doubled on-plane seam face
// is KEPT (both the coplanar original AND its winding-reversed clone), so the
// result carries a degenerate on-plane membrane exactly as the reference
// editor ships it.
//
// The +x face (v1,v2,v5,v6) lies ENTIRELY on the mirror plane
// (center=[0.5,0,0]) — it doesn't move under reflection, so its clone lands
// back on the exact same 4 verts: a degenerate on-plane membrane. The
// reference keeps BOTH copies, so faceCount = 12 (6 orig + 6 clones, nothing
// dropped). This makes each of the 4 seam edges shared by more than two faces
// — a deliberate non-manifold artifact of Mirror+Merge — so assertManifold is
// intentionally NOT applied here; assertMembranePresent guards the doubled
// seam face instead. (The seam-vertex weld itself is unchanged: the 4 on-plane
// clone verts still collapse onto v1,v2,v5,v6.)
// ---------------------------------------------------------------------------

unittest { // Cube reflected across plane x=0.5 with weld=0.001: verts on
           // the +x face (v1,v2,v5,v6) coincide with their clones and get
           // welded; the coplanar +x face and its clone are BOTH kept
           // (doubled on-plane membrane, full parity).
    resetCube();

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[0.5,0,0],"weld":0.001,"flip_normals":true
    }}`);

    auto m = getModel();
    assertNonEmpty(m, "mirror weld coplanar (X)");
    // 8 original verts kept. 4 cloned verts (mirror of v0,v3,v4,v7) at
    // x=1.5; the other 4 mirror verts collapse onto v1,v2,v5,v6 and are
    // compacted out.
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    // 6 orig + 6 clones, nothing dropped — the coplanar +x face and its
    // winding-reversed clone both survive as the on-plane membrane.
    assert(m["faceCount"].integer == 12,
        "faces: expected 12 (doubled on-plane membrane kept), got "
        ~ m["faceCount"].integer.to!string);
    // Edge count unchanged (20): the membrane reuses the 4 seam edges the
    // adjacent side faces already provide — it adds no new edges, it just
    // ALSO claims them (which is what makes those 4 edges non-manifold).
    assert(m["edgeCount"].integer == 20,
        "edges: expected 20, got "  ~ m["edgeCount"].integer.to!string);
    // Intentionally non-manifold (seam edges shared by >2 faces); assert the
    // membrane is present instead of the manifold invariant.
    assertMembranePresent(m, "mirror weld coplanar (X)");
}

unittest { // Same repro mirrored on Y instead of X (axis=Y,
           // center=[0,0.5,0]) — the +y (top) face is the coplanar one
           // this time. Full-parity: the doubled on-plane membrane is kept.
    resetCube();

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Y","center":[0,0.5,0],"weld":0.001,"flip_normals":true
    }}`);

    auto m = getModel();
    assertNonEmpty(m, "mirror weld coplanar (Y)");
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12 (doubled on-plane membrane kept), got "
        ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 20,
        "edges: expected 20, got "  ~ m["edgeCount"].integer.to!string);
    assertMembranePresent(m, "mirror weld coplanar (Y)");
}

// ---------------------------------------------------------------------------
// A large weld threshold must stay LOCAL to the seam, never folding
// together unrelated far-apart vertices across the whole mesh (task 0306
// bug B), and must never silently collapse the mesh to nothing (the
// empty-mesh guard, task 0306's systemic gap).
// ---------------------------------------------------------------------------

unittest { // weld=100 on a unit cube: under the old GLOBAL weld, every
           // vertex pair is "coincident" at that threshold and the whole
           // mesh collapsed to 0v/0e/0f while still reporting status:"ok".
           // The fix never merges two PRE-EXISTING (pre-mirror) vertices
           // with each other, regardless of `weld`'s magnitude — only
           // pairs touching a freshly mirrored vertex are eligible — so
           // the original 8 verts / 6 faces survive untouched (the newly
           // mirrored geometry folds away into them instead of the whole
           // document vanishing).
    resetCube();

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[0,0,0],"weld":100.0,"flip_normals":true
    }}`);

    auto m = getModel();
    assertNonEmpty(m, "mirror weld=100 (bug B)");
    assert(m["vertexCount"].integer == 8,
        "verts: expected 8 (original cube preserved), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "faces: expected 6 (original cube preserved), got "
        ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "edges: expected 12, got " ~ m["edgeCount"].integer.to!string);
    assertManifold(m, "mirror weld=100 (bug B)");
}

// ---------------------------------------------------------------------------
// Selected-faces-only mirror — verts outside the selected faces stay put
// ---------------------------------------------------------------------------

unittest { // Select just the top face (f4) and mirror it across plane y=1.
           // Only the 4 top verts get cloned (no weld); 12 total verts,
           // 7 faces, 16 edges.
    resetCube();
    postSelect("polygons", [4]);   // top face = v3,v7,v6,v2

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Y","center":[0,1,0],"weld":0,"flip_normals":true
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "faces: expected 7, got "  ~ m["faceCount"].integer.to!string);
    // Cloned verts at y = 2 - 0.5 = 1.5; x,z preserved.
    foreach (x; [-0.5, 0.5])
    foreach (z; [-0.5, 0.5]) {
        assert(clonedHasPosition(m, 8, [x, 1.5, z]),
            "cloned vert missing at top mirror");
    }
    // Selection should be just the new mirrored face.
    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 1 && selFaces[0].integer == 6,
        "expected single mirror face index 6, got " ~ sel["selectedFaces"].toString);
}

// ---------------------------------------------------------------------------
// flip_normals on/off — verifies winding order through the saved face list
// ---------------------------------------------------------------------------

unittest { // flip_normals=true reverses the vert order in the cloned face.
           // For the back face [v0,v3,v2,v1], the cloned face indices [c0,
           // c3, c2, c1] should appear reversed → [c1, c2, c3, c0].
    resetCube();
    postSelect("polygons", [0]);  // back face

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Z","center":[0,0,1],"weld":0,"flip_normals":true
    }}`);

    auto m = getModel();
    auto faces = m["faces"].array;
    auto orig  = faces[0].array;   // back face: [0,3,2,1]
    auto cloned = faces[6].array;  // mirrored back face

    assert(cloned.length == orig.length);
    // The cloned face's i-th vert must be at the position the original's
    // (n-1-i)-th vert had AFTER reflection. Equivalent: orig[n-1-i]'s
    // position reflected = cloned[i]'s position.
    auto verts = m["vertices"].array;
    foreach (i; 0 .. orig.length) {
        auto oArr = vToArr(verts[orig[orig.length - 1 - i].integer]);
        auto cArr = vToArr(verts[cloned[i].integer]);
        // Reflected across z=1: cz = 2 - oz.
        assert(approxEq(cArr[0], oArr[0])
            && approxEq(cArr[1], oArr[1])
            && approxEq(cArr[2], 2.0 - oArr[2]),
            "winding mismatch at i=" ~ i.to!string);
    }
}

unittest { // flip_normals=false preserves the cloned vert order — i-th vert
           // of cloned face is the reflected i-th vert of original face.
    resetCube();
    postSelect("polygons", [0]);

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Z","center":[0,0,1],"weld":0,"flip_normals":false
    }}`);

    auto m = getModel();
    auto faces  = m["faces"].array;
    auto orig   = faces[0].array;
    auto cloned = faces[6].array;
    auto verts  = m["vertices"].array;
    foreach (i; 0 .. orig.length) {
        auto oArr = vToArr(verts[orig[i].integer]);
        auto cArr = vToArr(verts[cloned[i].integer]);
        assert(approxEq(cArr[0], oArr[0])
            && approxEq(cArr[1], oArr[1])
            && approxEq(cArr[2], 2.0 - oArr[2]),
            "flip_normals=false: cloned[i] should mirror orig[i] in order");
    }
}

// ---------------------------------------------------------------------------
// Undo restores the original cage
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[1,0,0],"weld":0,"flip_normals":true
    }}`);
    auto pre = getModel();
    assert(pre["faceCount"].integer == 12);

    auto undoResp = postUndo();
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}

// ---------------------------------------------------------------------------
// Defaults — `params:{}` runs the command with axis=X, center=0, weld=0.001
// ---------------------------------------------------------------------------

unittest { // No params ⇒ mirror across plane x=0 with weld=0.001 (defaults).
           // For a symmetric cube `[-0.5,0.5]³` this welds every cloned
           // vert onto its original (8 verts). FULL PARITY: the weld merges
           // coincident VERTS only — it does NOT dedup faces, so the doubled
           // coincident faces (each original + its winding-reversed clone)
           // survive as an opposite-wound shell: 8 verts, 12 edges, 12 faces
           // (matches the reference's keep-doubled weld convention).
    resetCube();
    postCommand(`{"id":"mesh.mirror","params":{}}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "verts: expected 8 (full weld), got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12 (keep doubled coincident faces), got "
        ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "edges: expected 12, got " ~ m["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Edit mode is orthogonal — Vertices-mode selection has empty selectedFaces,
// which triggers the whole-mesh fallback.
// ---------------------------------------------------------------------------

unittest { // In Vertices mode, mesh.mirror with non-default plane mirrors
           // the whole cube (the vertex selection is ignored — only face
           // selection drives the mask, and there is none).
    resetCube();
    postSelect("vertices", [0, 1, 2, 3]);

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[1,0,0],"weld":0,"flip_normals":true
    }}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16 (whole-mesh fallback), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Empty-collapse rollback path (HTTP smoke test) — a mirror op that
// internally collapses to empty and rolls back must still leave the app in
// a selectable, non-crashed state via the ordinary command surface.
//
// Repro: a scalene (non-symmetric) triangle lying entirely in the z=0
// plane, mirrored about that SAME plane. Every face — the original and
// its clone alike — is exactly on-plane, so the drop-both block (task
// 0306 bug A) empties `faces` unconditionally, independent of `weld`'s
// magnitude; `isEmpty()` fires and the un-welded pre-pass snapshot is
// restored. A generous weld additionally guarantees the seam-vertex merge
// (clone verts sit exactly atop their originals) runs the full
// weld+compactUnreferenced path that truncates vertexSelectionOrder/
// edgeSelectionOrder pre-fix (see the in-process test below for the actual
// unguarded-index regression proof — `/api/select` → mesh.select always
// calls `mesh.syncSelection()` first, which defensively re-grows any
// truncated array and would mask the bug here).
// ---------------------------------------------------------------------------

unittest {
    postReset(true);
    postLoadMesh(`{
        "vertices": [[0,0,0],[2,0,0],[0,1,0]],
        "faces": [[0,1,2]]
    }`);

    postCommand(`{"id":"mesh.mirror","params":{
        "axis":"Z","center":[0,0,0],"weld":10.0,"flip_normals":true
    }}`);

    auto m = getModel();
    assertNonEmpty(m, "mirror empty-collapse rollback");
    long n = m["vertexCount"].integer;
    assert(n > 0, "rollback should have restored a non-empty mesh");
    assertManifold(m, "mirror empty-collapse rollback");

    int[] allVerts;
    foreach (i; 0 .. n) allVerts ~= cast(int)i;
    postSelect("vertices", allVerts);

    auto sel = getSelection();
    assert(sel["selectedVertices"].array.length == n,
        "expected all " ~ n.to!string ~ " verts selected, got "
        ~ sel["selectedVertices"].array.length.to!string);

    long edgeCount = m["edgeCount"].integer;
    assert(edgeCount > 0, "rollback should have restored edges too");
    int[] allEdges;
    foreach (i; 0 .. edgeCount) allEdges ~= cast(int)i;
    postSelect("edges", allEdges);

    auto sel2 = getSelection();
    assert(sel2["selectedEdges"].array.length == edgeCount,
        "expected all " ~ edgeCount.to!string ~ " edges selected, got "
        ~ sel2["selectedEdges"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// Empty-collapse rollback path (in-process regression, no HTTP) — proves
// the actual unguarded-index bug the HTTP smoke test above cannot reach.
//
// `/api/select` routes through `commands.mesh.select.MeshSelect`, whose
// `apply()` calls `mesh.syncSelection()` BEFORE dispatching to
// `selectVertex`/`selectEdge` — that defensively re-grows any parallel
// array shorter than `vertices`/`edges`, silently papering over exactly
// the length mismatch this test is about. The genuinely unguarded callers
// are the interactive click-pick paths (source/symmetry_pick.d's
// `symmetricSelectVertex`/`symmetricSelectEdge`, and app.d's direct mouse
// picks) — they call `mesh.selectVertex`/`selectEdge` straight, no sync.
// Exercising `Mesh`'s own API in-process (same pattern as
// tests/test_edge_extrude_crash.d) reaches that real call site.
//
// Before the SHOULD-FIX: `vertexSelectionOrder`/`edgeSelectionOrder` were
// missing from `mirrorFacesPlane`'s empty-mesh-guard snapshot/restore.
// The collapse (compactUnreferenced, driven by the coincident-vertex weld
// below) truncates both to length 0; the rollback then restores `vertices`
// /`edges`/`faces` but NOT those two — leaving `vertices.length == N` with
// `vertexSelectionOrder.length == 0`. The very next `selectVertex(idx)`
// indexes `vertexSelectionOrder[idx]` unguarded (mesh.d, `selectVertex`)
// and throws `core.exception.RangeError`, taking down the whole process
// under the HTTP-driven suite (a crash there is only observable as a
// dropped connection, not a normal assert failure) — hence testing this
// in-process instead.
// ---------------------------------------------------------------------------

unittest {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(2, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0, 1, 2]);

    bool[] mask = [true];
    size_t n = m.mirrorFacesPlane(mask, Vec3(0, 0, 0), Vec3(0, 0, 1), 10.0f, true);
    assert(n == 1, "expected the single face to be cloned");
    assert(m.vertices.length > 0 && m.faces.length > 0,
        "rollback should have restored a non-empty mesh");

    // The regression: direct selectVertex/selectEdge calls (the real
    // click-pick path, bypassing MeshSelect's syncSelection safety net)
    // must not crash — proves vertexSelectionOrder/edgeSelectionOrder stay
    // length-consistent with vertices/edges across the rollback.
    foreach (i; 0 .. m.vertices.length)
        m.selectVertex(cast(int)i);
    foreach (i; 0 .. m.edges.length)
        m.selectEdge(cast(int)i);

    size_t selVerts = 0;
    foreach (b; m.selectedVertices) if (b) ++selVerts;
    assert(selVerts == m.vertices.length,
        "expected every vertex selected, got " ~ selVerts.to!string);

    size_t selEdges = 0;
    foreach (b; m.selectedEdges) if (b) ++selEdges;
    assert(selEdges == m.edges.length,
        "expected every edge selected, got " ~ selEdges.to!string);
}
