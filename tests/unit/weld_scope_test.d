// weld_scope_test — which vertex pairs a weld joins, and at what distance
// (task 9436). Every client of the one coincidence search, `Mesh.computeWeldRemap`,
// is driven over the frozen capture `tests/fixtures/weld_scope.json` (K-W1, task
// 9419): the duplicators (line array, grid array, radial array, mirror) weld
// PER-COPY, the comparison is inclusive, distance 0 has a 1e-9 floor, and cleanup
// has no user distance. Duplicator cells compare counts AND positions (the earlier
// vertex survives in place); cleanup / vertex-merge cells compare counts only —
// their survivor tail is a separate recorded law.
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT: run blocks in isolation.
module tests.unit.weld_scope_test;

import std.conv   : to;
import std.file   : readText;
import std.format : format;
import std.json   : JSONType, JSONValue, parseJSON;
import std.math   : PI, abs;
import std.path   : buildPath, dirName;

import mesh;
import math : Vec3;
import mesh_ops.cleanup : cleanupMesh, kCleanupEditScope;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private JSONValue fixture() {
    static JSONValue cached;
    static bool loaded;
    if (!loaded) {
        cached = parseJSON(readText(buildPath(repoRoot, "tests", "fixtures", "weld_scope.json")));
        loaded = true;
    }
    return cached;
}

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger : v.floating;
}

private Vec3 vec(JSONValue v) {
    return Vec3(cast(float) num(v[0]), cast(float) num(v[1]), cast(float) num(v[2]));
}

private Mesh settle(Vec3[] vs, uint[][] fs) {
    Mesh m;
    m.vertices = vs;
    m.faces = fs;
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

private Mesh inputOf(JSONValue cell) {
    Vec3[] vs;
    foreach (p; cell["input"]["points"].array) vs ~= vec(p);
    uint[][] fs;
    foreach (f; cell["input"]["faces"].array) {
        uint[] ring;
        foreach (i; f.array) ring ~= cast(uint) i.integer;
        fs ~= ring;
    }
    return settle(vs, fs);
}

/// The face mask a cell's selection names: "all", or "polygons [a,b,…]".
private bool[] faceMaskOf(JSONValue cell, size_t faceCount) {
    const sel = cell["selection"].str;
    auto mask = new bool[](faceCount);
    if (sel == "all") { mask[] = true; return mask; }
    enum prefix = "polygons ";
    assert(sel.length > prefix.length && sel[0 .. prefix.length] == prefix,
           "fixture: unknown face selection " ~ sel);
    foreach (i; parseJSON(sel[prefix.length .. $]).array) mask[cast(size_t) i.integer] = true;
    return mask;
}

/// Our run of one cell through one production entry; `positions` = the cell
/// compares final positions (a duplicator keeps the earlier vertex in place).
private struct Run { string variant; Mesh m; bool positions; }

private Run[] runCell(JSONValue cell) {
    auto op = cell["operation"];
    const kind = op["kind"].str;
    Run[] runs;
    switch (kind) {
    case "array_linear": {
        const int count = cast(int) op["count"].integer;
        const Vec3 offset = vec(op["offset"]);
        const float dist = cast(float) num(op["weld_distance"]);
        // The line array's single float is its weld switch (0 = off), so its
        // distance-0 cells are the grid array's alone.
        if (dist > 0) {
            Mesh a = inputOf(cell);
            auto mask = faceMaskOf(cell, a.faces.length);
            a.arrayFaces(mask, count, offset, dist, true);
            // A partial selection detaches the source onto fresh vertices, so
            // its own slots renumber (W1k keeps them in place): counts only.
            bool partial = false;
            foreach (b; mask) partial |= !b;
            runs ~= Run("line", a, !partial);
        }
        Mesh g = inputOf(cell);
        g.arrayFacesGrid(faceMaskOf(cell, g.faces.length), count, 1, 1, offset,
                         Vec3(0, 0, 0), Vec3(1, 1, 1), Vec3(0, 0, 0),
                         false, false, false, true, dist);
        runs ~= Run("grid", g, true);
        break;
    }
    case "array_radial": {
        const int count = cast(int) op["count"].integer;
        assert(op["axis"].str == "Z" && num(op["start_deg"]) == 0, "fixture: radial rig changed");
        // Ours spaces `count` copies over the total angle; the rig's last copy
        // sits at `end_deg`, so the total is end * count / (count - 1).
        const float total = cast(float)(num(op["end_deg"]) * count / (count - 1) * PI / 180.0);
        Mesh r = inputOf(cell);
        r.radialArrayFaces(faceMaskOf(cell, r.faces.length), count, 'Z', vec(op["center"]),
                           total, Vec3(0, 0, 0), cast(float) num(op["weld_distance"]));
        runs ~= Run("radial", r, true);
        break;
    }
    case "mirror": {
        const float dist = cast(float) num(op["weld_distance"]);
        if (dist > 0) {   // the mirror's float is its weld switch too
            Mesh r = inputOf(cell);
            r.mirrorFaces(faceMaskOf(cell, r.faces.length), op["axis"].str[0],
                          vec(op["center"]), dist, false);
            runs ~= Run("mirror", r, true);
        }
        break;
    }
    case "cleanup": {
        Mesh r = inputOf(cell);
        CleanupOptions o;
        o.dropDegenerate = false;
        o.unify = false;
        o.dissolve2Valent = false;
        o.mergeVerts = true;
        o.removeOrphans = true;   // ours leaves welded slots for this stage to drop
        {
            auto ed = MeshEditBatch.unrecorded(r, kCleanupEditScope);
            cast(void) ed.cleanupMesh(o);
            ed.close();
        }
        runs ~= Run("cleanup", r, false);
        break;
    }
    case "vertex_merge": {
        Mesh r = inputOf(cell);
        auto all = new bool[](r.vertices.length);
        all[] = true;
        const double d = num(op["distance"]);
        cast(void) r.weldVerticesByMask(all, d * d, true);
        runs ~= Run("vertex_merge", r, false);
        break;
    }
    default:   // vertex_merge_auto: a command default, witnessed by the suite
        break;
    }
    return runs;
}

unittest { // every K-W1 cell, every production entry that can express it
    string[] ran, diffs;
    foreach (cell; fixture()["cells"].array) {
        const id = cell["cell"].str;
        auto want = cell["reference"];
        foreach (run; runCell(cell)) {
            ran ~= id ~ "/" ~ run.variant;
            const nv = run.m.vertices.length, nf = run.m.faces.length;
            if (nv != want["vertex_count"].integer || nf != want["face_count"].integer) {
                diffs ~= format("%s/%s: %d verts %d faces, captured %d / %d", id, run.variant,
                                nv, nf, want["vertex_count"].integer, want["face_count"].integer);
                continue;
            }
            if (!run.positions) continue;
            foreach (i, p; want["points"].array) {
                const Vec3 w = vec(p), g = run.m.vertices[i];
                if (abs(w.x - g.x) > 1e-5 || abs(w.y - g.y) > 1e-5 || abs(w.z - g.z) > 1e-5) {
                    diffs ~= format("%s/%s: vertex %d at %s, captured %s", id, run.variant, i, g, w);
                    break;
                }
            }
        }
    }
    // Floor: 19 of the 21 cells reach a kernel here — line + grid for the 5 array
    // cells with a distance, grid alone for the 2 at distance 0, radial 1, mirror 1,
    // cleanup 7, vertex merge 3; the distance-0 mirror and the automatic merge do not.
    assert(ran.length == 24, format("population: expected 24 runs, got %d: %s", ran.length, ran));
    assert(diffs.length == 0, format("weld scope differs from the capture in %d run(s):\n  %-(%s\n  %)",
                                     diffs.length, diffs));
}

unittest { // the comparison is inclusive in the coincidence search, both directions
    // Two vertices exactly 0.5 apart (exact in float) at distance 0.5 weld;
    // nudged one float step further they do not (K-W1 W1g; one comparator).
    import std.math : nextUp;
    foreach (far; [false, true]) {
        const float x = far ? nextUp(0.5f) : 0.5f;
        Mesh m = settle([Vec3(0, 0, 0), Vec3(-2, 0, 0), Vec3(-2, -2, 0),
                         Vec3(x, 0, 0), Vec3(2.5f, 0, 0), Vec3(2.5f, 2, 0)],
                        [[0u, 1u, 2u], [3u, 4u, 5u]]);
        const welded = m.weldCoincidentVertices(0.25);
        assert(welded == (far ? 0 : 1), format("x = %.9g at distance 0.5: expected %d weld(s), got %d",
                                               x, far ? 0 : 1, welded));
    }
}

unittest { // the seed walk does not chain: 0, 0.4, 0.8 at distance 0.5 is ONE weld
    Mesh a = settle([Vec3(0, 0, 0), Vec3(0.4f, 0, 0), Vec3(0.8f, 0, 0), Vec3(0, 5, 0)],
                    [[0u, 3u, 1u], [1u, 3u, 2u]]);
    Mesh b = settle(a.vertices.dup, [[0u, 3u, 1u], [1u, 3u, 2u]]);
    assert(a.weldCoincidentVertices(0.25) == 1, "coincidence weld: 0.8 is 0.8 from its seed 0");
    assert(b.weldVerticesByMask([true, true, true, true], 0.25) == 1,
           "mask weld: 0.8 is 0.8 from its seed 0");
}

unittest { // the mask restricts both ends of a pair
    Mesh m = settle([Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
                    [[0u, 3u, 4u], [1u, 3u, 4u], [2u, 4u, 3u]]);
    assert(m.weldVerticesByMask([false, true, true, false, false], 1e-12) == 1,
           "only the two masked coincident vertices weld; the unmasked one stays");
    assert(m.vertices.length == 4, format("expected 4 vertices, got %d", m.vertices.length));
}

unittest { // the cleanup detector reports exactly what cleanup welds (W1e_bracket)
    import mesh_analysis : coincidentVertexClusters;
    JSONValue cell;
    foreach (c; fixture()["cells"].array) if (c["cell"].str == "W1e_bracket") cell = c;
    Mesh m = inputOf(cell);
    const clusters = coincidentVertexClusters(m);
    // 36 input vertices, 34 captured: the 0 and 1e-30 pairs; 1e-7 .. 0.5 stay apart.
    assert(clusters.length == 2 && cell["reference"]["vertex_count"].integer == 34,
           format("detector: expected the 2 captured clusters, found %s", clusters));
}

unittest { // census: one coincidence search, and the mask weld holds no copy of it
    import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
                                       enclosingSymbols, symbolAt;
    import std.algorithm : count, sort;
    import std.string : splitLines;
    string[] declsOf(string src, string needle) {
        const code = blankUnittestBodies(blankNonCode(src));
        const syms = enclosingSymbols(code);
        string[] outp;
        foreach (li, ln; code.splitLines())
            foreach (_; 0 .. ln.count(needle)) outp ~= symbolAt(syms, li);
        sort(outp);
        return outp;
    }
    // Scanner control: the pre-9436 nested seed walk is seen where it stands.
    enum probe = "struct Mesh {\n    void w() {\n        foreach (i; 0 .. n)\n"
               ~ "            foreach (j; i + 1 .. n) {}\n    }\n}\n";
    assert(declsOf(probe, "foreach (j; i + 1") == ["Mesh.w"], "scanner control");

    const src = readText(buildPath(repoRoot, "source", "mesh.d"));
    const nested = declsOf(src, "foreach (j; i + 1");
    assert(nested.count("Mesh.weldVerticesByMask") == 0, format(
        "Mesh.weldVerticesByMask carries its own O(n^2) seed walk again: %s", nested));
    // Keyed on the bare identifier so an address or a template call counts too.
    const callers = declsOf(src, "computeWeldRemap");
    const string[] want = ["Mesh", "Mesh.weldCoincidentVertices", "Mesh.weldVerticesByMask"];
    assert(callers == want, format("computeWeldRemap roster in source/mesh.d: expected %s, found %s",
                                   want, callers));
}

version (PerfProbe) unittest { // the mask weld is bucketed: a 20k-vertex grid at distance 1
    // A 142 x 142 grid of unit spacing (20 164 vertices), all selected, merged at
    // distance 1 (each seed claims its grid neighbours). The work is the number of
    // candidate pairs the one search looked at — the quadratic walk it replaced
    // compared ~2e8 pairs; this pins the bucketed count.
    enum side = 142;
    Vec3[] vs;
    foreach (z; 0 .. side) foreach (x; 0 .. side) vs ~= Vec3(x, 0, z);
    uint[][] fs;
    foreach (z; 0 .. side - 1) foreach (x; 0 .. side - 1) {
        const uint a = cast(uint)(z * side + x);
        fs ~= [a, a + 1, a + 1 + side, a + side];
    }
    Mesh m = settle(vs, fs);
    auto all = new bool[](m.vertices.length);
    all[] = true;
    const before = weldPairVisits;
    const welded = m.weldVerticesByMask(all, 1.0, true);
    const visits = weldPairVisits - before;
    assert(welded == 10_082, format("population: expected 10082 welds, got %d", welded));
    assert(visits == 90_740, format("bucket visits: expected 90740, got %d", visits));
}
