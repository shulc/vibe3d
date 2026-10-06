// The tool attribute door's bounds (task 9492; captured K-A3, findings_K-A3.md
// table b, the EXECUTED-write column): one out-of-range write per side through
// `tool.attr` reads back the captured bound, or the written value where the
// reference stores it as given ("free"). Ints are probed at -1000000 / 100000,
// floats at -1e30 / 1e30 (spelled out: the wire's argstring does not read an
// exponent). Rows are collected so one run names every divergence.
//
// `tool.set <id> on name:value` is a door too (cell `toolset`, one cell per
// family). A row with no max stores any count, so each kernel caps it itself:
// cell `kernel` builds once from a stored value past the kernel cap and once
// from the cap written through the door, and the two meshes must agree.
//
// Cell `toolset`: the arm's named arguments clamp from the same rows.
//
// Cell `edgeEnd`: a loop slice stored at an edge end (0 or 1, the reference's
// bound) reads back as written and builds the cut its nearest open-interval
// slice builds (0.001 / 0.999): an edge-end cut is degenerate in our kernel.
// The remembered list keeps the edge end across a drop.
//
// Cell `axis`: an axis attribute takes its number and clamps it to [0, 2]
// (K-A3 table b), read back as its tag.
//
// Run via: ./run_test.d test_tool_attr_bounds   (one block: VIBE3D_CELL=door|kernel|toolset|exponent|edgeEnd|axis)

import http_client : getJson, postRawAllowingErrorStatus;
import http_command_helpers : commandBody;
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
        Row("mesh.mirrorTool", "tool.attr mesh.mirrorTool merge true", "dist", false, "0.0", "free"),
        Row("mesh.radialArrayTool", "", "count", true, "1", "free"),
        Row("mesh.radialArrayTool", "tool.attr mesh.radialArrayTool merge true", "dist", false, "0.0", "free"),
        Row("mesh.loopSliceTool", "", "count", true, "1", "1024"),
        Row("mesh.loopSliceTool", "tool.attr mesh.loopSliceTool split true", "gap", false, "0.0", "free"),
        Row("mesh.loopSliceTool", "", "position", false, "0.0", "1.0"),
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
        Row("pen", "tool.attr pen wall inner", "offset", false, "0.0", "free"),
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
    assert(visited == 114, format("probes visited %d, expected 114", visited));
    assert(failed.length == 0, format("bounds diverge in %d probes:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS tool attribute bounds, 57 rows");
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
        Cap("prim.capsule", "", " endsegments:5000", "tool.attr prim.capsule endsegments 1024"),
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
    assert(caps.length == 7, "kernel cells: measured 7");
    assert(failed.length == 0, format("kernel caps failed in %d cells:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS kernel caps, 7 cells");
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

unittest {
    if (!cell("axis")) return;
    static immutable tools = ["prim.cube", "prim.sphere", "prim.ellipsoid", "prim.cone",
                              "prim.cylinder", "prim.capsule", "prim.torus"];
    static immutable string[2][] writes = [["-1000000", "x"], ["1", "y"], ["100000", "z"]];
    string[] failed;
    size_t visited;
    foreach (t; tools) {
        ok("scene.reset");
        ok("tool.set " ~ t ~ " on");
        foreach (w; writes) {
            ++visited;
            auto r = cmd("tool.attr " ~ t ~ " axis " ~ w[0]);
            auto q = cmd("tool.attr " ~ t ~ " axis ?");
            if (r["status"].str != "ok" || q["value"].str != w[1])
                failed ~= format("%s axis %s: %s, reads %s, expected %s", t, w[0],
                                 r.toString, q["value"].toString, w[1]);
        }
        ok("tool.set " ~ t ~ " off");
    }
    assert(visited == 21, format("axis writes visited %d, expected 21", visited));
    assert(failed.length == 0, format("axis writes failed in %d:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS axis writes, 7 tools");
}

/// The loop slice on cube edge 0 at `position`: its readback and the vertex list.
string[2] sliceAt(string position) {
    ok("scene.reset");
    auto r = parseJSON(postRawAllowingErrorStatus("/api/command",
        commandBody("mesh.select", `{"mode":"edges","indices":[0]}`)));
    assert(r["status"].str == "ok", r.toString);
    ok("tool.set mesh.loopSliceTool on");
    ok("tool.attr mesh.loopSliceTool position " ~ position);
    const read = cmd("tool.attr mesh.loopSliceTool position ?")["value"].toString;
    ok("tool.doApply");
    ok("tool.set mesh.loopSliceTool off");
    return [read, getJson("/api/model")["vertices"].toString];
}

unittest {
    if (!cell("edgeEnd")) return;
    string[] failed;
    foreach (end; [["0", "0.001"], ["1", "0.999"]]) {
        const atEnd = sliceAt(end[0]), inside = sliceAt(end[1]);
        if (num(parseJSON(atEnd[0])) != end[0].to!double)
            failed ~= format("position %s reads %s", end[0], atEnd[0]);
        if (atEnd[1] != inside[1])
            failed ~= format("position %s built %s, %s built %s", end[0], atEnd[1], end[1], inside[1]);
    }
    // The stored list is remembered across a drop and re-fitted at activation.
    ok("scene.reset");
    ok("tool.set mesh.loopSliceTool on");
    ok("tool.attr mesh.loopSliceTool position 0");
    ok("tool.set mesh.loopSliceTool off");
    ok("tool.set mesh.loopSliceTool on");
    const again = cmd("tool.attr mesh.loopSliceTool position ?")["value"];
    ok("tool.set mesh.loopSliceTool off");
    if (num(again) != 0) failed ~= format("position 0 re-activated reads %s", again);
    // The row is the panels' range too (the tool clamps the write itself).
    size_t ranged;
    foreach (q; getJson("/api/registry?params=1")["toolParams"]["mesh.loopSliceTool"].array)
        if (q["name"].str == "position" && "min" in q && "max" in q
            && num(q["min"]) == 0 && num(q["max"]) == 1) ++ranged;
    if (ranged != 1) failed ~= format("position's published range [0, 1] seen %d times", ranged);
    const mid = sliceAt("0.5");    // the rig cuts at all: the vertex list moves with the slice
    if (mid[1] == sliceAt("0.001")[1]) failed ~= "rig: 0.5 and 0.001 built the same mesh";
    assert(failed.length == 0, format("edge-end slices failed in %d:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS loop slice edge ends");
}

unittest {
    if (!cell("toolset")) return;
    struct W { string tool, named, attr, want; }
    static immutable W[] writes = [
        W("pen", " wall:inner offset:-1", "offset", "0.0"),
        W("prim.cube", " axis:5", "axis", `"z"`),
        W("prim.cone", " sides:5000", "sides", "1024"),
        W("prim.sphere", " order:100", "order", "32"),
        W("xfrm.smooth", " iter:0", "iter", "1"),
        W("xfrm.smooth", " iter:500", "iter", "500"),
        W("mesh.loopSliceTool", " count:5000", "count", "1024"),
    ];
    // `VIBE3D_TOOL=<id>` keeps one family's writes (a drill names the family).
    const only = environment.get("VIBE3D_TOOL", "");
    string[] failed;
    foreach (w; writes) {
        if (only.length && only != w.tool) continue;
        ok("scene.reset");
        auto r = cmd("tool.set " ~ w.tool ~ " on" ~ w.named);
        const got = r["status"].str != "ok" ? r.toString
            : cmd("tool.attr " ~ w.tool ~ " " ~ w.attr ~ " ?")["value"].toString;
        cmd("tool.set " ~ w.tool ~ " off");
        if (got != w.want)
            failed ~= format("tool.set %s on%s reads %s %s, expected %s", w.tool, w.named,
                             w.attr, got, w.want);
    }
    assert(writes.length == 7, "tool.set writes: measured 7");
    assert(failed.length == 0, format("tool.set writes failed in %d:\n  %-(%s\n  %)",
                                      failed.length, failed));
    writeln("PASS tool.set writes, 7");
}


unittest { // pipe writes clamp even a hidden config row; other stages stay free
    if (!cell("stage")) return;
    ok("scene.reset");
    ok("tool.pipe.attr constrain enabled false");
    ok("tool.pipe.attr constrain offset -0.1");
    ok("tool.pipe.attr constrain enabled true");
    assert(num(cmd("tool.pipe.attr constrain offset ?")["value"]) == 0,
           "hidden constraint offset did not clamp to 0");
    ok(q{tool.pipe.attr constrain offset "0.123456789"});
    const expectedOffset = "0.123456789".to!float;
    const precise = num(cmd("tool.pipe.attr constrain offset ?")["value"]);
    assert(abs(precise - expectedOffset) < 1e-14,
           format("an in-range offset lost precision at the stage door: %.17g expected %.17g",
                  precise, cast(double)expectedOffset));
    ok("tool.pipe.attr constrain offset 1000000");
    assert(num(cmd("tool.pipe.attr constrain offset ?")["value"]) == 1000000,
           "constraint offset acquired an upper bound");
    auto bad = cmd("tool.pipe.attr constrain offset nan");
    assert(bad["status"].str == "error"
        && num(cmd("tool.pipe.attr constrain offset ?")["value"]) == 1000000,
           "a refused offset write changed the live stage");
    ok("tool.pipe.attr symmetry enabled true");
    ok("tool.pipe.attr symmetry offset -0.2");
    assert(abs(num(cmd("tool.pipe.attr symmetry offset ?")["value"]) + 0.2) < 1e-6,
           "control: an unrelated stage offset acquired the constraint bound");
    writeln("PASS pipe stage bound and unbounded control");
}
