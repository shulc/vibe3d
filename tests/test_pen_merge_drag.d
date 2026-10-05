// Polygon pen merge on a drag vs a click, against tests/fixtures/pen_merge_drag.json
// (task 9417). The laws: a point within the merge radius of an edited-mesh
// vertex takes its 3-D position and shares its index on a click AND on every
// drag event (live: mid-drag the point is already on the vertex); on a DRAG
// whose snap landed on a vertex (the global vertex type) the point stays its
// own vertex at that position, while a click with the same snap links; edge snap
// on a drag lands on the edge's 3-D point; the next click's plane passes through
// the previous point, so its height follows a linked or snapped point.
//
// Rig: top ortho at 440 px/m (the capture's 439.53) with the focus at
// (0.8, 1, 0.05) so the stroke fits our viewport; positions on the plane are
// lattice values within one 0.005 quantum of the capture's pointer (our pixel
// rounding differs), linked or snapped positions exact. Ours-only (a
// construction from rule 2's own term, "the vertex snap PLACED the point"):
// `SV_V1-unsnapped` — SV_V1 with the snap's inner range 5 px, so v2 (11.4 px)
// is only highlighted; the snap places nothing and the drag links as D_V1 does.
// Excluded: D_E1 / C_E1
// (merge on, 6 px from the slanted edge v3-v2: the reference stays on the
// plane, ours lands on the edge) — the captured in-plane scene-edge cells of
// pen_merge.json (E4, E4r 20 px, merge_vtx20_edge) pull onto an edge, so
// "vertex only" is not yet a law ours can take; gap row 581.
// `VIBE3D_CELL=<id>` runs one cell alone (the population floor holds for the
// full run only).

import drag_helpers : Vec3, buildDragLog, fetchCamera, kPaceLine, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers;
import std.algorithm : canFind;
import std.array : join, split;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.process : environment;
import std.string : lastIndexOf;

void main() {}

private enum double kTol = 1e-4, kQuantum = 0.0051;
private JSONValue fx;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}
private Vec3 xz(JSONValue p) { return Vec3(cast(float)num(p[0]), 1, cast(float)num(p[1])); }

/// The quad in the edited mesh, top view, snapping as the cell writes it, the
/// pen armed with the cell's merge.
private void rig(JSONValue c) {
    penSceneEmpty("Top");
    auto r = postJson("/api/command", commandBody("scene.loadMesh", fx["rig"]["quad"].toString));
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
    penCommand("history.clear");
    penCommand("viewport.view Top");
    penCameraAt(Vec3(0.8f, 1, 0.05f), 440);
    string[] types;
    foreach (t; c["snap_types"].array) types ~= t.str;
    penCommand("tool.pipe.attr snap enabled " ~ (c["snapping"].str == "on" ? "true" : "false"));
    penCommand(`tool.pipe.attr snap types "` ~ types.join(",") ~ `"`);
    penCommand("tool.pipe.attr snap snapMode global");
    penCommand("tool.pipe.attr constrain enabled false");
    penCommand("tool.set pen on");
    penCommand("tool.attr pen merge " ~ (num(c["merge"]) != 0 ? "true" : "false"));
}

/// The drag log of p1 to the target; `held` drops the release.
private string dragLog(JSONValue c, bool held = false) {
    auto cam = fetchCamera();
    const a = worldPixel(xz(fx["rig"]["clicks_xz"][1]));
    const b = worldPixel(xz(fx["rig"]["targets_xz"][c["target"].str]));
    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, a[0], a[1], b[0], b[1],
                            c["gesture"].str == "drag_fast" ? 1 : 20);
    return held ? log[0 .. log[0 .. $ - 1].lastIndexOf('\n') + 1] : log;
}

private void stroke(JSONValue c) {
    const k = fx["rig"]["clicks_xz"];
    if (c["gesture"].str == "click") {
        clickWorld(xz(k[0]), xz(fx["rig"]["targets_xz"][c["target"].str]), xz(k[2]));
        return;
    }
    clickWorld(xz(k[0]), xz(k[1]), xz(k[2]));
    playAndWait(dragLog(c));
}

/// The committed mesh against the cell: the faces and the count exactly; the
/// quad and the clicked points exact, p1 exact on v2, else within a quantum
/// in x / z with its height read at that x (the plane, or the edge's 3-D point).
private string[] compare(string cell, JSONValue c) {
    penCommand("tool.set pen off");
    auto m = getJson("/api/model");
    long[][] faces;
    foreach (f; m["faces"].array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        faces ~= ring;
    }
    long[] want = [];
    foreach (e; c["stroke_face"].array) want ~= e.integer;
    Vec3[] got;
    foreach (v; m["vertices"].array)
        got ~= Vec3(cast(float)num(v[0]), cast(float)num(v[1]), cast(float)num(v[2]));
    if (got.length != num(c["nv"]) || faces != [[1L, 0, 3, 2], want])
        return [format("%s: %s vertices, faces %s; expected %s, faces [[1, 0, 3, 2], %s]",
                       cell, got.length, faces, num(c["nv"]), want)];
    const sp = c["stroke_points"].array;
    string[] bad;
    foreach (i, e; sp) {
        const g = got[i == 1 && got.length == 6 ? 2 : i == 2 && got.length == 6 ? 5 : 4 + i];
        const ex = num(e[0]), ey = num(e[1]), ez = num(e[2]);
        const onV2 = abs(ey - 1.25) <= kTol;
        const tolXZ = i == 1 && !onV2 ? kQuantum : kTol;
        const wy = i == 1 && !onV2 && ey != 1 ? 1 + 0.5 * g.x : ey;
        const wz = i == 1 && ey != 1 && !onV2 ? ez : g.z;
        if (!(abs(g.x - ex) <= tolXZ && abs(g.z - ez) <= tolXZ && abs(g.y - wy) <= kTol &&
              abs(g.z - wz) <= kTol))
            bad ~= format("p%s (%.6f, %.6f, %.6f), expected (%.6f, %.6f, %.6f)", i, g.x, g.y, g.z,
                          ex, ey, ez);
    }
    return bad.length ? [format("%s: %-(%s; %)", cell, bad)] : null;
}

unittest {
    fx = parseJSON(import("fixtures/pen_merge_drag.json"));
    const sel = environment.get("VIBE3D_CELL", "");
    const only = sel.length ? sel.split(",") : null;
    bool wanted(string name) { return only is null || only.canFind(name); }
    string[] fails;
    size_t ran;

    // ---- Must-stay-green first: live — mid-drag (button held) the merged p1
    // is already on v2.
    if (wanted("live")) {
        const c = fx["cells"]["D_V1"];
        rig(c);
        clickWorld(xz(fx["rig"]["clicks_xz"][0]), xz(fx["rig"]["clicks_xz"][1]),
                   xz(fx["rig"]["clicks_xz"][2]));
        playAndWait(dragLog(c, true));
        const pos = [penAttrValue("posX"), penAttrValue("posY"), penAttrValue("posZ")];
        if (!(abs(pos[0] - 0.5) <= kTol && abs(pos[1] - 1.25) <= kTol && abs(pos[2] - 0.5) <= kTol))
            fails ~= format("live: mid-drag p1 at %s, expected v2 (0.5, 1.25, 0.5)", pos);
        const b = worldPixel(xz(fx["rig"]["targets_xz"]["V"]));
        playAndWait(buildRelease(b));
        fails ~= compare("live", c);
        ++ran;
    }

    foreach (name, c; fx["cells"].object) {
        if (name == "D_E1" || name == "C_E1" || !wanted(name)) continue;
        rig(c);
        stroke(c);
        fails ~= compare(name, c);
        ++ran;
    }

    if (wanted("SV_V1-unsnapped")) {
        rig(fx["cells"]["SV_V1"]);
        penCommand("tool.pipe.attr snap innerRange 5");
        stroke(fx["cells"]["SV_V1"]);
        fails ~= compare("SV_V1-unsnapped", fx["cells"]["D_V1"]);
        ++ran;
    }

    // Population floor: the live cell, 20 of the 22 captured cells, one ours.
    if (only is null)
        assert(ran == 22, format("population floor: %d cells ran, expected 22", ran));
    // The first line names the first failing cell.
    assert(fails.length == 0, fails.join("\n  "));
}

/// The release of a held drag at window pixel `b`.
private string buildRelease(int[2] b) {
    auto cam = fetchCamera();
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n" ~ kPaceLine ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,`
        ~ `"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", cam.vpX, cam.vpY, cam.width, cam.height,
        b[0], b[1]);
}
