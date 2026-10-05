// The polygon pen over a BACKGROUND surface with the surface constraint on,
// against tests/fixtures/pen_background_constraint.json (task 9415). The pen's
// point is the create family's free point: the plane point (the first point =
// the create click, later ones = the plane through the current point, a drag =
// the plane through the dragged point), quantised, then the background hit on
// the view ray through it, offset after the quantum, then the snap; the
// constraint's `handle` gates it, its geometry mode does not.
//
// Must-stay-green cells run first (handle off, constraint off, a fresh scene
// before any tool drop: the plane). In-plane channels are exact (every click
// aims at a lattice point, q 0.005); heights carry the reference's depth read
// (tolerance 2e-3, K-C2 PF-5). VIBE3D_CELL=<name>[,<name>...] runs only those
// cells (mutation drills).

import drag_helpers : Vec3, buildDragLog, fetchCamera, pixelRay, playAndWait,
    viewportFromCameraMatrices;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import pen_rig_helpers : clickPixels, penAttr, penCameraAt, penCommand, penSceneEmpty,
    readVerts, worldPixel;
import std.algorithm : canFind;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : PI, abs, cos, sqrt, tan;
import std.process : environment;
import std.string : split;

void main() {}

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private double[3] arr3(JSONValue a) { return [num(a.array[0]), num(a.array[1]), num(a.array[2])]; }
private Vec3 v3(double[3] a) { return Vec3(cast(float)a[0], cast(float)a[1], cast(float)a[2]); }
private double[3] d3(Vec3 v) { return [v.x, v.y, v.z]; }
private double[3] sub(double[3] a, double[3] b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
private double dot3(double[3] a, double[3] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
private double len(double[3] a) { return sqrt(dot3(a, a)); }
private Vec3 xz(JSONValue a) { return Vec3(cast(float)num(a.array[0]), 1, cast(float)num(a.array[1])); }

/// Distance from `p` to the line through `o` along `d`.
private double rayDist(double[3] p, double[3] o, double[3] d) {
    const u = 1 / len(d);
    const double[3] n = [d[0] * u, d[1] * u, d[2] * u];
    const w = sub(p, o), t = dot3(w, n);
    return len([w[0] - n[0] * t, w[1] - n[1] * t, w[2] - n[2] * t]);
}

private JSONValue fx;
private double heightTol;

/// Empty foreground, the background sphere at `centre`, the top 440 camera;
/// with `constrain`, the constraint on (geometry off, `handle`, `offset`)
/// before the pen is armed.
private void rig(double[3] centre = [0, 1, 0], bool constrain = true, bool handleOn = true,
                 double offset = 0, string view = "Top", double focusX = double.nan) {
    penSceneEmpty(view);
    penCommand("layer.add name:Bg");
    penCommand(format("prim.sphere cenX:%.9f cenY:%.9f cenZ:%.9f sizeX:1 sizeY:1 sizeZ:1 "
                      ~ "sides:64 segments:32", centre[0], centre[1], centre[2]));
    penCommand("layer.setVisible index:1 value:true");
    penCommand("layer.select index:0");
    penCommand("tool.pipe.attr snap enabled false");
    const r = fx["rig"];
    if (view == "Top") {
        // A wide cell moves the focus along x: in top view only its height
        // (the first point's plane) is a term.
        auto f = arr3(r["focus"]);
        if (focusX == focusX) f[0] = focusX;
        penCameraAt(v3(f), num(r["px_per_m"]));
    } else {
        // Straight down, exactly (the orbit chart clamps at 89 degrees), at
        // the record's scale (`penCameraAt`'s perspective law).
        const f = arr3(r["focus"]);
        const dist = fetchCamera().height / (1.6 * num(r["px_per_m"]) * tan(PI / 8));
        auto c = postJson("/api/camera", format(`{"orientation":[1,0,0, 0,0,-1, 0,1,0],`
            ~ `"focus":{"x":%.9f,"y":%.9f,"z":%.9f},"distance":%.9f}`, f[0], f[1], f[2], dist));
        assert(c["status"].str == "ok", "rig: camera " ~ c.toString);
    }
    const g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    assert(abs(num(g["subStep"]) - num(r["q"])) <= 1e-9,
        format("rig: our click quantum %.9g, the record's %.9g", num(g["subStep"]), num(r["q"])));
    if (constrain) {
        penCommand("tool.pipe.attr constrain enabled true");
        penCommand("tool.pipe.attr constrain geometry off");
        penCommand(format("tool.pipe.attr constrain offset %.9f", offset));
        handle(handleOn);
    }
}

private JSONValue consAttrs() {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == "CONS") return st["attrs"];
    return JSONValue(null);
}

private void handle(bool on) {
    penCommand("tool.pipe.attr constrain handle " ~ (on ? "true" : "false"));
    const a = consAttrs();
    assert(!a.isNull && a["enabled"].str == "true" && a["handle"].str == (on ? "true" : "false"),
        "rig: the constraint did not read back as written: " ~ a.toString);
}

/// One key tap through the event path (the drop is a key gesture).
private void key(int sym, int scan) {
    auto cam = fetchCamera();
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n"
        ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":0,"repeat":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, sym, scan, sym, scan));
    quiesce();
}

private void penOn() { penCommand("tool.set pen on"); }
private Vec3[] commit() {
    penCommand("tool.set pen off");
    return readVerts();
}

private void clickXZ(JSONValue pts) {
    int[2][] px;
    foreach (p; pts.array) px ~= worldPixel(xz(p));
    clickPixels(px);
}

private void dragPixels(int[2] from, int[2] to) {
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             from[0], from[1], to[0], to[1]));
}

/// Every vertex against the expected list: x/z within `xzTol`, y within
/// `yTol`; one message per failing vertex.
private string[] compare(string cell, Vec3[] got, JSONValue want, double yTol, double xzTol = 1e-4) {
    if (got.length != want.array.length)
        return [format("%s: %d vertices, expected %d (got %s)", cell, got.length,
                       want.array.length, got)];
    string[] fails;
    foreach (i, w; want.array) {
        const e = arr3(w), g = d3(got[i]);
        if (!(abs(g[0] - e[0]) <= xzTol && abs(g[2] - e[2]) <= xzTol && abs(g[1] - e[1]) <= yTol))
            fails ~= format("%s: point %d at %(%.6f %), expected %(%.6f %) (x/z tol %g, y tol %g)",
                            cell, i, g[], e[], xzTol, yTol);
    }
    return fails;
}

unittest {
    fx = parseJSON(import("fixtures/pen_background_constraint.json"));
    heightTol = num(fx["height_tol"]);
    const sel = environment.get("VIBE3D_CELL", "");
    const only = sel.length ? sel.split(",") : null;
    bool wanted(string name) { return only is null || only.canFind(name); }
    JSONValue cell(string n) { return fx["cells"][n]; }
    string[] fails;
    int ran;

    // ---- must stay green: the plane.
    if (wanted("pen-handle-off")) {
        auto c = cell("C1");
        rig([0, 1, 0], true, false);
        penOn();
        clickXZ(c["clicks_xz"]);
        fails ~= compare("pen-handle-off", commit(), c["handle_off"], 1e-5);
        ++ran;
    }
    if (wanted("pen-constraint-off")) {
        auto c = cell("C1");
        rig([0, 1, 0], false);
        penCommand("tool.pipe.attr constrain enabled false");
        penOn();
        clickXZ(c["clicks_xz"]);
        fails ~= compare("pen-constraint-off", commit(), c["constraint_off"], 1e-5);
        ++ran;
    }
    // A fresh scene holds the constraint remembered but out of the pipe; the
    // session's first tool drop puts it in (tests/test_constraint_boot.d).
    foreach (drop; [false, true]) {
        const name = drop ? "pen-after-first-drop" : "pen-fresh-boot";
        if (!wanted(name)) continue;
        auto c = cell("C1");
        rig([0, 1, 0], false);
        const a0 = consAttrs();
        assert(a0.isNull || a0["enabled"].str == "false",
            name ~ " rig: a fresh scene must hold the constraint out of the pipe: " ~ a0.toString);
        if (drop) {
            key(119, 26);   // w: the move tool
            key(113, 20);   // q: the drop key
            const a = consAttrs();
            assert(!a.isNull && a["enabled"].str == "true" && a["handle"].str == "true",
                name ~ " rig: the first drop did not put the constraint in the pipe: " ~ a.toString);
        }
        penOn();
        clickXZ(c["clicks_xz"]);
        fails ~= compare(name, commit(), drop ? c["handle_on"] : c["handle_off"],
                         drop ? heightTol : 1e-5);
        ++ran;
    }

    // ---- C1: the surface, whatever the geometry mode.
    foreach (geom; cell("C1")["geometry_swept"].array) {
        const name = "pen-surface-" ~ geom.str;
        if (!wanted(name)) continue;
        auto c = cell("C1");
        rig();
        penCommand("tool.pipe.attr constrain geometry " ~ geom.str);
        penOn();
        clickXZ(c["clicks_xz"]);
        fails ~= compare(name, commit(), c["handle_on"], heightTol);
        ++ran;
    }

    // ---- C2b: a miss after a hit keeps the plane through the hit, quantised.
    if (wanted("pen-hit-miss-hit")) {
        auto c = cell("C2b");
        rig([0, 1, 0], true, true, 0, "Top", num(c["focus_x"]));
        penOn();
        clickXZ(c["clicks_xz"]);
        auto got = commit();
        fails ~= compare("pen-hit-miss-hit", got, c["expected"], heightTol);
        if (got.length == 3 && !(abs(got[1].y - num(c["expected"][1][1])) <= num(c["p1_height_tol"])))
            fails ~= format("pen-hit-miss-hit: the miss lands at y %.6f, expected the quantised "
                            ~ "plane through the hit, %.4f", got[1].y, num(c["expected"][1][1]));
        ++ran;
    }

    // ---- C3: a drag reads the surface.
    if (wanted("pen-drag-surface")) {
        auto c = cell("C3");
        rig();
        penOn();
        clickXZ(c["clicks_xz"]);
        const k = cast(size_t)c["drag"]["point"].integer;
        dragPixels(worldPixel(xz(c["clicks_xz"][k])), worldPixel(xz(c["drag"]["to_xz"])));
        fails ~= compare("pen-drag-surface", commit(), c["expected"], heightTol);
        ++ran;
    }

    // ---- B6: the straight-line guide does not pull a point the surface placed.
    if (wanted("pen-guide-vs-surface")) {
        auto c = cell("B6");
        rig();
        penOn();
        clickXZ(c["clicks_xz"]);
        penCommand("tool.pipe.attr snap enabled true");
        penCommand(`tool.pipe.attr snap types "` ~ c["snap_types"].str ~ `"`);
        scope (exit) postJson("/api/command", "tool.pipe.attr snap enabled false");
        const k = cast(size_t)c["drag"]["point"].integer;
        dragPixels(worldPixel(xz(c["clicks_xz"][k])), worldPixel(xz(c["drag"]["to_xz"])));
        fails ~= compare("pen-guide-vs-surface", commit(), c["expected"], num(c["height_tol"]));
        ++ran;
    }

    // ---- D: symmetry mirrors the constrained points, no re-projection.
    if (wanted("pen-symmetry-surface")) {
        auto c = cell("D");
        rig(arr3(c["sphere_centre"]));
        penCommand("tool.pipe.attr symmetry enabled true");
        penCommand("tool.pipe.attr symmetry axis " ~ c["symmetry_axis"].str);
        scope (exit) postJson("/api/command", "tool.pipe.attr symmetry enabled false");
        penOn();
        clickXZ(c["clicks_xz"]);
        fails ~= compare("pen-symmetry-surface", commit(), c["expected"], heightTol);
        ++ran;
    }

    // ---- B7: quantised x/z on the surface; a typed position stands.
    if (wanted("pen-typed-stands")) {
        auto c = cell("B7");
        rig();
        penOn();
        clickXZ(c["clicks_xz"]);
        penAttr("currentPoint", num(c["typed"]["point"]));
        penAttr("posY", num(c["typed"]["posY"]));
        fails ~= compare("pen-typed-stands", commit(), c["expected"], heightTol);
        ++ran;
    }

    // ---- B7b: the offset along the hit normal, AFTER the quantum: the same
    // pixels with offset 0 give the surface points it is measured from.
    if (wanted("pen-surface-offset")) {
        auto c = cell("B7b");
        rig();
        penOn();
        clickXZ(c["clicks_xz"]);
        auto surf = commit();
        penCommand("tool.pipe.attr constrain offset " ~ format("%.9f", num(c["offset"])));
        penOn();
        penCommand("tool.attr pen merge false");   // 13 px from the first stroke's points
        clickXZ(c["clicks_xz"]);
        auto all = commit();
        const want = num(c["offset"]);
        if (all.length != 2 * surf.length || surf.length != c["expected"].array.length)
            fails ~= format("pen-surface-offset: %d + %d vertices", surf.length, all.length);
        else {
            auto off = all[surf.length .. $];
            foreach (i, t; c["tol"].array)
                fails ~= compare(format("pen-surface-offset p%d", i), off[i .. i + 1],
                                 JSONValue([c["expected"][i]]), num(t), num(t));
            foreach (i; 0 .. surf.length) {
                const d = sub(d3(off[i]), d3(surf[i]));
                if (!(abs(len(d) - want) <= 1e-5))
                    fails ~= format("pen-surface-offset: point %d offset %(%.6f %) has length %.6f, "
                        ~ "expected %.6f from the surface point %(%.6f %)", i, d[], len(d), want,
                        d3(surf[i])[]);
                const nrm = sub(d3(surf[i]), [0.0, 1.0, 0.0]);
                if (!(dot3(d, nrm) / (len(d) * len(nrm)) >= cos(3 * PI / 180)))
                    fails ~= format("pen-surface-offset: point %d offset %(%.6f %) is not along "
                        ~ "the surface normal %(%.6f %)", i, d[], nrm[]);
            }
        }
        ++ran;
    }

    // ---- C2i: the snap runs last; the pen welds onto the snapped vertex.
    if (wanted("pen-snap-weld")) {
        auto c = cell("C2i");
        rig([0, 1, 0], true, true, 0, "Top", num(c["focus_x"]));
        const v = arr3(c["foreground_vertex"]);
        auto r = postJson("/api/command", commandBody("mesh.addVertex",
            format(`{"pos":[%.9f,%.9f,%.9f]}`, v[0], v[1], v[2])));
        assert(r["status"].str == "ok", "pen-snap-weld rig: " ~ r.toString);
        penCommand("tool.pipe.attr snap enabled true");
        penCommand("tool.pipe.attr snap types vertex");
        scope (exit) postJson("/api/command", "tool.pipe.attr snap enabled false");
        penOn();
        clickPixels(worldPixel(xz(c["aim_xz"])));
        penCommand("tool.pipe.attr snap enabled false");
        clickXZ(c["more_clicks_xz"]);
        auto got = commit();
        if (got.length != cast(size_t)num(c["expect_nv"]))
            fails ~= format("pen-snap-weld: %d vertices, expected %s (the pen reuses the snapped "
                ~ "vertex): %s", got.length, num(c["expect_nv"]), got);
        else if (!(len(sub(d3(got[0]), v)) <= 1e-5))
            fails ~= format("pen-snap-weld: the snapped vertex moved to %(%.6f %)", d3(got[0])[]);
        else {
            auto f = getJson("/api/model")["faces"].array;
            if (f.length != 1 || !f[0].array.canFind!(x => x.integer == 0))
                fails ~= "pen-snap-weld: the polygon does not reuse vertex 0: " ~ JSONValue(f).toString;
        }
        ++ran;
    }

    // ---- C2i SNAP-LAST without the weld: the snapped point itself (all three
    // channels), not the surface under it; merge off, so no link rescues it.
    if (wanted("pen-snap-last")) {
        auto c = cell("C2i");
        rig([0, 1, 0], true, true, 0, "Top", num(c["focus_x"]));
        const v = arr3(c["foreground_vertex"]);
        auto r = postJson("/api/command", commandBody("mesh.addVertex",
            format(`{"pos":[%.9f,%.9f,%.9f]}`, v[0], v[1], v[2])));
        assert(r["status"].str == "ok", "pen-snap-last rig: " ~ r.toString);
        penCommand("tool.pipe.attr snap enabled true");
        penCommand("tool.pipe.attr snap types vertex");
        scope (exit) postJson("/api/command", "tool.pipe.attr snap enabled false");
        penOn();
        penCommand("tool.attr pen merge false");
        clickPixels(worldPixel(xz(c["aim_xz"])));
        penCommand("tool.pipe.attr snap enabled false");
        clickXZ(c["more_clicks_xz"]);
        auto got = commit();
        if (got.length != 4)
            fails ~= format("pen-snap-last: %d vertices, expected 4 (no weld): %s", got.length, got);
        else if (!(len(sub(d3(got[1]), v)) <= 1e-5))
            fails ~= format("pen-snap-last: the snapped point %(%.6f %) is not the vertex %(%.6f %)",
                            d3(got[1])[], v[]);
        ++ran;
    }

    // ---- The guide gate on the B6 drag, both halves (task 9416: the guide is
    // anchored on the dragged point's ring neighbours, so the straight line
    // z 0 through p1, p2 engages on p3's drag). Control: handle off, the guide
    // pulls p3 onto z 0; on: the surface point at q, z 0.005, no guide.
    if (wanted("pen-guide-drag-vs-surface")) {
        auto c = cell("B6");
        foreach (on; [false, true]) {
            rig([0, 1, 0], true, on);
            penOn();
            clickXZ(c["clicks_xz"]);
            penCommand("tool.pipe.attr snap enabled true");
            penCommand(`tool.pipe.attr snap types "` ~ c["snap_types"].str ~ `"`);
            const k = cast(size_t)c["drag"]["point"].integer;
            dragPixels(worldPixel(xz(c["clicks_xz"][k])), worldPixel(xz(c["drag"]["to_xz"])));
            penCommand("tool.pipe.attr snap enabled false");
            auto vs = commit();
            if (vs.length != 4) { fails ~= format("pen-guide-drag-vs-surface: %d vertices", vs.length); break; }
            const p = d3(vs[3]);
            if (!on && !(abs(p[2]) <= 1e-5))
                fails ~= format("pen-guide-drag-vs-surface control: the guide did not engage, "
                                ~ "p3 %(%.6f %) (expected z 0)", p[]);
            if (on && !(abs(p[2] - 0.005) <= 1e-5 && abs(len(sub(p, [0.0, 1.0, 0.0])) - 1) <= 2.5e-3))
                fails ~= format("pen-guide-drag-vs-surface: p3 %(%.6f %), expected the "
                                ~ "surface point at q (0.2, z 0.005)", p[]);
        }
        ++ran;
    }

    // ---- C2h: the pen's first point is the vertex tool's at the same pixel.
    foreach (i, view; cell("C2h")["views"].array) {
        const name = "pen-first-point-" ~ (view.str == "Top" ? "top" : "persp");
        if (!wanted(name)) continue;
        rig([0, 1, 0], true, true, 0, view.str);
        const px = worldPixel(v3(arr3(cell("C2h")["aim_world"][i])));
        penCommand("tool.set prim.vertex on");
        handle(false);
        clickPixels(px);
        handle(true);
        clickPixels(px);
        penCommand("tool.set prim.vertex off");
        auto vt = readVerts();
        penOn();
        penCommand("tool.attr pen merge false");   // the point must not merge onto the vertex
        clickPixels(px, [px[0] + 60, px[1]], [px[0], px[1] + 60]);
        auto all = commit();
        if (vt.length != 2 || all.length != 5) {
            fails ~= format("%s: %d vertex-tool and %d total vertices, expected 2 and 5", name,
                            vt.length, all.length);
        } else {
            const q = d3(vt[0]), s = d3(vt[1]), p = d3(all[2]);
            if (!(len(sub(p, s)) <= 1e-6))
                fails ~= format("%s: the pen's first point %(%.7f %) is %.2e from the vertex "
                    ~ "tool's %(%.7f %)", name, p[], len(sub(p, s)), s[]);
            // The law, not just the agreement: on the eye ray through the
            // handle-off q, off the pixel's own ray.
            const eye = d3(fetchCamera().eye);
            auto vp = viewportFromCameraMatrices();
            Vec3 po, pd;
            pixelRay(px[0], px[1], vp, po, pd);
            const dq = view.str == "Top" ? rayDist(p, q, [0.0, 1.0, 0.0])
                                         : rayDist(p, eye, sub(q, eye));
            if (!(dq <= 1e-5))
                fails ~= format("%s: %(%.6f %) is %.2e off the view ray through q %(%.6f %)",
                                name, p[], dq, q[]);
            if (abs(p[1] - 1) < 0.5)
                fails ~= format("%s: %(%.6f %) is not on the background", name, p[]);
            if (view.str != "Top" && !(rayDist(p, d3(po), d3(pd)) >= 1e-3))
                fails ~= format("%s: %(%.6f %) is on the pixel's own ray (the q-ray law puts it "
                    ~ ">= 1e-3 off)", name, p[]);
        }
        ++ran;
    }

    const want = only is null ? 19 : cast(int)only.length;
    assert(ran == want, format("cell population: %d run, expected %d", ran, want));
    assert(fails.length == 0, "pen background constraint cells:\n" ~ fails.join("\n"));
}
