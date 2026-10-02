// Topology-redo laws, autoact family (EdgeExtrude, EdgeBevel, VertexBevel,
// VertexExtrude): every checkpoint of every captured cell of the family,
// replayed on our product and compared relation by relation with the frozen reference
// (`tests/fixtures/topology_redo_law_cells.json`; executor and comparison:
// tests/topology_redo_law_helpers.d). Wave plan topology-redo, slice S1b — the same
// executor and comparison as the inset family; the tools differ only by their rig.
//
// A green run says: every parity field still matches the reference AND every declared
// known divergence is still exactly the declared one. A divergence a later slice closes
// (or moves) turns its cell red with "divergence closed or moved: <cell>/<point> law <n>
// — flip to parity in <owner>". Order (form item 2): the family floor first, then one
// `unittest` per cell, then the count of compared cells.

import std.conv : to;
import std.json;
import http_client : getJson, postJson, frameFence;
import topology_redo_law_helpers;

void main() {}

enum string kFixture = import("fixtures/topology_redo_law_cells.json");

/// The family's cells (the generator's `--family autoact` census, measured literal).
immutable string[] kCells = [
    "begin_redo_select_haul_eextrude", "begin_undone_haul_ebevel", "close_cmd_eextrude_script",
    "close_cmd_eextrude_ui", "cmdclose_press_ebevel_gdb_ui", "ebevel_dormant",
    "ebevel_dormant_level_ui", "ebevel_dormant_ui", "ebevel_row", "ebevel_row_ui",
    "eextrude_dormant_ui", "eextrude_mech", "eextrude_mech_ui", "fold_close_eextrude",
    "fold_close_eextrude_ui", "fold_restart_eextrude", "fold_restart_eextrude_ui",
    "moment_eextrude", "moment_eextrude_ui", "nav_redo_refire_ebevel", "nav_redo_refire_ebevel_ui",
    "nav_redo_restart_eextrude", "nav_redo_restart_eextrude_ui", "nav_undo_refire_ebevel",
    "nav_undo_refire_ebevel_ui", "nav_undo_restart_eextrude", "nav_undo_restart_eextrude_ui",
    "param_after_arm_ebevel_script", "param_between_ebevel_script", "param_between_ebevel_ui",
    "param_between_moment_ebevel_ui", "param_closed_ebevel_ui", "rclick_close_eextrude_ui",
    "rearm_ebevel_ui", "rearm_vextrude", "rebegin_redo_act_ebevel", "rebegin_redo_act_ebevel_ui",
    "vbevel_actundo", "vbevel_actundo_ui", "vbevel_dormant", "vbevel_dormant_ui",
    "vextrude_dormant", "vextrude_dormant_ui", "vextrude_row", "vextrude_row_ui",
    "wundo_restart_ebevel_gdb_ui"
];

// `freeze_fixture.py --family autoact` (2026-10-01; + 9270 C9 3 cells, C10-r 3 cells):
// TOPO-REDO-CELLS family=autoact cells=46 checkpoints=550 …
enum long kCellCount = 46;
enum long kCheckpointCount = 550;

unittest { // the floor: the fixture still holds the whole family
    familyFloor(parseJSON(kFixture), "autoact", kCells, kCellCount, kCheckpointCount);
}

// The middle-button restart of EdgeExtrude (plan §11, verdict 8890): one layer per press
// on both sides, so every `_M` point is parity but its `origin` (S2b), and the fields
// after it take their owners by the general rule. Floor: generator output 2026-10-02 —
// 6 `_M` points (`LIST middleRestartParity n=6`). (The haul after the restart's undo is
// law 6's PF-7 rule, `LIST undoneRestartTail`, plan §14.5.)
unittest {
    const fx = parseJSON(kFixture);
    size_t points;
    foreach (c; fx["cells"].array) {
        if (c["family"].str != "autoact" || !c["measured"].boolean) continue;
        string m;
        foreach (s; c["steps"].array)
            if (s["op"].str == "haul" && s["button"].str == "middle") { m = s["label"].str; break; }
        if (!m.length) continue;
        foreach (p; c["points"].array) {
            const at = c["id"].str ~ "/" ~ p["label"].str;
            if (p["label"].str != m) continue;
            ++points;
            foreach (field, f; p["fields"].object)
                assert("ours" !in f || field == "origin", "fixture: " ~ at ~ "." ~ field
                    ~ " — the middle press diverges (plan §11: one layer per press)");
        }
    }
    assert(points == 6, "fixture family autoact holds " ~ points.to!string
        ~ " middle-restart points, frozen at 6");
}

// The kernel owner (reviewer's adjudication of S1b PLAN-FINDING-1, gap row 486): EdgeExtrude
// after `select.invert` rebuilds both faces at the reference (7), ours 9 — a first-haul
// COUNT no law moves; the generator's `KERNEL_SEEDS` names the two seeds, and only the
// `vcount` fields carrying a seed's (reference, ours) pair inherit it. Stationary; the
// exact set of this family (`freeze_fixture.py --print-lists`: `LIST kernelOwned n=30`,
// 2026-10-02: these 6 + VertexMerge's 24, pinned by the inset suite).
unittest {
    const fx = parseJSON(kFixture);
    string[] kernel;
    foreach (c; fx["cells"].array)
        if (c["family"].str == "autoact")
        foreach (p; c["points"].array)
            foreach (field, f; p["fields"].object)
                if ("ours" in f && f["owner"].str == "none: kernel (gap row 486)")
                    kernel ~= c["id"].str ~ "/" ~ p["label"].str ~ "." ~ field;
    assert(kernel == ["moment_eextrude/s05_drag.vcount", "moment_eextrude/s06_drag.vcount",
        "moment_eextrude/s07_Z.vcount", "moment_eextrude_ui/s05_drag.vcount",
        "moment_eextrude_ui/s06_drag.vcount", "moment_eextrude_ui/s07_Z.vcount"],
        "fixture: the kernel-owned fields " ~ kernel.to!string ~ " are not gap row 486's six");
}

static foreach (id; kCells) {
    unittest { runCell(parseJSON(kFixture), id); }
}

// Task 8950 (wave S3): OUR checks, not fixture cells. Off under a cell filter / a dump,
// unless the filter names the check.
private bool skipFor(string name) {
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    return (only.length && only != name) || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length;
}

private JSONValue fixtureCell(string id) {
    foreach (c; parseJSON(kFixture)["cells"].array)
        if (c["id"].str == id) return c;
    assert(false, "fixture holds no cell " ~ id ~ " (a rig of the S3 checks)");
}

private void cmdOkHere(string line, string ctx) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", ctx ~ ": " ~ line ~ ": " ~ r.toString);
    frameFence(null, 2);
}

/// The drawn handles: every part's screen anchor, in part order (`/api/tool/handles` is
/// refreshed by the tool's draw; read after the frame fence).
private double[] handleScreens() {
    double[] out_;
    auto h = getJson("/api/tool/handles")["handles"];
    if (h.type != JSONType.object) return out_;
    foreach (p; h["parts"].array) {
        out_ ~= p["part"].integer;
        if (p["screen"].type == JSONType.array)
            foreach (v; p["screen"].array)
                out_ ~= v.type == JSONType.integer ? v.integer : v.floating;
    }
    return out_;
}

private bool sameScreens(const double[] a, const double[] b) {
    import std.math : abs;
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) if (abs(a[i] - b[i]) > 1e-5) return false;
    return true;
}

// The base of a new operation is set when the operation ENDS (model §R6.2): a scripted
// write after a haul (M-PS) rebases the tool on the live mesh, and on a live mesh the
// rebase body recomputes the gizmo there (`else computeGizmoFrame()`). Control at the
// site: a fresh script arm of the same tool on the same mesh, the same write. The six
// tools whose rebase body carries the gizmo "dance"; rigs: their families' cells.
// Polarity: false before S3 (every tool an offender — the gizmo stays on the old base),
// true after.
unittest {
    if (skipFor("rebase_gizmo")) return;
    immutable string[2][] rigs = [
        ["smooth_direct", "shift"], ["pextrude_direct", "distance"],
        ["eextrude_mech", "extrude"], ["ebevel_row", "width"],
        ["vbevel_dormant", "inset"], ["vextrude_row", "width"]];
    string[] offenders;
    size_t visited;
    foreach (r; rigs) {
        const cell = fixtureCell(r[0]);
        const rig = rigOf(cell["variant"].str);
        const ctx = "rebase gizmo " ~ rig.tool;
        setupCell(cell, rig);
        runStep(cell["steps"][0], rig, ctx);              // script arm
        assert(cell["steps"][0]["op"].str == "arm" && cell["steps"][0]["door"].str == "script",
            "rig VOID " ~ ctx ~ ": the cell does not open with a script arm");
        const armed = handleScreens();
        runStep(cell["steps"][1], rig, ctx);              // haul: moves the image
        const write = "tool.attr " ~ rig.tool ~ " " ~ r[1] ~ " 0.05";
        cmdOkHere(write, ctx);                            // M-PS: ends the operation
        const live = handleScreens();
        string meshNow() {   // the mesh, less the read's own timestamp
            auto m = getJson("/api/model");
            m.object.remove("timestamp");
            return m.toString;
        }
        const model = meshNow();
        cmdOkHere("tool.set " ~ rig.tool ~ " off", ctx);
        assert(meshNow() == model,
            "rig VOID " ~ ctx ~ ": the drop changed the mesh (the control needs the same mesh)");
        cmdOkHere("tool.set " ~ rig.tool ~ " on", ctx);
        cmdOkHere(write, ctx);
        const control = handleScreens();
        cmdOkHere("tool.set " ~ rig.tool ~ " off", ctx);
        assert(control.length > 0, "rig VOID " ~ ctx ~ ": the control arm draws no handle");
        assert(!sameScreens(armed, control),
            "rig VOID " ~ ctx ~ ": the haul did not move the gizmo");
        ++visited;
        if (!sameScreens(live, control)) offenders ~= rig.tool;
    }
    assert(visited == 6, "rebase gizmo: " ~ visited.to!string ~ " of the six dance tools visited");
    assert(offenders.length == 0, "rebase on close recomputes the gizmo on the live mesh: "
        ~ offenders.to!string ~ " keep the gizmo of the old base (expected none)");
}

// A scripted attribute write ends the operation (M-PS) and rebases on the live mesh —
// the rebase body's gizmo dance is guarded by `basis.matches(*mesh)`, so no mesh write:
// `totalPolygons` of /api/changes (moved by every `MeshSnapshot.restore`) stays put.
// Positive control at the site: the haul b1 moves it.
unittest {
    if (skipFor("script_write_no_mesh_write")) return;
    const cell = fixtureCell("ebevel_row");
    const rig = rigOf(cell["variant"].str);
    enum ctx = "script write is not a mesh write";
    setupCell(cell, rig);
    runStep(cell["steps"][0], rig, ctx);
    long polys() { return getJson("/api/changes")["totalPolygons"].integer; }
    const p0 = polys();
    runStep(cell["steps"][1], rig, ctx);
    const p1 = polys();
    assert(p1 != p0, "rig VOID " ~ ctx ~ ": the haul b1 moved no totalPolygons");
    cmdOkHere("tool.attr " ~ rig.tool ~ " width 0.03", ctx);
    const p2 = polys();
    cmdOkHere("tool.set " ~ rig.tool ~ " off", ctx);
    assert(p2 == p1, "a script attribute write is not a mesh write: totalPolygons moved by "
        ~ (p2 - p1).to!string);
}

unittest { // every cell was played and compared (a skipped cell is not a green one)
    import std.process : environment;
    if (environment.get("VIBE3D_CELL", "").length || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    assert(cellsCompared == kCellCount, "the suite compared " ~ cellsCompared.to!string
        ~ " cells of the family's " ~ kCellCount.to!string);
}
