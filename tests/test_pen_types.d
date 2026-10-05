// Polygon pen stroke types, close, selectNew and the editor's global commands
// met mid-stroke (wave plan S8), against tests/fixtures/pen_types.json and
// tests/fixtures/pen_instroke_undo.json (`backspace`, `backspace_one_click`,
// `ui_cmd`, `ui_cmd_one_click`; F7 is `backspace.backspace_with_selection`).
//
// Laws: lines = n - 1 two-point polygons in click order (+ the closing segment
// with close), mirror segments keep [m(a), m(b)]; vertices = free vertices;
// subdiv = the polygon ring with the subdivision mark. selectNew 1 selects the
// new vertices and edges in every selection mode and the new polygon only in
// polygon mode, keeps the prior selection and the mode; selectNew 0 selects
// nothing new. Backspace is the editor's global delete: a UI command met
// mid-stroke ENDS the stroke first (committed and selected from the commit
// minimum, nothing below it), then runs; the pen stays armed.
//
// Rig: top ortho at 250 px/m (the captured 440 cannot fit the 1.8 m spread
// of the Backspace cells in our viewport; 250 keeps every clicked fixture
// value, a multiple of 0.05 m, on our placement lattice), focus on y = 1, snapping and symmetry off unless
// a cell says otherwise, scene geometry loaded as the edited mesh before the
// pen is armed (the captures made it by script), the selection mode set with
// select.typeFrom. Global commands are SDL keys through /api/play-events (the
// UI door); `script-delete-drops-pen` is the script door's control. Counts,
// rings and selections are exact; positions compare to 1e-4 (every click is a
// lattice value of the 0.005 m quantum). `VIBE3D_CELL=<id>` runs one cell.
//
// Ours-only: `close-refused-unless-lines` — close is enabled for the lines
// type only (wave plan S8); the pen refuses a disabled write at the door
// (refusesDisabledParamWrites), so under the command no-op contract a close
// write while the type is polygons is refused: status error, history depth
// unchanged, the value read back false. `shift-click-keeps-stroke` — a
// Shift+LMB over a committable stroke is not apply-and-continue for the pen
// (the UI-command close is its `commitOperation`, not `commitUncommittedEdit`):
// the stroke stays live and nothing is committed (today's behaviour, gap 555).

import drag_helpers : Vec3, fetchCamera, kPaceLine, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import pen_rig_helpers;
import std.algorithm : sort;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.process : environment;

void main() {}

private enum double kTol = 1e-4;
private enum int kSymBackspace = 8, kSymBracket = 91, kSymF = 102;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private Vec3 p(double x, double z, double y = 1) {
    return Vec3(cast(float)x, cast(float)y, cast(float)z);
}
private Vec3[] verts(JSONValue a) {
    Vec3[] r;
    foreach (v; a.array)
        r ~= Vec3(cast(float)num(v[0]), cast(float)num(v[1]), cast(float)num(v[2]));
    return r;
}
private long[][] rings(JSONValue a) {
    long[][] r;
    foreach (f; a.array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        r ~= ring;
    }
    return r;
}
private long[] ints(JSONValue a) {
    long[] r;
    foreach (e; a.array) r ~= e.integer;
    return r.sort.release;
}

// ---- rig ------------------------------------------------------------------

/// Empty top view at 250 px/m with focus (0, 1, 0), `mesh` (vertices, faces)
/// loaded as the edited mesh, nothing selected, selection mode `mode`,
/// snapping off, symmetry X when `symX`, empty history. No tool armed.
private void rig(string mode, Vec3[] tv = null, long[][] tf = null, bool symX = false) {
    penSceneEmpty("Top");
    if (tv.length) {
        string[] vs, fs;
        foreach (w; tv) vs ~= format("[%.9g,%.9g,%.9g]", w.x, w.y, w.z);
        foreach (r; tf) fs ~= format("%s", r);
        auto r = postJson("/api/command", commandBody("scene.loadMesh",
            format(`{"vertices":[%-(%s,%)],"faces":[%-(%s,%)]}`, vs, fs)));
        assert(r["status"].str == "ok", "scene load failed: " ~ r.toString);
        penCommand("viewport.view Top");     // a scene load leaves another view
    }
    assert(getJson("/api/camera")["projKind"].str == "Ortho",
        "rig premise: the top view must be orthographic");
    penCameraAt(p(0, 0), 250);
    penCommand("tool.pipe.attr snap enabled false");
    penCommand("tool.pipe.attr symmetry enabled " ~ (symX ? "true" : "false"));
    penCommand("tool.pipe.attr symmetry axis x");
    penCommand("tool.pipe.attr symmetry offset 0");
    penCommand("tool.pipe.attr symmetry useWorkplane false");
    foreach (m; ["vertex", "edge", "polygon"]) penCommand("select.drop " ~ m);
    penCommand("select.typeFrom " ~ mode);
    penCommand("history.clear");
}
private void arm() { penCommand("tool.set pen on"); }
private void drop() { postJson("/api/command", "tool.set pen off"); }
/// A pen attribute written while Idle; a refusal is a finding, not an abort
/// (step 0 runs this file on a binary without the attribute).
private string[] write(string cell, string name, string value) {
    auto r = postJson("/api/command", "tool.attr pen " ~ name ~ " " ~ value);
    return r["status"].str == "ok" ? null
        : [format("%s: write %s %s refused: %s", cell, name, value, r.toString)];
}
/// One Shift+LMB click over a world point.
private void shiftClickWorld(Vec3 w) {
    auto cam = fetchCamera();
    auto q = worldPixel(w);
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":1}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":1}` ~ "\n"
        ~ `{"t":150.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":1}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, q[0], q[1], q[0], q[1], q[0], q[1]));
}
/// A key over the viewport (the pointer first hovers a point away from T).
private void key(int sym) {
    hoverWorld(p(-0.6, 0.6));
    auto cam = fetchCamera();
    playAndWait(format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,`
        ~ `"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine
        ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height, sym, sym));
}
private bool penArmed() {
    return postJson("/api/command", "tool.attr pen currentPoint ?")["status"].str == "ok";
}
private double attr(string name) {
    auto r = postJson("/api/command", "tool.attr pen " ~ name ~ " ?");
    if (r["status"].str != "ok") return double.nan;
    auto v = r["value"];
    return v.type == JSONType.true_ ? 1 : v.type == JSONType.false_ ? 0 : num(v);
}

/// The fixture cell's click lists, parsed from its `click (x,z) …` lines.
private Vec3[] clicksOf(JSONValue cell) {
    import std.regex : matchAll, regex;
    import std.conv : to;
    Vec3[] r;
    foreach (line; cell["script"].array)
        foreach (m; matchAll(line.str, regex(`\((-?[0-9.]+),(-?[0-9.]+)\)`)))
            r ~= p(m[1].to!double, m[2].to!double);
    return r;
}

// ---- reads ----------------------------------------------------------------

/// The mesh against expected vertices / rings (counts and rings exactly,
/// positions to 1e-4); empty when it matches.
private string[] meshIs(string cell, Vec3[] want, long[][] wantF) {
    auto j = getJson("/api/model");
    auto got = verts(j["vertices"]);
    auto gotF = rings(j["faces"]);
    if (got.length != want.length || gotF != wantF)
        return [format("%s: %s vertices, faces %s; expected %s, faces %s", cell,
                       got.length, gotF, want.length, wantF)];
    string[] bad;
    foreach (i, w; want) {
        const g = got[i];
        if (!(abs(g.x - w.x) <= kTol && abs(g.y - w.y) <= kTol && abs(g.z - w.z) <= kTol))
            bad ~= format("v%s (%.6f, %.6f, %.6f) vs (%.6f, %.6f, %.6f)", i,
                          g.x, g.y, g.z, w.x, w.y, w.z);
    }
    return bad.length ? [format("%s: %-(%s; %)", cell, bad)] : null;
}
private string[] meshIs(string cell, JSONValue exp) {
    return meshIs(cell, verts(exp["vertices"]),
        rings("polygons" in exp.object ? exp["polygons"] : exp["faces"]));
}
/// Selected edges as sorted vertex pairs, sorted.
private long[][] selectedEdgePairs() {
    auto model = rings(getJson("/api/model")["edges"]);
    long[][] r;
    foreach (e; getJson("/api/selection")["selectedEdges"].array) {
        auto pr = model[cast(size_t)e.integer].dup;
        r ~= pr.sort.release;
    }
    return r.sort.release;
}
private long[][] pairsOf(JSONValue a) {
    long[][] r;
    foreach (pr; rings(a)) r ~= pr.dup.sort.release;
    return r.sort.release;
}
private string[] selectionIs(string cell, JSONValue exp) {
    auto s = getJson("/api/selection");
    string[] bad;
    void same(T)(string what, T got, T want) {
        if (got != want) bad ~= format("%s %s, expected %s", what, got, want);
    }
    if ("selected_vertices" in exp.object)
        same("selected vertices", ints(s["selectedVertices"]), ints(exp["selected_vertices"]));
    if ("selected_edges" in exp.object)
        same("selected edges", selectedEdgePairs(), pairsOf(exp["selected_edges"]));
    same("selected polygons", ints(s["selectedFaces"]), ints(exp["selected_polygons"]));
    if ("selection_mode_after" in exp.object)
        same("selection mode", s["selType"].str, exp["selection_mode_after"].str);
    return bad.length ? [format("%s: %-(%s; %)", cell, bad)] : null;
}
private string[] check(string cell, bool ok, string what) {
    return ok ? null : [cell ~ ": " ~ what];
}

unittest {
    auto types = parseJSON(import("fixtures/pen_types.json"))["cells"];
    auto undo = parseJSON(import("fixtures/pen_instroke_undo.json"));
    auto bs = undo["backspace"];
    const only = environment.get("VIBE3D_CELL", "");
    bool want(string cell) { return only.length == 0 || only == cell; }
    string[] fails;
    int ran;

    // The scene triangle T of every Backspace / UI-command cell.
    auto tExp = bs["BSscene_selectNew1"]["expected"];
    auto tV = verts(tExp["vertices"]);
    auto tF = rings(tExp["faces"]);
    Vec3[3] away = [p(-0.8, -0.6), p(-0.2, -0.8), p(-0.5, -0.2)];
    Vec3 next = p(-0.9, 0.2);
    assert(tV.length == 3 && tF == [[0L, 1, 2]], "fixture premise: T is one triangle");

    // ===== must stay green ==================================================
    // bs-notool-polygon / -vertex: no tool, T, nothing selected: Backspace is
    // the global delete of the whole mesh (ours before S8 already).
    foreach (cell, mode; ["bs-notool-polygon": "polygon", "bs-notool-vertex": "vertex"]) {
        if (!want(cell)) continue;
        rig(mode, tV, tF);
        key(kSymBackspace);
        fails ~= meshIs(cell, bs[mode == "polygon" ? "BSnotool_polygon"
                                                   : "BSnotool_vertex"]["expected"]);
        ++ran;
    }
    // script-delete-drops-pen: the SCRIPT door is not the pen's: a mid-stroke
    // `/api/command mesh.delete` drops the pen (today's funnel rule).
    if (want("script-delete-drops-pen")) {
        rig("polygon", tV, tF);
        arm();
        clickWorld(away[]);
        postJson("/api/command", "mesh.delete");
        fails ~= check("script-delete-drops-pen", !penArmed(),
                       "the pen is still armed after a script mesh.delete");
        drop(); ++ran;
    }

    // close-refused-unless-lines (ours-only, see the header).
    if (want("close-refused-unless-lines")) {
        rig("vertex");
        arm();
        const before = getJson("/api/history")["undo"].array.length;
        auto r = postJson("/api/command", "tool.attr pen close true");
        const after = getJson("/api/history")["undo"].array.length;
        fails ~= check("close-refused-unless-lines", r["status"].str == "error" &&
            before == after && attr("close") == 0,
            format("close write under polygons: %s, history %s -> %s, close %s",
                   r.toString, before, after, attr("close")));
        drop(); ++ran;
    }

    // ===== must turn: types and close (fixture pen_types.json) ==============
    foreach (cell; ["lines", "lines_close", "vertices", "subdiv"]) {
        if (!want(cell)) continue;
        rig("vertex");
        arm();
        fails ~= write(cell, "type", cell == "lines_close" ? "lines" : cell);
        if (cell == "lines_close") fails ~= write(cell, "close", "true");
        clickWorld(clicksOf(types[cell == "subdiv" || cell == "lines_close"
                                   ? "lines" : cell]));
        drop(); ++ran;
        fails ~= meshIs(cell, types[cell]["expected"]);
        if (cell == "subdiv") {
            auto sub = getJson("/api/model")["isSubpatch"].array;
            fails ~= check(cell, sub.length == 1 && sub[0].type == JSONType.true_,
                format("subdivision marks %s, expected [true]", sub));
        }
    }
    // lines_symmetry: mirror segments keep [m(a), m(b)] (not reversed).
    if (want("lines_symmetry")) {
        rig("vertex", null, null, true);
        arm();
        fails ~= write("lines_symmetry", "type", "lines");
        clickWorld(clicksOf(types["lines_symmetry"]));
        drop(); ++ran;
        fails ~= meshIs("lines_symmetry", types["lines_symmetry"]["expected"]);
    }

    // ===== must turn: selectNew (T0 loaded and selected in the mode) ========
    foreach (on; ["1", "0"])
        foreach (mode; ["vertex", "edge", "polygon"]) {
            const cell = "select_new_" ~ on ~ "_" ~ mode ~ "_mode";
            if (!want(cell)) continue;
            auto exp = types[cell]["expected"];
            auto all = verts(exp["vertices"]);
            rig(mode, all[0 .. 3], [[0L, 1, 2]]);
            const string[string] token = ["vertex": "vertices", "edge": "edges",
                                          "polygon": "polygons"];
            const string[string] every = ["vertex": "[0,1,2]", "edge": "[0,1,2]",
                                          "polygon": "[0]"];
            penCommand(`{"id":"mesh.select","params":{"mode":"` ~ token[mode]
                ~ `","indices":` ~ every[mode] ~ `}}`);
            arm();
            fails ~= write(cell, "selectNew", on == "1" ? "true" : "false");
            clickWorld(clicksOf(types[cell]));
            drop(); ++ran;
            fails ~= meshIs(cell, exp);
            fails ~= selectionIs(cell, exp);
        }

    // select-new-switch-drop: the polygon-mode selectNew row ended by a tool
    // SWITCH (the prepared drop image builds the commit, the selection mode
    // read at its prepare) selects as the drop does.
    if (want("select-new-switch-drop")) {
        auto exp = types["select_new_1_polygon_mode"]["expected"];
        auto all = verts(exp["vertices"]);
        rig("polygon", all[0 .. 3], [[0L, 1, 2]]);
        penCommand(`{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`);
        arm();
        clickWorld(clicksOf(types["select_new_1_polygon_mode"]));
        penCommand("tool.set move on");
        penCommand("tool.set move off");
        ++ran;
        fails ~= meshIs("select-new-switch-drop", exp);
        fails ~= selectionIs("select-new-switch-drop", exp);
    }

    // ===== must turn: Backspace = the global delete (fixture `backspace`) ====
    // bs-scene-selectnew1: the stroke ends (committed, selected), the delete
    // removes it; T stays; the pen stays armed; the next click a new stroke
    // (dropped below the minimum).
    if (want("bs-scene-selectnew1")) {
        rig("polygon", tV, tF);
        arm();
        clickWorld(away[]);
        key(kSymBackspace);
        fails ~= check("bs-scene-selectnew1", penArmed(), "the pen is not armed after Backspace");
        clickWorld(next);
        drop(); ++ran;
        fails ~= meshIs("bs-scene-selectnew1", tExp);
    }
    // bs-scene-selectnew0: nothing selected at the delete: the whole mesh.
    if (want("bs-scene-selectnew0")) {
        rig("polygon", tV, tF);
        arm();
        fails ~= write("bs-scene-selectnew0", "selectNew", "false");
        clickWorld(away[]);
        key(kSymBackspace);
        clickWorld(next);
        drop(); ++ran;
        fails ~= meshIs("bs-scene-selectnew0", bs["BSscene_selectNew0"]["expected"]);
    }
    // F7 backspace_with_selection: T drawn by the pen (selected by selectNew in
    // polygon mode); a new stroke; Backspace deletes T and the stroke; the
    // click begins a new 1-point stroke (current 0) that the drop discards.
    if (want("backspace_with_selection")) {
        auto f7 = bs["backspace_with_selection"];
        auto c = clicksOf(f7);
        assert(c.length == 7, "fixture premise: 3 + 3 + 1 clicks");
        rig("polygon");
        arm();
        clickWorld(c[0 .. 3]);
        drop();
        arm();
        clickWorld(c[3 .. 6]);
        key(kSymBackspace);
        clickWorld(c[6]);
        const cur = attr("currentPoint");
        fails ~= check("backspace_with_selection",
            cur == num(f7["expected"]["panel_after"]["current"]),
            format("current point %s after the click, expected 0", cur));
        drop(); ++ran;
        fails ~= meshIs("backspace_with_selection", f7["expected"]);
    }

    // ===== must turn: other UI commands mid-stroke (fixture `ui_cmd`) =======
    // ui-cmd-commits-keeps-armed: select.invert ([) commits the stroke
    // (selected), then inverts: T selected; the pen stays armed.
    if (want("ui-cmd-commits-keeps-armed")) {
        auto exp = undo["ui_cmd"]["select_invert_mid_stroke"]["expected"];
        rig("polygon", tV, tF);
        arm();
        clickWorld(away[]);
        key(kSymBracket);
        fails ~= check("ui-cmd-commits-keeps-armed", penArmed(),
                       "the pen is not armed after the command");
        clickWorld(next);
        drop(); ++ran;
        fails ~= meshIs("ui-cmd-commits-keeps-armed", exp);
        fails ~= selectionIs("ui-cmd-commits-keeps-armed", exp);
    }
    // idle-pen-ui-cmd-stays-armed: an armed pen with no stroke meets the
    // command: armed afterwards.
    if (want("idle-pen-ui-cmd-stays-armed")) {
        rig("polygon", tV, tF);
        arm();
        key(kSymBracket);
        fails ~= check("idle-pen-ui-cmd-stays-armed", penArmed(),
                       "an idle pen was dropped by the command");
        drop(); ++ran;
    }
    // ui-flip-commits-flips-stroke: the flip key commits the stroke (selected)
    // and flips the selection = the stroke only; T untouched. Which corner the
    // flip starts from is the flip command's: the cycle is compared
    // rotation-insensitively against the reverse of the unflipped ring.
    if (want("ui-flip-commits-flips-stroke")) {
        auto exp = undo["ui_cmd"]["flip_mid_stroke"];
        rig("polygon", tV, tF);
        arm();
        clickWorld(away[]);
        key(kSymF);
        clickWorld(next);
        drop(); ++ran;
        auto j = getJson("/api/model");
        auto f = rings(j["faces"]);
        long[] rev = rings(JSONValue([exp["stroke_ring_unflipped"]]))[0].dup;
        import std.algorithm : reverse;
        reverse(rev);
        bool cycle(long[] a, long[] b) {
            if (a.length != b.length) return false;
            foreach (s; 0 .. a.length)
                if (a[s .. $] ~ a[0 .. s] == b) return true;
            return false;
        }
        fails ~= check("ui-flip-commits-flips-stroke",
            f.length == 2 && f[0] == tF[0] && cycle(f[1], rev) &&
            verts(j["vertices"]).length == 6,
            format("faces %s; expected T %s and a cycle of %s", f, tF[0], rev));
        fails ~= selectionIs("ui-flip-commits-flips-stroke", exp["expected"]);
    }

    // ===== must turn: below the commit minimum (A4) =========================
    // bs-one-click: the 1-point stroke ENDS with nothing at the command; the
    // delete removes the whole mesh; the pen stays armed; the next click is a
    // new 1-point stroke (the drop keeps nothing).
    if (want("bs-one-click")) {
        rig("polygon", tV, tF);
        arm();
        clickWorld(away[0]);
        key(kSymBackspace);
        fails ~= check("bs-one-click", penArmed(), "the pen is not armed after Backspace");
        const pts = attr("points"), cur = attr("currentPoint");
        fails ~= check("bs-one-click", pts == 0 && cur == -1,
            format("stroke %s points, current %s after Backspace; expected 0, -1", pts, cur));
        clickWorld(next);
        drop(); ++ran;
        fails ~= meshIs("bs-one-click", undo["backspace_one_click"]["expected"]);
    }
    // ui-invert-one-click (K-B5 UC1-end): a non-delete command also ends the
    // 1-point stroke first; T inverted to selected; nothing else committed.
    if (want("ui-invert-one-click")) {
        auto exp = undo["ui_cmd_one_click"]["expected"];
        rig("polygon", tV, tF);
        arm();
        clickWorld(away[0]);
        key(kSymBracket);
        clickWorld(next);
        drop(); ++ran;
        fails ~= meshIs("ui-invert-one-click", exp);
        fails ~= selectionIs("ui-invert-one-click", exp);
    }

    // shift-click-keeps-stroke (ours-only, see the header).
    if (want("shift-click-keeps-stroke")) {
        rig("polygon");
        arm();
        clickWorld(away[]);
        shiftClickWorld(p(0.4, 0.4));
        const pts = attr("points"), nf = getJson("/api/model")["faces"].array.length;
        fails ~= check("shift-click-keeps-stroke", pts == 3 && nf == 0,
            format("stroke %s points, %s faces after Shift+LMB; expected 3, 0", pts, nf));
        drop(); ++ran;
    }

    assert(only.length || ran == 25, format("cells ran %s, expected 25", ran));
    assert(fails.length == 0, "pen types / selectNew / UI commands: " ~ fails.join(" | "));
}
