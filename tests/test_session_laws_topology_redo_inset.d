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
// the "backlog: PR" fields are exactly the plan's table (§4.7 R8: six written by S1a,
// `s07_drag.origin` by S2b 8930, the ten `vcount` rows by S3 8950 — the +5 of
// `s03_drag.vcount` they carried until S3, plan §11, is gone: 17 fields, the whole table).
immutable string[] kBacklogPR = [
    "param_rebegun_undo_inset_ui/s06_UC.image=[]",
    "param_rebegun_undo_inset_ui/s06_UC.vcount=18",
    "param_rebegun_undo_inset_ui/s07_drag.origin=\"restart\"",
    "param_rebegun_undo_inset_ui/s07_drag.vcount=23",
    "param_rebegun_undo_inset_ui/s08_W.vcount=23",
    "param_rebegun_undo_inset_ui/s09_Z.vcount=23",
    "param_rebegun_undo_inset_ui/s10_Z.image=[\"s06\"]",
    "param_rebegun_undo_inset_ui/s10_Z.vcount=18",
    "param_rebegun_undo_inset_ui/s11_Z.armed=true",
    "param_rebegun_undo_inset_ui/s11_Z.image=[\"s03\",\"s04\",\"s05\"]",
    "param_rebegun_undo_inset_ui/s11_Z.on=\"tool\"",
    "param_rebegun_undo_inset_ui/s11_Z.vcount=13",
    "param_rebegun_undo_inset_ui/s13_R.image=[\"s06\",\"s10\"]",
    "param_rebegun_undo_inset_ui/s13_R.vcount=18",
    "param_rebegun_undo_inset_ui/s14_R.vcount=23",
    "param_rebegun_undo_inset_ui/s15_R.vcount=23",
    "param_rebegun_undo_inset_ui/s16_R.vcount=23",
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
        ~ "17: " ~ pr.to!string);
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
    assert(pr == kBacklogPR.length, "fixture: " ~ pr.to!string ~ " law-PR fields, the table "
        ~ "holds " ~ kBacklogPR.length.to!string);
}

// The middle-button restart (gap 462: the reference stacks two layers per press, we stack
// one; a driver double press or a law — not captured): every known divergence from the
// first middle haul of a cell on, except `origin` (S2b's law everywhere), is ONE status,
// outside the model. Floor: generator output 2026-10-01 — 8 `_M` points, 107 fields;
// 102 since S2a (8920): five `armed` fields after the press now match (law 1 settle).
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
    assert(points == 8 && fields == 102, "fixture family inset holds " ~ points.to!string
        ~ " middle-restart points / " ~ fields.to!string ~ " divergent fields after them, "
        ~ "frozen at 8 / 102");
}

// VertexMerge's first haul merges 3 → 2 at the reference, 3 → 1 here (gap row 486, S3 fix
// 8950): the generator's four `KERNEL_SEEDS` (each `s02_drag`, every other field parity) and
// the later `vcount` fields carrying the seed's (2, 1) pair. Stationary; the exact set of
// this family (`freeze_fixture.py --print-lists`: `LIST kernelOwned n=30`, 2026-10-02: these
// 24 + EdgeExtrude's 6, pinned by the autoact suite).
unittest {
    const fx = parseJSON(kFixture);
    string[] kernel;
    foreach (c; fx["cells"].array)
        if (c["family"].str == "inset")
        foreach (p; c["points"].array)
            foreach (field, f; p["fields"].object)
                if ("ours" in f && f["owner"].str == "none: kernel (gap row 486)")
                    kernel ~= c["id"].str ~ "/" ~ p["label"].str ~ "." ~ field;
    string[] want;
    foreach (cell; ["vmerge_discrim", "vmerge_discrim_ui"])
        foreach (lab; ["s02_drag", "s04_Z", "s06_R"])
            want ~= cell ~ "/" ~ lab ~ ".vcount";
    foreach (cell, arm; ["vmerge_dormant": "s08_arm", "vmerge_dormant_ui": "s08_armui"])
        foreach (lab; ["s02_drag", "s03_W", "s04_Z", "s06_R", "s07_R", arm, "s09_drag", "s10_Z",
                       "s11_R"])
            want ~= cell ~ "/" ~ lab ~ ".vcount";
    import std.algorithm : sort;
    kernel.sort();
    want.sort();
    assert(want.length == 24 && kernel == want, "fixture: the kernel-owned fields of the "
        ~ "inset family " ~ kernel.to!string ~ " are not VertexMerge's 24");
}

static foreach (id; kCells) {
    unittest { runCell(parseJSON(kFixture), id); }
}

// Task 8930 (wave S2b), M-N2: an undo inside the same session reopens the operation of
// the row it took off — after the middle restart M is undone, the next haul refires M's
// operation, not g1's (`stepOperation` is not a fixture field: read from /api/history
// on the cell's own steps s01…s05).
unittest {
    import http_client : getJson;
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    if ((only.length && only != "n2_restart_operation")
        || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    JSONValue cell;
    foreach (c; parseJSON(kFixture)["cells"].array)
        if (c["id"].str == "nav_undo_restart_pextrude") cell = c;
    assert(cell.type == JSONType.object, "fixture holds no nav_undo_restart_pextrude (the N2 rig)");
    const rig = rigOf(cell["variant"].str);
    setupCell(cell, rig);
    JSONValue top() { return getJson("/api/history")["undo"].array[$ - 1]; }
    long[string] op;
    foreach (k; 0 .. 5) {
        const step = cell["steps"][k];
        runStep(step, rig, "N2 " ~ step["label"].str);
        if (step["op"].str == "haul") op[step["label"].str] = top()["stepOperation"].integer;
    }
    assert(op["s02_drag"] != op["s03_M"], "N2 rig: the middle restart did not open its own operation");
    assert(top()["stepOrigin"].str == "refire" && op["s05_drag"] == op["s03_M"],
        "N2: the haul after undoing M is " ~ top()["stepOrigin"].str ~ " of operation "
        ~ op["s05_drag"].to!string ~ ", expected a refire of M's " ~ op["s03_M"].to!string
        ~ " (g1's is " ~ op["s02_drag"].to!string ~ ")");
}

// Task 8950 (wave S3), law E6: the base of a new operation is the image at the press
// that opens it — the selection included. PolyInset script-armed on face 0 (the rig's
// pentagon), `mesh.select` of face 1 (its triangle), a haul: the inset is on the triangle
// (+3 vertices), not the pentagon (+5). OUR check (not a fixture cell): the opening press
// rebases a stale base (`ToolSession.notePointerDown`).
unittest {
    import http_client : getJson, postJson;
    import http_command_helpers : commandBody;
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    if ((only.length && only != "select_between_arm_and_haul")
        || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    JSONValue cell;
    foreach (c; parseJSON(kFixture)["cells"].array)
        if (c["id"].str == "inset_direct") cell = c;
    assert(cell.type == JSONType.object, "fixture holds no inset_direct (the E6 rig)");
    const rig = rigOf(cell["variant"].str);
    enum ctx = "E6 selection";
    const base = setupCell(cell, rig);
    assert(base == 8, "rig VOID " ~ ctx ~ ": the rig holds " ~ base.to!string ~ " vertices, not 8");
    runStep(cell["steps"][0], rig, ctx);
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[1]}`));
    assert(r["status"].str == "ok", ctx ~ ": mesh.select failed: " ~ r.toString);
    auto st = getJson("/api/tool/state");
    assert("session" in st, "rig VOID " ~ ctx ~ ": the selection dropped the tool");
    runStep(cell["steps"][1], rig, ctx);
    const n = cast(long) getJson("/api/model")["vertices"].array.length;
    postJson("/api/command", "tool.set " ~ rig.tool ~ " off");
    assert(n == base + 3, "E6: the first haul after a selection change insets the selection "
        ~ "at the press (face 1, +3), got " ~ (n - base).to!string ~ " new vertices");
}

unittest { // every cell was played and compared (a skipped cell is not a green one)
    import std.process : environment;
    if (environment.get("VIBE3D_CELL", "").length || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    assert(cellsCompared == kCellCount, "the suite compared " ~ cellsCompared.to!string
        ~ " cells of the family's " ~ kCellCount.to!string);
}
