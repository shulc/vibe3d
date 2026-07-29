// Topology Pen — `penMode` / `edgeLoop` / `edgeSlide` readback over
// `/api/tool/state` (doc/tasks/done/0482-topopen-move-nonvertex.md item 2,
// extended by task 0483).
//
// The gap this closes: the Mode dropdown could be WRITTEN over HTTP
// (`tool.attr mesh.topoPen mode <tag>`) but not READ BACK, so an automated run
// had no way to verify the setting actually took. A Fill-mode press that
// resolves no cell and a press that never left the previous mode look
// identical from outside — the first is a legitimate no-op, the second is a
// misconfigured run, and nothing distinguished them.
//
// Read-only observability: the field reports the param's WIRE TAG (the same
// token `tool.attr` accepts and `params()` publishes), never the raw enum
// ordinal, so a reordered enum cannot silently change the wire contract.
//
// Task 0483 grew the dropdown from 2 vibe3d-only values to the reference's own
// EIGHT, so this test walks all eight tags: every one must be accepted by
// `tool.attr` and reported back verbatim. It writes the starting mode instead
// of assuming it — the mode is sticky and the runner shares one app across a
// worker's whole slice of tests, so "whatever the previous test left" is not a
// baseline this test may lean on.
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
    cmd("tool.attr mesh.topoPen mode move");

    auto s0 = getJson("/api/tool/state");
    assert(s0["tool"].str == "mesh.topoPen", "unexpected active tool: " ~ s0.toString);
    assert("penMode" in s0,
        "/api/tool/state must publish penMode: " ~ s0.toString);
    assert(s0["penMode"].type == JSONType.string,
        "penMode must be the param's wire TAG (a string), not a raw ordinal: " ~ s0.toString);
    assert(s0["penMode"].str == "move",
        "the pen must report the mode just written; got " ~ s0["penMode"].str);

    // Every one of the reference's eight modes round-trips through the write
    // path an automated run uses — the whole point of the field.
    static immutable string[8] tags =
        ["move", "duplicate", "remove", "split", "addLoop", "point", "fill", "smooth"];
    foreach (tag; tags) {
        cmd("tool.attr mesh.topoPen mode " ~ tag);
        auto st = getJson("/api/tool/state");
        assert(st["penMode"].str == tag,
            "after `tool.attr mesh.topoPen mode " ~ tag ~ "` the state must report \"" ~ tag
          ~ "\"; got " ~ st["penMode"].str);
    }

    // The two dropdown-adjacent flags (task 0483) are writable and readable
    // the same way, and default OFF.
    cmd("tool.attr mesh.topoPen mode move");
    cmd("tool.attr mesh.topoPen loop false");
    cmd("tool.attr mesh.topoPen slide false");
    auto sf0 = getJson("/api/tool/state");
    assert(sf0["edgeLoop"].type  == JSONType.false_, "edgeLoop must read back false");
    assert(sf0["edgeSlide"].type == JSONType.false_, "edgeSlide must read back false");
    assert(sf0["lmbAction"].str == "place_or_move",
        "with no press yet, the recorded LMB action must be the neutral one; got "
      ~ sf0["lmbAction"].str);

    cmd("tool.attr mesh.topoPen loop true");
    cmd("tool.attr mesh.topoPen slide true");
    auto sf1 = getJson("/api/tool/state");
    assert(sf1["edgeLoop"].type  == JSONType.true_, "edgeLoop must read back true");
    assert(sf1["edgeSlide"].type == JSONType.true_, "edgeSlide must read back true");

    // Leave the tool the way a freshly activated one looks — the mode and both
    // flags are sticky, and the next test on this worker inherits them.
    cmd("tool.attr mesh.topoPen loop false");
    cmd("tool.attr mesh.topoPen slide false");
    cmd("tool.attr mesh.topoPen mode move");
}
