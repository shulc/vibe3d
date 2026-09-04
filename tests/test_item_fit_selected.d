// Task 1880 — `viewport.fit_selected` (Shift+A) and `viewport.fit` (A) frame
// ITEMS when the current selection type is Item.
//
// ---------------------------------------------------------------------------
// THE FIXTURE TRAP THIS FILE EXISTS TO AVOID
// ---------------------------------------------------------------------------
// Two cubes both sitting at the origin cannot tell "framed the union of the
// selected items" from "framed one item" from "framed the active layer's local
// mesh" — every candidate answers focus (0,0,0) and they are indistinguishable.
// That is the shape CLAUDE.md calls "the fixture cannot exhibit the
// phenomenon", and it is the reason every rig below OFFSETS one layer with a
// per-item transform (`layer.attr <n> pos.x`).
//
// The offset also separates a second pair the origin rig hides. Our per-item
// transform is NOT baked: it is a display matrix, so a layer's `Mesh.vertices`
// stay local. An implementation that gathers the right LAYERS but forgets
// `xform.composedMatrix()` answers the local centroid — which at the origin is
// the correct answer by accident, and at x=10 is off by exactly the offset.
//
// ---------------------------------------------------------------------------
// The numbers, and where they come from
// ---------------------------------------------------------------------------
// Two unit cubes (`/api/reset` gives one; `layer.add` + `prim.cube` gives the
// second), layer 0 pushed to x=10. So:
//
//   both selected      -> centre (5, 0, 0), and a distance that must clear the
//                         ~11-unit span, not the ~1-unit span of one cube
//   only layer 0       -> centre (10, 0, 0)      <- the offset one
//   only layer 1       -> centre (0, 0, 0)
//   nothing selected   -> centre (5, 0, 0)       <- "empty means everything"
//
// The centre is asserted EXACTLY (to 1e-3); the distance is asserted as a
// BAND, not a literal, because it is `computeFrame`'s output and depends on the
// cell aspect — freezing it would pin the viewport size instead of the law.
// What the band has to do is separate one cube from two, and 11 units versus 1
// leaves that gap wide.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION — run one at a time (druntime stops a module at its
// first failed assert, so two reasons cannot be read from one run).
// ---------------------------------------------------------------------------
//   * the item arm removed entirely (i.e. the state before this task)
//       -> F1 "with both items selected the camera must centre on their union
//          — focus.x is 0.0000, want 5.0000".
//   * the arm gathers layers but skips `xform.composedMatrix()` (local verts)
//       -> F1 first, "…focus is (0.0000, 0.0000, 0.0000), want (5.0000, …)" —
//          two LOCAL cubes centre at 0, not 5. With F1 disabled so the module
//          gets past it, F2 reddens on its own account: "framing the OFFSET
//          item alone must centre on it — focus is (0.0000, 0.0000, 0.0000),
//          want (10.0000, 0.0000, 0.0000)". Both were run; the isolation is
//          why, since druntime stops a module at its first failed assert.
//          F2 still earns its place — it is the row that separates
//          "forgot the matrix" from "framed the wrong layer", which F1 alone
//          reports with the same number for both.
//   * the arm keys on `editMode` instead of `currentType()`
//       -> F1 again: `EditMode` has no Item member, so the branch never runs
//          and the geometry arm answers the local cube.
//   * the arm frames EVERY layer rather than the selected ones
//       -> F2 "…focus.x is 5.0000, want 10.0000".
//   * the empty-selection case frames nothing instead of everything
//       -> F4 "with NOTHING selected the item fit must frame every visible
//          item — focus.x is 0.0000, want 5.0000" (the camera never moved).
//   * the item arm FALLS THROUGH to the geometry arms when it gathers no
//     vertices
//       -> F5 "an item selection that carries no geometry must leave the
//          camera alone".
//   * `viewport.fit` left on the active layer's local mesh
//       -> F6 "A must frame the whole SCENE — focus.x is 0.0000, want 5.0000".
//   * the item arm made unconditional (not gated on the selection type), so it
//     hijacks the geometry modes
//       -> F7 "in POLYGON mode the fit must stay on the active layer's own
//          geometry — focus.x is 5.0000, want 0.0000".

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.math   : abs;

void main() {}

alias BASE = testBaseUrl;

private JSONValue getJson(string p) { return parseJSON(cast(string) get(BASE ~ p)); }

private JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

private struct Cam { double fx, fy, fz, dist; }

private Cam cam() {
    auto c = getJson("/api/camera");
    return Cam(c["focus"]["x"].get!double, c["focus"]["y"].get!double,
               c["focus"]["z"].get!double, c["distance"].get!double);
}

/// Two unit cubes, layer 0 pushed to x = +10, current selection type Item,
/// nothing selected. The OFFSET is the whole discriminator — see the header.
private void rigTwoCubes() {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd("layer.add");
    cmd("prim.cube");
    cmd("layer.attr 0 pos.x 10.0");

    auto ls = getJson("/api/layers")["layers"].array;
    assert(ls.length == 2, format("rig: expected 2 layers, got %d", ls.length));
    assert(abs(ls[0]["xform"]["pos"].array[0].get!double - 10.0) < 1e-6,
        "rig premise: layer 0 must actually carry the x=10 item transform — "
        ~ "without it this whole file cannot distinguish its candidates");
    assert(ls[0]["vertexCount"].integer == 8 && ls[1]["vertexCount"].integer == 8,
        "rig: both layers are unit cubes");
    cmd("select.item");
}

/// Park the camera somewhere neutral, so a fit that does NOTHING is visible as
/// "the camera did not move" rather than hiding behind a coincidence.
private void parkCamera() {
    cmd("layer.select mode:clear");
    cmd("select.vertex");
    cmd("viewport.fit_selected");   // geometry arm: centres on the local cube
    cmd("select.item");
}

private void assertFocus(Cam c, double wantX, double wantY, double wantZ,
                         string what) {
    assert(abs(c.fx - wantX) < 1e-3 && abs(c.fy - wantY) < 1e-3
        && abs(c.fz - wantZ) < 1e-3,
        format("%s — focus is (%.4f, %.4f, %.4f), want (%.4f, %.4f, %.4f)",
               what, c.fx, c.fy, c.fz, wantX, wantY, wantZ));
}

// ===========================================================================

unittest {  // F1 — both items selected: the UNION, in world space
    rigTwoCubes();
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");
    cmd("viewport.fit_selected");
    auto c = cam();
    assertFocus(c, 5.0, 0.0, 0.0,
        "with both items selected the camera must centre on their union");
    assert(c.dist > 5.0,
        format("and stand back far enough for an ~11-unit span, not the ~1 "
               ~ "unit of a single cube — distance %.4f. A distance under 5 "
               ~ "means one cube was framed even though the centre came out "
               ~ "right", c.dist));
}

unittest {  // F2 — only the OFFSET item: the row that pins the item matrix
    rigTwoCubes();
    cmd("layer.select index:0 mode:set");
    cmd("viewport.fit_selected");
    auto c = cam();
    assertFocus(c, 10.0, 0.0, 0.0,
        "framing the OFFSET item alone must centre on it. The per-item "
        ~ "transform is a DISPLAY matrix, so its mesh vertices are still "
        ~ "local. This is the row that separates 'forgot the item matrix' "
        ~ "(answers 0) from 'framed the wrong layer' (answers 0 or 5) — F1 "
        ~ "reports the same number for both");
    assert(c.dist < 5.0,
        format("and one cube must be framed close, not the union — distance "
               ~ "%.4f", c.dist));
}

unittest {  // F3 — only the item at the origin
    rigTwoCubes();
    cmd("layer.select index:1 mode:set");
    cmd("viewport.fit_selected");
    assertFocus(cam(), 0.0, 0.0, 0.0,
        "framing the origin item alone must centre on the origin");
}

unittest {  // F4 — empty selection means EVERYTHING, not nothing
    rigTwoCubes();
    parkCamera();
    cmd("layer.select mode:clear");
    assert(getJson("/api/layers")["layers"].array
             .length == 2, "rig still has two layers");
    cmd("viewport.fit_selected");
    assertFocus(cam(), 5.0, 0.0, 0.0,
        "with NOTHING selected the item fit must frame every visible item — "
        ~ "the reference's standing rule that an empty selection means the "
        ~ "whole set is active");
}

unittest {  // F5 — an item with NO geometry must not fall through
    // THE FAILURE THIS EXCLUDES is a silent FALLTHROUGH. If the item arm
    // gathers no vertices and then drops into the geometry arms, the camera
    // reframes on a geometry selection the user cannot see while Items is
    // current — and it reframes it in the LATCHED mesh's local space, which is
    // a place nothing on screen is.
    //
    // The rig has to park the camera somewhere the fallthrough would MOVE it
    // from, or the check is vacuous: framed on the offset item (x=10), a
    // fallthrough answers the latched local cube (x=0) and the two numbers are
    // 10 apart. An image plane is the geometry-less item — `ItemKind.ImagePlane`
    // is a scene row (`isSceneItem`) but carries no mesh (`hasMesh` false), so
    // `meshOrNull` is null and the arm gathers nothing.
    rigTwoCubes();
    cmd("imagePlane.add");
    auto ls = getJson("/api/layers")["layers"].array;
    assert(ls.length == 3 && ls[2]["type"].str == "imagePlane",
        "rig premise: index 2 must be the geometry-less item");

    cmd("layer.select index:0 mode:set");
    cmd("viewport.fit_selected");
    auto parked = cam();
    assertFocus(parked, 10.0, 0.0, 0.0,
        "rig premise: the camera must first be parked on the OFFSET item, or "
        ~ "a fallthrough would land on the same number and be invisible");

    cmd("layer.select index:2 mode:set");   // only the image plane
    cmd("viewport.fit_selected");
    auto after = cam();
    assertFocus(after, 10.0, 0.0, 0.0,
        "an item selection that carries no geometry must leave the camera "
        ~ "ALONE. Falling through to the geometry arms reframes on the "
        ~ "latched mesh's LOCAL cube and answers 0");
    assert(abs(after.dist - parked.dist) < 1e-6,
        format("and not touch the distance either — %.4f became %.4f",
               parked.dist, after.dist));
}

unittest {  // F6 — `viewport.fit` (A) frames the SCENE, not the active layer
    rigTwoCubes();
    parkCamera();
    cmd("viewport.fit");
    auto c = cam();
    assertFocus(c, 5.0, 0.0, 0.0,
        "A must frame the whole SCENE. Framing only the active layer's local "
        ~ "mesh answers 0 and leaves the other item off screen");
    assert(c.dist > 5.0,
        format("and cover both cubes — distance %.4f", c.dist));
}

unittest {  // F7 — the geometry modes are UNTOUCHED
    rigTwoCubes();
    cmd("select.polygon");
    cmd("viewport.fit_selected");
    auto c = cam();
    assertFocus(c, 0.0, 0.0, 0.0,
        "in POLYGON mode the fit must stay on the ACTIVE layer's own geometry, "
        ~ "in ITS OWN local space — an item arm that is not gated on the "
        ~ "current selection type hijacks every geometry mode and answers 5");
    assert(c.dist < 5.0,
        format("and frame that one local cube — distance %.4f", c.dist));
}
