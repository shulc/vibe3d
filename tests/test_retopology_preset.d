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
//     separates the two;
//   * the preset writes no template field: Single -> Quad still re-seeds
//     cell 0 to the orthographic template, with the five atoms intact;
//   * a user-visible reset (`file.new`, `scene.reset` through the UI door)
//     keeps the atoms, the test-automation reset (script `scene.reset`)
//     clears them. The keeps run first, so the clear is the last reading.
module test_retopology_preset;

import http_client : getJson, postJson, quiesce, frameFence;
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
// Pixel rig: layer 0 (background) one +Z tile, layer 1 (the primary) a small
// +Z quad away from it; front orthographic camera, shaded active style.
// ---------------------------------------------------------------------------
private immutable double[3] kBgCentre = [-1.5, 0.5, 0];
private immutable double[3] kFgCentre = [1.5, -1.0, 0];

private JSONValue quad(double[3] c, double half) {
    JSONValue[] verts;
    foreach (k; [[-half, -half], [half, -half], [half, half], [-half, half]])
        verts ~= JSONValue([c[0] + k[0], c[1] + k[1], c[2]]);
    return JSONValue(["vertices": JSONValue(verts),
                      "faces": JSONValue([JSONValue([0L, 1L, 2L, 3L])])]);
}

private int[2] toPx(double[3] w, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) w[0], cast(float) w[1], cast(float) w[2]),
                           vp, px, py), "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

private int[2] buildPixelRig() {
    freshSingle();
    cmdOk(commandBody("scene.loadMesh", quad(kBgCentre, 0.6).toString));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh", quad(kFgCentre, 0.3).toString));
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
    return toPx(kBgCentre, vp);
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
    immutable int[2] bg = buildPixelRig();
    immutable int[3] off = probe(bg);            // mode off, same: the 0.45 dim
    cmd("viewport.retopology", `{"value":"on"}`);
    auto c = cellAt(0);
    assertAtoms(c, Atoms(true, "SameAsActive", "Shaded", false, 0.0), "3 toggle only");
    auto plan = c["plan"]["backdrop"];
    assert(jb(plan["joinsItemSequence"]) && num(plan["dim"]) == 1.0,
        "3: the toggle's backdrop plan must join the item sequence undimmed: "
        ~ plan.toString);
    immutable int[3] same = probe(bg);
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
