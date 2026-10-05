// The work-plane symmetry plane (task 9414): ONE plane per app state for every
// axis — the axis plane at the offset in work-plane-LOCAL space, mapped to world
// by W once: normal R·e_axis through o + offset·R·e_axis (R = Rz·Rx·Ry, Y
// first). Flag off: the world plane. Frozen capture
// tests/fixtures/symmetry_workplane_plane.json (11 cases: axis X under two
// planes and a plane-local offset, axes Y and Z under two rotations, two
// flag-off controls). An axis-Y case alone cannot fail on the old
// WORK-PLANE-ITSELF body (R·e_y IS the work plane's normal): X and Z cases are
// the witnesses.
//
// Each case: a mesh of lone vertices = v plus v mirrored by every candidate
// plane, so the partner the selection CLICK pairs names the plane; then the
// published plane against the law; then a Move haul of the pair, whose partner
// delta must be the source delta reflected about the law normal (the haul runs
// along the projected normal, so the reflection differs from the delta itself).
// Law checks are collected and listed together (tests/symmetry_selection_helpers.d).

import symmetry_selection_helpers;
import http_client : getJson, postJson;
import drag_helpers : fetchCamera;

import std.algorithm : sort;
import std.format : format;
import std.json;
import std.math : abs, sqrt, round;

void main() {}

double dot3(V3 a, V3 b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
V3 sub3(V3 a, V3 b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
double maxAbs(V3 a, V3 b) {
    double m = 0;
    foreach (k; 0 .. 3) m = abs(a[k] - b[k]) > m ? abs(a[k] - b[k]) : m;
    return m;
}

string vlist(JSONValue a) {
    string s = "[";
    foreach (i, v; a.array) {
        auto p = vec(v);
        s ~= format("%s[%.9g,%.9g,%.9g]", i ? "," : "", p[0], p[1], p[2]);
    }
    return s ~ "]";
}

void runCase(JSONValue c, double tol) {
    immutable string id = c["case"].str;
    auto wp = c["work_plane"], sy = c["symmetry"];
    const V3 n = vec(c["law_plane"]["normal"]), lp = vec(c["law_plane"]["point"]);
    const size_t nv = c["vertices"].array.length;
    immutable int vi = cast(int) c["source_index"].integer;

    rig();
    cmd(`{"id":"scene.loadMesh","params":{"vertices":` ~ vlist(c["vertices"]) ~ `,"faces":[]}}`);
    auto before = verts();
    assert(before.length == nv, format("rig %s: loaded %d vertices, expected %d", id, before.length, nv));
    const V3 cen = vec(wp["centre"]), rot = vec(wp["rotation_xyz_deg"]);
    cmd(format("workplane.edit cenX:%.9g cenY:%.9g cenZ:%.9g rotX:%.9g rotY:%.9g rotZ:%.9g",
               cen[0], cen[1], cen[2], rot[0], rot[1], rot[2]));
    cmd("tool.pipe.attr symmetry axis " ~ sy["axis"].str);
    cmd(format("tool.pipe.attr symmetry offset %.9g", num(sy["offset"])));
    cmd("tool.pipe.attr symmetry useWorkplane " ~ (sy["use_work_plane"].boolean ? "true" : "false"));
    symmetry(true);

    // Frame the rig: focus on its centroid, a generic perspective direction.
    V3 mid = [0, 0, 0];
    double rad = 0;
    foreach (p; before) foreach (k; 0 .. 3) mid[k] += p[k] / nv;
    foreach (p; before) { auto d = sub3(p, mid); rad = sqrt(dot3(d, d)) > rad ? sqrt(dot3(d, d)) : rad; }
    void camera(double az, double el) {
        auto cr = postJson("/api/camera", format(`{"azimuth":%g,"elevation":%g,"distance":%.6g,"focus":[%.9g,%.9g,%.9g]}`,
                                                 az, el, 3.2 * rad + 1.0, mid[0], mid[1], mid[2]));
        assert("error" !in cr, "rig " ~ id ~ ": /api/camera " ~ cr.toString);
        settle();
    }
    camera(0.6, 0.45);
    const int[2] pv = px(before[vi]);
    foreach (i, p; before) if (i != vi) {
        const int[2] q = px(p);
        assert((q[0] - pv[0]) ^^ 2 + (q[1] - pv[1]) ^^ 2 >= 15 * 15,
               format("rig %s: vertex %d projects %s px from v — the click would be ambiguous", id, i,
                      sqrt(cast(double) ((q[0] - pv[0]) ^^ 2 + (q[1] - pv[1]) ^^ 2))));
    }

    // 1. The published plane is the law's.
    auto s = getJson("/api/toolpipe/eval")["symmetry"];
    const V3 gotN = vec(s["planeNormal"]), gotP = vec(s["planePoint"]);
    law(maxAbs(gotN, n) <= tol && maxAbs(gotP, lp) <= tol,
        format("%s: published plane %s through %s, law %s through %s", id, fmt(gotN), fmt(gotP), fmt(n), fmt(lp)));

    // 2. The selection click pairs the partner the law names.
    click(before[vi]);
    int[] sel = selV().dup;
    sel.sort();
    int[] want;
    foreach (x; c["selected_after"].array) want ~= cast(int) x.integer;
    law(sel == want, format("%s: the click on v%d selected %s, expected %s", id, vi, sel, want));
    bool hasV;
    foreach (x; sel) hasV |= x == vi;
    assert(hasV, format("rig %s: the click on v%d selected %s — v is not in it", id, vi, sel));
    immutable int pi = want[0] == vi ? want[1] : want[0];

    // 3. A Move haul of the pair: the partner delta = the source delta reflected about n.
    // The haul runs along the projected normal; a view whose drag plane leaves
    // the normal out is undone and the next view tried (the click above stays).
    V3[] after;
    V3 dv, dp;
    foreach (view; [[0.6, 0.45], [0.6, 1.2], [1.4, 0.15]]) {
        camera(view[0], view[1]);
        cmd("tool.set move on");
        const int[2] pa = px(before[vi]);
        V3 tip = before[vi];
        foreach (k; 0 .. 3) tip[k] += 0.3 * n[k];
        const int[2] pt = px(tip);
        immutable double dx = pt[0] - pa[0], dy = pt[1] - pa[1];
        immutable double len = sqrt(dx * dx + dy * dy);
        // Press off every handle anchor (>= 60 px), on the ring of 150 px around v.
        int[2] press = [-1, -1];
        auto cam = fetchCamera();
        foreach (k; 0 .. 16) {
            import std.math : cos, sin, PI;
            const int[2] q = [pa[0] + cast(int) round(150 * cos(k * PI / 8)), pa[1] + cast(int) round(150 * sin(k * PI / 8))];
            if (q[0] < cam.vpX + 60 || q[1] < cam.vpY + 60 || q[0] > cam.vpX + cam.width - 120
                || q[1] > cam.vpY + cam.height - 120)
                continue;
            bool clear = true;
            foreach (h; handlePixels()) clear &= (h[0] - q[0]) ^^ 2 + (h[1] - q[1]) ^^ 2 >= 60 * 60;
            if (clear) { press = q; break; }
        }
        if (len >= 3 && press[0] >= 0)
            haulPx(press[0], press[1], cast(int) round(4 * dx / len), cast(int) round(4 * dy / len), 10);
        cmd("tool.set move off");
        after = verts();
        dv = sub3(after[vi], before[vi]);
        dp = sub3(after[pi], before[pi]);
        if (sqrt(dot3(dv, dv)) >= 0.02 && abs(dot3(dv, n)) >= 0.01) break;
        if (sqrt(dot3(dv, dv)) > 1e-9) cmd("history.undo");
        foreach (i, p; verts())
            assert(maxAbs(p, before[i]) <= 1e-6, format("rig %s: the undo did not restore v%d", id, i));
    }
    assert(sqrt(dot3(dv, dv)) >= 0.02 && abs(dot3(dv, n)) >= 0.01,
           format("rig %s: no view's haul moved v with a normal part (last %s, normal part %.4f)",
                  id, fmt(dv), dot3(dv, n)));
    V3 refl = dv;
    foreach (k; 0 .. 3) refl[k] -= 2 * dot3(dv, n) * n[k];
    law(maxAbs(dp, refl) <= tol,
        format("%s: partner v%d moved %s, expected the reflection %s of %s", id, pi, fmt(dp), fmt(refl), fmt(dv)));
    size_t moved;
    foreach (i; 0 .. nv) if (i != vi && i != pi && maxAbs(after[i], before[i]) > 1e-6) ++moved;
    law(moved == 0, format("%s: %d unselected vertices moved", id, moved));
}

unittest {
    auto fx = parseJSON(import("fixtures/symmetry_workplane_plane.json"));
    immutable double tol = num(fx["tolerance_m"]);
    int cases;
    foreach (c; fx["cases"].array) { runCase(c, tol); ++cases; }
    assert(cases == 11, format("fixture population %d, expected 11", cases));
    cmd("workplane.reset");
    lawSummary("test_symmetry_workplane_plane", 44);
}
