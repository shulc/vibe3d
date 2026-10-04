// Polygon pen placement quantum, against the captured cells of
// tests/fixtures/pen_placement.json key `quantum`: a clicked point's two
// in-plane channels are rounded to the view's grid sub-step q (one pixel of
// world rounded UP on the grid ladder, the step the view's vector snap uses);
// the plane-normal channel is not rounded.
//
// Each ortho cell first asserts that OUR pixel size sits in its q's ladder
// bracket (q_lower, q] (a zoom drift would otherwise move it to another rung
// silently), then clicks the pixel of OUR projection of each captured lattice
// point: the raw plane hit lies within half a pixel of it and half a pixel is
// below q/2, so the quantised channels must equal the captured ones to 1e-4.
// The 110 and 622 px/m cells separate the sub-step from grid/20; the sweep at
// 440 px/m (eight arbitrary pixels, at least one ODD multiple of q) separates
// q from 2q. The perspective cell is lattice membership under OUR q only: a
// perspective pixel size is 0.8 of a real pixel at the focus, so half a real
// pixel may exceed q/2 there.
//
// The stroke is read live (`posX/posY/posZ` of the current point after every
// click), so no commit, ring or facing rule takes part.

import drag_helpers : Vec3, Viewport, fetchCamera, pixelRay,
    viewportFromCameraMatrices;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, round, tan, PI;

void main() {}

private enum double kTolQ = 1e-4;   // a quantised channel vs the captured one
private enum double kTolLattice = 1e-3; // |v/q - round(v/q)| on the lattice

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}

/// The renderer's grid terms for cell 0: OUR `viewWorldPerPixel` and the
/// sub-step it gives (the pen reads the same camera).
private double[2] liveGrid() {
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    return [num(g["pixelSize"]), num(g["subStep"])];
}

/// Ortho Top rig at `ppm` pixels per metre, focus on the y-1 plane.
private void rigOrtho(double ppm, double fx, double fz) {
    // Ortho pixel size = 2 * distance * tan(pi/8) / viewport height.
    const h = fetchCamera().height;
    penRigEmpty(Vec3(cast(float)fx, 1, cast(float)fz), "Top",
                h / (ppm * 2.0 * tan(PI / 8)));
}

/// The plane-y-1 hit of window pixel `p` under the live camera (OUR raw).
private double[2] rawAt(int[2] p) {
    Viewport vp = viewportFromCameraMatrices();
    Vec3 org, dir;
    pixelRay(cast(float)p[0], cast(float)p[1], vp, org, dir);
    const t = (1.0 - org.y) / dir.y;
    return [org.x + dir.x * t, org.z + dir.z * t];
}

/// Click pixel `p`; the current point's position afterwards.
private double[3] clickRead(int[2] p) {
    clickPixels(p);
    return [penAttrValue("posX"), penAttrValue("posY"), penAttrValue("posZ")];
}

private bool onLattice(double v, double q) {
    return abs(v / q - round(v / q)) < kTolLattice;
}

unittest {
    auto cells = parseJSON(import("fixtures/pen_placement.json"))["quantum"]["cells"];
    string[] fails;
    int scored;

    // Exact ortho cells: B4a (440), B4b (32), KC_110, KC_622.
    foreach (id; ["B4a", "B4b", "KC_110", "KC_622"]) {
        auto c = cells[id];
        const q = num(c["q"]), qLower = num(c["q_lower"]);
        auto pts = c["points_xz"].array;
        double fx = 0, fz = 0;
        foreach (p; pts) { fx += num(p.array[0]); fz += num(p.array[1]); }
        rigOrtho(num(c["px_per_m"]), fx / pts.length, fz / pts.length);
        const g = liveGrid();
        string[] cellFails;
        assert(g[0] > qLower && g[0] <= q, format("%s rig: our pixel size %.9g "
            ~ "is outside the bracket (%s, %s] of q %s", id, g[0], qLower, q, q));
        foreach (i, p; pts) {
            const wx = num(p.array[0]), wz = num(p.array[1]);
            const px = worldPixel(Vec3(cast(float)wx, 1, cast(float)wz));
            const raw = rawAt(px);
            const got = clickRead(px);
            assert(abs(got[1] - 1.0) <= kTolQ, format("%s p%d rig: the point "
                ~ "must lie on the focus plane y 1, got y %.6f", id, i, got[1]));
            scored += 2;
            if (!(abs(got[0] - wx) <= kTolQ && abs(got[2] - wz) <= kTolQ))
                cellFails ~= format("p%d placed (%.6f, %.6f) raw (%.6f, %.6f) "
                    ~ "expected (%.4f, %.4f)", i, got[0], got[2], raw[0], raw[1],
                    wx, wz);
        }
        if (cellFails.length)
            fails ~= format("%s [q %s, our px %.6g sub %.6g]: %-(%s; %)", id, q,
                            g[0], g[1], cellFails);
        penCommand("tool.set pen off");
    }
    assert(scored == 20, format("population: %d channels scored, expected 20", scored));

    // Sweep at 440 px/m: eight arbitrary pixels, every in-plane channel a
    // multiple of q, at least one ODD multiple (q, not 2q).
    {
        auto c = cells["B4a"];
        const q = num(c["q"]), qLower = num(c["q_lower"]);
        rigOrtho(num(c["px_per_m"]), 0.07, 0.0);
        const g = liveGrid();
        assert(g[0] > qLower && g[0] <= q, format("sweep rig: our pixel size "
            ~ "%.9g is outside (%s, %s]", g[0], qLower, q));
        auto cam = fetchCamera();
        const cx = cam.vpX + cam.width / 2, cy = cam.vpY + cam.height / 2;
        static immutable int[2][8] offsets = [[-151, -97], [-63, -131], [37, -113],
            [149, -59], [173, 41], [89, 127], [-23, 139], [-137, 71]];
        int n, odd;
        double[] bad;
        foreach (o; offsets) {
            const got = clickRead([cx + o[0], cy + o[1]]);
            foreach (v; [got[0], got[2]]) {
                ++n;
                if (!onLattice(v, q)) bad ~= v;
                else if ((cast(long)round(v / q)) % 2 != 0) ++odd;
            }
        }
        penCommand("tool.set pen off");
        assert(n == 16, format("sweep population: %d channels, expected 16", n));
        if (bad.length)
            fails ~= format("sweep: %d of 16 channels off the q %s lattice: %(%.6f %)",
                            bad.length, q, bad);
        if (odd == 0)
            fails ~= format("sweep: no channel is an odd multiple of q %s", q);
    }

    // Perspective (B4c): lattice membership under OUR q; the raw-to-placed
    // residual is reported in real pixels at the focus (1.25 x pixel size).
    {
        auto c = cells["B4c"];
        auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
        assert(r["status"].str == "ok", "empty reset failed: " ~ r.toString);
        penCommand("history.clear");
        penCommand("workplane.reset");
        penCommand("viewport.view Perspective");
        r = postJson("/api/camera", `{"focus":{"x":0.07,"y":1.0,"z":0.0},`
            ~ `"azimuth":0.3,"elevation":1.1,"distance":4.0}`);
        assert(r["status"].str == "ok", "camera setup failed: " ~ r.toString);
        assert(getJson("/api/camera")["projKind"].str == "Perspective",
            "B4c rig: the view must be perspective");
        penCommand("tool.set pen on");
        const g = liveGrid();
        const q = g[1];
        assert(q > 0, format("B4c rig: our sub-step must be positive, got %s", q));
        int n;
        bool bad;
        string[] report;
        foreach (i, p; c["points_xz"].array) {
            const px = worldPixel(Vec3(cast(float)num(p.array[0]), 1,
                                       cast(float)num(p.array[1])));
            const raw = rawAt(px);
            const got = clickRead(px);
            assert(abs(got[1] - 1.0) <= kTolQ, format("B4c p%d rig: the point "
                ~ "must lie on the focus plane y 1, got y %.6f", i, got[1]));
            // Raw-to-lattice residual in real pixels at the focus.
            report ~= format("p%d raw (%.6f, %.6f) placed (%.6f, %.6f) residual "
                ~ "(%.3f, %.3f) real px", i, raw[0], raw[1], got[0], got[2],
                abs(raw[0] - round(raw[0] / q) * q) / (1.25 * g[0]),
                abs(raw[1] - round(raw[1] / q) * q) / (1.25 * g[0]));
            foreach (v; [got[0], got[2]]) {
                ++n;
                bad |= !onLattice(v, q);
            }
        }
        if (bad)
            fails ~= format("B4c [our px %.6g, our q %.6g, captured q %s]: a channel "
                ~ "is off our lattice: %-(%s; %)", g[0], q, num(c["q"]), report);
        penCommand("tool.set pen off");
        penCommand("viewport.view Perspective");
        assert(n == 6, format("B4c population: %d channels, expected 6", n));
    }

    assert(fails.length == 0, "\n" ~ fails.join("\n"));
}
