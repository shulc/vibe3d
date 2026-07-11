// Golden parity fixture for the interactive Array tool (task 0355,
// `mesh.arrayTool`, `source/tools/array_tool.d`), backed by the new 3-axis
// grid kernel `Mesh.arrayFacesGrid` (source/mesh.d). Frozen from the
// reference toolcard's captured parity case (vibe3d_private/toolcards/
// poly.array/findings.md §6) — NO reference engine runs at test time; see
// tests/fixtures/array.json for the full provenance note.
//
// This file also carries a handful of vibe3d-ONLY regression checks (not
// reference-parity claims) for the parts of the new grid kernel the
// captured toolcard case doesn't exercise: a genuine multi-axis grid,
// Replace Source, Invert Polygons, Merge Vertices, and undo — each is
// checked against vibe3d's own documented kernel semantics (source/mesh.d's
// `arrayFacesGrid` doc comment), not against a reference capture.

import fixture_helpers;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;

void main() {}

// ---------------------------------------------------------------------------
// T1 — reference-captured parity case (see tests/fixtures/array.json).
// ---------------------------------------------------------------------------

unittest {
    enum string json = import("fixtures/array.json");
    runFixture(json);
}

// ---------------------------------------------------------------------------
// Local HTTP helpers (same shapes as tests/test_mesh_array.d /
// tests/test_loop_slice_tool.d) for the vibe3d-only regression checks below.
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void cmd(string s) {
    auto resp = post("http://localhost:8080/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(cast(string) get("http://localhost:8080/api/model")); }
JSONValue postUndo()     { return parseJSON(post("http://localhost:8080/api/undo", "")); }

bool approxEq(double a, double b, double eps = 1e-5) { return abs(a - b) < eps; }

void selectAllFaces() { postSelect("polygons", [0, 1, 2, 3, 4, 5]); }

void armArrayTool() { cmd("tool.set mesh.arrayTool on"); }

// ---------------------------------------------------------------------------
// T2 — captured LIVE DEFAULTS smoke test: activating the tool and applying
// with ZERO attr writes reproduces the captured default grid (Count 2/1/2,
// Offset 1m/1m/1m) — 4 clone slots x 8v/6f, no welding (Merge Vertices
// default off): 32 verts, 24 faces.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    selectAllFaces();
    armArrayTool();
    cmd("tool.doApply");

    auto m = getModel();
    assert(m["vertexCount"].integer == 32,
        "verts: expected 32, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "faces: expected 24, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// T3 — genuine multi-axis grid (vibe3d-only regression, findings.md §6's own
// suggested follow-on: "numY=2, offY=2 ... a true 2-axis grid"). numX=2,
// numY=2, numZ=1, offX=2, offY=2 => 4 total slots, no shared verts (offsets
// exceed the cube's unit extent) => 4*8=32 verts, 4*6=24 faces. Confirms the
// grid multiplies independently per axis rather than just summing offsets.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    selectAllFaces();
    armArrayTool();
    cmd("tool.attr mesh.arrayTool numX 2");
    cmd("tool.attr mesh.arrayTool numY 2");
    cmd("tool.attr mesh.arrayTool numZ 1");
    cmd("tool.attr mesh.arrayTool offX 2");
    cmd("tool.attr mesh.arrayTool offY 2");
    cmd("tool.attr mesh.arrayTool offZ 0");
    cmd("tool.doApply");

    auto m = getModel();
    assert(m["vertexCount"].integer == 32,
        "verts: expected 32 (4 slots x 8v), got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 24,
        "faces: expected 24 (4 slots x 6f), got " ~ m["faceCount"].integer.to!string);

    // Every one of the 4 grid slots (0,0)/(1,0)/(0,1)/(1,1) is a full cube
    // (8 verts) translated to its own (x,y) slot span: slot 0 spans
    // [-0.5,0.5], slot 1 spans [1.5,2.5] on both X and Y (z untouched,
    // numZ=1). 16 verts have x>1 (the 2 hi-X slots x {lo,hi}-Y), 16 have
    // x<1; symmetrically for y.
    auto verts = m["vertices"].array;
    int seenXlo = 0, seenXhi = 0, seenYlo = 0, seenYhi = 0;
    foreach (v; verts) {
        double x = v.array[0].floating, y = v.array[1].floating;
        if (x < 1.0) ++seenXlo; else ++seenXhi;
        if (y < 1.0) ++seenYlo; else ++seenYhi;
    }
    assert(seenXlo == 16 && seenXhi == 16,
        "expected 16 verts at each X slot, got lo=" ~ seenXlo.to!string ~ " hi=" ~ seenXhi.to!string);
    assert(seenYlo == 16 && seenYhi == 16,
        "expected 16 verts at each Y slot, got lo=" ~ seenYlo.to!string ~ " hi=" ~ seenYhi.to!string);
}

// ---------------------------------------------------------------------------
// T4 — Between: Offset reinterpreted as the total FIRST-to-LAST span. numX=3,
// offX=4, between=true => step = 4/(3-1) = 2, byte-identical clone positions
// to the T1 golden case (numX=3, offX=2, between=false).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    selectAllFaces();
    armArrayTool();
    cmd("tool.attr mesh.arrayTool numX 3");
    cmd("tool.attr mesh.arrayTool numY 1");
    cmd("tool.attr mesh.arrayTool numZ 1");
    cmd("tool.attr mesh.arrayTool offX 4");
    cmd("tool.attr mesh.arrayTool between true");
    cmd("tool.doApply");

    auto m = getModel();
    assert(m["vertexCount"].integer == 24,
        "verts: expected 24, got " ~ m["vertexCount"].integer.to!string);
    // Each grid slot is a full cube: 4 of its 8 verts sit at its lo-X face,
    // 4 at its hi-X face. Slot 1's lo face (x=1.5) and slot 2's hi face
    // (x=4.5) exactly match the T1 golden's clone-1/clone-2 corners.
    auto verts = m["vertices"].array;
    int seen15 = 0, seen45 = 0;
    foreach (v; verts) {
        double x = v.array[0].floating;
        if (approxEq(x, 1.5)) ++seen15;
        if (approxEq(x, 4.5)) ++seen45;
    }
    assert(seen15 == 4 && seen45 == 4,
        "Between step should match the T1 golden's per-step offset=2 layout; got 1.5="
        ~ seen15.to!string ~ " 4.5=" ~ seen45.to!string);
}

// ---------------------------------------------------------------------------
// T5 — Replace Source: a 1x1x1 "array" (no new clones) with Replace Source
// on still mutates the original in place (kernel doc: "Jitter/Scale/Rotate
// also apply to what was the source") — vertex/face COUNT is unchanged (no
// new geometry), but Scale is visibly applied to the original.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    selectAllFaces();
    armArrayTool();
    cmd("tool.attr mesh.arrayTool numX 1");
    cmd("tool.attr mesh.arrayTool numY 1");
    cmd("tool.attr mesh.arrayTool numZ 1");
    cmd("tool.attr mesh.arrayTool replace true");
    cmd("tool.attr mesh.arrayTool sclX 200");
    cmd("tool.attr mesh.arrayTool sclY 200");
    cmd("tool.attr mesh.arrayTool sclZ 200");
    cmd("tool.doApply");

    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "verts: expected 8 (in-place, no new geometry), got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6);

    // 200% scale about the mask centroid (the origin, for a centered cube)
    // doubles every extent: +-0.5 -> +-1.0.
    auto verts = m["vertices"].array;
    int seen10 = 0;
    foreach (v; verts) {
        double x = v.array[0].floating;
        if (approxEq(abs(x), 1.0)) ++seen10;
    }
    assert(seen10 == 8,
        "expected all 8 verts scaled to |x|=1.0, got " ~ seen10.to!string);
}

// ---------------------------------------------------------------------------
// T6 — Merge Vertices: two cap-to-cap cubes (offset = extent) weld their
// shared face when Merge Vertices is on (default off leaves them separate) —
// same dedup law as mesh.array's `weld` (arrayFaces), now gated by an
// explicit boolean instead of always-on.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    selectAllFaces();
    armArrayTool();
    cmd("tool.attr mesh.arrayTool numX 2");
    cmd("tool.attr mesh.arrayTool numY 1");
    cmd("tool.attr mesh.arrayTool numZ 1");
    cmd("tool.attr mesh.arrayTool offX 1");
    cmd("tool.attr mesh.arrayTool merge true");
    cmd("tool.attr mesh.arrayTool dist 0.01");
    cmd("tool.doApply");

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12 (16 - 4 welded), got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 11,
        "faces: expected 11 (12 - 1 duplicate seam), got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// T7 — undo restores the original cage.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    selectAllFaces();
    armArrayTool();
    cmd("tool.attr mesh.arrayTool numX 3");
    cmd("tool.attr mesh.arrayTool numY 1");
    cmd("tool.attr mesh.arrayTool numZ 1");
    cmd("tool.attr mesh.arrayTool offX 2");
    cmd("tool.doApply");

    auto pre = getModel();
    assert(pre["vertexCount"].integer == 24);

    auto undoResp = postUndo();
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}
