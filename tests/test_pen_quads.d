// Polygon pen, Make Quads (wave plan S7) against the captured cells of
// tests/fixtures/pen_quads.json. The strip law: the first two clicks seed the
// leading edge (L0, L1) = (c1, c0); every later click c adds c and its
// automatic corner a = L1 + (c - L0) right after it, the quad is [L1, a, c, L0]
// under flip 1 and that ring reversed keeping its first index under flip 0 (the
// flag read when the strip is built, so a flip written later turns every quad),
// then (L0, L1) <- (c, a). A click on an automatic corner selects it. One
// in-stroke undo removes a click together with its corner. From 3 points Make
// Quads is locked: a write is refused (status error, no history row) and the
// value stays. Under symmetry each quad is mirrored as a polygon; a corner on
// the image of a stroke point shares it crosswise (merge).
//
// Rig: top ortho, focus on y = 1, 360 px/m (the captured 440 cannot fit the
// 1.4 m strips in our viewport; 360 keeps the 0.005 m placement quantum, so
// every clicked fixture position is a lattice value and positions compare to
// 1e-4). Counts and rings are exact. Typed fields go through the interactive
// door (the panel's source); Ctrl+Z through /api/play-events. `VIBE3D_CELL=<id>`
// runs one cell alone (the population floor holds for the full run only).
//
// Ours-only cells: `B5_sym_merge_off` (no shared corner with merge off — the
// weld is merge's, as in the polygon pen's captured B4m), and two refusals
// (the reference's script door is not observable — a script call ends its
// stroke): `refuse-script-3-points` (the script door refuses the locked
// write: status error, history depth unchanged, the value read back false)
// and `refuse-idle-posX` (an Idle write to a disabled point field is refused
// the same way). Both follow from the captured lock and the command no-op
// contract (refusal or a real edit; a real edit would break the lock).

import drag_helpers : Vec3, fetchCamera, kPaceLine, playAndWait;
import http_client : frameFence, getJson, postJson;
import pen_rig_helpers;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.process : environment;

void main() {}

private enum double kTol = 1e-4;
private enum double kPpm = 360;
private enum int kSymZ = 122, kModCtrl = 64;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private Vec3 p(double x, double z, double y = 1) {
    return Vec3(cast(float)x, cast(float)y, cast(float)z);
}
private Vec3[] verts(JSONValue a) {
    Vec3[] r;
    foreach (v; a.array)
        r ~= Vec3(cast(float)num(v[0]), cast(float)num(v[1]), cast(float)num(v[2]));
    return r;
}
private long[][] rings(JSONValue a) {
    long[][] r;
    foreach (f; a.array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        r ~= ring;
    }
    return r;
}

// ---- rig ------------------------------------------------------------------

/// Empty top view, focus `focus` at 360 px/m, snapping off, symmetry X (or
/// off), the pen armed with Make Quads `quads`.
private void rig(Vec3 focus, bool quads = true, bool symX = false) {
    penSceneEmpty("Top");
    penCameraAt(focus, kPpm);
    penCommand("tool.pipe.attr snap enabled false");
    penCommand("tool.pipe.attr symmetry enabled " ~ (symX ? "true" : "false"));
    penCommand("tool.pipe.attr symmetry axis x");
    penCommand("tool.pipe.attr symmetry offset 0");
    penCommand("tool.pipe.attr symmetry useWorkplane false");
    penCommand("tool.set pen on");
    penCommand("tool.attr pen makeQuads " ~ (quads ? "true" : "false"));
}
private void drop() { penCommand("tool.set pen off"); }
private void ctrlZ() {
    auto cam = fetchCamera();
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, kSymZ, kModCtrl, kSymZ, kModCtrl));
}
/// A panel write (the interactive door); returns the reply.
private JSONValue panel(string name, string value) {
    return postJson("/api/script?interactive=true", "tool.attr pen " ~ name ~ " " ~ value);
}
private double attr(string name) {
    auto r = postJson("/api/command", "tool.attr pen " ~ name ~ " ?");
    assert(r["status"].str == "ok", "attr query " ~ name ~ " failed: " ~ r.toString);
    auto v = r["value"];
    return v.type == JSONType.true_ ? 1 : v.type == JSONType.false_ ? 0 : num(v);
}
private size_t depth() { return getJson("/api/history")["undo"].array.length; }

/// The fixture cell's click list, parsed from its `click (x,z) (x,z) …` lines.
private Vec3[] scriptClicks(JSONValue cell, size_t line) {
    import std.regex : matchAll, regex;
    Vec3[] r;
    foreach (m; matchAll(cell["script"][line].str, regex(`\((-?[0-9.]+),(-?[0-9.]+)\)`))) {
        import std.conv : to;
        r ~= p(m[1].to!double, m[2].to!double);
    }
    return r;
}

// ---- reads ----------------------------------------------------------------

/// The mesh against the cell's `expected` (counts and rings exactly, positions
/// to 1e-4); null when it matches.
private string[] compare(string cell, JSONValue exp) {
    auto j = getJson("/api/model");
    auto got = verts(j["vertices"]);
    auto gotF = rings(j["faces"]);
    auto want = verts(exp["vertices"]);
    auto wantF = rings(exp["polygons"]);
    if (got.length != want.length || gotF != wantF)
        return [format("%s: %s vertices, faces %s; expected %s, faces %s", cell,
                       got.length, gotF, want.length, wantF)];
    string[] bad;
    foreach (i, w; want) {
        const g = got[i];
        if (!(abs(g.x - w.x) <= kTol && abs(g.y - w.y) <= kTol && abs(g.z - w.z) <= kTol))
            bad ~= format("v%s (%.6f, %.6f, %.6f) vs (%.6f, %.6f, %.6f)", i,
                          g.x, g.y, g.z, w.x, w.y, w.z);
    }
    return bad.length ? [format("%s: %-(%s; %)", cell, bad)] : null;
}
private string[] expect(string cell, string what, double got, double want) {
    return got == want ? null : [format("%s: %s %s, expected %s", cell, what, got, want)];
}

unittest {
    auto c = parseJSON(import("fixtures/pen_quads.json"))["cells"];
    const only = environment.get("VIBE3D_CELL", "");
    bool want(string cell) { return only.length == 0 || only == cell; }
    string[] fails;
    int ran;
    auto strip7 = scriptClicks(c["strip_7_clicks"], 1);
    auto strip7ccw = scriptClicks(c["strip_7_clicks_ccw"], 1)[0 .. 7];
    assert(strip7.length == 7 && strip7ccw.length == 7, "fixture premise: 7 clicks");

    // ===== must stay green ==================================================
    // lock_0_points / lock_2_points: below 3 points the panel turns Make
    // Quads on (written false first: the cells start with it off).
    foreach (n, cell; ["lock_0_points", "lock_2_points"]) {
        if (!want(cell)) continue;
        rig(p(-0.15, 0), false);
        if (n) clickWorld(strip7[0 .. 2 * n]);
        auto r = panel("makeQuads", "true");
        fails ~= expect(cell, "status ok", r["status"].str == "ok", 1);
        fails ~= expect(cell, "quads_after", attr("makeQuads"),
                        num(c[cell]["expected"]["quads_after"]));
        drop(); ++ran;
    }

    // ===== must turn ========================================================
    // strip_7_clicks: 12 vertices, 5 quads, flip decided 1.
    if (want("strip_7_clicks")) {
        rig(p(-0.15, 0));
        clickWorld(strip7);
        fails ~= expect("strip_7_clicks", "flip", attr("flip"), 1);
        drop(); ++ran;
        fails ~= compare("strip_7_clicks", c["strip_7_clicks"]["expected"]);
    }

    // strip_7_clicks_ccw: mirrored in x, flip decided 0: every ring reversed.
    if (want("strip_7_clicks_ccw")) {
        rig(p(0.15, 0));
        clickWorld(strip7ccw);
        fails ~= expect("strip_7_clicks_ccw", "flip", attr("flip"),
                        num(c["strip_7_clicks_ccw"]["flip_after"]));
        drop(); ++ran;
        fails ~= compare("strip_7_clicks_ccw", c["strip_7_clicks_ccw"]["expected"]);
    }

    // strip_7_clicks_flip_written_off: flip written 0 after quad 0 exists.
    if (want("strip_7_clicks_flip_written_off")) {
        rig(p(-0.15, 0));
        clickWorld(strip7[0 .. 3]);
        auto fw = panel("flip", "false");
        assert(fw["status"].str == "ok", "flip write failed: " ~ fw.toString);
        clickWorld(strip7[3 .. $]);
        drop(); ++ran;
        fails ~= compare("strip_7_clicks_flip_written_off",
                         c["strip_7_clicks_flip_written_off"]["expected"]);
    }

    // strip_plane_anchor: the 4th click lands on the automatic corner and
    // selects it; typed height 0.5; the next clicks land on the plane through
    // the current point.
    if (want("strip_plane_anchor")) {
        auto e = c["strip_plane_anchor"]["expected"]["vertices"].array;
        rig(p(0, 0.15));
        clickWorld(scriptClicks(c["strip_plane_anchor"], 1));
        clickWorld(p(0.25, 0.05));
        fails ~= expect("strip_plane_anchor", "current after the corner click",
                        attr("currentPoint"), 3);
        penAttr("posY", 0.5);
        clickWorld(p(0.25, 0.55, 0.5));
        clickWorld(p(-0.25, 0.75, 0.5));
        drop(); ++ran;
        assert(e.length == 8, "fixture premise: 8 vertices");
        fails ~= compare("strip_plane_anchor", c["strip_plane_anchor"]["expected"]);
    }

    // strip_undo_last_click / strip_undo_then_click (QU-pair).
    if (want("strip_undo_last_click")) {
        rig(p(-0.15, 0));
        clickWorld(strip7[0 .. 4]);
        fails ~= expect("strip_undo_last_click", "current before the undo",
            attr("currentPoint"), num(c["strip_undo_last_click"]["current_before_undo"]));
        ctrlZ();
        fails ~= expect("strip_undo_last_click", "current after the undo",
            attr("currentPoint"), num(c["strip_undo_last_click"]["current_after_undo"]));
        drop(); ++ran;
        fails ~= compare("strip_undo_last_click", c["strip_undo_last_click"]["expected"]);
    }
    if (want("strip_undo_then_click")) {
        rig(p(-0.15, 0));
        clickWorld(strip7[0 .. 4]);
        ctrlZ();
        clickWorld(strip7[4]);
        drop(); ++ran;
        fails ~= compare("strip_undo_then_click", c["strip_undo_then_click"]["expected"]);
    }

    // B5_nosym / B5_sym: the 4th click selects the automatic corner; under
    // symmetry X the corner on the 5th click's image shares it crosswise.
    auto b5 = [p(0.25, -0.25), p(0.75, -0.25), p(0.75, 0.25), p(0.25, 0.25), p(0.25, 0.75)];
    foreach (sym; [false, true]) {
        const cell = sym ? "B5_sym" : "B5_nosym";
        if (!want(cell)) continue;
        rig(p(0, 0.25), true, sym);
        clickWorld(b5);
        if (!sym) {
            fails ~= expect(cell, "current", attr("currentPoint"),
                            num(c[cell]["current_after"]));
            fails ~= expect(cell, "flip", attr("flip"), num(c[cell]["flip_after"]));
        }
        drop(); ++ran;
        fails ~= compare(cell, c[cell]["expected"]);
    }

    // B5_sym with merge off (ours; the weld is merge's, as in the polygon
    // pen's B4m): no shared corner, 12 vertices, the mirror rings unwelded.
    if (want("B5_sym_merge_off")) {
        rig(p(0, 0.25), true, true);
        penCommand("tool.attr pen merge false");
        clickWorld(b5);
        drop(); ++ran;
        auto m = getJson("/api/model");
        const nv = m["vertices"].array.length;
        auto f = rings(m["faces"]);
        if (nv != 12 || f != [[0L, 3, 2, 1], [3L, 5, 4, 2], [6L, 7, 8, 9], [9L, 8, 10, 11]])
            fails ~= format("B5_sym_merge_off: %s vertices, faces %s; expected 12, "
                ~ "faces [[0, 3, 2, 1], [3, 5, 4, 2], [6, 7, 8, 9], [9, 8, 10, 11]]", nv, f);
        rig(p(0, 0), false);
        penCommand("tool.attr pen merge true");
        drop();
    }

    // lock_3_points: from 3 points the panel's write is refused, the value stays.
    if (want("lock_3_points")) {
        rig(p(-0.15, 0), false);
        clickWorld(strip7[0 .. 3]);
        auto r = panel("makeQuads", "true");
        fails ~= expect("lock_3_points", "status error", r["status"].str == "error", 1);
        fails ~= expect("lock_3_points", "quads_after", attr("makeQuads"),
                        num(c["lock_3_points"]["expected"]["quads_after"]));
        drop(); ++ran;
    }

    // refuse-script-3-points: the script door refuses the locked write — the
    // command no-op contract's refusal arm.
    if (want("refuse-script-3-points")) {
        rig(p(-0.15, 0), false);
        clickWorld(strip7[0 .. 3]);
        const before = depth();
        auto r = postJson("/api/command", "tool.attr pen makeQuads true");
        fails ~= expect("refuse-script-3-points", "status error",
                        r["status"].str == "error", 1);
        fails ~= expect("refuse-script-3-points", "history depth", depth(), before);
        fails ~= expect("refuse-script-3-points", "makeQuads read back",
                        attr("makeQuads"), 0);
        drop(); ++ran;
    }

    // refuse-idle-posX: no stroke, the point fields are disabled: refused.
    if (want("refuse-idle-posX")) {
        rig(p(0, 0), false);
        const before = depth();
        auto r = postJson("/api/command", "tool.attr pen posX 1");
        fails ~= expect("refuse-idle-posX", "status error", r["status"].str == "error", 1);
        fails ~= expect("refuse-idle-posX", "history depth", depth(), before);
        drop(); ++ran;
    }

    rig(p(0, 0), false);    // leave the remembered value as found
    drop();
    assert(ran == (only.length ? 1 : 14), format("ran %s cells, pinned 14 (1 under %s)",
                                                 ran, only));
    assert(fails.length == 0, format("%s failure(s): %-(%s | %)", fails.length, fails));
}
