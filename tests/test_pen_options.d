// Polygon pen raycast (pen wave plan S10; task 9416) against
// tests/fixtures/pen_options.json `b9` and `k_b3` R-front / R4b. The law: with
// raycast on, a press on a stroke point hidden behind the background surface
// does not grab it — the press acts on empty space (a new point, dragged); a
// visible point (in front of the surface) is grabbed; raycast never places a
// point on a surface (the constraint is off in every cell). Off: the hidden
// point is grabbed.
//
// Rig: top ortho on y = 1 at 360 px/m (the fixture's `rig_ours`; the 0.005 m
// quantum kept), snapping off; the background is
// a unit sphere at (0, 1, 0) in layer 1 (64 x 32), the edit layer 0. The
// hidden-press panel is read from currentPoint and posXYZ proxies while the
// stroke is live. A skipped first duplicate binds the last retained corner;
// safe update moves that corner until the next click rebuilds from panel points.
// `VIBE3D_CELL=<id>` runs one cell alone (the population floor
// holds for the full run only).

import drag_helpers : Vec3, buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers;
import std.algorithm : canFind;
import std.array : join, split;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.process : environment;

void main() {}

private enum double kTol = 1e-4;
private JSONValue fx;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}
private Vec3 xz(JSONValue p) {
    return Vec3(cast(float)num(p[0]), 1, cast(float)num(p[1]));
}

/// The scene: the background sphere (or a foreground mesh), snapping off,
/// the constraint off, the pen armed with `raycast`.
private void rig(bool raycast, JSONValue foreground = JSONValue(null)) {
    penSceneEmpty("Top");
    if (foreground.isNull) {
        penCommand("layer.add name:Bg");
        penCommand("prim.sphere cenX:0 cenY:1 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 sides:64 segments:32");
        penCommand("layer.setVisible index:1 value:true");
        penCommand("layer.select index:0");
    } else {
        auto r = postJson("/api/command", commandBody("scene.loadMesh", foreground.toString));
        assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
    }
    const r = fx["rig_ours"];
    penCameraAt(xz(r["focus_xz"]["b9"]), num(r["px_per_m"]["b9"]));
    const g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    assert(abs(num(g["subStep"]) - num(r["q"])) <= 1e-9,
        format("rig: our placement quantum %.9g, the fixture's %.9g", num(g["subStep"]), num(r["q"])));
    penCommand("tool.pipe.attr snap enabled false");
    penCommand("tool.pipe.attr constrain enabled false");
    penCommand("tool.set pen on");
    penCommand("tool.attr pen raycast " ~ (raycast ? "true" : "false"));
}
private void drag(int[2] a, int[2] b) {
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height, a[0], a[1], b[0], b[1]));
}
private void clicks(JSONValue pts) { foreach (p; pts.array) clickWorld(xz(p)); }
/// The edit layer's vertices after the drop (the background is layer 1).
private Vec3[] commit() {
    penCommand("tool.set pen off");
    return readVerts();
}
private string[] compare(string cell, const(Vec3)[] got, JSONValue want) {
    if (got.length != want.array.length)
        return [format("%s: %d vertices, expected %d (got %s)", cell, got.length,
                       want.array.length, got)];
    string[] fails;
    foreach (i, w; want.array) {
        const e = [num(w[0]), num(w[1]), num(w[2])];
        const g = [cast(double)got[i].x, got[i].y, got[i].z];
        if (!(abs(g[0] - e[0]) <= kTol && abs(g[1] - e[1]) <= kTol && abs(g[2] - e[2]) <= kTol))
            fails ~= format("%s: point %d at %(%.6f %), expected %(%.6f %)", cell, i, g[], e[]);
    }
    return fails;
}

unittest {
    fx = parseJSON(import("fixtures/pen_options.json"));
    const sel = environment.get("VIBE3D_CELL", "");
    const only = sel.length ? sel.split(",") : null;
    bool wanted(string name) { return only is null || only.canFind(name); }
    string[] fails;
    size_t ran;
    const b9 = fx["b9"];
    const aliasCells = parseJSON(import("fixtures/pen_point_alias.json"));
    void faces(string id, JSONValue want) {
        const got = getJson("/api/model")["faces"];
        if (got != want) fails ~= format("%s: faces %s expected %s", id,got,want);
    }
    // The capture's +40 px at 440 px/m ends on x 0.39: drag to that point.
    int[2] plus40(int[2]) { return worldPixel(xz(b9["drag_to_xz"])); }

    // ---- Must-stay-green first: raycast off grabs the hidden p0.
    if (wanted("occluded_press_raycast_off")) {
        const c = b9["cases"]["occluded_press_raycast_off"];
        rig(false);
        clicks(b9["clicks_xz"]);
        const a = worldPixel(xz(b9["clicks_xz"][0]));
        drag(a, plus40(a));
        if (penAttrValue("currentPoint") != num(c["current_after"]))
            fails ~= format("occluded_press_raycast_off: current %s, expected %s",
                            penAttrValue("currentPoint"), num(c["current_after"]));
        fails ~= compare("occluded_press_raycast_off", commit(), aliasCells["ordinary-grab"]["vertices"]);
        faces("occluded_press_raycast_off", aliasCells["ordinary-grab"]["faces"]);
        ++ran;
    }

    // ---- raycast-front-grab: p0 typed to y 2.2 (above the sphere, visible) is
    // grabbed with raycast on and keeps its height.
    if (wanted("raycast-front-grab")) {
        const c = fx["k_b3"]["Rfront_visible_point"];
        rig(true);
        clicks(b9["clicks_xz"]);
        penAttr("currentPoint", 0);
        penAttr("posY", num(c["typed"]["posY"]));
        const a = worldPixel(xz(b9["clicks_xz"][0]));
        drag(a, plus40(a));
        fails ~= compare("raycast-front-grab", commit(), c["expected"]);
        ++ran;
    }

    // ---- Raycast on, a press on the hidden p0: p0 stays, a new point at the
    // press is dragged; mid-stroke the panel holds [p0, p1, p2, new], current 3.
    if (wanted("raycast-hidden-press-panel")) {
        const c = fx["k_b3"]["R4b_hidden_press"];
        rig(true);
        clicks(b9["clicks_xz"]);
        const a = worldPixel(xz(b9["clicks_xz"][0]));
        drag(a, plus40(a));
        if (penAttrValue("currentPoint") != num(c["panel_current"]))
            fails ~= format("raycast-hidden-press-panel: current %s, expected %s",
                            penAttrValue("currentPoint"), num(c["panel_current"]));
        Vec3[] panel;
        foreach (i; 0 .. 5) {
            penAttr("currentPoint", i);
            const cur = penAttrValue("currentPoint");
            const want = num(aliasCells["hidden-release"]["current"][i]);
            if (cur != want) fails ~= format("raycast-hidden-press-panel: current %s expected %s",cur,want);
            panel ~= Vec3(cast(float)penAttrValue("posX"),
                cast(float)penAttrValue("posY"), cast(float)penAttrValue("posZ"));
        }
        assert(panel.length == 5, "raycast-hidden-press-panel: observer population");
        fails ~= compare("raycast-hidden-press-panel", panel, aliasCells["hidden-release"]["panel"]);
        commit();
        ++ran;
    }
    if (wanted("occluded_press_raycast_on")) {
        rig(true);
        clicks(b9["clicks_xz"]);
        const a = worldPixel(xz(b9["clicks_xz"][0]));
        drag(a, plus40(a));
        const got = commit();
        const want = aliasCells["hidden-release"];
        fails ~= compare("occluded_press_raycast_on", got, want["vertices"]);
        faces("occluded_press_raycast_on", want["faces"]);
        ++ran;
    }

    if (wanted("hidden-next-click")) {
        rig(true);
        // This top-view focus keeps every captured point inside our viewport.
        penCameraAt(Vec3(.8,1,.15), 440);
        clicks(b9["clicks_xz"]);
        const a = worldPixel(xz(b9["clicks_xz"][0]));
        drag(a, plus40(a));
        const c = aliasCells["hidden-next-click"];
        const n = c["nextPoint"];
        clickWorld(Vec3(cast(float)num(n[0]),cast(float)num(n[1]),cast(float)num(n[2])));
        fails ~= compare("hidden-next-click", commit(), c["vertices"]);
        faces("hidden-next-click", c["faces"]);
        ++ran;
    }

    // ---- Raycast never places on a surface: a visible point dragged over the
    // background / a foreground quad stays on the plane y 1.
    foreach (name; ["click_over_background_raycast_on", "click_over_foreground_raycast_on",
                    "click_over_foreground_raycast_off"]) {
        if (!wanted(name)) continue;
        const c = b9["cases"][name];
        const fg = "foreground" in c.object ? c["foreground"] : JSONValue(null);
        rig(c["raycast"].type == JSONType.true_, fg);
        clicks("clicks_xz" in c.object ? c["clicks_xz"] : b9["clicks_xz"]);
        const k = cast(size_t)c["drag"]["point"].integer;
        const pts = "clicks_xz" in c.object ? c["clicks_xz"] : b9["clicks_xz"];
        drag(worldPixel(xz(pts[k])), worldPixel(xz(c["drag"]["to_xz"])));
        if (penAttrValue("currentPoint") != num(c["current_after"]))
            fails ~= format("%s: current %s, expected %s", name, penAttrValue("currentPoint"),
                            num(c["current_after"]));
        fails ~= compare(name, commit(), c["expected"]);
        ++ran;
    }

    // Population floor: five raycast cells, two panel/visible cells, one rebuild.
    if (only is null)
        assert(ran == 8, format("population floor: %d cells ran, expected 8", ran));
    // The first line names the first failing cell.
    assert(fails.length == 0, fails.join("\n  "));
}
