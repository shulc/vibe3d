// Topology-redo laws, inset family (PolyInset, SmoothShift, Thicken, VertexMerge,
// PolyExtrude): every checkpoint of every captured cell of the family, replayed on our
// product and compared relation by relation with the frozen reference
// (`tests/fixtures/topology_redo_law_cells.json`; executor and comparison:
// tests/topology_redo_law_helpers.d). Wave plan topology-redo, slice S1a.
//
// A green run says: every parity field still matches the reference AND every
// declared known divergence is still exactly the declared one. A divergence that a
// later slice closes (or moves) turns its cell red with "divergence closed or moved:
// <cell>/<point> law <n> — flip to parity in <owner>": the owner flips the field to
// parity in the same commit. Order (form item 2): the family floor first, then one
// `unittest` per cell.

import std.conv : to;
import std.json;
import topology_redo_law_helpers;

void main() {}

enum string kFixture = import("fixtures/topology_redo_law_cells.json");

/// The family's cells (the generator's `--family inset` census, measured literal).
immutable string[] kCells = [
    "close_cmd_inset_script", "close_cmd_inset_ui", "close_drop_inset_script",
    "close_drop_inset_ui", "close_enter_inset_ui", "dormant2_inset", "dormant2_inset_ui",
    "dormant3_cross_inset_ui", "dormant3_inset", "dormant3_inset_ui", "fold_close_inset",
    "fold_close_inset_ui", "fold_restart_pextrude", "fold_restart_pextrude_ui",
    "inset_direct", "inset_dormant", "inset_dormant_ui", "inset_mech", "inset_mech_ui",
    "inset_ui_direct", "inset_ui_redo", "moment_inset", "moment_inset_ui",
    "moment_restart_pextrude", "moment_restart_pextrude_ui", "nav_redo_opens_inset",
    "nav_redo_opens_inset_ui", "nav_redo_refire_inset", "nav_redo_refire_inset_ui",
    "nav_redo_restart_pextrude", "nav_redo_restart_pextrude_ui", "nav_undo_refire_inset",
    "nav_undo_refire_inset_ui", "nav_undo_restart_pextrude",
    "nav_undo_restart_pextrude_ui", "param_after_undo_inset_script",
    "param_after_undo_inset_ui", "param_between_inset_script", "param_between_inset_uc",
    "param_between_inset_ui", "param_between_moment_inset_script",
    "param_between_moment_inset_ui", "param_closed_after_end_inset",
    "param_closed_inset_ui", "param_rebegun_redo_inset", "param_rebegun_undo_inset_ui",
    "param_twohaul_inset_script", "pextrude_direct", "pextrude_direct_ui",
    "rclick_close_inset_script", "rclick_close_inset_ui", "rebegin_redo_closed_inset",
    "rebegin_redo_closed_inset_ui", "rebegin_undo_close_inset",
    "rebegin_undo_close_inset_ui", "rebegin_undo_cmd_inset_ui", "reset_inset",
    "reset_inset_ui", "smooth_attrs_script", "smooth_attrs_ui", "smooth_direct",
    "smooth_direct_ui", "smooth_dormant", "smooth_dormant_ui", "thicken_direct",
    "thicken_direct_ui", "thicken_dormant", "thicken_dormant_ui", "vmerge_discrim",
    "vmerge_discrim_ui", "vmerge_dormant", "vmerge_dormant_ui"
];

// `freeze_fixture.py --family inset` (2026-10-01):
// TOPO-REDO-CELLS family=inset cells=72 checkpoints=868 …
enum long kCellCount = 72;
enum long kCheckpointCount = 868;

unittest { // the floor: the fixture still holds the whole family
    familyFloor(parseJSON(kFixture), "inset", kCells, kCellCount, kCheckpointCount);
}

// The fixture's structure, before any cell: the class rule's triples are exactly the
// frozen `classOwned` (plan §4.7 R8 rule 1; generator output 2026-10-01: none), and
// the "backlog: PR" fields are exactly those of the plan's table today's run already
// gives (§4.7 R8: written by S1a; the rest are written by S2b).
immutable string[] kBacklogPR = [
    "param_rebegun_undo_inset_ui/s06_UC.image=[]",
    "param_rebegun_undo_inset_ui/s10_Z.image=[\"s06\"]",
    "param_rebegun_undo_inset_ui/s11_Z.armed=true",
    "param_rebegun_undo_inset_ui/s11_Z.image=[\"s03\",\"s04\",\"s05\"]",
    "param_rebegun_undo_inset_ui/s11_Z.on=\"tool\"",
    "param_rebegun_undo_inset_ui/s13_R.image=[\"s06\",\"s10\"]",
];

unittest {
    const fx = parseJSON(kFixture);
    assert(classOwnedTriples(fx).length == 0,
        "the class rule now gives owners to classmates the generator did not freeze");
    string[] pr;
    foreach (c; fx["cells"].array)
        foreach (p; c["points"].array)
            foreach (field, f; p["fields"].object)
                if ("owner" in f && f["owner"].str == "backlog: PR")
                    pr ~= c["id"].str ~ "/" ~ p["label"].str ~ "." ~ field ~ "=" ~ f["ours"].toString;
    import std.algorithm : sort;
    pr.sort();
    assert(pr == kBacklogPR, "the fixture's backlog: PR fields are not the plan table's "
        ~ "today-part: " ~ pr.to!string);
}

// A table field not yet at its table value belongs to the general owner rule until its
// «вводит» slice (§4.7 R8 п.2): no field carries `law PR` under an in-wave owner.
unittest {
    const fx = parseJSON(kFixture);
    size_t pr;
    foreach (c; fx["cells"].array)
        foreach (p; c["points"].array)
            foreach (field, f; p["fields"].object)
                if ("law" in f && f["law"].str == "PR") {
                    ++pr;
                    assert(f["owner"].str == "backlog: PR", "fixture: " ~ c["id"].str ~ "/"
                        ~ p["label"].str ~ "." ~ field ~ " is law PR under owner " ~ f["owner"].str
                        ~ " (until its slice it belongs to the general owner rule)");
                }
    assert(pr == kBacklogPR.length, "fixture: " ~ pr.to!string ~ " law-PR fields, the table's "
        ~ "today-part holds " ~ kBacklogPR.length.to!string);
}

// The middle-button restart (gap 462: the reference stacks two layers per press, we stack
// one; a driver double press or a law — not captured): every known divergence from the
// first middle haul of a cell on, except `origin` (S2b's law everywhere), is ONE status,
// outside the model. Floor: generator output 2026-10-01 — 8 `_M` points, 107 fields.
unittest {
    const fx = parseJSON(kFixture);
    size_t points, fields;
    foreach (c; fx["cells"].array) {
        if (c["family"].str != "inset" || !c["measured"].boolean) continue;
        string m;
        foreach (s; c["steps"].array)
            if (s["op"].str == "haul" && s["button"].str == "middle") { m = s["label"].str; break; }
        if (!m.length) continue;
        bool tail;
        foreach (p; c["points"].array) {
            if (p["label"].str == m) { tail = true; ++points; }
            if (!tail) continue;
            foreach (field, f; p["fields"].object) {
                if ("ours" !in f || field == "origin") continue;
                ++fields;
                assert(f["owner"].str == "none: outside the model", "fixture: " ~ c["id"].str
                    ~ "/" ~ p["label"].str ~ "." ~ field ~ " after the middle restart " ~ m
                    ~ " is owned by " ~ f["owner"].str ~ " (gap 462: outside the model)");
            }
        }
    }
    assert(points == 8 && fields == 107, "fixture family inset holds " ~ points.to!string
        ~ " middle-restart points / " ~ fields.to!string ~ " divergent fields after them, "
        ~ "frozen at 8 / 107");
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
