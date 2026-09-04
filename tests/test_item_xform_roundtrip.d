// Task 0614 Phase 7 — a GIZMO-authored item transform survives a `.v3d`
// save -> reopen, through the real File > Save / File > Open command path.
//
// The codec itself is pinned inside `source/io/native.d` (a bit-exact
// twelve-channel save->load unittest, plus the non-mesh-item and parent-link
// LOSSES); `tests/test_layer_xform_io.d` pins the hand-written-file
// load->save direction. Neither one drives the path a user actually walks:
// drag the gizmo, Ctrl+S, reopen. That is this file — and the reason it is
// worth a separate test is that the value under test here was produced by
// the drag machinery, not typed in, so it is an arbitrary float rather than
// a decimal literal a codec could round-trip by luck.
//
// The fixture is deliberately built so a WRONG serialiser reads a DIFFERENT
// number: every one of the twelve channels is off its identity, the twelve
// are pairwise distinct, `rot` carries no zero and no multiple of 90 (so a
// permuted euler triple is a different pose), `scl` is non-uniform with one
// negative (mirror) component, and the pivot is non-zero at a rotated,
// scaled pose (where it is load-bearing — at rot=0/scl=1 any pivot composes
// to the same matrix and the pivot assertions would be decoration). Those
// properties are ASSERTED below, not left to a comment: an identity or
// near-identity fixture would pass against a serialiser that dropped fields.
//
// The reset between save and load is load-bearing too: without it, "the
// values still match" is also what a completely no-op `file.load` produces.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.math  : fabs, fmod;
import std.conv  : to;
import std.format: format;
import std.file  : remove, exists;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void fileCmd(string id, string params) {
    auto body = `{"id":"` ~ id ~ `","params":` ~ params ~ `}`;
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", body));
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

// The `vertices` array's own JSON text — NOT the whole /api/model response,
// which carries a fresh `"timestamp"` on every call.
string verticesJson(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ format("/api/model?layer=%d", layer)));
    return j["vertices"].toString();
}

JSONValue layerXform(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    return j["layers"].array[layer]["xform"];
}

double n(const JSONValue v) {
    return v.type == JSONType.float_   ? v.floating
         : v.type == JSONType.integer  ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger
         : double.nan;
}

double[3] triple(const JSONValue x, string key) {
    auto a = x[key].array;
    return [n(a[0]), n(a[1]), n(a[2])];
}

// /api/layers prints every component with a fixed "%.6f", so the text — and
// therefore the parsed double — is a deterministic function of the stored
// float. Comparing EXACTLY is correct here, not optimistic: a tolerance would
// hide precisely the low-order loss a JSON codec is most likely to introduce.
void assertTripleExact(double[3] got, double[3] want, string what) {
    foreach (k; 0 .. 3)
        assert(got[k] == want[k],
            what ~ " component " ~ k.to!string ~ " did not survive the .v3d "
            ~ "round-trip: saved " ~ want[k].to!string ~ ", reopened as "
            ~ got[k].to!string);
}

// -----------------------------------------------------------------------
// 1. Drag the gizmo, save, reopen — every channel comes back, and the mesh
//    is still byte-identical (the drag never wrote vertices, and neither
//    did the round-trip).
// -----------------------------------------------------------------------

unittest {
    enum string outp = "/tmp/vibe3d-test-item-xform-roundtrip.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);

    resetCube();
    cmd("layer.select index:0");          // promotes SelType.Item to current

    auto sel = parseJSON(cast(string)get(BASE ~ "/api/selection"));
    assert(sel["selType"].str == "item", "layer.select must make item current");

    // --- a REAL gizmo Move drag authors `pos.x` --------------------------
    post(BASE ~ "/api/script", "tool.set move");
    {
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int gx, gy; double ux, uy;
        axisGrabPx(Vec3(0, 0, 0), vp, gx, gy, ux, uy);   // world pivot == origin
        auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                gx, gy,
                                gx + cast(int)(70.0 * ux), gy + cast(int)(70.0 * uy));
        playAndWait(log);
    }
    post(BASE ~ "/api/script", "tool.set move off");

    immutable double draggedPosX = triple(layerXform(0), "pos")[0];
    assert(draggedPosX != 0.0,
        "sanity: the Move gizmo drag must actually have written pos.x");

    // --- a REAL gizmo Scale drag authors `scl.x` -------------------------
    post(BASE ~ "/api/script", "tool.set scale");
    {
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int gx, gy; double ux, uy;
        // World pivot is pos + pivot; pivot is still 0 at this point.
        axisGrabPx(Vec3(cast(float) draggedPosX, 0, 0), vp, gx, gy, ux, uy);
        auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                gx, gy,
                                gx + cast(int)(50.0 * ux), gy + cast(int)(50.0 * uy));
        playAndWait(log);
    }
    post(BASE ~ "/api/script", "tool.set scale off");

    immutable double draggedSclX = triple(layerXform(0), "scl")[0];
    assert(draggedSclX != 1.0,
        "sanity: the Scale gizmo drag must actually have written scl.x");

    // --- the remaining channels from the numeric panel -------------------
    // (`rot` and `pivot` have no single-drag authoring that lands on a value
    // worth pinning; the point of the fixture is that all twelve are off
    // identity and mutually distinct, not that all twelve came from a drag.)
    cmd("layer.attr 0 pos.y 0.6");
    cmd("layer.attr 0 pos.z -1.4");
    cmd("layer.attr 0 rot.x 13.0");
    cmd("layer.attr 0 rot.y -47.0");
    cmd("layer.attr 0 rot.z 61.0");
    cmd("layer.attr 0 scl.y 0.4");
    cmd("layer.attr 0 scl.z -1.75");
    cmd("layer.attr 0 pivot.x 0.35");
    cmd("layer.attr 0 pivot.y -0.8");
    cmd("layer.attr 0 pivot.z 1.15");

    auto before = layerXform(0);
    double[3] posB   = triple(before, "pos");
    double[3] rotB   = triple(before, "rot");
    double[3] sclB   = triple(before, "scl");
    double[3] pivotB = triple(before, "pivot");
    double[16] matB;
    foreach (i; 0 .. 16) matB[i] = n(before["matrix"].array[i]);
    string vertsB = verticesJson(0);

    // --- the fixture must be able to fail -------------------------------
    {
        double[12] c = [posB[0], posB[1], posB[2], rotB[0], rotB[1], rotB[2],
                        sclB[0], sclB[1], sclB[2], pivotB[0], pivotB[1], pivotB[2]];
        double[12] identity = [0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0];
        foreach (i; 0 .. 12)
            assert(c[i] != identity[i],
                "fixture: channel " ~ i.to!string ~ " sits at its identity — a "
                ~ "serialiser that DROPPED it would still pass");
        foreach (i; 0 .. 12)
            foreach (j; i + 1 .. 12)
                assert(fabs(c[i]) != fabs(c[j]),
                    "fixture: channels " ~ i.to!string ~ "/" ~ j.to!string
                    ~ " share a magnitude — a serialiser that SWAPPED them "
                    ~ "would still pass");
        foreach (v; rotB)
            assert(fmod(fabs(v), 90.0) != 0.0,
                "fixture: a multiple of 90 degrees makes the euler ORDER "
                ~ "unobservable, so a permuted triple would still pass");
        assert(sclB[0] != sclB[1] && sclB[1] != sclB[2],
            "fixture: a uniform scale cannot tell a per-axis codec from a "
            ~ "single-factor one");
        assert(sclB[2] < 0.0,
            "fixture: one scale component must be negative — a codec that "
            ~ "persisted a MAGNITUDE would still pass without it");
    }

    // --- save, wipe, reopen ---------------------------------------------
    fileCmd("file.save", `{"path":"` ~ outp ~ `"}`);

    resetCube();
    {
        // The wipe is what makes the comparison mean anything: without it, a
        // `file.load` that did nothing at all would also "preserve" the values.
        auto blank = layerXform(0);
        assertTripleExact(triple(blank, "pos"),   [0.0, 0.0, 0.0], "post-reset pos");
        assertTripleExact(triple(blank, "rot"),   [0.0, 0.0, 0.0], "post-reset rot");
        assertTripleExact(triple(blank, "scl"),   [1.0, 1.0, 1.0], "post-reset scl");
        assertTripleExact(triple(blank, "pivot"), [0.0, 0.0, 0.0], "post-reset pivot");
    }

    fileCmd("file.load", `{"path":"` ~ outp ~ `"}`);

    // --- every channel, and the composed matrix, and the geometry --------
    auto after = layerXform(0);
    assertTripleExact(triple(after, "pos"),   posB,   "pos");
    assertTripleExact(triple(after, "rot"),   rotB,   "rot");
    assertTripleExact(triple(after, "scl"),   sclB,   "scl");
    assertTripleExact(triple(after, "pivot"), pivotB, "pivot");
    foreach (i; 0 .. 16)
        assert(n(after["matrix"].array[i]) == matB[i],
            "composed world matrix entry " ~ i.to!string ~ " changed across "
            ~ "the .v3d round-trip: saved " ~ matB[i].to!string
            ~ ", reopened as " ~ n(after["matrix"].array[i]).to!string);

    assert(verticesJson(0) == vertsB,
        "the item transform is NOT baked into the mesh: local vertex "
        ~ "coordinates must come back byte-identical after save + reopen");
}
