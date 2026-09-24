// Which selection doors pair a mirror partner under symmetry X (task 7143 —
// the R half of wave slice S3b; the fix is task 7144).
//
// The captured law (tests/fixtures/symmetry_selection_time_laws.json): a
// partner joins the selection only through a POINTER gesture — a click, a
// Shift/Ctrl click (deselecting drops the partner too), a right-button region
// gesture, an edge or polygon click, a double-click loop. Script and command
// doors (`select.element`, `mesh.select`, `select.expand`) never pair.
//
// One block per door: a floor on the selection before, then the verdict set.
// The capture's selection lists are CAPTURE indices; they are translated
// through the fixture's index_map (or matched by position where the cell
// records positions). The motions of these cells are not repeated here, with
// one exception: the double-click loop, whose two loops cross the plane and so
// discriminate the authoring frame on edges.
//
// Law checks are collected; the file ends with one assert listing the red ones
// (tests/symmetry_selection_helpers.d).

import symmetry_selection_helpers;
import http_client : getJson;

import std.algorithm : sort, all;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;

void main() {}

enum V3 V6 = [0.5, 0.5, 0.5];
enum V3 V7 = [-0.5, 0.5, 0.5];
enum V3 V2 = [0.5, 0.5, -0.5];

int[] sorted(int[] a) { auto b = a.dup; b.sort(); return b; }

int[] mapped(JSONValue list) {
    int[] r;
    foreach (v; list.array) r ~= mapIndex(v.integer);
    return sorted(r);
}

void door(string name, int[] got, int[] want) {
    law(sorted(got) == sorted(want),
        format("%s selection with symmetry X gave %s, expected %s", name, sorted(got), sorted(want)));
}

/// Vertex positions of the selected edges (each edge as its two endpoints).
V3[2][] selectedEdgePoints() {
    auto m = getJson("/api/model");
    auto vs = m["vertices"].array;
    V3[2][] r;
    foreach (e; selE()) {
        auto ed = m["edges"].array[e].array;
        r ~= [vec(vs[ed[0].integer]), vec(vs[ed[1].integer])];
    }
    return r;
}

void blockClick() {
    // Control: a vertex click pairs.
    rig();
    symmetry(true);
    assert(selV().length == 0, "rig: selection not empty before the click");
    click(V6);
    door("vertex click", selV(), [6, 7]);
}

void blockScript() {
    auto c = cell("C-script");
    foreach (action; ["set", "add"]) {
        rig();
        symmetry(true);
        assert(selV().length == 0, "rig: selection not empty before select.element");
        cmd("select.element vertex " ~ action ~ " 6");
        door("select.element " ~ action, selV(), mapped(c["index_command_" ~ action]));
    }
    rig();
    symmetry(true);
    assert(selV().length == 0, "rig: selection not empty before mesh.select");
    selectVerts([6]);
    door("mesh.select", selV(), mapped(c["scripting_api_select"]));
}

void blockDesel() {
    auto c = cell("C-desel");
    rig();
    symmetry(true);
    click(V6);
    door("C-desel click", selV(), mapped(c["after_click"]));
    click(V2, KMOD_LSHIFT);
    door("C-desel Shift-click", selV(), mapped(c["after_shift_click"]));
    click(V7, KMOD_LCTRL);
    door("C-desel Ctrl-click", selV(), mapped(c["after_ctrl_click"]));
}

void blockLasso() {
    auto c = cell("C-lasso");
    rig();
    symmetry(true);
    assert(selV().length == 0, "rig: selection not empty before the region gesture");
    lasso(V2);
    door("C-lasso region", selV(), mapped(c["selection"]));
}

void blockEdge() {
    // Edge click on the top edge at x = +0.5: its mirror edge joins.
    auto c = cell("C-edge");
    rig();
    cmd("select.typeFrom edge");
    symmetry(true);
    click([0.5, 0.5, 0.0]);
    auto pts = selectedEdgePoints();
    immutable size_t want = c["selection"].array.length;
    bool plus, minus;
    foreach (e; pts) {
        if (e[0][0] > 0.4 && e[1][0] > 0.4 && abs(e[0][1] - 0.5) < 1e-5 && abs(e[1][1] - 0.5) < 1e-5) plus = true;
        if (e[0][0] < -0.4 && e[1][0] < -0.4 && abs(e[0][1] - 0.5) < 1e-5 && abs(e[1][1] - 0.5) < 1e-5) minus = true;
    }
    law(pts.length == want && plus && minus,
        format("C-edge edge click selection with symmetry X gave %s, expected the x=+0.5 top edge and its mirror",
               pts));
    cmd("select.typeFrom vertex");
}

void blockPoly() {
    // Polygon click on the +X face: the -X face joins.
    auto c = cell("C-poly");
    rig();
    cmd("select.typeFrom polygon");
    symmetry(true);
    click([0.5, 0.0, 0.0]);
    auto m = getJson("/api/model");
    auto vs = m["vertices"].array;
    bool plus, minus;
    auto faces = selF();
    foreach (f; faces) {
        double[] xs;
        foreach (vi; m["faces"].array[f].array) xs ~= vec(vs[vi.integer])[0];
        if (xs.all!(x => abs(x - 0.5) < 1e-5)) plus = true;
        if (xs.all!(x => abs(x + 0.5) < 1e-5)) minus = true;
    }
    law(faces.length == c["selection"].array.length && plus && minus,
        format("C-poly polygon click selection with symmetry X gave faces %s, expected the +X face and the -X face",
               faces));
    cmd("select.typeFrom vertex");
}

void blockLoop() {
    // Double-click loop at x = +0.25 on a 4-segment cube: both loops (8 edges).
    auto c = cell("C-loop");
    cubeRig(4);
    cmd("select.typeFrom edge");
    symmetry(true);
    click([0.25, 0.5, 0.0]);
    click([0.25, 0.5, 0.0], 0, 2);
    auto pts = selectedEdgePoints();
    bool onBothLoops = pts.length > 0;
    foreach (e; pts) foreach (p; e) onBothLoops = onBothLoops && abs(abs(p[0]) - 0.25) < 1e-5;
    law(pts.length == c["selected_edges"].array.length && onBothLoops,
        format("C-loop double-click selection with symmetry X gave %d edges %s, expected %d edges on x = +-0.25",
               pts.length, pts, c["selected_edges"].array.length));

    // The move of the selected loops, one-block door (A = -X: the -X loop on A).
    // A segmented cube: matched by position only (index_map is the 8-vertex cube's).
    int[string] ours;
    foreach (key, rec; c["moved"].object) ours[key] = near(vec(rec["before"]));
    assert(ours.length == 8, "rig: C-loop moves 8 vertices");
    cmd("select.typeFrom vertex");
    cmd("select.element vertex set " ~ ours.values.to!(string[]).join(" "));
    assert(selV().length == 8, format("rig: the loop's vertex selection is %s", selV()));
    sideFloor(-1, "C-loop move: fresh session");
    meshTranslate([0.4, 0, 0]);
    auto v = verts();
    bool ok = true;
    double negGot = double.nan, posGot = double.nan, negWant = double.nan, posWant = double.nan;
    foreach (key, rec; c["moved"].object) {
        V3 before = vec(rec["before"]), after = vec(rec["after"]);
        ok = ok && near3(v[ours[key]], after);
        if (before[0] < 0) { negGot = v[ours[key]][0]; negWant = after[0]; }
        else               { posGot = v[ours[key]][0]; posWant = after[0]; }
    }
    law(ok, format("double-click loop move: -X loop %.4f, +X loop %.4f, expected %.2f/%.2f",
                   negGot, posGot, negWant, posWant));
}

void blockExpand() {
    // select.expand after a click made with symmetry OFF does not pair.
    auto c = cell("C-expand");
    cubeRig(4);
    click(V6);
    assert(selV().length == c["after_click"].array.length,
        format("rig: the click (symmetry off) selected %s", selV()));
    symmetry(true);
    cmd("select.expand");
    auto s = selV();
    auto v = verts();
    law(s.length == c["after_expand"].array.length && s.all!(i => v[i][0] > 0),
        format("select.expand selection with symmetry X gave %s, expected %d vertices, all x > 0",
               s, c["after_expand"].array.length));
}

unittest {
    blockClick();
    blockScript();
    blockDesel();
    blockLasso();
    blockEdge();
    blockPoly();
    blockLoop();
    blockExpand();
    cmd("tool.pipe.attr symmetry enabled false");
    lawSummary("test_symmetry_selection_doors", 13);
    sideFloorSummary("test_symmetry_selection_doors", 1);
}
