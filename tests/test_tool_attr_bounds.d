// The tool attribute door's bounds (task 9492; captured K-A3, findings_K-A3.md
// table b, the EXECUTED-write column): one out-of-range write per side through
// `tool.attr` reads back the captured bound, or the written value where the
// reference stores it as given ("free"). Ints are probed at -1000000 / 100000,
// floats at -1e30 / 1e30 (spelled out: the wire's argstring does not read an
// exponent). Rows are collected so one run names every divergence.
//
// Run via: ./run_test.d test_tool_attr_bounds

import http_client : getJson, postRawAllowingErrorStatus;
import std.algorithm : splitter;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, fmax;
import std.stdio : writeln;

void main() {}

JSONValue cmd(string line) {
    return parseJSON(postRawAllowingErrorStatus("/api/command", line));
}

void ok(string line) {
    auto r = cmd(line);
    assert(r["status"].str == "ok", line ~ " -> " ~ r.toString);
}

double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}

unittest {
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
        Row("mesh.radialArrayTool", "", "weld", false, "0.0", "free"),
        Row("mesh.loopSliceTool", "", "count", true, "1", "1024"),
        Row("mesh.loopSliceTool", "tool.attr mesh.loopSliceTool split true", "gap", false, "0.0", "free"),
        Row("mesh.sliceTool", "", "gap", false, "0.0", "free"),
        Row("mesh.edgeSliceTool", "", "snap", false, "0.0", "1.0"),
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
