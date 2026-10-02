// test_viewport_surface_order.d — the frame order of the backdrop pass (task
// 9060, model M4): outside the item sequence every face pass precedes every
// line pass, so a translucent backdrop wire in front of a primary face blends
// OVER that face; inside the item sequence (retopology) each backdrop layer's
// wire stays right after its faces, so the captured per-item frame is
// unchanged. Plus the probe's `buffer=` channel (D3).
//
// RELATIONAL cells only: every prediction is built from pixels probed in the
// same run with the layers in question moved out of the view (pos.x 1000), so
// the cells survive any later change of colours, lighting or dim factors.
// Rigs: OPEN quads, front orthographic camera, pointer parked off the mesh.
module test_viewport_surface_order;

import http_client : getJson, postJson, quiesce, frameFence, waitPlaybackProcessed;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import std.json;
import std.format : format;
import std.math : abs, round;
import std.algorithm : max;
import std.stdio : writefln;

void main() {}

private void settle() { quiesce(); frameFence(null, 2); }
private void cmdOk(string body) {
    auto r = postJson("/api/command", body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ body ~ " -> " ~ r.toString);
}
private void cmd(string id, string params) { cmdOk(commandBody(id, params)); settle(); }

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "expected a number, got " ~ v.toString);
    }
}
private bool jb(JSONValue v) {
    assert(v.type == JSONType.true_ || v.type == JSONType.false_,
        "expected a bool, got " ~ v.toString);
    return v.type == JSONType.true_;
}

// ---------------------------------------------------------------------------
// Rig geometry: axis-aligned quads at a depth z (counter-clockwise from +Z).
// ---------------------------------------------------------------------------
private struct Quad { double x0, y0, x1, y1, z; }

private JSONValue meshJson(Quad[] qs) {
    JSONValue[] verts, faces;
    foreach (v; qs) {
        long[] f;
        foreach (p; [[v.x0, v.y0], [v.x1, v.y0], [v.x1, v.y1], [v.x0, v.y1]]) {
            verts ~= JSONValue([p[0], p[1], v.z]);
            f ~= cast(long)(verts.length - 1);
        }
        faces ~= JSONValue(f);
    }
    return JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
}

private Viewport frontOrtho() {
    cmdOk("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0",
        `{"focus":{"x":0,"y":0,"z":0},"distance":9}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    settle();
    auto cam = getJson("/api/camera?viewport=0");
    assert(cam["projKind"].str != "Perspective" && cam["viewPreset"].str == "Front",
        "rig: the cell must be in the orthographic Front view: " ~ cam.toString);
    auto vp = viewportFromCameraMatrices();
    assert(vp.proj[15] != 0.0f, "rig: the Front view must be orthographic");
    return vp;
}

private int[2] toPx(double x, double y, double z, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) x, cast(float) y, cast(float) z), vp, px, py),
        "rig point projects behind the camera");
    int[2] p = [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
    assert(p[0] > 10 && p[1] > 10 && p[0] < vp.width - 10 && p[1] < vp.height - 10,
        format("rig: (%s,%s,%s) projects to %s, outside the cell", x, y, z, p));
    return p;
}

private void parkPointer(ref Viewport vp) {
    string log = format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}`, vp.x, vp.y, vp.width, vp.height) ~ "\n";
    foreach (i; 0 .. 3)
        log ~= format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
            ~ `"state":0,"mod":0}`, 30 + i * 20, vp.x + vp.width - 8,
            vp.y + vp.height - 8) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert(pr["status"].str == "success", "park: /api/play-events failed: " ~ pr.toString);
    waitPlaybackProcessed();
    settle();
}

// ---------------------------------------------------------------------------
// Probing
// ---------------------------------------------------------------------------
private struct Px { int[3] c; }

private string pointsArg(int[2][] pts) {
    string s;
    foreach (k, p; pts) s ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
    return s;
}

private Px[] probe(int[2][] pts) {
    auto j = getJson("/api/viewport/probe?cell=0&points=" ~ pointsArg(pts));
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(jb(j["renders"]), "the probed cell is not rendered; every reading is void");
    Px[] o;
    foreach (e; j["points"].array) {
        assert("error" !in e, "probe point unreadable: " ~ e.toString);
        o ~= Px([cast(int) e["r"].integer, cast(int) e["g"].integer, cast(int) e["b"].integer]);
    }
    assert(o.length == pts.length);
    return o;
}

private int maxDiff(Px a, Px b) {
    int m = 0;
    foreach (k; 0 .. 3) m = max(m, abs(a.c[k] - b.c[k]));
    return m;
}
private int maxDiffD(Px a, double[3] b) {
    double m = 0;
    foreach (k; 0 .. 3) m = max(m, abs(a.c[k] - b[k]));
    return cast(int) round(m);
}

private double layerPosX(int i) {
    return num(getJson("/api/layers")["layers"].array[i]["xform"]["pos"].array[0]);
}

/// The pixels at `pts` with layers `idx` moved out of the view and back.
private Px[] under(int[2][] pts, int[] idx) {
    foreach (i; idx) {
        assert(layerPosX(i) == 0.0, format("under: layer %d must start at pos.x 0", i));
        cmdOk(format("layer.attr %d pos.x 1000", i));
    }
    settle();
    foreach (i; idx) assert(layerPosX(i) == 1000.0, format("under: layer %d did not move", i));
    auto u = probe(pts);
    foreach (i; idx) cmdOk(format("layer.attr %d pos.x 0", i));
    settle();
    foreach (i; idx) assert(layerPosX(i) == 0.0, format("under: layer %d did not come back", i));
    return u;
}

/// A 1x9 vertical column of pixels centred on `p`.
private int[2][] column(int[2] p) {
    int[2][] o;
    foreach (dy; -4 .. 5) o ~= [p[0], p[1] + dy];
    return o;
}

/// The row of the column where `shown` deviates most from `without`.
private size_t wireRow(Px[] shown, Px[] without) {
    size_t best = 0;
    foreach (i; 0 .. shown.length)
        if (maxDiff(shown[i], without[i]) > maxDiff(shown[best], without[best])) best = i;
    return best;
}

private JSONValue cellPlan() {
    return getJson("/api/viewport/display")["cells"].array[0]["plan"];
}

private void loadLayers(Quad[][] content) {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));
    foreach (i, qs; content) {
        if (i > 0) cmdOk(`{"id":"layer.add"}`);
        cmdOk(commandBody("scene.loadMesh", meshJson(qs).toString));
    }
}

private void restoreDisplay() {
    postJson("/api/command", commandBody("viewport.retopology", `{"value":"off"}`));
    postJson("/api/command", commandBody("viewport.backdropStyle", `{"value":"same"}`));
    postJson("/api/command", commandBody("viewport.displayStyle", `{"style":"shaded"}`));
    postJson("/api/command", commandBody("viewport.wireAlpha", `1.0`));
    postJson("/api/command", "viewport.view Perspective");
}

// ===========================================================================
// (e) the named intended change: a translucent backdrop wire in front of the
// primary's face blends over it
// ===========================================================================
// Same-as-active backdrop + Solid style: the backdrop runs NO face pass but
// draws its wire at the active slot's alpha (0.5) — the one configuration
// where a translucent backdrop wire sits in front of a primary face with
// nothing of its own behind it. Layer 0 (primary): a quad at z = 0 over
// x,y in [-1, 1]. Layer 1 (backdrop): a quad at z = +0.5 whose top edge
// (y = 0.33) runs from x = -0.4 (over the primary's face) to x = 2.4 (over
// the empty view); the probes sit at x = 0.27 (inner) and x = 1.83 (outer).
// Off-integer coordinates keep every probe off the grid's axis lines.
//   bg    background, no wire          P_out  the wire over the background
//   F     primary face, backdrop gone  P_in   the inner wire pixel, all shown
// W = 2 P_out - bg (the dimmed wire colour; P_out = a W + (1-a) bg, a = 0.5).
// Before task 9060 the wire was drawn before the primary's face, wrote depth,
// and the face failed the depth test there: P_in == P_out. Now the faces come
// first: P_in == 0.5 W + 0.5 F. Tolerance 2 (8-bit quantisation of two reads
// propagated through W).
unittest {
    loadLayers([[Quad(-1, -1, 1, 1, 0)], [Quad(-0.4, -1.8, 2.4, 0.33, 0.5)]]);
    cmdOk(`{"id":"layer.select","index":0,"mode":"set"}`);
    scope (exit) restoreDisplay();
    auto vp = frontOrtho();
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    cmd("viewport.displayStyle", `{"style":"solid"}`);
    cmd("viewport.wireOverlay", `{"overlay":"uniform"}`);
    cmd("viewport.wireAlpha", `0.5`);
    parkPointer(vp);
    {
        auto L = getJson("/api/layers");
        assert(L["active"].integer == 0 && jb(L["layers"].array[1]["background"]),
            "rig e: layer 0 must be the primary and layer 1 background: " ~ L.toString);
        auto b = cellPlan()["backdrop"];
        assert(!jb(b["drawFaces"]) && jb(b["drawWire"]) && abs(num(b["wireAlpha"]) - 0.5) < 1e-6,
            "rig e premise: the backdrop draws no faces and a 0.5 wire: " ~ b.toString);
    }
    auto inner = column(toPx(0.27, 0.33, 0.5, vp));
    auto outer = column(toPx(1.83, 0.33, 0.5, vp));
    auto shown = probe(inner ~ outer);
    auto gone  = under(inner ~ outer, [1]);
    immutable size_t ri = wireRow(shown[0 .. 9], gone[0 .. 9]);
    immutable size_t ro = 9 + wireRow(shown[9 .. 18], gone[9 .. 18]);
    immutable Px pIn = shown[ri], F = gone[ri], pOut = shown[ro], bg = gone[ro];
    writefln("  e bg %s P_out %s F %s P_in %s (rows %d, %d)", bg.c, pOut.c, F.c, pIn.c, ri, ro - 9);
    // Floors first: the wire exists (also the witness that the upkeep feeds a
    // wire when the backdrop draws no faces), and face and background differ,
    // so the two predictions are >= 10 apart.
    assert(maxDiff(pOut, bg) >= 10,
        format("e floor: no backdrop wire over the background (P_out %s, bg %s)", pOut.c, bg.c));
    assert(maxDiff(F, bg) >= 20,
        format("e floor: the primary face %s is too close to the background %s", F.c, bg.c));
    double[3] pred;
    foreach (k; 0 .. 3) pred[k] = 0.5 * (2.0 * pOut.c[k] - bg.c[k]) + 0.5 * F.c[k];
    assert(maxDiffD(pIn, pred) <= 2,
        format("e: the inner wire pixel reads %s, predicted %s = 0.5 W + 0.5 F (the wire over "
               ~ "the face); %s would be the wire depth-occluding the face (P_out, the order "
               ~ "before task 9060)", pIn.c, pred, pOut.c));
}

// ===========================================================================
// (f) the retopology (item-sequence) frame keeps the backdrop wire inline
// ===========================================================================
// Retopology on, backdrop style Wireframe (does not join the sequence).
// Layer 0 = P (primary, a small quad off to the left), layer 1 = B (background:
// a quad whose top edge y = 0.33 runs under I), layer 2 = I (foreground item,
// index above P's, so it draws BEFORE the primary on its own depth clear).
// X = B's wire under I's face (I translucent, alpha a from the plan).
//   P_shown all visible, P_noB B moved away, P_noI I moved away, bg both away.
// Inline (today): B's wire is drawn before I, and I blends over it:
//   P_shown - P_noB == (1 - a)(P_noI - bg)        (I's colour cancels)
// The two mutated outcomes of deferring the wire: depth-rejected behind I
// (P_shown = P_noB) and drawn over I (P_shown = P_noI) — each >= 6 levels away.
unittest {
    loadLayers([[Quad(-2.6, -0.4, -2.0, 0.4, 0)], [Quad(-1.4, -1.6, 1.4, 0.33, 0)],
                [Quad(-0.8, -0.8, 0.8, 0.8, 0.5)]]);
    cmdOk(`{"id":"layer.select","index":0,"mode":"set"}`);
    cmdOk(`{"id":"layer.select","index":2,"mode":"add"}`);
    cmdOk("select.typeFrom polygon");
    scope (exit) restoreDisplay();
    auto vp = frontOrtho();
    cmd("viewport.displayStyle", `{"style":"shaded"}`);
    cmd("viewport.backdropStyle", `{"value":"wireframe"}`);
    cmd("viewport.retopology", `{"value":"on"}`);
    parkPointer(vp);
    double a;
    {
        auto L = getJson("/api/layers");
        auto ls = L["layers"].array;
        assert(ls.length == 3 && L["active"].integer == 0
            && jb(ls[1]["background"]) && jb(ls[2]["foreground"]) && !jb(ls[2]["primary"]),
            "rig f: P = 0 primary, B = 1 background, I = 2 foreground: " ~ L.toString);
        auto p = cellPlan();
        assert(jb(p["active"]["clearDepthFirst"]) && !jb(p["backdrop"]["joinsItemSequence"])
            && !jb(p["backdrop"]["drawFaces"]) && jb(p["backdrop"]["drawWire"]),
            "rig f premise: item sequence on, a wire-only backdrop outside it: " ~ p.toString);
        a = num(p["active"]["faceAlpha"]);
        assert(a > 0.05 && a < 0.95, format("rig f premise: the item is translucent (a = %s)", a));
    }
    auto col = column(toPx(0.27, 0.33, 0.0, vp));
    auto noI = under(col, [2]);
    auto bgC = under(col, [1, 2]);
    immutable size_t r = wireRow(noI, bgC);
    int[2][] X = [col[r]];
    immutable Px pShown = probe(X)[0], pNoB = under(X, [1])[0], pNoI = noI[r], bg = bgC[r];
    writefln("  f a %.3f bg %s P_noI %s P_noB %s P_shown %s (row %d)", a, bg.c, pNoI.c, pNoB.c,
             pShown.c, r);
    assert(maxDiff(pNoI, bg) >= 20,
        format("f floor: no backdrop wire at X (P_noI %s, bg %s)", pNoI.c, bg.c));
    double[3] pred;
    foreach (k; 0 .. 3) pred[k] = pNoB.c[k] + (1 - a) * (pNoI.c[k] - bg.c[k]);
    // Discrimination: each mutated outcome is >= 6 levels from the prediction.
    immutable int dRejected = maxDiffD(pNoB, pred), dOver = maxDiffD(pNoI, pred);
    writefln("  f prediction %s; depth-rejected at %d, drawn-over at %d levels", pred, dRejected, dOver);
    assert(dRejected >= 6 && dOver >= 6,
        format("f floor: a mutated outcome is within 6 levels of the prediction "
               ~ "(depth-rejected %d, drawn-over %d)", dRejected, dOver));
    assert(maxDiffD(pShown, pred) <= 2,
        format("f: X reads %s, predicted %s = P_noB + (1-a)(P_noI - bg); %s would be the wire "
               ~ "rejected behind I, %s the wire drawn over I (moved out of the item sequence)",
               pShown.c, pred, pNoB.c, pNoI.c));
}

// ===========================================================================
// D3: the probe's buffer channel
// ===========================================================================
unittest {
    cmdOk(commandBody("scene.reset"));
    cmdOk(commandBody("viewport.layout", `"Single"`));
    settle();
    auto def = getJson("/api/viewport/probe?cell=0&points=20,20;40,30");
    auto col = getJson("/api/viewport/probe?cell=0&points=20,20;40,30&buffer=color");
    assert("error" !in def && def["points"].array.length == 2, "probe: " ~ def.toString);
    assert(def.toString == col.toString,
        format("buffer=color must equal the default probe: %s vs %s", def, col));
    // No slice allocates the G-buffer yet: the channel reports so, not zeros.
    auto g = getJson("/api/viewport/probe?cell=0&points=20,20&buffer=gbuf");
    assert("error" in g && g["error"].str == "gbuf not allocated",
        "buffer=gbuf before allocation must report the error: " ~ g.toString);
}
