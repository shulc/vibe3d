// A recording command through the UI door closes the live tool operation
// FIRST, and the tool stays (slice M2 of the tool session model,
// doc/tool_session_model_plan_2026-09-24.md R2.5 M2 / R4.2 witness 2 / R5;
// the cell list of doc/editor_bugfix_wave_plan_2026-09-23.md §S2b, which this
// slice replaces).
//
// Law (captured, toolcards/bugfix_w17_slice_tools residual 11-12:
// C1-h-sel, C1-h-sel-model, C1-h-sel-fam; toolcards/tool_session_model M0 H3):
// a command that records an undo row, run by a KEY while a tool holds a live
// edit, first writes the edit's row, then its own (K-commit); Ctrl+Z #1 pops
// the command alone, #2 the edit. The mesh-edit tools keep their tag with no
// live operation; the transform re-arms in place (C-H3-move). A command that
// records nothing (view fit) leaves the live edit alone.
//
// Every command here is a REAL key through /api/play-events, i.e. the UI door
// (`ApplicationCommandBinding` -> guard -> `CommandExecutor.applyOrRefireFromUi`).
// Per block: X0 (no tool, the same key on the same rig: the command's own row
// label, measured, then undone) -> floor (the live edit changed the mesh) ->
// needle (added rows and the tool) -> the Ctrl+Z ladder by the real Ctrl+Z.
// Green-in-both-states blocks (V) come before the ones that redden without M2.

import slice_grid_helpers;
import slice_leak_helpers;
import http_client : getJson, postJson;
import ssh = symmetry_selection_helpers;
import eeh = edge_extend_gesture_helpers;

import std.format : format;
import std.json;
import std.math : abs;
import std.stdio : writeln, stdout;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum int K_INVERT = 91, K_HIDE = 104, K_FLIP = 102, K_FIT = 97, K_DELETE = 127;

string[] addedSince(const string[] before) {
    auto now = slHistoryLabels();
    assert(now.length >= before.length && now[0 .. before.length] == before,
           format("live-op rig: an earlier row changed: before %s, now %s", before, now));
    return now[before.length .. $].dup;
}

void ctrlZ(string what) { slKey(SL_SDLK_z, SL_KMOD_LCTRL, "Ctrl+Z (" ~ what ~ ")"); }

/// X0: the row `sym` writes on this rig with no tool, then undone. A floor:
/// exactly one row, and the undo restores the rig.
string keyLabel(int sym, string what) {
    assert(slTool() == "", "live-op X0: a tool is armed before the label probe (" ~ what ~ ")");
    const L = slHistoryLabels();
    const m = slMesh();
    slKey(sym, 0, what ~ " (X0)");
    const added = addedSince(L);
    assert(added.length == 1, format("live-op X0 floor: %s wrote %s rows with no tool: %s",
                                     what, added.length, added));
    ctrlZ(what ~ " X0 undo");
    assert(slHistoryLabels() == L && slMesh().canon == m.canon,
           "live-op X0 floor: the probe's undo did not restore the rig (" ~ what ~ ")");
    return added[0];
}

/// The K-commit template. `editRows`: the rows the close writes (empty for a
/// transform whose gestures already recorded theirs).
void kCommit(string fam, string key, int sym, string cmdLabel, const string[] editRows,
             string toolId, const SlMesh base) {
    const L0 = slHistoryLabels();
    const edited = slMesh();
    assert(edited.canon != base.canon,
           format("%s %s floor: the live edit did not change the mesh", fam, key));
    assert(slTool() == toolId, format("%s %s floor: the tool is %s, expected %s", fam, key, slTool(), toolId));
    slKey(sym, 0, fam ~ " " ~ key);
    const added = addedSince(L0);
    const tool = slTool();
    writeln(fam, " ", key, ": added ", added, ", tool ", tool);
    stdout.flush();
    assert(added == editRows ~ [cmdLabel] && tool == toolId,
           format("%s %s: undoable command did not commit the live edit first and keep the tool: "
                  ~ "added %s (expected %s), tool %s", fam, key, added, editRows ~ [cmdLabel], tool));
    ctrlZ(fam ~ " #1");
    assert(slHistoryLabels() == L0 ~ editRows && slMesh().canon == edited.canon && slTool() == toolId,
           format("%s ctrl+z 1 did not pop the command alone: rows %s, tool %s",
                  fam, slHistoryLabels(), slTool()));
    ctrlZ(fam ~ " #2");
    const expectRows = editRows.length ? L0.dup : L0[0 .. $ - 1].dup;
    assert(slHistoryLabels() == expectRows && slMesh().canon == base.canon,
           format("%s ctrl+z 2 did not pop the edit: rows %s (expected %s)",
                  fam, slHistoryLabels(), expectRows));
    writeln(fam, " after ctrl+z 2: tool ", slTool());
}

// ---- Edge Slice (grid rig; t1, t2 as tests/test_edge_slice_history_order.d) --

void clickAt(int[2] p, string what) {
    slPlay(format(`{"t":20.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
                  ~ "\n" ~ `{"t":40.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
                  ~ "\n" ~ `{"t":60.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
                  ~ "\n" ~ `{"t":80.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  p[0], p[1], p[0], p[1], p[0], p[1], p[0], p[1]), what);
}

void latchOnEdge(double x0, double x1, double z, string what) {
    const pr = gridPair(x0, z, x1, z);
    const p = pixelOf((x0 + x1) / 2, 0, z);
    hoverFloor(p, pr[0], pr[1], what);
    clickAt(p, what);
}

/// Grid rig, the command's label (X0), Edge Slice armed with `points` latched.
string esRig(int points, int sym, string what, out SlMesh base) {
    gridRig(false);
    base = slMesh();
    const label = keyLabel(sym, what);
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "ES floor: Edge Slice did not activate");
    if (points >= 1) latchOnEdge(0, 1, 0, "point 1");
    if (points >= 2) latchOnEdge(0, 1, 1, "point 2");
    assert(slChain().pairs.length == points,
           format("ES floor: %s points latched, expected %s", slChain().pairs.length, points));
    return label;
}

unittest { // ES-V (green in both states): a command without a row leaves the chain live.
    SlMesh base;
    gridRig(false);
    base = slMesh();
    slLine("tool.set mesh.edgeSliceTool on");
    latchOnEdge(0, 1, 0, "point 1");
    latchOnEdge(0, 1, 1, "point 2");
    const L0 = slHistoryLabels();
    slKey(K_FIT, 0, "A (view fit)");
    assert(addedSince(L0) == [] && slChain().pairs.length == 2 && slTool() == "edgeSlice",
           format("a no-undo command ended the live chain (view fit): added %s, pairs %s, tool %s",
                  addedSince(L0), slChain().pairs.length, slTool()));
}

unittest { // ES-B: `[` (select.invert, a Model command) closes the chain first.
    SlMesh base;
    const label = esRig(2, K_INVERT, "[", base);
    kCommit("edge slice", "[", K_INVERT, label, ["Edge Slice"], "edgeSlice", base);
}

unittest { // ES-H: H (mesh.hide, UiState).
    SlMesh base;
    const label = esRig(2, K_HIDE, "H", base);
    kCommit("edge slice", "H", K_HIDE, label, ["Edge Slice"], "edgeSlice", base);
}

unittest { // ES-F: F (mesh.flip) — a model command closes the same way (P-uniform).
    SlMesh base;
    const label = esRig(2, K_FLIP, "F", base);
    kCommit("edge slice", "F", K_FLIP, label, ["Edge Slice"], "edgeSlice", base);
}

unittest { // ES-Del: Delete with nothing selected.
    SlMesh base;
    const label = esRig(2, K_DELETE, "Delete", base);
    kCommit("edge slice", "Delete", K_DELETE, label, ["Edge Slice"], "edgeSlice", base);
}

unittest { // ES-H1: a lone point is cancelled, not committed, and the tool stays.
    SlMesh base;
    const label = esRig(1, K_HIDE, "H", base);
    const L0 = slHistoryLabels();
    slKey(K_HIDE, 0, "H (one point)");
    assert(addedSince(L0) == [label] && slMesh().canon == base.canon
           && slChain().pairs.length == 0 && slTool() == "edgeSlice",
           format("one-point chain survived an undoable command: added %s, mesh %s, pairs %s, tool %s",
                  addedSince(L0), slMesh(), slChain().pairs.length, slTool()));
}

// ---- Slice (tests/test_slice_tool_switch_records.d's prologue and line) --------

unittest { // SL-B
    slPrologue(false, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    const label = keyLabel(K_INVERT, "[");
    slSliceActivateAndDraw();
    kCommit("slice", "[", K_INVERT, label, ["Slice"], "slice", base);
}

// ---- Loop Slice (tests/test_loop_slice_ctrlz.d's cube, belt seed, arming click)

unittest { // LS-B
    slCmd("scene.reset");
    auto m = getJson("/api/model");
    int vertAt(double x, double y, double z) {
        foreach (i, v; m["vertices"].array) {
            auto a = v.array;
            if (abs(a[0].floating - x) < 1e-4 && abs(a[1].floating - y) < 1e-4
                    && abs(a[2].floating - z) < 1e-4) return cast(int) i;
        }
        return -1;
    }
    const seed = slEdgeOf(m, vertAt(-0.5, -0.5, -0.5), vertAt(0.5, -0.5, -0.5));
    assert(seed >= 0, "LS rig: the belt seed edge is missing");
    slCmd("mesh.select", format(`{"mode":"edges","indices":[%d]}`, seed));
    slCmd("history.clear");
    const base = slMesh();
    const label = keyLabel(K_INVERT, "[");
    slLine("tool.set mesh.loopSliceTool on");
    enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
    enum CX = VPX + VPW / 2, CY = VPY + VPH / 2;
    slPlay(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
                  ~ "\n" ~ `{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
                  ~ "\n" ~ `{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
                  ~ "\n" ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  VPX, VPY, VPW, VPH, CX, CY, CX, CY, CX, CY), "the arming click");
    assert(slMesh().verts == 12, "LS floor: the arming click did not cut the loop: " ~ slMesh().toString);
    kCommit("loop slice", "[", K_INVERT, label, ["Loop Slice"], "loopSlice", base);
}

// ---- Edge Extend (the golden rig: plane, two edges, top view, one haul) -------

void extendLive() {
    slCmd("scene.reset");
    eeh.loadPlaneRig();
    eeh.setSymmetryX(false);
    eeh.selectEdges(eeh.edgesOf([[6, 7], [7, 8]]));
    slLine("viewport.view Top");
    auto r = postJson("/api/camera", `{"focus":{"x":0.5,"y":0,"z":0}}`);
    assert(r["status"].str == "ok", "EX rig: camera focus failed");
    slCmd("history.clear");
}

unittest { // EX-B
    extendLive();
    const base = slMesh();
    const label = keyLabel(K_INVERT, "[");
    slLine("tool.set edge.extend on");
    Thread.sleep(250.msecs);
    eeh.haul(eeh.haulPx(), eeh.kIncrementPx, 0, 10);
    kCommit("edge extend", "[", K_INVERT, label, ["Edge Extend"], "edgeExtend", base);
}

// ---- Polygon Bevel (cube, face 0, a Shift-handle haul) --------------------------

void bevelHaul() {
    Thread.sleep(300.msecs);
    int sx, sy;
    bool found;
    foreach (p; getJson("/api/tool/handles")["handles"]["parts"].array)
        if (p["part"].integer == 0) {
            sx = cast(int)(p["screen"].array[0].floating + 0.5);
            sy = cast(int)(p["screen"].array[1].floating + 0.5);
            found = true;
        }
    assert(found, "PB rig: the Shift handle is not published");
    ssh.haulPx(sx, sy, -20, -35, 3);
}

void bevelRig() {
    slCmd("scene.reset");
    slCmd("mesh.select", `{"mode":"polygons","indices":[0]}`);
    slCmd("history.clear");
}

unittest { // PB-B
    bevelRig();
    const base = slMesh();
    const label = keyLabel(K_INVERT, "[");
    slLine("tool.set poly.bevel on");
    bevelHaul();
    kCommit("poly bevel", "[", K_INVERT, label, ["Poly Bevel"], "polyBevel", base);
}

unittest { // PB-row: the UI door writes the SAME operation row the drop door writes.
    bevelRig();
    slLine("tool.set poly.bevel on");
    bevelHaul();
    slKey(K_INVERT, 0, "[ (PB-row)");
    auto viaKey = getJson("/api/history")["undo"].array;
    assert(viaKey.length >= 2, "PB-row floor: the key wrote no rows");
    const opKey = viaKey[$ - 2];
    slLine("tool.set poly.bevel off");

    bevelRig();
    slLine("tool.set poly.bevel on");
    bevelHaul();
    slLine("tool.set poly.bevel off");
    auto viaDrop = getJson("/api/history")["undo"].array;
    assert(viaDrop.length >= 1, "PB-row floor: the drop wrote no row");
    const opDrop = viaDrop[$ - 1];
    foreach (k; ["label", "command", "args", "flags"])
        assert(opKey[k] == opDrop[k],
               format("PB-row: the UI-door close wrote a different operation row than the drop door: "
                      ~ "%s %s vs %s", k, opKey[k], opDrop[k]));
}

// ---- Move (TransformMove; the transform RE-ARMS in place) -----------------------

void moveLive() {
    ssh.rig();
    ssh.selectVerts([6, 7]);
    slCmd("history.clear");
}

unittest { // MV-B: the haul already recorded its row; `[` closes the run and re-arms.
    moveLive();
    const base = slMesh();
    const label = keyLabel(K_INVERT, "[");
    slLine("tool.set TransformMove on");
    Thread.sleep(300.msecs);
    ssh.haul([0.5, -0.3, 0.5], 8, 0, 5);
    kCommit("move", "[", K_INVERT, label, [], "xfrm", base);
}

unittest { // MV-R: the re-arm is a FRESH run — the panel's channels start from zero.
    moveLive();
    slLine("tool.set TransformMove on");
    Thread.sleep(300.msecs);
    ssh.haul([0.5, -0.3, 0.5], 8, 0, 5);
    auto t0 = getJson("/api/tool/state")["values"]["t"].array;
    assert(abs(t0[0].floating) > 1e-3, "MV-R floor: the haul wrote no TX: " ~ JSONValue(t0).toString);
    slKey(K_INVERT, 0, "[ (MV-R)");
    auto st = getJson("/api/tool/state");
    assert(st["tool"].str == "xfrm", "MV-R floor: the transform was not kept");
    auto t1 = st["values"]["t"].array;
    assert(abs(t1[0].floating) < 1e-6 && abs(t1[1].floating) < 1e-6 && abs(t1[2].floating) < 1e-6,
           "move [: the transform did not re-arm in place after the command (TX kept "
           ~ JSONValue(t1).toString ~ ")");
}

unittest { // MV-LA: `layer.attr` through the UI door CONTINUES the transform run
    // (the Layers panel's rows, the carve-out shared with the drop rule): the
    // run is not closed, so the haul's channels are not reset by a re-arm.
    moveLive();
    slLine("tool.set TransformMove on");
    Thread.sleep(300.msecs);
    ssh.haul([0.5, -0.3, 0.5], 8, 0, 5);
    auto t0 = getJson("/api/tool/state")["values"]["t"].array;
    assert(abs(t0[0].floating) > 1e-3, "MV-LA floor: the haul wrote no TX");
    const L0 = slHistoryLabels();
    auto r = postJson("/api/command?origin=ui", "layer.attr 0 pos.y 0.25");
    assert(r["status"].str == "ok", "MV-LA floor: the UI layer.attr failed: " ~ r.toString);
    assert(slHistoryLabels().length == L0.length + 1,
           format("MV-LA floor: layer.attr is not a recording command here: %s", addedSince(L0)));
    auto st = getJson("/api/tool/state");
    assert(st["tool"].str == "xfrm", "MV-LA: the UI layer.attr dropped the transform");
    auto t1 = st["values"]["t"].array;
    assert(abs(t1[0].floating - t0[0].floating) < 1e-6,
           "move layer.attr: the Layers-panel command closed the transform run (channels reset "
           ~ JSONValue(t0).toString ~ " -> " ~ JSONValue(t1).toString ~ ")");
}

unittest { // MV-H: H (mesh.hide, UiState) — the transform closes and re-arms the
    // same way; hiding changes no selection, so the channel reset here is the
    // command close's resume and not the transform's own selection-change path.
    moveLive();
    const base = slMesh();
    const label = keyLabel(K_HIDE, "H");
    slLine("tool.set TransformMove on");
    Thread.sleep(300.msecs);
    ssh.haul([0.5, -0.3, 0.5], 8, 0, 5);
    auto t0 = getJson("/api/tool/state")["values"]["t"].array;
    assert(abs(t0[0].floating) > 1e-3, "MV-H floor: the haul wrote no TX");
    const L0 = slHistoryLabels();
    slKey(K_HIDE, 0, "H (MV-H)");
    assert(addedSince(L0) == [label], format("MV-H floor: H wrote %s", addedSince(L0)));
    auto st = getJson("/api/tool/state");
    assert(st["tool"].str == "xfrm", "move H: the UI command dropped the transform");
    auto t1 = st["values"]["t"].array;
    assert(abs(t1[0].floating) < 1e-6 && abs(t1[1].floating) < 1e-6 && abs(t1[2].floating) < 1e-6,
           "move H: the transform did not re-arm in place after the command (TX kept "
           ~ JSONValue(t1).toString ~ ")");
}
