// Align Work Plane to Selection on vertices / edges, and the typed-plane Euler
// order (tasks 7119 R / 7120 F). Every expectation is reference data read from
// tests/fixtures/workplane_align_and_primitive_placement.json (`align`,
// `skew_rigs`, `placement[b-cube].plane_at_gesture`); law: measured_laws §23.
//
// Rig: our cube (+-0.5) after scene.reset, shifted by the cell's cube_offset
// and re-loaded; the fixture's vertex ids 4*(x>0)+2*(y>0)+(z>0) are mapped to
// OUR vertices by POSITION and edges by their endpoint pair. The plane is read
// back through the WORK stage's read-only basis attrs on /api/toolpipe.
//
// Order is load-bearing (druntime stops at the first red): population floor,
// the a-1p control, vertex cells, edge cells (skew pair last), the skew rigs,
// the coplanar-through-origin refusal, then the Euler block.

import http_client : testBaseUrl, getJson, postJson, postRawAllowingErrorStatus;
import http_command_helpers : commandBody;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.format : format;
import std.algorithm : canFind;

void main() {}

private JSONValue fixture() {
    return parseJSON(import("fixtures/workplane_align_and_primitive_placement.json"));
}

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}

private double[3] vec(JSONValue a) {
    return [num(a.array[0]), num(a.array[1]), num(a.array[2])];
}

private void ok(string cmdBody) {
    auto r = postJson("/api/command", cmdBody);
    assert(r["status"].str == "ok", "/api/command " ~ cmdBody ~ " failed: " ~ r.toString);
}

private void runLine(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

/// The align command through the script door; true = status ok.
private bool alignSel() {
    auto r = parseJSON(postRawAllowingErrorStatus("/api/command", "workplane.alignToSelection"));
    return r["status"].str == "ok";
}

private struct Plane { double[3] o, x, y, z; }

private Plane readPlane() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str != "WORK") continue;
        string[string] a;
        foreach (k, v; st["attrs"].object) a[k] = v.str;
        foreach (key; ["cenX", "axisXx", "normalX", "axisZx"])
            assert((key in a) !is null, "WORK stage has no '" ~ key ~ "' attr");
        double g(string k) { return a[k].to!double; }
        Plane p;
        p.o = [g("cenX"), g("cenY"), g("cenZ")];
        p.x = [g("axisXx"), g("axisXy"), g("axisXz")];
        p.y = [g("normalX"), g("normalY"), g("normalZ")];
        p.z = [g("axisZx"), g("axisZy"), g("axisZz")];
        return p;
    }
    assert(false, "WORK stage not found in /api/toolpipe");
}

private bool near(double[3] a, double[3] b, double tol) {
    foreach (i; 0 .. 3) if (fabs(a[i] - b[i]) > tol) return false;
    return true;
}

private bool sameLine(double[3] a, double[3] b, double tol) {
    double d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    return fabs(d) >= 1.0 - tol;
}

private string fmt(double[3] v) { return format("(%.7f, %.7f, %.7f)", v[0], v[1], v[2]); }

/// Load a mesh (vertices, polygons) and return the live model.
private JSONValue loadMesh(double[3][] verts, JSONValue faces) {
    JSONValue body_ = JSONValue(string[string].init);
    JSONValue[] vs;
    foreach (v; verts) vs ~= JSONValue([v[0], v[1], v[2]]);
    body_["vertices"] = JSONValue(vs);
    body_["faces"] = faces;
    ok(commandBody("scene.loadMesh", body_.toString));
    return getJson("/api/model");
}

/// Our vertex index at `p` (floor: it must exist).
private int vertexAt(JSONValue model, double[3] p, string cell) {
    foreach (i, v; model["vertices"].array)
        if (near(vec(v), p, 1e-4)) return cast(int)i;
    assert(false, cell ~ ": no vertex of ours at " ~ fmt(p));
}

private int edgeOf(JSONValue model, int a, int b, string cell) {
    foreach (i, e; model["edges"].array) {
        int x = cast(int)e.array[0].integer, y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    assert(false, format("%s: no edge of ours between %d and %d", cell, a, b));
}

/// Order floor: the selection order the command reads is the cell's order.
private void assertOrder(string mode, int[] verts, int[2][] edges, string cell) {
    auto planes = getJson("/api/mesh/planes");
    int last = 0;
    if (mode == "vertices") {
        auto ord = planes["vertexSelectionOrder"].array;
        foreach (v; verts) {
            int o = cast(int)ord[v].integer;
            assert(o > last, format("%s: vertexSelectionOrder not increasing in cell order (%d after %d)",
                                    cell, o, last));
            last = o;
        }
    } else {
        foreach (e; edges) {
            int lo = e[0] < e[1] ? e[0] : e[1], hi = e[0] < e[1] ? e[1] : e[0];
            int o = -1;
            foreach (row; planes["edgePlanes"].array)
                if (row["ends"].array[0].integer == lo && row["ends"].array[1].integer == hi)
                    o = cast(int)row["order"].integer;
            assert(o > last, format("%s: edge selection order not increasing in cell order (%d after %d)",
                                    cell, o, last));
            last = o;
        }
    }
}

private double[3] refCubeVertex(long id, double[3] off) {
    return [((id & 4) ? 0.5 : -0.5) + off[0],
            ((id & 2) ? 0.5 : -0.5) + off[1],
            ((id & 1) ? 0.5 : -0.5) + off[2]];
}

/// scene.reset, shift our cube by `off`, re-load it; returns the model.
private JSONValue cubeRig(double[3] off) {
    ok(commandBody("scene.reset"));
    auto m = getJson("/api/model");
    double[3][] vs;
    foreach (v; m["vertices"].array) {
        auto p = vec(v);
        vs ~= [p[0] + off[0], p[1] + off[1], p[2] + off[2]];
    }
    return loadMesh(vs, m["faces"]);
}

private void setPrior(JSONValue cell) {
    if (cell["prior_plane"].type == JSONType.null_) return;
    auto pp = cell["prior_plane"];
    auto o = vec(pp["origin"]);
    auto r = vec(pp["rotation_rad_xyz"]);
    enum d = 180.0 / 3.14159265358979323846;
    runLine(format("workplane.edit cenX:%.9g cenY:%.9g cenZ:%.9g rotX:%.9g rotY:%.9g rotZ:%.9g",
                   o[0], o[1], o[2], r[0] * d, r[1] * d, r[2] * d));
}

private void checkPlane(string cell, Plane got, JSONValue want, string xRule, double tol) {
    auto o = vec(want["origin"]);
    auto y = vec(want["axis_y_normal"]);
    auto x = vec(want["axis_x"]);
    assert(near(got.o, o, 1e-5), format("workplane from %s differs from reference: origin — got %s want %s",
                                        cell, fmt(got.o), fmt(o)));
    assert(near(got.y, y, tol), format("workplane from %s differs from reference: Y — got %s want %s",
                                       cell, fmt(got.y), fmt(y)));
    if (xRule == "full") {
        assert(near(got.x, x, tol), format("workplane from %s differs from reference: X — got %s want %s",
                                           cell, fmt(got.x), fmt(x)));
        auto z = vec(want["axis_z"]);
        assert(near(got.z, z, tol), format("workplane from %s differs from reference: Z — got %s want %s",
                                           cell, fmt(got.z), fmt(z)));
    } else if (xRule == "line") {
        assert(sameLine(got.x, x, 1e-5), format("workplane from %s differs from reference: X — got %s want line %s",
                                                cell, fmt(got.x), fmt(x)));
    }
}

unittest { // 1. population floor; 2. a-1p control; 4. vertex then edge cells; 3. skew pair
    auto fx = fixture();
    auto cells = fx["align"].array;
    assert(cells.length == 16, format("align population changed: %d, expected 16", cells.length));

    // 2. control — the polygon branch, green before and after the fix.
    int polygons = 0;
    foreach (cell; cells) {
        if (cell["selection_type"].str != "polygon") continue;
        string name = cell["cell"].str;
        assert(name == "a-1p", "unexpected polygon cell " ~ name);
        auto m = cubeRig(vec(cell["cube_offset"]));
        // reference face 0 = [1,5,7,3]: our face with the same vertex set.
        int[] want;
        foreach (id; [1, 5, 7, 3]) want ~= vertexAt(m, refCubeVertex(id, vec(cell["cube_offset"])), name);
        int face = -1;
        foreach (fi, f; m["faces"].array) {
            if (f.array.length != 4) continue;
            bool all = true;
            foreach (vi; f.array) if (!want.canFind(cast(int)vi.integer)) all = false;
            if (all) face = cast(int)fi;
        }
        assert(face >= 0, "a-1p: our cube has no face over reference face 0");
        ok(commandBody("mesh.select", format(`{"mode":"polygons","indices":[%d]}`, face)));
        assert(alignSel(), "workplane from a-1p refused (reference aligns)");
        checkPlane(name, readPlane(), cell["result_plane"], "none", 1e-5);
        ++polygons;
    }
    assert(polygons == 1, format("polygon control cells: %d, expected 1", polygons));

    // 4. vertex cells in fixture order, then edge cells (the skew pair last).
    static immutable string[] fullX = ["a-1v", "a-1v-p-key", "a-1v-p-btn", "a-3v", "a-2e-adj",
                                       "a-2e-skew", "a-2e-skew-t"];
    int aligned = 0, skew = 0;
    foreach (pass; 0 .. 3) {
        foreach (cell; cells) {
            string name = cell["cell"].str;
            string type = cell["selection_type"].str;
            bool isSkew = name == "a-2e-skew" || name == "a-2e-skew-t";
            if (pass == 0 && type != "vertex") continue;
            if (pass == 1 && (type != "edge" || isSkew)) continue;
            if (pass == 2 && !isSkew) continue;
            auto off = vec(cell["cube_offset"]);
            auto m = cubeRig(off);
            setPrior(cell);
            if (type == "vertex") {
                int[] ours;
                foreach (id; cell["selection_in_order"].array)
                    ours ~= vertexAt(m, refCubeVertex(id.integer, off), name);
                ok(commandBody("mesh.select", format(`{"mode":"vertices","indices":%s}`, ours)));
                assertOrder("vertices", ours, null, name);
            } else {
                int[] ids;
                int[2][] pairs;
                foreach (e; cell["selection_in_order"].array) {
                    int a = vertexAt(m, refCubeVertex(e.array[0].integer, off), name);
                    int b = vertexAt(m, refCubeVertex(e.array[1].integer, off), name);
                    ids ~= edgeOf(m, a, b, name);
                    pairs ~= [a, b];
                }
                ok(commandBody("mesh.select", format(`{"mode":"edges","indices":%s}`, ids)));
                assertOrder("edges", null, pairs, name);
            }
            assert(alignSel(), "workplane from " ~ name ~ " refused (reference aligns)");
            string rule = fullX.canFind(name) ? "full" : "line";
            checkPlane(name, readPlane(), cell["result_plane"], rule, 1e-5);
            ++aligned;
            if (isSkew) ++skew;
        }
    }
    assert(aligned == 15, format("aligned vertex/edge cells: %d, expected 15", aligned));
    assert(skew == 2, format("skew-pair cells: %d, expected 2", skew));
}

unittest { // 5. the typed plane's Euler order: B = Rz * Rx * Ry
    auto fx = fixture();
    JSONValue want;
    int found = 0;
    foreach (c; fx["placement"].array)
        if (c["cell"].str == "b-cube") { want = c["plane_at_gesture"]; ++found; }
    assert(found == 1, "fixture has no b-cube placement cell");
    auto r = vec(want["rotation_rad_xyz"]);
    // Discrimination floor: with one non-zero angle every order agrees.
    int nonZero = 0;
    foreach (a; r) if (fabs(a) > 1e-6) ++nonZero;
    assert(nonZero == 2, format("b-cube plane must carry exactly two angles, has %d", nonZero));

    ok(commandBody("scene.reset"));
    runLine("workplane.edit rotX:30 rotY:40 rotZ:0");
    auto p = readPlane();
    foreach (ax; [["X", "axis_x"], ["Y", "axis_y_normal"], ["Z", "axis_z"]]) {
        double[3] got = ax[0] == "X" ? p.x : ax[0] == "Y" ? p.y : p.z;
        auto w = vec(want[ax[1]]);
        assert(near(got, w, 1e-5), format("typed plane basis differs from the reference Euler order: %s got %s want %s",
                                          ax[0], fmt(got), fmt(w)));
    }
}
