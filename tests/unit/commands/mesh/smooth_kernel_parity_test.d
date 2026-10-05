// Task 9484: MeshSmooth against the captured relax law (tests/fixtures/smooth_kernel.json
// — the step law, the selection/lock mask, the preserve re-projection and its sampling).
// Every cell drives the production builder on a mesh built from the captured rig.
module tests.unit.commands.mesh.smooth_kernel_parity_test;

import std.algorithm : max;
import std.file : readText;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : fabs, sqrt;

import commands.mesh.smooth : MeshSmooth, preserveProjectsAt;
import commands.mesh.vertex_position_result : VertexPositionResult;
import document : primaryModelSpaceResolver;
import editmode : EditMode;
import falloff : evaluateFalloff;
import math : ModelSpace, Vec3, aimSpace;
import mesh : Mesh;
import operator : VectorStack;
import params : Param;
import toolpipe.packets : FalloffPacket, FalloffShape, FalloffType, SubjectPacket;
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
