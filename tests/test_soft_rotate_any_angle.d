// Soft rotate turns each vertex by angle x weight, R(w*theta), for ANY angle
// (task 9446, capture K-F4, register row 83). The arc arm used to slerp the
// composed matrix, which takes the SHORT arc: at 190/270/400 degrees it turned
// the wrong way (1.04 m off). 90 degrees is the control both laws agree on.
// Rig and readback: tests/fixtures/soft_rotate_any_angle.json.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.format : format;
import std.json;
import std.math : fabs, fmax;

void main() {}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "`" ~ s ~ "` failed: " ~ j.toString);
}

// Arms the swirl rig at `angleDeg` and applies it; returns the WORLD positions.
// A layer turned by `rot` and scaled by `scl` holds the rig points mapped back
// through its matrix, so the world scene is the fixture's on every layer.
double[3][] swirl(JSONValue rig, double angleDeg, double[3] rot = [0, 0, 0],
                  double scl = 1) {
    auto piv = rig["pivot"].array;
    cmd(commandBody("scene.reset", `{"empty":true}`));
    foreach (i, ax; ["x", "y", "z"]) {
        cmd(format("layer.attr 0 rot.%s %.9g", ax, rot[i]));
        cmd(format("layer.attr 0 scl.%s %.9g", ax, scl));
    }
    double[16] m;
    foreach (i, e; getJson("/api/layers")["layers"].array[0]["xform"]["matrix"].array)
        m[i] = e.get!double;
    // The linear part is scl x rotation: its inverse is the transpose / scl^2.
    string local = "[";
    foreach (vi, pt; rig["points"].array) {
        double[3] l;
        foreach (r; 0 .. 3) {
            l[r] = 0;
            foreach (c; 0 .. 3) l[r] += m[r * 4 + c] * pt.array[c].get!double / (scl * scl);
        }
        local ~= format("%s[%.9g,%.9g,%.9g]", vi ? "," : "", l[0], l[1], l[2]);
    }
    cmd(commandBody("scene.loadMesh", format(`{"vertices":%s],"faces":%s}`,
        local, rig["faces"].toString)));
    cmd("history.clear");
    cmd("tool.set xfrm.swirl on");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0,0,0"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);
    foreach (i, ax; ["X", "Y", "Z"])
        cmd(format("tool.pipe.attr actionCenter userPlaced%s %.6f",
                   ax, piv[i].get!double));
    cmd(format("tool.attr xfrm.swirl RX %.9g", angleDeg));
    cmd("tool.doApply");
    // Measured: the arm and the apply, one row each.
    assert(getJson("/api/history")["undo"].array.length == 2,
        "expected the arm + apply rows: " ~ getJson("/api/history").toString);
    cmd("tool.set xfrm.swirl off");
    double[3][] world;
    foreach (v; getJson("/api/model")["vertices"].array) {
        double[3] w = 0;
        foreach (r; 0 .. 3) foreach (c; 0 .. 3)
            w[r] += m[c * 4 + r] * v.array[c].get!double;
        world ~= w;
    }
    return world;
}

double worstOff(double[3][] got, JSONValue cell) {
    assert(got.length == cell["after"].array.length, "vertex count changed");
    double worst = 0;
    foreach (vi, want; cell["after"].array)
        foreach (c; 0 .. 3)
            worst = fmax(worst, fabs(got[vi][c] - want.array[c].get!double));
    return worst;
}

unittest {
    enum string json = import("fixtures/soft_rotate_any_angle.json");
    auto fx = parseJSON(json);
    auto rig = fx["rig"];
    assert(rig["points"].array.length == 10 && fx["cells"].array.length == 4,
        "the fixture lost its ten-point rig or one of its four cells");

    string red;
    foreach (cell; fx["cells"].array) {
        const string id = cell["cell"].str;
        const double worst = worstOff(swirl(rig, cell["angle_deg"].get!double), cell);
        // The 90-degree control must hold before any wide-angle cell is read.
        assert(id != "KF_F4c" || worst < 1e-4,
            format("control KF_F4c (90 deg) off by %.6f m", worst));
        if (worst >= 1e-4)
            red ~= format(" %s (%g deg) off by %.6f m;", id,
                          cell["angle_deg"].get!double, worst);
    }
    assert(red.length == 0, "R(w*theta) violated:" ~ red);
}

unittest { // KF_F4a on a turned, scaled layer: the arc is written in the
           // layer's own space, so the WORLD result is the fixture's.
    auto fx = parseJSON(import("fixtures/soft_rotate_any_angle.json"));
    auto cell = fx["cells"].array[1];
    assert(cell["cell"].str == "KF_F4a", "the fixture reordered its cells");
    const double worst = worstOff(
        swirl(fx["rig"], cell["angle_deg"].get!double, [30, -50, 20], 1.5), cell);
    assert(worst < 1e-4, format("KF_F4a on a turned layer off by %.6f m", worst));
}
