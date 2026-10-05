// The tool attribute door's bounds (task 9492; captured K-A3, findings_K-A3.md
// table b, the EXECUTED-write column): one out-of-range write per side through
// `tool.attr` reads back the captured bound, or the written value where the
// reference stores it as given ("free"). Ints are probed at -1000000 / 100000,
// floats at -1e30 / 1e30 (spelled out: the wire's argstring does not read an
// exponent). Rows are collected so one run names every divergence.
//
// The stored-state paths do not clamp (here `tool.set <id> on name:value`), so
// each kernel caps the count itself: cell `kernel` builds once from a stored
// value past the door's bound and once from the cap written through the door,
// and the two meshes must agree.
//
// Run via: ./run_test.d test_tool_attr_bounds   (one block: VIBE3D_CELL=door|kernel|exponent)

import http_client : getJson, postRawAllowingErrorStatus;
import std.algorithm : splitter;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, fmax;
import std.process : environment;
import std.stdio : writeln;

void main() {}

JSONValue cmd(string line) {
    return parseJSON(postRawAllowingErrorStatus("/api/command", line));
}

void ok(string line) {
    auto r = cmd(line);
    assert(r["status"].str == "ok", line ~ " -> " ~ r.toString);
}

bool cell(string id) {
    const want = environment.get("VIBE3D_CELL", "");
    return want.length == 0 || want == id;
}

double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}

unittest {
    if (!cell("door")) return;
    struct Row { string tool, setup, attr; bool isInt; string lo, hi; }
    static immutable Row[] rows = [
        Row("prim.cube", "", "segmentsX", true, "1", "free"),
        Row("prim.cube", "", "segmentsY", true, "1", "free"),
        Row("prim.cube", "", "segmentsZ", true, "1", "free"),
        Row("prim.cube", "", "radius", false, "0.0", "free"),
        Row("prim.cube", "tool.attr prim.cube radius 0.1", "segmentsR", true, "1", "free"),
        Row("prim.sphere", "", "sides", true, "3", "1024"),
        Row("prim.sphere", "", "segments", true, "1", "1024"),
        Row("prim.sphere", "tool.attr prim.sphere method qball", "order", true, "0", "32"),
        Row("prim.cone", "", "sides", true, "3", "1024"),
        Row("prim.cone", "", "segments", true, "1", "1024"),
        Row("prim.cylinder", "", "sides", true, "3", "1024"),
        Row("prim.cylinder", "", "segments", true, "1", "1024"),
        Row("prim.capsule", "", "sides", true, "3", "1024"),
        Row("prim.capsule", "", "segments", true, "1", "1024"),
        Row("prim.capsule", "", "endsegments", true, "1", "free"),
        Row("prim.ellipsoid", "", "sides", true, "3", "1024"),
        Row("prim.ellipsoid", "", "segments", true, "2", "free"),
        Row("prim.torus", "", "majorSegments", true, "3", "1024"),
        Row("prim.torus", "", "minorSegments", true, "2", "free"),
        Row("prim.torus", "", "majorRadius", false, "0.0", "free"),
        Row("mesh.arrayTool", "", "numX", true, "1", "free"),
        Row("mesh.arrayTool", "", "numY", true, "1", "free"),
        Row("mesh.arrayTool", "", "numZ", true, "1", "free"),
        Row("mesh.arrayTool", "tool.attr mesh.arrayTool merge true", "dist", false, "0.0", "free"),
        Row("mesh.clone", "", "num", true, "0", "free"),
        Row("mesh.clone", "tool.pipe.attr snap enabled true|tool.attr mesh.clone snap true", "snapAngle", false, "0.0", "5156.620156177409"),
        Row("mesh.clone", "tool.attr mesh.clone merge true", "dist", false, "0.0", "free"),
        Row("mesh.mirrorTool", "tool.attr mesh.mirrorTool mergeVerts true", "distance", false, "0.0", "free"),
        Row("mesh.radialArrayTool", "", "count", true, "1", "free"),
        Row("mesh.radialArrayTool", "tool.attr mesh.radialArrayTool merge true", "dist", false, "0.0", "free"),
        Row("mesh.loopSliceTool", "", "count", true, "1", "1024"),
        Row("mesh.loopSliceTool", "tool.attr mesh.loopSliceTool split true", "gap", false, "0.0", "free"),
        Row("mesh.sliceTool", "", "gap", false, "0.0", "free"),
        Row("mesh.edgeSliceTool", "", "snap", false, "0.0", "100.0"),
        Row("edge.bevel", "", "width", false, "0.0", "free"),
        Row("edge.bevel", "", "roundLevel", true, "0", "free"),
        Row("edge.extend", "", "segments", true, "1", "free"),
        Row("edge.extrude", "", "width", false, "0.0", "free"),
        Row("mesh.vertexBevel", "", "inset", false, "0.0", "free"),
        Row("mesh.vertexExtrude", "", "width", false, "0.0", "free"),
        Row("vert.merge", "", "dist", false, "0.0", "free"),
        Row("poly.bevel", "", "segments", true, "0", "free"),
        Row("xfrm.jitter", "tool.attr xfrm.jitter enableX true", "rangeX", false, "-1000000000.0", "1000000000.0"),
        Row("xfrm.jitter", "tool.attr xfrm.jitter enableY true", "rangeY", false, "-1000000000.0", "1000000000.0"),
        Row("xfrm.jitter", "tool.attr xfrm.jitter enableZ true", "rangeZ", false, "-1000000000.0", "1000000000.0"),
        Row("xfrm.linearAlignTool", "", "weight", false, "0.0", "1.0"),
        Row("xfrm.radialAlignTool", "", "side", true, "3", "free"),
        Row("xfrm.radialAlignTool", "", "weight", false, "0.0", "1.0"),
        Row("xfrm.quantize", "", "X", false, "0.0", "1000000000.0"),
        Row("xfrm.quantize", "", "Y", false, "0.0", "1000000000.0"),
        Row("xfrm.quantize", "", "Z", false, "0.0", "1000000000.0"),
        Row("xfrm.smooth", "", "iter", true, "1", "free"),
        Row("xfrm.smooth", "", "strn", false, "0.0", "1.0"),
        Row("xfrm.smooth", "tool.attr xfrm.smooth lockSharp true", "sharpThreshold", false, "0.0", "180.0"),
        Row("mesh.topoPen", "tool.attr mesh.topoPen mode 7", "smoothStrength", false, "0.0", "free"),
    ];
    string[] failed;
    size_t visited;
    foreach (r; rows) {
        foreach (side; 0 .. 2) {
            const probe = r.isInt ? (side ? "100000" : "-1000000")
                : (side ? "" : "-") ~ "1000000000000000000000000000000.0";
            const want = side ? r.hi : r.lo;
            ok("scene.reset");
            ok("tool.set " ~ r.tool ~ " on");
            foreach (line; r.setup.splitter('|')) if (line.length) ok(line);
            ++visited;
            auto w = cmd("tool.attr " ~ r.tool ~ " " ~ r.attr ~ " " ~ probe);
            auto q = cmd("tool.attr " ~ r.tool ~ " " ~ r.attr ~ " ?");
            const expect = (want == "free" ? probe : want).to!double;
            if (w["status"].str != "ok" || q["status"].str != "ok"
                || abs(num(q["value"]) - expect) > 1e-6 * fmax(1, abs(expect)))
                failed ~= format("%s %s <- %s: %s, reads %s, expected %s", r.tool, r.attr,
                                 probe, w["status"].str, q.toString, want);
        }
        ok("tool.set " ~ r.tool ~ " off");
    }
    assert(visited == 110, format("probes visited %d, expected 110", visited));
    assert(failed.length == 0, format("bounds diverge in %d probes:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS tool attribute bounds, 55 rows");
}

/// Vertex and face count of the mesh `tool` builds from `setup` (one line per
/// `|`, after `tool.set <tool> on<named>`), applied headless.
string built(string tool, string named, string setup) {
    ok("scene.reset");
    ok("tool.set " ~ tool ~ " on" ~ named);
    foreach (line; setup.splitter('|')) if (line.length) ok(line);
    ok("tool.doApply");
    ok("tool.set " ~ tool ~ " off");
    auto m = getJson("/api/model");
    return format("%s/%s", m["vertexCount"].integer, m["faceCount"].integer);
}

unittest {
    if (!cell("kernel")) return;
    struct Cap { string tool, setup, stored, atCap; }
    static immutable Cap[] caps = [
        Cap("prim.cone", "", " sides:5000", "tool.attr prim.cone sides 1024"),
        Cap("prim.cylinder", "", " segments:5000", "tool.attr prim.cylinder segments 1024"),
        Cap("prim.capsule", "", " endsegments:5000", "tool.attr prim.capsule endsegments 1024"),
        Cap("prim.sphere", "", " sides:5000", "tool.attr prim.sphere sides 1024"),
        Cap("prim.sphere", "tool.attr prim.sphere method qball", " order:100",
            "tool.attr prim.sphere order 32"),
        Cap("prim.sphere", "tool.attr prim.sphere method tess", " order:100",
            "tool.attr prim.sphere order 32"),
        Cap("prim.ellipsoid", "", " segments:5000", "tool.attr prim.ellipsoid segments 1024"),
        Cap("prim.torus", "", " minorSegments:5000", "tool.attr prim.torus minorSegments 1024"),
        Cap("prim.cube", "", " segmentsX:500", "tool.attr prim.cube segmentsX 64"),
        Cap("prim.cube", "", " segmentsY:100", "tool.attr prim.cube segmentsY 64"),
        Cap("prim.cube", "", " segmentsZ:100", "tool.attr prim.cube segmentsZ 64"),
        Cap("prim.cube", "tool.attr prim.cube radius 0.1", " segmentsR:100",
            "tool.attr prim.cube segmentsR 64"),
    ];
    string[] failed;
    foreach (c; caps) {
        const stored = built(c.tool, c.stored, c.setup);
        const atCap = built(c.tool, "", c.setup ~ "|" ~ c.atCap);
        if (stored != atCap)
            failed ~= format("%s%s built %s, the cap built %s", c.tool, c.stored, stored, atCap);
    }
    // The loop slice re-fit caps its stored count before it allocates.
    ok("scene.reset");
    ok("tool.set mesh.loopSliceTool on count:5000");
    const n = cmd("tool.attr mesh.loopSliceTool count ?")["value"].integer;
    ok("tool.set mesh.loopSliceTool off");
    if (n != 1024) failed ~= format("loop slice stored count:5000 reads %s, expected 1024", n);
    assert(caps.length == 12, "kernel cells: measured 12");
    assert(failed.length == 0, format("kernel caps failed in %d cells:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS kernel caps, 13 cells");
}

// The wire reads an exponent (`5e2` used to arrive as 5 and `1e30` as 1); the
// door then clamps where the row is bounded.
unittest {
    if (!cell("exponent")) return;
    struct W { string tool, attr, value; double expect; }
    static immutable W[] writes = [
        W("prim.cube", "radius", "5e2", 500), W("prim.cube", "radius", "1e30", 1e30),
        W("prim.cube", "radius", "-1e30", 0), W("prim.sphere", "sides", "5e2", 500),
        W("prim.sphere", "sides", "1e30", 1024),
    ];
    string[] failed;
    foreach (w; writes) {
        ok("scene.reset");
        ok("tool.set " ~ w.tool ~ " on");
        auto r = cmd("tool.attr " ~ w.tool ~ " " ~ w.attr ~ " " ~ w.value);
        const got = num(cmd("tool.attr " ~ w.tool ~ " " ~ w.attr ~ " ?")["value"]);
        if (r["status"].str != "ok" || abs(got - w.expect) > 1e-6 * fmax(1, abs(w.expect)))
            failed ~= format("%s %s %s: %s, reads %s, expected %s", w.tool, w.attr, w.value,
                             r.toString, got, w.expect);
        ok("tool.set " ~ w.tool ~ " off");
    }
    assert(writes.length == 5, "exponent writes: measured 5");
    assert(failed.length == 0, format("exponent writes failed in %d:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS exponent writes, 5");
}
