// Task 9484: MeshSmooth against the captured relax law (tests/fixtures/smooth_kernel.json
// — the step law, the selection/lock mask, the preserve re-projection and its sampling).
// Every cell drives the production builder on a mesh built from the captured rig.
module tests.unit.commands.mesh.smooth_kernel_parity_test;

import std.algorithm : max;
import std.file : readText;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : fabs, sqrt;

import commands.mesh.smooth : MeshSmooth, SurfaceLineIndex, preserveProjectsAt,
    projectOntoSurfaceBrute;
version (PerfProbe) import commands.mesh.smooth : surfaceHitTests;
import commands.mesh.vertex_position_result : VertexPositionResult;
import document : primaryModelSpaceResolver;
import editmode : EditMode;
import falloff : evaluateFalloff;
import math : ModelSpace, Vec3, aimSpace;
import mesh : Mesh;
import operator : VectorStack;
import params : Param, ParamProvider;
import toolpipe.packets : FalloffPacket, FalloffShape, FalloffType, SubjectPacket;
import tools.edit.smooth_relax : RelaxVec3;
import view : View;

private JSONValue fixture() {
    static JSONValue cached;
    static bool loaded;
    if (!loaded) {
        cached = parseJSON(readText("tests/fixtures/smooth_kernel.json"));
        loaded = true;
    }
    return cached;
}

private double num(const JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}

private Vec3 vec(const JSONValue v) {
    return Vec3(cast(float)num(v[0]), cast(float)num(v[1]), cast(float)num(v[2]));
}

private Mesh rig(const JSONValue cell) {
    Mesh m;
    foreach (p; cell["points"].array) m.vertices ~= vec(p);
    foreach (f; cell["faces"].array) {
        uint[] idx;
        foreach (i; f.array) idx ~= cast(uint)i.integer;
        m.addFace(idx);
    }
    m.buildLoops();
    m.syncSelection();
    return m;
}

private void setParam(MeshSmooth cmd, string name, double value) {
    foreach (ref p; cmd.params()) if (p.name == name) {
        if (p.kind == Param.Kind.Float) *p.fptr = cast(float)value;
        else if (p.kind == Param.Kind.Int) *p.iptr = cast(int)value;
        else if (p.kind == Param.Kind.Bool) *p.bptr = value != 0;
        else assert(false, "unexpected kind of parameter " ~ name);
        return;
    }
    assert(false, "missing parameter " ~ name);
}

/// Run the production builder and return the full position image.
private Vec3[] smoothed(ref Mesh m, EditMode mode, MeshSmooth cmd,
                        FalloffPacket* falloff = null) {
    View view = new View(0, 0, 800, 600);
    SubjectPacket subj;
    subj.mesh = &m;
    subj.editMode = mode;
    subj.viewport = view.viewport();
    VectorStack vts;
    vts.put(&subj);
    if (falloff !is null) vts.put(falloff);
    VertexPositionResult r;
    assert(cmd.buildVertexPositionResult(m.vertices, vts, r), "smooth builder refused");
    auto out_ = m.vertices.dup;
    foreach (i, vi; r.indices) out_[vi] = r.after[i];
    return out_;
}

private double maxErr(const(Vec3)[] got, const JSONValue want) {
    assert(got.length == want.array.length);
    double e = 0;
    foreach (i, w; want.array) {
        const dx = got[i].x - num(w[0]), dy = got[i].y - num(w[1]), dz = got[i].z - num(w[2]);
        e = max(e, sqrt(dx * dx + dy * dy + dz * dz));
    }
    return e;
}

// The captured outcomes match the law to <= 1.2e-7 (float storage); the
// nearest refuted candidate in any cell is 4.8e-5 away, the old Laplacian >= 0.09.
enum double kTol = 1e-6;

unittest { // the step law: four rigs, nothing selected, no locks, no falloff
    auto cells = fixture()["kernel"].array;
    assert(cells.length == 4, "kernel cell population");
    foreach (cell; cells) {
        Mesh m = rig(cell);
        View cv = new View(0, 0, 800, 600);
        auto cmd = new MeshSmooth(&m, cv, EditMode.Vertices);
        setParam(cmd, "strn", num(cell["strn"]));
        setParam(cmd, "iter", num(cell["iter"]));
        const e = maxErr(smoothed(m, EditMode.Vertices, cmd), cell["after"]);
        assert(e <= kTol, format("%s: smooth step off the captured law by %.3g m",
            cell["id"].str, e));
    }
}

unittest { // preserve sampling: i < 10, the last iteration and every 100th
    auto cell = fixture()["preserve_sampling"];
    const iters = cast(int)cell["iter"].integer;
    int[] got;
    foreach (i; 0 .. iters) if (preserveProjectsAt(i, iters)) got ~= i;
    int[] want;
    foreach (v; cell["projected_iterations"].array) want ~= cast(int)v.integer;
    assert(want.length == 12, "sampling population");
    assert(got == want, format("preserve sampled %s, captured %s", got, want));
}

unittest { // selection mask and the three locks
    auto cells = fixture()["selection_locks"].array;
    assert(cells.length == 6, "selection/lock cell population");
    foreach (cell; cells) {
        Mesh m = rig(cell);
        EditMode mode = EditMode.Vertices;
        if (cell["selection"].type == JSONType.object) {
            const kind = cell["selection"]["type"].str;
            foreach (i; cell["selection"]["indices"].array) {
                if (kind == "vertex") m.selectVertex(cast(int)i.integer);
                else m.selectFace(cast(int)i.integer);
            }
            if (kind == "polygon") mode = EditMode.Polygons;
        }
        View cv = new View(0, 0, 800, 600);
        auto cmd = new MeshSmooth(&m, cv, mode);
        setParam(cmd, "strn", num(cell["strn"]));
        setParam(cmd, "iter", num(cell["iter"]));
        setParam(cmd, "lockBound", cell["lockBound"].boolean);
        setParam(cmd, "lockCorner", cell["lockCorner"].boolean);
        setParam(cmd, "lockSharp", cell["lockSharp"].boolean);
        setParam(cmd, "sharpThreshold", num(cell["sharpThreshold"]));
        const before = m.vertices.dup;
        auto got = smoothed(m, mode, cmd);
        int[] moved;
        foreach (i; 0 .. got.length) if (got[i] != before[i]) moved ~= cast(int)i;
        int[] active;
        foreach (v; cell["active"].array) active ~= cast(int)v.integer;
        assert(moved == active, format("%s: moved %s, captured active set %s",
            cell["id"].str, moved, active));
        const e = maxErr(got, cell["after"]);
        assert(e <= kTol, format("%s: smooth off the captured law by %.3g m",
            cell["id"].str, e));
    }
}

unittest { // preserve: projection onto the original surface inside the loop, falloff lerp last
    auto savedModelSpace = primaryModelSpaceResolver;
    scope(exit) primaryModelSpaceResolver = savedModelSpace;
    primaryModelSpaceResolver = () => ModelSpace.world();

    auto cells = fixture()["preserve"].array;
    assert(cells.length == 3, "preserve cell population");
    foreach (cell; cells) {
        Mesh m = rig(cell);
        View cv = new View(0, 0, 800, 600);
        auto cmd = new MeshSmooth(&m, cv, EditMode.Vertices);
        setParam(cmd, "strn", num(cell["strn"]));
        setParam(cmd, "iter", num(cell["iter"]));
        setParam(cmd, "preserve", cell["preserve"].boolean);
        FalloffPacket fp;
        fp.enabled = true;
        fp.type = FalloffType.Radial;
        fp.shape = FalloffShape.Linear;
        fp.center = vec(cell["falloff"]["center"]);
        fp.size = vec(cell["falloff"]["size"]);
        // Control: our radial weight is the captured one at every vertex.
        View view = new View(0, 0, 800, 600);
        const vp = view.viewport();
        const aim = aimSpace(vp, ModelSpace.world());
        size_t weighted;
        foreach (i, wv; cell["weights"].array) {
            const w = evaluateFalloff(fp, m.vertices[i], cast(int)i, aim);
            assert(fabs(w - num(wv)) <= 1e-6, format("%s: weight %d ours %.9g captured %.9g",
                cell["id"].str, i, w, num(wv)));
            if (num(wv) > 0) ++weighted;
        }
        assert(weighted == 13, format("%s: weighted population %d", cell["id"].str, weighted));
        const e = maxErr(smoothed(m, EditMode.Vertices, cmd, &fp), cell["expected"]);
        assert(e <= kTol, format("%s: preserve/falloff smooth off the captured law by %.3g m",
            cell["id"].str, e));
    }
}

unittest { // the sampling predicate is the one the iteration loop consults
    import std.algorithm : count;
    const src = readText("source/commands/mesh/smooth.d");
    assert(src.count("preserveProjectsAt(") == 2,
        "smooth.d: one definition and one call of preserveProjectsAt");
    assert(src.count("if (preserve_ && preserveProjectsAt(i, iters))") == 1,
        "the preserve projection must run only at the sampled iterations");
}

unittest { // a non-finite strength is refused by the kernel: nothing moves
    auto cell = fixture()["kernel"].array[0];
    Mesh m = rig(cell);
    View cv = new View(0, 0, 800, 600);
    auto cmd = new MeshSmooth(&m, cv, EditMode.Vertices);
    setParam(cmd, "strn", double.nan);
    setParam(cmd, "iter", 3);
    const before = m.vertices.dup;
    assert(smoothed(m, EditMode.Vertices, cmd) == before,
        "a NaN strength must leave every vertex in place");
    setParam(cmd, "strn", 0.5);   // control: the same rig moves at a finite strength
    assert(smoothed(m, EditMode.Vertices, cmd) != before, "control: finite strength moves");
}

unittest { // a regular cube is a fixed point of the law: the builder result is EMPTY
    import mesh : makeCube;
    Mesh m = makeCube();
    View cv = new View(0, 0, 800, 600);
    auto cmd = new MeshSmooth(&m, cv, EditMode.Vertices);
    setParam(cmd, "strn", 1.0);
    setParam(cmd, "iter", 3);
    SubjectPacket subj;
    subj.mesh = &m;
    subj.editMode = EditMode.Vertices;
    subj.viewport = cv.viewport();
    VectorStack vts;
    vts.put(&subj);
    VertexPositionResult r;
    assert(cmd.buildVertexPositionResult(m.vertices, vts, r));
    assert(r.empty, format("a cube smooth carried %d unchanged vertices", r.indices.length));
}

// Lock rules on shapes the capture did not drive, pinned as ours.
private Mesh fan() {   // three quads on the spine (0,1): a non-manifold edge
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
                  Vec3(1, -1, 0), Vec3(0, -1, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)];
    m.faces = [[0u, 1u, 2u, 3u], [1u, 0u, 5u, 4u], [0u, 1u, 6u, 7u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

private Vec3[] runLocks(ref Mesh m, bool lockCorner, bool lockSharp) {
    View cv = new View(0, 0, 800, 600);
    auto cmd = new MeshSmooth(&m, cv, EditMode.Vertices);
    setParam(cmd, "strn", 1.0);
    setParam(cmd, "iter", 2);
    setParam(cmd, "lockCorner", lockCorner);
    setParam(cmd, "lockSharp", lockSharp);
    setParam(cmd, "sharpThreshold", 180);
    return smoothed(m, EditMode.Vertices, cmd);
}

unittest { // lockSharp: a non-manifold edge is sharp at any threshold
    Mesh m = fan();
    const before = m.vertices.dup;
    auto free = runLocks(m, false, false);
    assert(free[0] != before[0] && free[1] != before[1], "control: the spine moves unlocked");
    auto locked = runLocks(m, false, true);
    assert(locked[0] == before[0] && locked[1] == before[1],
        "lockSharp must pin both ends of the three-face spine");
    assert(locked[3] != before[3], "control: a rim vertex still moves");
}

unittest { // lockCorner counts polygons of >= 3 sides: a two-corner polygon on
           // a quad's edge leaves its ends used by ONE polygon, so still locked
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0.2f, 0), Vec3(1.3f, 1, 0.1f), Vec3(0, 1, 0)];
    m.faces = [[0u, 1u, 2u, 3u], [0u, 1u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    const before = m.vertices.dup;
    assert(runLocks(m, false, false) != before, "control: the quad moves unlocked");
    assert(runLocks(m, true, false) == before,
        "lockCorner must pin every vertex used by one polygon of >= 3 sides");
}

// Preserve's hit index answers exactly what the brute pass over every triangle
// answers: a folded, overlapping surface (several hits per line, both signs of
// t) and lines through shared grid vertices and edges (|t| ties).
private RelaxVec3[3][] foldedSurface() {
    import std.math : sin;
    RelaxVec3[3][] tris;
    enum side = 12;
    RelaxVec3 at(int x, int z, double lift) {
        return RelaxVec3(x * 0.25, lift + 0.3 * sin(x * 0.9) * sin(z * 0.7), z * 0.25);
    }
    foreach (sheet; 0 .. 3) foreach (z; 0 .. side) foreach (x; 0 .. side) {
        const double l = sheet * 0.4;
        RelaxVec3[3] a = [at(x, z, l), at(x + 1, z, l), at(x + 1, z + 1, l)];
        RelaxVec3[3] b = [at(x, z, l), at(x + 1, z + 1, l), at(x, z + 1, l)];
        tris ~= a;
        tris ~= b;
    }
    return tris;
}

unittest {
    import std.random : Random, uniform;
    auto tris = foldedSurface();
    assert(tris.length == 864, "surface population");
    const index = SurfaceLineIndex(tris);
    auto rng = Random(9484);
    size_t hits, misses, indexTests;
    foreach (i; 0 .. 4000) {
        // Half the lines start on an exact grid vertex with an axis normal.
        const bool onGrid = i % 2 == 0;
        RelaxVec3 p = onGrid
            ? RelaxVec3(uniform(0, 13, rng) * 0.25, uniform(-1.0, 2.0, rng), uniform(0, 13, rng) * 0.25)
            : RelaxVec3(uniform(-0.5, 3.5, rng), uniform(-1.0, 2.0, rng), uniform(-0.5, 3.5, rng));
        Vec3 n = onGrid ? Vec3(0, i % 4 == 0 ? 1 : -1, 0)
            : Vec3(uniform(-1.0f, 1.0f, rng), uniform(-1.0f, 1.0f, rng), uniform(-1.0f, 1.0f, rng));
        if (!onGrid && n.length > 0) n = n * (1.0f / n.length);
        RelaxVec3 viaIndex = p, viaBrute = p;
        version (PerfProbe) const t0 = surfaceHitTests;
        index.project(viaIndex, n);
        version (PerfProbe) indexTests += surfaceHitTests - t0;
        projectOntoSurfaceBrute(viaBrute, n, tris);
        assert(viaIndex == viaBrute, format("line %d: index (%.17g %.17g %.17g) brute (%.17g %.17g %.17g)",
            i, viaIndex.x, viaIndex.y, viaIndex.z, viaBrute.x, viaBrute.y, viaBrute.z));
        if (viaBrute == p) ++misses; else ++hits;
    }
    assert(hits == 3106 && misses == 894, format("hit population %d / %d", hits, misses));
    // A line inside a wall's padded box but off its plane: t = ±inf, no hit.
    RelaxVec3[3][] wall = [[RelaxVec3(1, 0, 0), RelaxVec3(1, 1, 0), RelaxVec3(1, 0, 1)]];
    const wallIndex = SurfaceLineIndex(wall);
    foreach (dx; [-1e-10, 1e-10]) foreach (ny; [-1.0f, 1.0f]) {
        const p = RelaxVec3(1 + dx, 0.5, 0.25);
        RelaxVec3 q = p;
        wallIndex.project(q, Vec3(0, ny, 0));
        assert(q == p, format("a parallel wall (dx %g, n.y %g) moved the point", dx, ny));
    }
    // The brute pass runs 4000 x 864 = 3 456 000 triangle tests.
    // Floor: every hit came from at least one triangle test.
    version (PerfProbe) assert(indexTests >= hits, format("index triangle tests: %d", indexTests));
    version (PerfProbe) assert(indexTests <= 45_000,
        format("index triangle tests: %d (measured 42 624)", indexTests));
}

version (PerfProbe) unittest { // preserve on a 40k-face surface tests a bounded set of triangles
    import std.math : sin, cos;
    enum side = 200;
    Mesh m;
    foreach (z; 0 .. side + 1) foreach (x; 0 .. side + 1)
        m.vertices ~= Vec3(x * 0.1f, 0.05f * sin(x * 0.37f) * cos(z * 0.23f), z * 0.1f);
    foreach (z; 0 .. side) foreach (x; 0 .. side) {
        const uint a = cast(uint)(z * (side + 1) + x);
        m.addFace([a, a + 1, a + 2 + side, a + 1 + side]);
    }
    m.buildLoops();
    m.syncSelection();
    View cv = new View(0, 0, 800, 600);
    auto cmd = new MeshSmooth(&m, cv, EditMode.Vertices);
    setParam(cmd, "iter", 10);
    setParam(cmd, "preserve", 1);
    const before = surfaceHitTests;
    auto got = smoothed(m, EditMode.Vertices, cmd);
    const tests = surfaceHitTests - before;
    size_t moved;
    foreach (i; 0 .. got.length) if (got[i] != m.vertices[i]) ++moved;
    assert(moved == 40_328, format("population: %d vertices moved", moved));
    // 40 401 vertices x 10 projections x 80 000 triangles = 3.2e10 for the brute pass.
    assert(tests >= moved, format("triangle tests: %d below the moved population", tests));
    assert(tests <= 3_000_000, format("triangle tests: %d (measured 2 932 256)", tests));
}

// A prefs file written before the threshold became degrees holds the radians
// sentinel "-1" (and the former `sharpAngle`): its recall must leave the default.
unittest {
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import prefs : loadPrefs;
    import toolpipe.attr_cache : kToolNode, recallNodeAttrs;
    const dir = buildPath(tempDir(), "vibe3d_smooth_prefs_9484");
    mkdirRecurse(dir);
    scope(exit) rmdirRecurse(dir);
    float recalled(string file) {
        write(buildPath(dir, "prefs.json"), file);
        auto attrs = loadPrefs(dir).toolAttrCache.lookup("xfrm.smooth", kToolNode);
        assert(attrs !is null, "the smooth entry is kept");
        assert("sharpAngle" !in *attrs, "the former sharpAngle attribute is dropped");
        Mesh m;
        View cv = new View(0, 0, 800, 600);
        auto cmd = new MeshSmooth(&m, cv, EditMode.Vertices);
        recallNodeAttrs(new class ParamProvider {
            Param[] params() { return cmd.params(); }
            bool paramEnabled(string) const { return true; }
            void onParamChanged(string) {}
        }, *attrs, false);
        foreach (ref p; cmd.params()) {
            if (p.name == "lockSharp") assert(*p.bptr, "the other attributes recall");
            if (p.name == "sharpThreshold") return *p.fptr;
        }
        assert(false, "no sharpThreshold");
    }
    enum tool = `"toolAttrCache":{"xfrm.smooth":{"tool":{"lockSharp":"true",%s"sharpThreshold":"%s"}}}`;
    assert(recalled(`{"version":1,` ~ format(tool, `"sharpAngle":"60",`, "-1") ~ `}`) == 60.0f,
        "a version-1 sharpThreshold (radians) must not recall");
    assert(recalled(`{"version":2,` ~ format(tool, "", "45") ~ `}`) == 45.0f,
        "control: a current-version threshold recalls");

    // Only the retired (preset, node, attribute) rows of a version-1 file go,
    // the legacy `toolDefaults` section included; a saved file keeps them.
    import prefs : Prefs, savePrefs;
    write(buildPath(dir, "prefs.json"), `{"version":1,`
        ~ `"toolDefaults":{"xfrm.smooth":{"sharpThreshold":"-1","iter":"3"}},`
        ~ `"toolAttrCache":{"bevel":{"tool":{"sharpThreshold":"-1"}},`
        ~ `"xfrm.smooth":{"falloff":{"sharpAngle":"5"}}}}`);
    auto old = loadPrefs(dir).toolAttrCache;
    const legacy = old.lookup("xfrm.smooth", kToolNode);
    assert(legacy.length == 1 && (*legacy)["iter"] == "3",
        "the legacy section drops the retired threshold");
    assert((*old.lookup("bevel", kToolNode))["sharpThreshold"] == "-1",
        "another preset's attribute of the same name is kept");
    assert((*old.lookup("xfrm.smooth", "falloff"))["sharpAngle"] == "5",
        "another node's attribute of the same name is kept");
    Prefs cur;
    cur.toolAttrCache.store("xfrm.smooth", kToolNode, ["sharpThreshold": "45"]);
    savePrefs(cur, dir);
    assert((*loadPrefs(dir).toolAttrCache.lookup("xfrm.smooth", kToolNode))["sharpThreshold"] == "45",
        "a file this build saves keeps the threshold");
}
