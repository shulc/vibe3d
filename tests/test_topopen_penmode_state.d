// Topology Pen — `penMode` readback over `/api/tool/state`
// (doc/tasks/work/0482-topopen-move-nonvertex.md item 2).
//
// The gap this closes: the Mode dropdown could be WRITTEN over HTTP
// (`tool.attr mesh.topoPen mode <tag>`) but not READ BACK, so an automated run
// had no way to verify the setting actually took. A Fill-mode press that
// resolves no cell and a press that never left Draw mode look identical from
// outside — the first is a legitimate no-op, the second is a misconfigured
// run, and nothing distinguished them.
//
// Read-only observability: the field reports the param's WIRE TAG (the same
// token `tool.attr` accepts and `params()` publishes), never the raw enum
// ordinal, so a reordered enum cannot silently change the wire contract.
//
// Run via: ./run_test.d topopen_penmode_state

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum float R   = 2.0f;
enum int   LON = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d

unittest {
    setupSphereBg(R, LON, LAT);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));

    cmd("tool.set mesh.topoPen on");

    auto s0 = getJson("/api/tool/state");
    assert(s0["tool"].str == "mesh.topoPen", "unexpected active tool: " ~ s0.toString);
    assert("penMode" in s0,
        "/api/tool/state must publish penMode: " ~ s0.toString);
    assert(s0["penMode"].type == JSONType.string,
        "penMode must be the param's wire TAG (a string), not a raw ordinal: " ~ s0.toString);
    assert(s0["penMode"].str == "draw",
        "a freshly activated pen must report the default \"draw\" mode; got "
      ~ s0["penMode"].str);

    // Write the mode the way an automated run does, then read it back — the
    // whole point of the field.
    cmd("tool.attr mesh.topoPen mode fill");
    auto s1 = getJson("/api/tool/state");
    assert(s1["penMode"].str == "fill",
        "after `tool.attr mesh.topoPen mode fill` the state must report \"fill\"; got "
      ~ s1["penMode"].str);

    cmd("tool.attr mesh.topoPen mode draw");
    auto s2 = getJson("/api/tool/state");
    assert(s2["penMode"].str == "draw",
        "switching back to Draw must report \"draw\" again; got " ~ s2["penMode"].str);
}
