// Task 0612 Stage 6 — the non-participation audit, as assertions.
//
// A plane is a DRAWABLE that owns no geometry. Every consumer in this tree
// that walks `Document.layers` was written when "item" meant "mesh", and the
// project's own history is that a new drawable gets forgotten by exactly one
// of them. §6 of `doc/backdrop_item_plan.md` enumerates twelve such paths and
// argues that eleven are already safe because `hasMesh` is false — a
// compile-time fact, enforced by `static assert(!hasImagePlane || !hasMesh)`.
//
// THE WRONG IMPLEMENTATION EVERY TEST HERE DISCRIMINATES AGAINST is the
// obvious cheap one the plan names: give the plane a two-triangle `Mesh`
// payload so it can reuse the background draw path. Under it, T-N1 gains four
// snap sources and T-N2 exports a second object. It is reachable as a
// deliberate break in two edits (`Layer.hasMesh()` also true for
// `hasImagePlane`, plus a quad written into `meshRef()` at creation), which
// is how the red values in the task log were obtained.
//
// ONE ROW IS NOT NON-PARTICIPATION AND MUST NOT BE "FIXED": §6.5. The item
// snap frames gate on `hasXform`, not on `hasMesh`, so a plane IS admitted
// and contributes one pivot target. A test asserting "the snap target set is
// unchanged" would go red on correct code. T-N1b asserts the +1 pivot / 0
// corners shape instead.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.format : format;
import std.file   : readText, exists, remove, mkdirRecurse;
import std.path   : buildPath;
import std.algorithm : count, startsWith;
import std.string : splitLines, strip;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}
JSONValue cmdJson(string body_) {
    auto j = postJson("/api/command", body_);
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

JSONValue layers() { return getJson("/api/layers")["layers"]; }

JSONValue querySnap(double cx, double cy, double cz, int sx, int sy) {
    return postJson("/api/snap", format(
        `{"cursor":[%.6f,%.6f,%.6f],"sx":%d,"sy":%d,"excludeVerts":[]}`,
        cx, cy, cz, sx, sy));
}

int[2] viewportCenter() {
    auto cam = getJson("/api/camera");
    return [cast(int)(cam["vpX"].integer + cam["width"].integer  / 2),
            cast(int)(cam["vpY"].integer + cam["height"].integer / 2)];
}

bool approx(double a, double b, double eps = 5e-3) { return fabs(a - b) < eps; }

string wp(JSONValue sr) {
    auto a = sr["worldPos"].array;
    return format("(%.4f, %.4f, %.4f)", a[0].floating, a[1].floating, a[2].floating);
}

/// The plane stays at the ORIGIN and the CUBE is parked far out in +X.
///
/// That way round, not the other, because `snapCursor` ranks candidates by
/// SCREEN distance to the (sx, sy) it is handed — the world `cursor` argument
/// does not rank pivots at all. The default camera looks at the origin, so
/// the viewport centre pixel is the plane's pivot and every rival is far from
/// it. Parking the PLANE out there instead (the first shape of this fixture)
/// made the cube's pivot win at the centre and the test read (0, 0, 0)
/// whether the plane had a frame or not — inert in exactly the direction that
/// looks like a pass.
///
/// 7.0 is not a multiple of the cube's 0.5 extent, so no cube coordinate can
/// coincide with it.
enum double kCubeX = 7.0;

void twoItemSetup() {
    postJson("/api/command", commandBody("scene.reset", `{"primitive":"cube"}`));
    cmdJson(`{"id":"imagePlane.add","name":"Ref"}`);
    cmd("layer.attr 0 pos.x " ~ to!string(kCubeX));
    assert(layers().array.length == 2, "cube + plane");
    assert(layers().array[1]["type"].str == "imagePlane", "item 1 is the plane");
}

void snapConfig(string types, string mode) {
    cmd("snap.mode " ~ mode);
    cmd("tool.pipe.attr snap enabled true");
    cmd(`tool.pipe.attr snap types "` ~ types ~ `"`);
    cmd("tool.pipe.attr snap innerRange 999999");
    cmd("tool.pipe.attr snap outerRange 999999");
}

// ---------------------------------------------------------------------------
// T-N1b — §6.5. The plane IS an item snap frame: exactly one pivot target,
// and zero box corners.
//
// Wrong implementations:
//   * the "safe" over-guard — `ui/panels.d`'s item-frame loop also skipping
//     `hasImagePlane`. Reads: the pivot query lands on the CUBE's pivot out at
//     x=7 instead of the plane's at the origin.
//   * `buildItemFrame` seeding a bbox when the vertex loop never ran (the
//     "give it a bbox so it participates" fix). Reads: the box query lands on
//     the plane's degenerate box at the origin instead of on a cube AABB
//     corner out at 7±0.5.
// ---------------------------------------------------------------------------
unittest {
    twoItemSetup();
    snapConfig("pivot", "item");
    auto p = viewportCenter();

    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "a plane contributes a pivot target: " ~ sr.toString);
    assert(cast(int) sr["targetType"].integer == 128,
        "targetType 128 (Pivot); read " ~ to!string(sr["targetType"].integer));
    assert(approx(sr["worldPos"].array[0].floating, 0.0),
        "the target is the PLANE's pivot at the origin, not the cube's at x="
        ~ to!string(kCubeX) ~ " — read " ~ wp(sr));
    // `targetIndex` is the ITEM FRAME index, and frames are built in
    // `document.layers` order. Index 1 exists only if the plane got a frame
    // AFTER the cube's — i.e. the plane ADDED one rather than replacing one.
    assert(cast(int) sr["targetIndex"].integer == 1,
        "the plane is item frame 1, appended after the mesh's frame 0 — read "
        ~ to!string(sr["targetIndex"].integer));

    // Zero box corners. The cube HAS a bbox, so the query cannot assert "no
    // box snap at all"; it asserts that no box target sits where the PLANE is.
    // A cube AABB corner is 7±0.5 in x and ±0.5 in y/z.
    snapConfig("box", "item");
    auto sb = querySnap(0, 0, 0, p[0], p[1]);
    if (sb["snapped"].type == JSONType.true_) {
        auto b = sb["worldPos"].array;
        assert(approx(b[0].floating, kCubeX - 0.5)
               || approx(b[0].floating, kCubeX + 0.5),
            "a plane contributes NO box corners, so the only box targets are "
            ~ "the CUBE's — read " ~ wp(sb));
        foreach (i; 1 .. 3)
            assert(approx(b[i].floating, -0.5) || approx(b[i].floating, 0.5),
                "cube AABB corner coordinate — read " ~ wp(sb));
    }
}

// ---------------------------------------------------------------------------
// T-N1 — §6.4. Background snap SOURCES are the same set with and without a
// plane in the document.
//
// The source set is `background(lyr) && lyr.hasMesh`, so the plane has to be
// DESELECTED for the guard's first half to pass and the second half to be the
// one doing the work. Without the deselect this test would pass on a build
// with no `hasMesh` guard at all.
//
// Wrong implementation: the mesh-quad payload. Reads: the nearest vertex to
// the centre cursor is one of the plane's four quad corners at x≈0, instead of
// a cube vertex at x = 7±0.5.
// ---------------------------------------------------------------------------
unittest {
    twoItemSetup();
    // Deselect the plane so it is `visible && !selected` — a BACKGROUND layer,
    // which is the only state the source guard even looks at.
    cmdJson(`{"id":"layer.select","index":1,"mode":"remove"}`);
    auto ls = layers().array;
    assert(!ls[1]["selected"].boolean && ls[1]["background"].boolean,
        "the plane is a background layer, which is the precondition this "
        ~ "test's guard is about: " ~ ls[1].toString);

    snapConfig("vertex", "component");
    auto p = viewportCenter();
    // The viewport centre is where the PLANE is; the cube sits out at x=7.
    // Screen-distance ranking therefore favours anything the plane would
    // contribute, which is what makes "no target here" a real answer rather
    // than an artefact of the cube being closer.
    auto sr = querySnap(0, 0, 0, p[0], p[1]);
    assert(sr["snapped"].type == JSONType.true_,
        "the cube's vertices are still snappable: " ~ sr.toString);
    auto v = sr["worldPos"].array;
    assert(approx(v[0].floating, kCubeX - 0.5) || approx(v[0].floating, kCubeX + 0.5),
        "every vertex snap target belongs to the CUBE (x = 7±0.5) — a plane "
        ~ "contributes none, even sitting right under the cursor. Read " ~ wp(sr));
}

// ---------------------------------------------------------------------------
// T-N2 — §6.8. Interchange export walks `meshLayers()`; a plane is not one.
//
// Wrong implementation: the mesh-quad payload. Reads: two objects and twelve
// vertices instead of one and eight.
// ---------------------------------------------------------------------------
unittest {
    twoItemSetup();
    immutable dir = "/tmp/vibe3d_plane_export";
    mkdirRecurse(dir);
    immutable path = buildPath(dir, "cube_and_plane.obj");
    if (exists(path)) remove(path);
    cmdJson(`{"id":"file.save","path":` ~ JSONValue(path).toString() ~ `}`);
    assert(exists(path), "the export produced a file");

    size_t vs = 0, os = 0;
    foreach (line; readText(path).splitLines) {
        auto t = line.strip;
        if (t.startsWith("v "))  ++vs;
        if (t.startsWith("o ")) ++os;
    }
    assert(vs == 8, format("a cube's eight vertices and nothing else — read %d", vs));
    assert(os <= 1, format("one exported object, not one per document item — read %d", os));
    remove(path);
}

// ---------------------------------------------------------------------------
// T-N3 — §6.10. A plane channel edit publishes no mesh change.
//
// `mutationVersion` is the mesh's own edit counter and the key every
// version-keyed cache in the tree hangs off (snap grids, visibility, symmetry,
// the subpatch preview). A plane edit that bumped it would silently rebuild
// all of them on every brightness drag.
//
// Wrong implementation: dirtying the active mesh from `layer.attr` so the
// viewport repaints after a channel edit — the naive alternative to Stage 5's
// `DirtyKey` term, and a genuinely tempting one. Reads: the cube's
// mutationVersion increments once per channel edit.
// ---------------------------------------------------------------------------
unittest {
    twoItemSetup();
    immutable before = layers().array[0]["mutationVersion"].integer;

    cmd("layer.attr 1 brightness 0.5");
    cmd("layer.attr 1 transparency 0.25");
    cmd("layer.attr 1 projection right");
    cmd("layer.attr 1 pixelSize 0.02");

    immutable after = layers().array[0]["mutationVersion"].integer;
    assert(after == before,
        format("four plane channel edits left the mesh untouched — read "
             ~ "%d, was %d", after, before));

    // The edits really happened, or the assertion above would be vacuous: a
    // command that refused, or a channel that does not exist, also leaves
    // `mutationVersion` alone.
    auto r = postJson("/api/command", "layer.attr 1 projection ?");
    assert(r["status"].str == "ok" && r["value"].str == "right",
        "the channel writes landed: " ~ r.toString);
}
