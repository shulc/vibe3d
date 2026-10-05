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

unittest {
    enum string json = import("fixtures/soft_rotate_any_angle.json");
    auto fx = parseJSON(json);
    auto rig = fx["rig"];
    auto piv = rig["pivot"].array;
    const size_t nPts = rig["points"].array.length;
    assert(nPts == 10 && fx["cells"].array.length == 4,
        "the fixture lost its ten-point rig or one of its four cells");

    string red;
    foreach (cell; fx["cells"].array) {
        const string id = cell["cell"].str;
        cmd(commandBody("scene.reset", `{"empty":true}`));
        cmd(commandBody("scene.loadMesh", format(`{"vertices":%s,"faces":%s}`,
            rig["points"].toString, rig["faces"].toString)));
        cmd("history.clear");
        cmd("tool.set xfrm.swirl on");
        cmd("tool.pipe.attr falloff type radial");
        cmd("tool.pipe.attr falloff shape linear");
        cmd(`tool.pipe.attr falloff center "0,0,0"`);
        cmd(`tool.pipe.attr falloff size "1,1,1"`);
        foreach (i, ax; ["X", "Y", "Z"])
            cmd(format("tool.pipe.attr actionCenter userPlaced%s %.6f",
                       ax, piv[i].get!double));
        cmd(format("tool.attr xfrm.swirl RX %.9g", cell["angle_deg"].get!double));
        cmd("tool.doApply");
        // Measured: the arm and the apply, one row each.
        assert(getJson("/api/history")["undo"].array.length == 2,
            id ~ ": expected the arm + apply rows: " ~ getJson("/api/history").toString);
        cmd("tool.set xfrm.swirl off");

        auto got = getJson("/api/model")["vertices"].array;
        assert(got.length == nPts, id ~ ": vertex count changed");
        double worst = 0;
        foreach (vi, want; cell["after"].array)
            foreach (c; 0 .. 3)
                worst = fmax(worst, fabs(got[vi].array[c].get!double
                                         - want.array[c].get!double));
        // The 90-degree control must hold before any wide-angle cell is read.
        assert(id != "KF_F4c" || worst < 1e-4,
            format("control KF_F4c (90 deg) off by %.6f m", worst));
        if (worst >= 1e-4)
            red ~= format(" %s (%g deg) off by %.6f m;", id,
                          cell["angle_deg"].get!double, worst);
    }
    assert(red.length == 0, "R(w*theta) violated:" ~ red);
}
