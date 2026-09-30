// test_retopology_preset.d — the retopology working-view preset, the
// toggle alone, per-cell reach, the template's re-seed across a layout
// switch, and which resets keep the view's display atoms (task 8620).
//
// What is pinned, and what makes each cell able to fail:
//   * the preset writes exactly five atoms into ONE cell (each read back;
//     cells 1-3 of a Quad are read untouched);
//   * arming the topology pen changes no atom and no pixel of the cell
//     (the mode is purely per view, never armed by the tool);
//   * the toggle alone leaves the default same-as-active backdrop, which then
//     draws the background as the Flat backdrop does under the mode (lit,
//     undimmed) — the mode-off control reads the dimmed value, so the probe
//     separates the two — and JOINS the item sequence (plan §10.3 7a): the
//     background at the lower index draws after the primary with no depth
//     clear, so a primary quad in front of it keeps its fill over the EMPTY
//     view and one behind it reads the background;
//   * the preset writes no template field: Single -> Quad still re-seeds
//     cell 0 to the orthographic template, with the five atoms intact;
//   * a user-visible reset (`file.new`, `scene.reset` through the UI door)
//     keeps the atoms, the test-automation reset (script `scene.reset`)
//     clears them. The keeps run first, so the clear is the last reading.
module test_retopology_preset;

import http_client : getJson, postJson, quiesce, frameFence, waitPlaybackProcessed;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import std.json;
import std.format : format;
import std.math : abs, round;
import std.algorithm : max;
import std.stdio : writeln, writefln;

void main() {}

private void settle() { quiesce(); frameFence(null, 2); }

private JSONValue cmdRaw(string body) { return postJson("/api/command", body); }

private void cmdOk(string body) {
    auto r = cmdRaw(body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ body ~ " -> " ~ r.toString);
}

private void cmd(string id, string params = null) {
    cmdOk(commandBody(id, params));
    settle();
}

private void uiCmd(string line) {
    auto r = postJson("/api/command?origin=ui", line);
    assert(r["status"].str == "ok", "UI door `" ~ line ~ "` failed: " ~ r.toString);
    settle();
}

private JSONValue cells() { return getJson("/api/viewport/display")["cells"]; }
private JSONValue cellAt(int k) { return cells().array[k]; }

private bool jb(JSONValue v) {
    assert(v.type == JSONType.true_ || v.type == JSONType.false_,
        "expected a bool, got " ~ v.toString);
    return v.type == JSONType.true_;
}

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "expected a number, got " ~ v.toString);
    }
}

/// The five atoms the preset writes, read from one cell's state.
private struct Atoms {
    bool retopology;
    string backdropStyle;
    string backdropSlot;
    bool showVertices;
    double pointSize;
}

private Atoms atomsOf(JSONValue c) {
    auto s = c["state"];
    return Atoms(jb(s["retopology"]), s["backdropStyle"].str,
                 s["backdrop"]["style"].str, jb(s["active"]["showVertices"]),
                 num(s["active"]["pointSize"]));
}

private enum Atoms kPreset  = Atoms(true, "Flat", "Shaded", true, 6.0);
private enum Atoms kDefault = Atoms(false, "SameAsActive", "Shaded", false, 0.0);

private void assertAtoms(JSONValue c, Atoms want, string label) {
    const got = atomsOf(c);
    int checked = 0;
    assert(got.retopology == want.retopology,
        format("%s: retopology %s, want %s", label, got.retopology, want.retopology));
    ++checked;
    assert(got.backdropStyle == want.backdropStyle,
        format("%s: backdropStyle %s, want %s", label, got.backdropStyle, want.backdropStyle));
    ++checked;
    assert(got.backdropSlot == want.backdropSlot,
        format("%s: backdrop slot style %s, want %s", label, got.backdropSlot, want.backdropSlot));
    ++checked;
    assert(got.showVertices == want.showVertices,
        format("%s: showVertices %s, want %s", label, got.showVertices, want.showVertices));
    ++checked;
    assert(got.pointSize == want.pointSize,
        format("%s: pointSize %s, want %s", label, got.pointSize, want.pointSize));
    ++checked;
    assert(checked == 5, label ~ ": expected five atoms");
}

private void freshSingle() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmd("viewport.layout", `"Single"`);
}

// ---------------------------------------------------------------------------
// Pixel rig: layer 0 (background) one +Z tile, layer 1 (the primary) three
// small +Z quads: D over the empty view, A in front of the tile and B behind
// it (both clear of the tile's centre, which cell 3 probes); front
// orthographic camera, shaded active style.
// ---------------------------------------------------------------------------
private immutable double[3] kBgCentre = [-1.5, 0.5, 0];
private immutable double[3] kFgCentre = [1.5, -1.0, 0.5];    // D
private immutable double[3] kACentre  = [-1.8, 0.85, 0.5];   // A, in front of the tile
private immutable double[3] kBCentre  = [-1.2, 0.85, -0.5];  // B, behind it
private enum double kFill = 0.5;                             // the mode's face alpha

private JSONValue quads(const(double[3])[] cs, double[] halves) {
    JSONValue[] verts, faces;
    foreach (i, c; cs) {
        immutable h = halves[i];
        long[] f;
        foreach (k; [[-h, -h], [h, -h], [h, h], [-h, h]]) {
            verts ~= JSONValue([c[0] + k[0], c[1] + k[1], c[2]]);
            f ~= cast(long)(verts.length - 1);
        }
        faces ~= JSONValue(f);
    }
    return JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
}
private JSONValue quad(double[3] c, double half) { return quads([c], [half]); }

private int[2] toPx(double[3] w, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) w[0], cast(float) w[1], cast(float) w[2]),
                           vp, px, py), "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

private Viewport buildPixelRig() {
    freshSingle();
    cmdOk(commandBody("scene.loadMesh", quad(kBgCentre, 0.6).toString));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh",
        quads([kFgCentre, kACentre, kBCentre], [0.3, 0.15, 0.15]).toString));
    cmdOk("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0",
        `{"focus":{"x":0,"y":0,"z":0},"distance":9}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    auto L = getJson("/api/layers");
    assert(L["layers"].array.length == 2 && L["active"].integer == 1
        && jb(L["layers"].array[0]["visible"]),
        "rig: expected a visible background layer 0 and primary layer 1: " ~ L.toString);
    auto vp = viewportFromCameraMatrices();
    assert(vp.proj[15] != 0.0f, "rig: the Front view must be orthographic");
    parkPointer(vp);
    return vp;
}

/// Move the pointer to the cell's corner, clear of every polygon, so no
/// rollover tint is drawn.
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

/// The pixels at `pts` with layers `idx` moved out of the view (pos.x 1000)
/// and back, each move read back: the value UNDER those layers, probed.
private int[3][] under(int[2][] pts, int[] idx) {
    double posX(int i) {
        return num(getJson("/api/layers")["layers"].array[i]["xform"]["pos"].array[0]);
    }
    foreach (i; idx) {
        assert(posX(i) == 0.0, format("under: layer %d must start at pos.x 0", i));
        cmdOk(format("layer.attr %d pos.x 1000", i));
    }
    settle();
    foreach (i; idx)
        assert(posX(i) == 1000.0, format("under: layer %d did not move away", i));
    int[3][] u;
    foreach (p; pts) u ~= probe(p);
    foreach (i; idx) cmdOk(format("layer.attr %d pos.x 0", i));
    settle();
    foreach (i; idx)
        assert(posX(i) == 0.0, format("under: layer %d did not come back", i));
    return u;
}

private int[3] probe(int[2] p) {
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%d,%d", p[0], p[1]));
    assert("error" !in j && jb(j["renders"]), "probe failed: " ~ j.toString);
    auto e = j["points"].array[0];
    return [cast(int) e["r"].integer, cast(int) e["g"].integer, cast(int) e["b"].integer];
}

private int maxDiff(int[3] a, int[3] b) {
    int m = 0;
    foreach (k; 0 .. 3) m = max(m, abs(a[k] - b[k]));
    return m;
}

private string hashCell() {
    auto j = getJson("/api/viewport/probe?cell=0&hash=1");
    assert("error" !in j && "hash" in j, "hash probe failed: " ~ j.toString);
    return j["hash"].toString;
}

unittest { // 1: the preset writes its five atoms, and the pen arms none of them
    freshSingle();
    assertAtoms(cellAt(0), kDefault, "1 precondition");
    cmd("viewport.retopologyPreset");
    auto c = cellAt(0);
    assertAtoms(c, kPreset, "1 preset");
    assert(!jb(c["userSet"]), "1: the preset must not claim the template: " ~ c.toString);
    immutable before = hashCell();
    cmdOk(`tool.set "mesh.topoPen" on 0`);
    settle();
    assertAtoms(cellAt(0), kPreset, "1 after arming the pen");
    immutable armed = hashCell();
    cmdOk(`tool.set "mesh.topoPen" off 0`);
    settle();
    assert(armed == before,
        "1: arming the topology pen changed the cell's pixels (" ~ before ~ " -> "
        ~ armed ~ ")");
    // And the mode OFF stays off under the pen: it never arms the view.
    freshSingle();
    cmdOk(`tool.set "mesh.topoPen" on 0`);
    settle();
    assertAtoms(cellAt(0), kDefault, "1 pen without the preset");
    cmdOk(`tool.set "mesh.topoPen" off 0`);
    settle();
}

unittest { // 2: per cell — the preset reaches one cell of a Quad
    freshSingle();
    cmd("viewport.layout", `"Quad"`);
    cmd("viewport.retopologyPreset", `{"viewport":2}`);
    auto cs = cells().array;
    assert(cs.length == 4, "2: Quad must expose four cells");
    int others = 0;
    foreach (k, c; cs) {
        if (k == 2) assertAtoms(c, kPreset, "2 cell 2");
        else { assertAtoms(c, kDefault, format("2 cell %d", k)); ++others; }
    }
    assert(others == 3, "2 floor: three untouched cells");
}

unittest { // 3: the toggle alone keeps the same-as-active backdrop, drawn as Flat
    auto vp = buildPixelRig();
    immutable int[2] bg = toPx(kBgCentre, vp);
    immutable int[3] off = probe(bg);            // mode off, same: the 0.45 dim
    cmd("viewport.retopology", `{"value":"on"}`);
    auto c = cellAt(0);
    assertAtoms(c, Atoms(true, "SameAsActive", "Shaded", false, 0.0), "3 toggle only");
    auto plan = c["plan"]["backdrop"];
    assert(jb(plan["joinsItemSequence"]) && num(plan["dim"]) == 1.0,
        "3: the toggle's backdrop plan must join the item sequence undimmed: "
        ~ plan.toString);
    immutable int[3] same = probe(bg);

    // 7a (plan §10.3) under the toggle alone: the background at the LOWER
    // index is drawn AFTER the primary with no clear, so A (in front of the
    // tile) keeps its fill over the EMPTY view — the tile fails the depth test
    // there — and B (behind the tile) reads the tile. A's own fill c is
    // unblended from D over the empty view: A = a c + (1-a) clear, error
    // 0.5 + a 1.5 + (1-a) 0.5 = 1.5. The rival — the tile drawn first, or
    // with a clear of its own — reads A over the tile, or the tile.
    {
        immutable int[2] pa = toPx(kACentre, vp), pb = toPx(kBCentre, vp),
                         pd = toPx(kFgCentre, vp);
        auto clearU = under([pa, pb, pd], [0, 1]);
        auto tileU  = under([pa, pb], [1]);
        immutable int[3] a = probe(pa), b = probe(pb), d = probe(pd);
        writefln("  3 7a: A %s B %s | clear %s tile %s", a, b, clearU[0], tileU[0]);
        assert(maxDiff(tileU[0], clearU[0]) >= 5,
            format("3 7a premise: the tile %s is not separable from the empty view %s",
                   tileU[0], clearU[0]));
        foreach (k; 0 .. 3) {
            immutable double fill = (d[k] - (1 - kFill) * clearU[2][k]) / kFill;
            immutable double pred  = kFill * fill + (1 - kFill) * clearU[0][k];
            immutable double rival = kFill * fill + (1 - kFill) * tileU[0][k];
            assert(abs(a[k] - pred) <= 1.5,
                format("3 7a: with the toggle alone A channel %d reads %d, predicted "
                       ~ "%.2f = its fill over the EMPTY view (the joined tile drawn "
                       ~ "after the primary, no clear); over the tile it would read "
                       ~ "%.2f, the tile itself %d", k, a[k], pred, rival, tileU[0][k]));
        }
        assert(maxDiff(b, tileU[1]) <= 1,
            format("3 7a: B reads %s, predicted the tile's %s (drawn after, in front)",
                   b, tileU[1]));
    }

    cmd("viewport.retopologyPreset");
    immutable int[3] flat = probe(bg);
    writefln("  3 bg tile: mode off %s, toggle only %s, preset (flat) %s", off, same, flat);
    // The control first: the mode-off reading is dimmed, so it must differ
    // from the flat one, or equality below proves nothing.
    assert(maxDiff(off, flat) >= 10,
        format("3 premise: mode off %s and preset %s are not separable", off, flat));
    assert(maxDiff(same, flat) <= 1,
        format("3: toggle only %s must draw the background as the preset's flat %s "
               ~ "(+-1 LSB)", same, flat));
}

unittest { // 4: Single -> Quad after the preset re-seeds the template, atoms intact
    freshSingle();
    auto c = cellAt(0);
    assert(!jb(c["ortho"]) && c["state"]["active"]["style"].str == "Shaded"
        && !jb(c["userSet"]),
        "4 precondition: cell 0 perspective, Shaded, unchosen: " ~ c.toString);
    cmd("viewport.retopologyPreset");
    cmd("viewport.layout", `"Quad"`);
    c = cellAt(0);
    assert(jb(c["ortho"]), "4: Quad cell 0 must be orthographic: " ~ c.toString);
    assert(c["state"]["active"]["style"].str == "Wireframe" && !jb(c["userSet"]),
        "4: the preset must not freeze the template (style Wireframe, userSet "
        ~ "false): " ~ c.toString);
    assertAtoms(c, kPreset, "4 after Quad");
}

unittest { // 5: a user-visible reset keeps the atoms; the test reset clears them
    freshSingle();
    cmd("viewport.retopologyPreset");
    assertAtoms(cellAt(0), kPreset, "5 precondition");
    cmd("file.new");
    assertAtoms(cellAt(0), kPreset, "5 file.new keeps retopology on");
    uiCmd("scene.reset");
    assertAtoms(cellAt(0), kPreset, "5 scene.reset through the UI door keeps it");
    cmdOk(commandBody("scene.reset"));
    settle();
    assertAtoms(cellAt(0), kDefault, "5 the test-automation scene.reset clears it");
    writeln("  test_retopology_preset: all cells passed");
}
