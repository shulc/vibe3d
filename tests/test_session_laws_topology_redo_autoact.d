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
import topology_redo_law_helpers;

void main() {}

enum string kFixture = import("fixtures/topology_redo_law_cells.json");

/// The family's cells (the generator's `--family autoact` census, measured literal).
immutable string[] kCells = [
    "begin_redo_select_haul_eextrude", "begin_undone_haul_ebevel", "close_cmd_eextrude_script",
    "close_cmd_eextrude_ui", "ebevel_dormant", "ebevel_dormant_ui", "ebevel_row",
    "ebevel_row_ui", "eextrude_mech", "eextrude_mech_ui", "fold_close_eextrude",
    "fold_close_eextrude_ui", "fold_restart_eextrude", "fold_restart_eextrude_ui",
    "moment_eextrude", "moment_eextrude_ui", "nav_redo_refire_ebevel",
    "nav_redo_refire_ebevel_ui", "nav_redo_restart_eextrude", "nav_redo_restart_eextrude_ui",
    "nav_undo_refire_ebevel", "nav_undo_refire_ebevel_ui", "nav_undo_restart_eextrude",
    "nav_undo_restart_eextrude_ui", "param_after_arm_ebevel_script",
    "param_between_ebevel_script", "param_between_ebevel_ui", "param_between_moment_ebevel_ui",
    "param_closed_ebevel_ui", "rclick_close_eextrude_ui", "rebegin_redo_act_ebevel",
    "rebegin_redo_act_ebevel_ui", "vbevel_actundo", "vbevel_actundo_ui", "vbevel_dormant",
    "vbevel_dormant_ui", "vextrude_dormant", "vextrude_dormant_ui", "vextrude_row",
    "vextrude_row_ui"
];

// `freeze_fixture.py --family autoact` (2026-10-01):
// TOPO-REDO-CELLS family=autoact cells=40 checkpoints=492 …
enum long kCellCount = 40;
enum long kCheckpointCount = 492;

unittest { // the floor: the fixture still holds the whole family
    familyFloor(parseJSON(kFixture), "autoact", kCells, kCellCount, kCheckpointCount);
}

// The middle-button restart of EdgeExtrude (plan §11, verdict 8890): one layer per press
// on both sides, so every `_M` point is parity but its `origin` (S2b), and the fields
// after it take their owners by the general rule — none is "none: outside the model"
// (that status belongs to the PolyExtrude tail, inset family). Floor: generator output
// 2026-10-01 — 6 `_M` points (`LIST middleRestartParity n=6`).
unittest {
    const fx = parseJSON(kFixture);
    size_t points;
    foreach (c; fx["cells"].array) {
        if (c["family"].str != "autoact" || !c["measured"].boolean) continue;
        string m;
        foreach (s; c["steps"].array)
            if (s["op"].str == "haul" && s["button"].str == "middle") { m = s["label"].str; break; }
        if (!m.length) continue;
        bool tail;
        foreach (p; c["points"].array) {
            const at = c["id"].str ~ "/" ~ p["label"].str;
            if (p["label"].str == m) {
                tail = true; ++points;
                foreach (field, f; p["fields"].object)
                    assert("ours" !in f || field == "origin", "fixture: " ~ at ~ "." ~ field
                        ~ " — the middle press diverges (plan §11: one layer per press)");
            }
            if (!tail) continue;
            foreach (field, f; p["fields"].object)
                assert("ours" !in f || f["owner"].str != "none: outside the model", "fixture: "
                    ~ at ~ "." ~ field ~ " after the middle press " ~ m ~ " is outside the "
                    ~ "model (plan §11: the general owner rule applies)");
        }
    }
    assert(points == 6, "fixture family autoact holds " ~ points.to!string
        ~ " middle-restart points, frozen at 6");
}

// The kernel owner (reviewer's adjudication of S1b PLAN-FINDING-1, gap row 486): EdgeExtrude
// after `select.invert` rebuilds both faces at the reference (7), ours 9 — a first-haul
// COUNT no law moves; the generator's `KERNEL_SEEDS` names the two seeds, and only the
// `vcount` fields carrying a seed's (reference, ours) pair inherit it. Stationary; the
// exact set (`freeze_fixture.py --print-lists`: `LIST kernelOwned n=6`, 2026-10-01).
unittest {
    const fx = parseJSON(kFixture);
    string[] kernel;
    foreach (c; fx["cells"].array)
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

unittest { // every cell was played and compared (a skipped cell is not a green one)
    import std.process : environment;
    if (environment.get("VIBE3D_CELL", "").length || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    assert(cellsCompared == kCellCount, "the suite compared " ~ cellsCompared.to!string
        ~ " cells of the family's " ~ kCellCount.to!string);
}
