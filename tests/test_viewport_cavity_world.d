// test_viewport_cavity_world.d — the world cavity of the composite stage
// (wave plan S3b, task 9240, model M4): a raw pass of taps on a three-turn
// spiral with the ridge/valley split, blurred H then V with a depth weight,
// multiplied into the resolve as `(1 - cav) (1 + edges)`.
//
// Rig: a ground slab (layer 0, top at y = 0.02, a Shaded backdrop) and a
// 3×3×3 box standing on it (layer 1, the primary) whose top-centre polygon is
// bevelled INTO a square pit (inset 0.05, shift −0.25), smooth OFF, Shaded.
// Two cameras: TOP (nearly straight down, so the whole pit floor is seen) and
// LOW (the box's top back edge against the background).
// Cells: (a) the far pit-floor corner darker than the pit-floor centre;
// (b) open ground away from the box unchanged ±1, the contact darkened (the
// control); (c) the background pixel beyond a silhouette unchanged ±0, a
// grazing surface pixel inside it NOT darkened, a camera-facing one a ridge
// (≥ +4) — the signature of the background push; (blur) occlusion on the slab grows
// toward the box right up to the box's silhouette (no bleed of the bright
// box top across the depth step); (d) determinism over re-renders; (e)
// samples 1 and 64 render, 65 is refused with no history entry; (f) the pass
// record (5 bindings) and the debug postcondition; (g) world gains 0 = off,
// Screen after World reads no world term; (h) distance and attenuation reach
// the kernel, and a sub-pixel distance (every tap on the centre) = off.
// `VIBE3D_CELL=<id>` runs one cell.
module test_viewport_cavity_world;

import http_client : getJson, postJson, quiesce, frameFence;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import std.json;
import std.format : format;
import std.math : abs, round;
import std.stdio : writefln;

void main() {}

private bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

private void settle() { quiesce(); frameFence(null, 2); }
private void cmdOk(string body) {
    auto r = postJson("/api/command", body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ body ~ " -> " ~ r.toString);
}
private void cmd(string id, string params) { cmdOk(commandBody(id, params)); settle(); }
private long ji(JSONValue v) {
    return v.type == JSONType.uinteger ? cast(long) v.uinteger : v.integer;
}
private JSONValue cell0() { return getJson("/api/viewport/display")["cells"].array[0]; }

private string hash() {
    string prev = getJson("/api/viewport/probe?cell=0&hash=1")["hash"].str;
    foreach (_; 0 .. 8) {
        settle();
        auto j = getJson("/api/viewport/probe?cell=0&hash=1");
        assert(j["renders"].type == JSONType.true_, "the probed cell is not rendered; the hash is void");
        if (j["hash"].str == prev) return prev;
        prev = j["hash"].str;
    }
    assert(false, "cell 0 hash never settled");
}

private void cavity(string mode) { cmd("viewport.cavity", `{"value":"` ~ mode ~ `"}`); hash(); }

// ---------------------------------------------------------------------------
// Probes. Coordinates are cell-local, y DOWN.
// ---------------------------------------------------------------------------
alias P = int[2];
private struct G { long id, flags; }

private string ptsArg(const P[] pts) {
    string s;
    foreach (k, p; pts) s ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
    return s;
}

private int[P] levelAt(const P[] pts) {
    int[P] o;
    auto j = getJson("/api/viewport/probe?cell=0&points=" ~ ptsArg(pts));
    assert("error" !in j, "colour probe failed: " ~ j.toString);
    foreach (pt; j["points"].array) {
        assert("error" !in pt, "colour probe point failed: " ~ pt.toString);
        o[[cast(int) ji(pt["x"]), cast(int) ji(pt["y"])]] = cast(int) ji(pt["r"]);
    }
    assert(o.length == pts.length, format("colour probe returned %d of %d points", o.length, pts.length));
    return o;
}

private G[P] gbufAt(const P[] pts) {
    G[P] o;
    auto j = getJson("/api/viewport/probe?cell=0&buffer=gbuf&points=" ~ ptsArg(pts));
    assert("error" !in j, "gbuf probe failed: " ~ j.toString);
    foreach (pt; j["points"].array) {
        auto a = pt["gbuf"].array;   // [x, y, id, flags, nx, ny]
        o[[cast(int) ji(a[0]), cast(int) ji(a[1])]] = G(ji(a[2]), ji(a[3]));
    }
    assert(o.length == pts.length, format("gbuf probe returned %d of %d points", o.length, pts.length));
    return o;
}

// ---------------------------------------------------------------------------
// The rig.
// ---------------------------------------------------------------------------
private enum double kSlabTop = 0.02, kTop = kSlabTop + 1.0, kFloor = kTop - 0.25;
private enum long kSlabId = 1, kBoxId = 2;   // G-buffer id = layer index + 1

private string slabJson() {
    JSONValue[] v;
    foreach (k; 0 .. 8)
        v ~= JSONValue([(k & 1) ? 2.0 : -2.0, (k & 2) ? kSlabTop : kSlabTop - 0.1, (k & 4) ? 2.0 : -2.0]);
    auto f = JSONValue([[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3],
                        [0, 4, 6, 2], [1, 3, 7, 5]]);
    return JSONValue(["vertices": JSONValue(v), "faces": f]).toString;
}

private void rig() {
    cmdOk(commandBody("scene.reset", `{"empty":true}`));
    cmdOk(commandBody("scene.loadMesh", slabJson()));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk("prim.cube segmentsX:3 segmentsY:3 segmentsZ:3 radius:0");
    auto m = getJson("/api/model");
    auto V = m["vertices"].array, F = m["faces"].array;
    long top = -1;
    size_t hits;
    foreach (i, f; F) {
        double[3] c = 0;
        foreach (vi; f.array)
            foreach (a; 0 .. 3) {
                auto x = V[ji(vi)].array[a];
                c[a] += x.type == JSONType.float_ ? x.floating : cast(double) ji(x);
            }
        foreach (a; 0 .. 3) c[a] /= f.array.length;
        if (abs(c[0]) < 1e-6 && abs(c[1] - 0.5) < 1e-6 && abs(c[2]) < 1e-6) { top = i; ++hits; }
    }
    assert(hits == 1 && F.length == 54,
        format("rig: a 3x3x3 box has 54 faces and one top-centre face; got %d faces, %d hits", F.length, hits));
    cmdOk(format(`{"id":"mesh.select","params":{"mode":"polygons","indices":[%d]}}`, top));
    cmdOk("tool.set poly.bevel on");
    cmdOk("tool.attr poly.bevel inset 0.05");
    cmdOk("tool.attr poly.bevel shift -0.25");
    cmdOk("tool.doApply");
    cmdOk("tool.set poly.bevel off");
    cmdOk(`{"id":"mesh.select","params":{"mode":"polygons","indices":[]}}`);
    assert(ji(getJson("/api/model")["faceCount"]) == 58, "rig: the bevel must add the pit's four walls (58 faces)");
    cmdOk(format("layer.attr 1 pos.y %s", kSlabTop + 0.5));
    cmdOk("history.clear");
    cmd("viewport.layout", `"Single"`);
    cmd("viewport.displayStyle", `{"style":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    cmd("viewport.smooth", `{"value":"off"}`);
    cmd("viewport.wireOverlay", `{"value":"none"}`);
    cmd("viewport.cavityParams",
        `{"worldRidge":1,"worldValley":1,"distance":0.2,"attenuation":1,"samples":16}`);
    // The G-buffer is allocated by the first non-empty plan; every cell reads it.
    cavity("world");
}

/// TOP: nearly straight down onto the pit. LOW: the box's top back edge
/// against the background.
private Viewport camera(double elevation, double focusY) {
    auto cr = postJson("/api/camera?viewport=0",
        format(`{"focus":{"x":0,"y":%s,"z":0},"distance":4,"azimuth":0.5,"elevation":%s}`,
               focusY, elevation));
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
    return viewportFromCameraMatrices();
}
private Viewport topCamera() { return camera(1.35, kTop - 0.3); }
private Viewport lowCamera() { return camera(0.12, kTop); }

private P toPx(double x, double y, double z, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) x, cast(float) y, cast(float) z), vp, px, py),
        "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

/// The column through the pit centre, inside the cell.
private P[] pitColumn(ref Viewport vp) {
    auto sz = getJson("/api/viewport/probe?cell=0&hash=1");
    immutable int H = cast(int) sz["h"].integer;
    immutable P c = toPx(0, kFloor, 0, vp);
    P[] col;
    foreach (y; 2 .. H - 2) col ~= [c[0], y];
    return col;
}

// ===========================================================================
// (a) the far pit-floor corner is darker than the pit-floor centre.
// ===========================================================================
unittest {
    if (!cellOn("a")) return;
    rig();
    auto vp = topCamera();
    // The floor corner on the FAR side from the eye (the near walls hide the
    // near corner), 0.027 inside both walls (the floor spans ±0.1167).
    immutable double sx = vp.eye.x > 0 ? -1 : 1, sz = vp.eye.z > 0 ? -1 : 1;
    immutable P centre = toPx(0, kFloor, 0, vp), corner = toPx(sx * 0.09, kFloor, sz * 0.09, vp);
    auto g = gbufAt([centre, corner]);
    assert(g[centre].id == kBoxId && g[corner].id == kBoxId && (g[centre].flags & 1) && (g[corner].flags & 1),
        format("(a) premise: both floor pixels lie on the flagged box (centre %s, corner %s)", g[centre], g[corner]));
    auto w = levelAt([centre, corner]);
    cavity("off");
    auto o = levelAt([centre, corner]);
    writefln("  (a) centre %s off %d world %d; corner %s off %d world %d",
             centre, o[centre], w[centre], corner, o[corner], w[corner]);
    assert(abs(o[centre] - o[corner]) <= 1,
        format("(a) premise: one flat floor reads one level with cavity off (centre %d, corner %d)",
               o[centre], o[corner]));
    assert(w[corner] <= w[centre] - 3,
        format("(a) the far pit-floor corner %s must be ≥ 3 darker than the floor centre %s: corner %d centre %d",
               corner, centre, w[corner], w[centre]));
}

// ===========================================================================
// (b) open ground far from the box is unchanged ±1; the contact at the box's
// foot darkens (the control: the kernel is live on the same surface).
// ===========================================================================
unittest {
    if (!cellOn("b")) return;
    rig();
    auto vp = topCamera();
    P[] ground = [toPx(0.9, kSlabTop, 0.9, vp), toPx(-0.9, kSlabTop, 0.9, vp), toPx(0.9, kSlabTop, -0.9, vp)];
    immutable P contact = toPx(0.55, kSlabTop, 0.55, vp);
    auto pts = ground ~ contact;
    auto g = gbufAt(pts);
    foreach (p; pts)
        assert(g[p].id == kSlabId && (g[p].flags & 1),
            format("(b) premise: %s lies on the flagged slab, got %s", p, g[p]));
    auto w = levelAt(pts);
    cavity("off");
    auto o = levelAt(pts);
    size_t checked;
    foreach (p; ground) {
        assert(abs(w[p] - o[p]) <= 1,
            format("(b) open ground %s must read cavity-off ±1: world %d off %d", p, w[p], o[p]));
        ++checked;
    }
    assert(checked == 3, format("(b) population: 3 open-ground pixels, checked %d", checked));
    writefln("  (b) contact %s off %d world %d", contact, o[contact], w[contact]);
    assert(w[contact] <= o[contact] - 2,
        format("(b) control: the contact pixel %s must darken by ≥ 2 (world %d off %d)",
               contact, w[contact], o[contact]));
}

// ===========================================================================
// (c) silhouettes against the background. A background tap's sample is the
// centre pushed back by `distance` along the view axis, so it scores
// `f = -distance * N.z`: an edge on a camera-facing pixel, never a cavity.
// (c1) LOW camera, the box top's back edge: the background pixel 2 px beyond
// it carries no flags and reads cavity-off ±0; the box-top pixel 2 px inside
// it (a grazing face) is NOT darkened. (c2) TOP camera, the slab's far edge
// against the background: the slab pixel 2 px inside reads as a ridge (≥ +4)
// — without the push the background taps sit on the far plane and weigh
// nothing.
// ===========================================================================
private P firstIdFromTop(P[] col, G[P] g, long id, out ptrdiff_t at) {
    at = -1;
    foreach (i, p; col)
        if (g[p].id == id) { at = i; break; }
    return at >= 0 ? col[at] : [0, 0];
}

unittest {
    if (!cellOn("c")) return;
    rig();
    {   // (c1)
        auto vp = lowCamera();
        immutable P mid = toPx(0, kTop, 0, vp);
        P[] col;
        foreach (y; 2 .. mid[1] + 1) col ~= [mid[0], y];
        auto g = gbufAt(col);
        ptrdiff_t s;
        firstIdFromTop(col, g, kBoxId, s);
        assert(s >= 4, format("(c1) rig: the box top's back edge must lie below the top of the cell (at %d)", s));
        foreach (i; 0 .. s)
            assert(g[col[i]].id == 0, format("(c1) rig: above the box the column must be background, %s is id %d",
                                             col[i], g[col[i]].id));
        immutable P sky = col[s - 2], inside = col[s + 2];
        assert(g[sky].flags == 0 && g[inside].id == kBoxId && (g[inside].flags & 1),
            format("(c1) premise: sky flags %d, inside %s", g[sky].flags, g[inside]));
        cavity("world");
        auto w = levelAt([sky, inside]);
        cavity("off");
        auto o = levelAt([sky, inside]);
        writefln("  (c1) silhouette at %s: sky off %d world %d; inside off %d world %d",
                 col[s], o[sky], w[sky], o[inside], w[inside]);
        assert(w[sky] == o[sky], format("(c1) the background pixel %s must equal cavity-off: world %d off %d",
                                        sky, w[sky], o[sky]));
        assert(w[inside] >= o[inside] - 1,
            format("(c1) no false darkening: the grazing box-top pixel %s inside the silhouette reads world %d, "
                   ~ "off %d", inside, w[inside], o[inside]));
    }
    {   // (c2) — the G-buffer is written only by frames with a non-empty plan
        cavity("world");
        auto vp = topCamera();
        auto col = pitColumn(vp);
        auto g = gbufAt(col);
        ptrdiff_t s;
        firstIdFromTop(col, g, kSlabId, s);
        assert(s >= 3, format("(c2) rig: the slab's far edge must lie below the top of the cell (at %d)", s));
        foreach (i; 0 .. s)
            assert(g[col[i]].id == 0, format("(c2) rig: beyond the slab the column must be background, %s is id %d",
                                             col[i], g[col[i]].id));
        immutable P inside = col[s + 2];
        assert(g[inside].id == kSlabId && (g[inside].flags & 1), format("(c2) premise: inside %s", g[inside]));
        cavity("world");
        auto w = levelAt([inside]);
        cavity("off");
        auto o = levelAt([inside]);
        writefln("  (c2) slab far edge at %s: inside off %d world %d", col[s], o[inside], w[inside]);
        assert(w[inside] >= o[inside] + 4,
            format("(c2) the background push: the slab pixel %s inside its far silhouette must read as a ridge "
                   ~ "(≥ +4): world %d off %d", inside, w[inside], o[inside]));
    }
}

// ===========================================================================
// (blur) the depth-aware blur. On the pit column the slab just beyond the box
// top's far edge is occluded by the box (darker toward it), while the box top
// across the depth step is brightened (a ridge). The occlusion must keep
// growing up to the silhouette: the slab pixels 1 and 2 px from it are no
// lighter than the slab pixel 5 px from it (±1). A blur without the depth
// weight mixes the bright box top into them.
// ===========================================================================
unittest {
    if (!cellOn("blur")) return;
    rig();
    auto vp = topCamera();
    auto col = pitColumn(vp);
    auto g = gbufAt(col);
    ptrdiff_t s = -1;   // the first box pixel from the top: the far edge of the box top
    foreach (i, p; col)
        if (g[p].id == kBoxId) { s = i; break; }
    assert(s >= 8, format("(blur) rig: the box's far edge must have slab above it on the column (at %d)", s));
    immutable P r1 = col[s - 1], r2 = col[s - 2], r5 = col[s - 5], b = col[s + 1];
    foreach (p; [r1, r2, r5])
        assert(g[p].id == kSlabId && (g[p].flags & 1), format("(blur) premise: %s is flagged slab: %s", p, g[p]));
    auto w = levelAt([r1, r2, r5, b]);
    cavity("off");
    auto o = levelAt([r1, r2, r5, b]);
    writefln("  (blur) edge %s: slab r5 off %d world %d, r2 %d/%d, r1 %d/%d; box top off %d world %d",
             col[s], o[r5], w[r5], o[r2], w[r2], o[r1], w[r1], o[b], w[b]);
    assert(o[r1] == o[r5] && o[r2] == o[r5], "(blur) premise: the flat slab reads one level with cavity off");
    assert(w[r5] <= o[r5] - 3, format("(blur) premise: the slab near the box is occluded (r5 world %d off %d)",
                                      w[r5], o[r5]));
    assert(w[b] - o[b] >= 10 && w[b] - w[r1] >= 50,
        format("(blur) discrimination floor: the box top across the step is a bright ridge (world %d off %d)",
               w[b], o[b]));
    assert(w[r1] <= w[r5] + 1 && w[r2] <= w[r5] + 1,
        format("(blur) no bleed across the depth step: slab r1 %d / r2 %d must be no lighter than r5 %d (±1)",
               w[r1], w[r2], w[r5]));
}

// ===========================================================================
// (d) determinism: re-rendering the same key reproduces the frame exactly
// (the spin is a fixed per-pixel hash, no per-frame noise).
// ===========================================================================
unittest {
    if (!cellOn("d")) return;
    rig();
    topCamera();
    cavity("off");
    immutable string off = hash();
    cavity("world");
    immutable string first = hash();
    assert(first != off, "(d) control: the world cavity must change the frame");
    size_t renders;
    foreach (k; 0 .. 3) {
        immutable long before = ji(cell0()["compositeRuns"]);
        cmd("viewport.cavityParams", `{"samples":16}`);   // same value: marks the cell dirty
        frameFence(null, 3);
        assert(ji(cell0()["compositeRuns"]) > before, "(d) premise: the cell re-rendered");
        immutable string again = getJson("/api/viewport/probe?cell=0&hash=1")["hash"].str;
        assert(again == first, format("(d) re-render %d of the same key changed the frame: %s vs %s", k, again, first));
        ++renders;
    }
    assert(renders == 3, "(d) population: 3 re-renders");
}

// ===========================================================================
// (e) samples 1 and 64 both render; 65 is refused, writes nothing and
// records no history entry.
// ===========================================================================
unittest {
    if (!cellOn("e")) return;
    rig();
    topCamera();
    cavity("off");
    immutable string off = hash();
    cavity("world");
    cmd("viewport.cavityParams", `{"samples":1}`);
    immutable string one = hash();
    cmd("viewport.cavityParams", `{"samples":64}`);
    immutable string many = hash();
    assert(one != off && many != off && one != many,
        "(e) samples 1 and 64 must both render a world cavity, and differently");
    assert(ji(cell0()["state"]["cavity"]["samples"]) == 64, "(e) premise: samples 64 accepted");
    cmdOk("history.clear");
    immutable size_t undo0 = getJson("/api/history")["undo"].array.length;
    auto r = postJson("/api/command", commandBody("viewport.cavityParams", `{"samples":65}`));
    assert(r["status"].str == "error", "(e) samples 65 must be refused: " ~ r.toString);
    settle();
    assert(getJson("/api/history")["undo"].array.length == undo0, "(e) the refusal must record no history entry");
    assert(ji(cell0()["state"]["cavity"]["samples"]) == 64, "(e) the refusal must write nothing");
    assert(hash() == many, "(e) the refusal must leave the frame as it was");
}

// ===========================================================================
// (f) the pass record: World runs copy, raw, blur H, blur V, resolve, all
// into the effects FBO, onto compositeSrc, ao0, ao1, ao0, color — and the
// debug postcondition holds after them.
// ===========================================================================
unittest {
    if (!cellOn("f")) return;
    rig();
    topCamera();
    size_t modes;
    foreach (mode; ["world", "both", "screen"]) {
        cavity(mode);
        auto c = cell0();
        auto ids = c["fboIds"];
        auto b = c["compositeBindings"].array;
        immutable size_t want = mode == "screen" ? 2 : 5;
        assert(b.length == want, format("(f) %s: %d composite bindings, expected %d", mode, b.length, want));
        long[] att;
        foreach (r; b) {
            assert(ji(r["bound"]) == ji(ids["effects"]),
                format("(f) %s: a pass bound fbo %d, not the effects fbo %d", mode, ji(r["bound"]), ji(ids["effects"])));
            att ~= ji(r["attached"]);
        }
        immutable long[] wantAtt = want == 2
            ? [ji(ids["compositeSrc"]), ji(ids["color"])]
            : [ji(ids["compositeSrc"]), ji(ids["ao0"]), ji(ids["ao1"]), ji(ids["ao0"]), ji(ids["color"])];
        assert(att == wantAtt, format("(f) %s: attachments %s, expected %s", mode, att, wantAtt));
        if (c["compositeChecked"].type == JSONType.true_)
            assert(ji(c["compositeFaults"]) == 0,
                format("(f) %s: the composite postcondition failed: %s", mode, c["firstCompositeFault"]));
        ++modes;
    }
    assert(modes == 3, "(f) population: 3 modes");
}

// ===========================================================================
// (g) the world gains: ridge = valley = 0 makes World equal to off and Both
// equal to Screen; at the defaults World differs from off (the control).
// ===========================================================================
unittest {
    if (!cellOn("g")) return;
    rig();
    topCamera();
    cavity("off");
    immutable string off = hash();
    cavity("screen");
    immutable string screen = hash();
    cavity("world");
    immutable string world = hash();
    assert(world != off, "(g) control: the world cavity at its defaults must change the frame");
    cavity("both");
    immutable string both = hash();
    assert(both != world && both != screen, "(g) Both must multiply the world term with the screen term");
    cavity("screen");
    assert(hash() == screen, "(g) Screen after World must not read the world buffer left by the World frames");
    cmd("viewport.cavityParams", `{"worldRidge":0,"worldValley":0}`);
    assert(hash() == screen, "(g) Both at world gains 0 must equal Screen");
    cavity("world");
    assert(hash() == off, "(g) World at world gains 0 must equal off");
    cmd("viewport.cavityParams", `{"worldRidge":1,"worldValley":1}`);
    cavity("off");
}

// ===========================================================================
// (h) the distance and attenuation parameters reach the kernel; a distance
// whose disk is under half a pixel puts every tap on the centre pixel (zero
// length, skipped), so World equals off exactly.
// ===========================================================================
unittest {
    if (!cellOn("h")) return;
    rig();
    topCamera();
    cavity("off");
    immutable string off = hash();
    cavity("world");
    immutable string base = hash();
    assert(base != off, "(h) control: the world cavity at its defaults must change the frame");
    cmd("viewport.cavityParams", `{"distance":0.1}`);
    assert(hash() != base, "(h) distance 0.1 must change the frame from distance 0.2");
    cmd("viewport.cavityParams", `{"distance":0.2,"attenuation":20}`);
    assert(hash() != base, "(h) attenuation 20 must change the frame from attenuation 1");
    cmd("viewport.cavityParams", `{"attenuation":1}`);
    assert(hash() == base, "(h) restoring the defaults must restore the frame");
    cmd("viewport.cavityParams", `{"distance":0.0001}`);
    assert(hash() == off, "(h) a sub-pixel distance must leave every pixel as cavity-off");
    cmd("viewport.cavityParams", `{"distance":0.2}`);
}
