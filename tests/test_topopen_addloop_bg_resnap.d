// Topology Pen Add Loop over a background surface: every vertex the cut
// inserts lands on the CLOSEST POINT of the background, in the same step.
//
// Fixture tests/fixtures/topology_pen_addloop_bg_resnap.json, frozen from the
// reference's own post-gesture dump. The background is one quad displaced
// behind the foreground grid AND tilted, so three candidate answers are far
// apart for every inserted vertex:
//   * the chord point (no re-snap)            — 0.020 .. 0.042 off;
//   * the camera-ray hit on the background     — ~6e-3 of the camera distance off;
//   * the perpendicular foot (what is frozen)  — the expectation.
// An UNTILTED background cannot separate the last two, and a background that
// coincides with the foreground cannot separate any of them — which is why
// the Add Loop conformance fixture (its background is a coincident copy) says
// nothing about this law and stays green either way.
//
// The split-at-the-middle option is on, so the fraction is exactly 0.5 and
// the pointer cannot move the answer: the only free quantity is where each
// inserted vertex lands.
//
// Cells, in this order (a later one is only reached if every earlier passed):
//   1. the rig discriminates: each frozen position is >= 100 tolerances from
//      its own chord midpoint (fixture data only, no editor);
//   2. the cut adds exactly the frozen counts and moves no original vertex;
//   3. each inserted vertex, found TOPOLOGICALLY (the new vertex sharing a
//      face edge with both ends of its rail), matches its frozen position
//      within the fixture tolerance — population exactly 4;
//   4. the background layer is untouched;
//   5. the gesture is ONE history row, and one Ctrl+Z restores the pre-cut
//      mesh to the bit.
//
// Run via: ./run_test.d topopen_addloop_bg_resnap

import http_command_helpers : commandBody;
import topopen_place_helpers;
import slice_leak_helpers : slLineUi, slKey, SL_SDLK_z, SL_KMOD_LCTRL;
import fixture_helpers : requireProvenance;
import std.json;
import std.format : format;
import std.math   : sqrt;
import std.net.curl : get;

void main() {}

enum uint LSHIFT = 0x0001;   // Add Loop = Shift + middle-button drag

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        case JSONType.float_:   return v.floating;
        default: assert(0, "fixture: number expected");
    }
}

private double[3] triple(JSONValue v) {
    auto a = v.array;
    return [num(a[0]), num(a[1]), num(a[2])];
}

private double dist(double[3] a, double[3] b) {
    double s = 0;
    foreach (k; 0 .. 3) s += (a[k] - b[k]) * (a[k] - b[k]);
    return sqrt(s);
}

private string meshBody(JSONValue m) {
    JSONValue j = JSONValue.emptyObject;
    j["vertices"] = m["vertices"];
    j["faces"]    = m["faces"];
    return j.toString();
}

/// The primary layer at full float precision (`%.9g`), vertices + faces.
private JSONValue primaryPlanes() {
    return parseJSON(cast(string) get(baseUrl ~ "/api/mesh/planes"));
}

private double[3][] planeVerts(JSONValue p) {
    double[3][] r;
    foreach (v; p["vertices"].array) r ~= triple(v);
    return r;
}

/// True iff some face of `faces` has `a` and `b` as consecutive corners.
private bool shareFaceEdge(JSONValue faces, long a, long b) {
    foreach (f; faces.array) {
        auto c = f.array;
        foreach (i; 0 .. c.length) {
            long u = c[i].integer, w = c[(i + 1) % c.length].integer;
            if ((u == a && w == b) || (u == b && w == a)) return true;
        }
    }
    return false;
}

unittest {
    enum string json = import("fixtures/topology_pen_addloop_bg_resnap.json");
    auto fx = parseJSON(json);
    requireProvenance(fx, fx["name"].str);
    assert(fx["schema"].str == "topology_pen.addloop.bg_resnap/1", "unexpected fixture schema");
    immutable double tol = num(fx["tolerance"]);
    auto ex = fx["expected"];
    auto inserted = ex["inserted"].array;
    assert(inserted.length == 4, "the frozen cut inserts four vertices (an open span of three quads)");

    // ---- 1. the rig discriminates (fixture data alone) --------------------
    foreach (row; inserted) {
        immutable double sep = dist(triple(row["position"]), triple(row["chord_midpoint"]));
        assert(sep >= 100 * tol, format(
            "rig: rail %s's frozen position is only %.3g from its chord midpoint "
          ~ "(tolerance %.3g) — this background cannot tell a re-snap from none",
            row["rail"].toString, sep, tol));
    }

    // ---- stand: background layer 0, foreground layer 1 (primary) ----------
    postJson("/api/command", commandBody("scene.reset"));
    auto lb = postJson("/api/command", commandBody("scene.loadMesh", meshBody(fx["background"])));
    assert(lb["status"].str == "ok", "load background failed: " ~ lb.toString);
    cmd("layer.add name:Edit");
    auto lf = postJson("/api/command", commandBody("scene.loadMesh", meshBody(fx["foreground"])));
    assert(lf["status"].str == "ok", "load foreground failed: " ~ lf.toString);

    auto ct = ex["counts"];
    immutable size_t nv0 = cast(size_t) ct["vertices_before"].integer;
    auto prePlanes = primaryPlanes();
    auto pre = planeVerts(prePlanes);
    assert(pre.length == nv0 && prePlanes["faces"].array.length == ct["faces_before"].integer,
        format("stand: the foreground must build to %d/%d, got %d/%d", nv0,
               ct["faces_before"].integer, pre.length, prePlanes["faces"].array.length));
    auto bgBefore = readVerticesLayer(0);

    auto cam = fx["camera"];
    auto eye = triple(cam["eye"]), foc = triple(cam["focus"]);
    postJson("/api/camera", format(
        `{"eye":{"x":%.9g,"y":%.9g,"z":%.9g},"focus":{"x":%.9g,"y":%.9g,"z":%.9g}}`,
        eye[0], eye[1], eye[2], foc[0], foc[1], foc[2]));
    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    // Press on the seed edge's midpoint, drag along it to 70 % of the edge
    // (the fraction is forced, so the drag only has to land the press on it).
    auto seed = fx["input"]["seed_edge"].array;
    auto sa = pre[seed[0].integer], sb = pre[seed[1].integer];
    Vec3 mid = Vec3(cast(float)((sa[0] + sb[0]) * 0.5), cast(float)((sa[1] + sb[1]) * 0.5),
                    cast(float)((sa[2] + sb[2]) * 0.5));
    Vec3 nearB = Vec3(cast(float)(sa[0] * 0.3 + sb[0] * 0.7), cast(float)(sa[1] * 0.3 + sb[1] * 0.7),
                      cast(float)(sa[2] * 0.3 + sb[2] * 0.7));
    float mx, my, bx, by;
    assert(projectToWindow(mid, vp, mx, my), "stand: the seed edge must project on-screen");
    assert(projectToWindow(nearB, vp, bx, by), "stand: the seed edge must project on-screen");
    immutable double len = sqrt((bx - mx) * (bx - mx) + (by - my) * (by - my));
    assert(len >= 3, format("stand: the seed edge's drag span must be at least 3 px, got %.2f", len));
    int downX = cast(int) mx, downY = cast(int) my;
    int upX = cast(int) bx, upY = cast(int) by;

    slLineUi("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen middle " ~ (fx["input"]["middle"].boolean ? "true" : "false"));

    immutable size_t rowsBefore = historySurfaceCounts().editRows;

    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height, downX, downY, upX, upY, 8, LSHIFT, 2));
    assert("error" !in pr, "Add Loop drag failed: " ~ pr.toString);
    waitPlayerIdle();

    // ---- 2. counts; no original vertex moved -------------------------------
    auto postPlanes = primaryPlanes();
    auto post  = planeVerts(postPlanes);
    auto faces = postPlanes["faces"];
    assert(post.length == ct["vertices_after"].integer && faces.array.length == ct["faces_after"].integer,
        format("the cut must add exactly +%d vertices / +%d faces; got %d/%d",
               ct["vertices_after"].integer - nv0, ct["faces_after"].integer - ct["faces_before"].integer,
               post.length, faces.array.length));
    foreach (i; 0 .. nv0)
        assert(post[i] == pre[i], format("original vertex %d moved: %s -> %s", i, pre[i], post[i]));

    // ---- 3. every inserted vertex on its frozen closest point --------------
    size_t matched = 0;
    auto used = new bool[](post.length);
    foreach (row; inserted) {
        auto rail = row["rail"].array;
        immutable long a = rail[0].integer, b = rail[1].integer;
        long nv = -1;
        foreach (v; nv0 .. post.length)
            if (!used[v] && shareFaceEdge(faces, a, v) && shareFaceEdge(faces, b, v)) { nv = v; break; }
        assert(nv >= 0, format("no inserted vertex sits on rail (%d,%d)", a, b));
        used[nv] = true;
        immutable double[3] want = triple(row["position"]);
        immutable double off = dist(post[nv], want);
        assert(off <= tol, format(
            "inserted vertex %d on rail (%d,%d) is %.3g from its frozen closest point on the "
          ~ "background (tolerance %.3g; chord midpoint is %.3g away): got %s want %s",
            nv, a, b, off, tol, dist(post[nv], triple(row["chord_midpoint"])), post[nv], want));
        ++matched;
    }
    assert(matched == 4, format("population: 4 inserted vertices matched, got %d", matched));

    // ---- 4. the background is untouched ------------------------------------
    assert(readVerticesLayer(0) == bgBefore, "the background layer must not change");

    // ---- 5. one row; one Ctrl+Z restores the pre-cut mesh to the bit -------
    assert(historySurfaceCounts().editRows == rowsBefore + ex["undo_steps"].integer,
        format("the Add Loop gesture must be exactly one history row; edit rows %d -> %d",
               rowsBefore, historySurfaceCounts().editRows));
    slKey(SL_SDLK_z, SL_KMOD_LCTRL, "Ctrl+Z after the cut");
    auto undone = primaryPlanes();
    assert(planeVerts(undone) == pre && undone["faces"] == prePlanes["faces"],
        "one Ctrl+Z must restore the pre-cut mesh exactly");
    assert(historySurfaceCounts().editRows == rowsBefore,
        "the Ctrl+Z must pop exactly the cut's row");

    cmd("tool.attr mesh.topoPen middle false");   // sticky option: leave it off for the next test
}
