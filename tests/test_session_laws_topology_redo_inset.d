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
    "close_drop_inset_ui", "close_drop_redo_inset_ui", "close_enter_inset_ui",
    "cmdattrs_nozr_pextrude", "cmdattrs_zr_pextrude_free", "cmdattrs_zr_pextrude_handle",
    "cmdclose_press_vmerge_gdb", "doapply_after_sa_inset", "doapply_after_sa_pextrude",
    "doapply_after_sa_smooth", "dormant2_inset", "dormant2_inset_ui", "dormant3_cross_inset_ui",
    "dormant3_inset", "dormant3_inset_ui", "fold_close_inset", "fold_close_inset_ui",
    "fold_restart_pextrude", "fold_restart_pextrude_ui", "inset_direct", "inset_dormant",
    "inset_dormant_ui", "inset_mech", "inset_mech_ui", "inset_ui_direct", "inset_ui_redo",
    "moment_inset", "moment_inset_ui", "moment_restart_pextrude", "moment_restart_pextrude_ui",
    "nav_redo_opens_inset", "nav_redo_opens_inset_ui", "nav_redo_refire_inset",
    "nav_redo_refire_inset_ui", "nav_redo_restart_pextrude", "nav_redo_restart_pextrude_ui",
    "nav_undo_refire_inset", "nav_undo_refire_inset_ui", "nav_undo_restart_pextrude",
    "nav_undo_restart_pextrude_ui", "pairundo_pred_inset_ui", "param_after_undo_inset_script",
    "param_after_undo_inset_ui", "param_between_inset_script", "param_between_inset_uc",
    "param_between_inset_ui", "param_between_moment_inset_script", "param_between_moment_inset_ui",
    "param_closed_after_end_inset", "param_closed_inset_ui", "param_rebegun_redo_inset",
    "param_rebegun_undo_inset_ui", "param_twohaul_inset_script", "pextrude_direct",
    "pextrude_direct_ui", "rclick_close_inset_script", "rclick_close_inset_ui", "rearm_inset_ui",
    "rearm_smooth_ui", "rearm_vmerge", "rebegin_redo_closed_inset", "rebegin_redo_closed_inset_ui",
    "rebegin_undo_close_inset", "rebegin_undo_close_inset_ui", "rebegin_undo_cmd_inset_ui",
    "reset_inset", "reset_inset_ui", "smooth_attrs_script", "smooth_attrs_ui", "smooth_direct",
    "smooth_direct_ui", "smooth_dormant", "smooth_dormant_ui", "thicken_direct",
    "thicken_direct_ui", "thicken_dormant", "thicken_dormant_ui", "vmerge_discrim",
    "vmerge_discrim_ui", "vmerge_dormant", "vmerge_dormant_ui", "wundo_restart_vmerge_gdb",
    "xinst_ctrl_inset_ui", "xinst_trunc_inset_ui"
];

// `freeze_fixture.py --family inset` (2026-10-02, + 8960 3 cells, 8980 3 cells, 9030 2 cells,
// 8940 C7, 9160 C10-c1, 9270 C9 3 cells, C10-r 2 cells):
// TOPO-REDO-CELLS family=inset cells=87 checkpoints=1005 …
enum long kCellCount = 87;
enum long kCheckpointCount = 1005;

// The helper's redo-step count (`redoStepCount`, wave plan §21-D): the pair's three terms,
// each where the fixture's 10 redo reads cannot reach it.
unittest {
    JSONValue row(string cmd, long session, ulong flags = 0x11) {
        JSONValue r;
        r["command"] = cmd; r["session"] = session; r["flags"] = cast(long) flags;
        return r;
    }
    const act = row("tool.activate", 1, 0x411), edit = row("mesh.bevel_edit", 1);
    assert(redoStepCount([act, edit]) == 1, "the UI pair is one redo step");
    assert(redoStepCount([act, row("mesh.bevel_edit", 2)]) == 2,
        "an activation pairs only with its own session's row");
    assert(redoStepCount([row("tool.activate", 0, 0x411), row("select.invert", 0)]) == 2,
        "an activation with no session pairs with nothing");
    assert(redoStepCount([edit, edit]) == 2, "only an activation opens a pair");
    assert(redoStepCount([act, edit, row("mesh.bevel_edit", 1, 0x11 | kJoinsBelow)]) == 1,
        "a row joining the pair below is the pair's step");
}

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
// 102 since S2a (8920): five `armed` fields after the press now match (law 1 settle);
// 104 since S4 (9020): the former (b) points are judged (+5: nav_redo_restart_pextrude
// s12/s13, its _ui s12, nav_undo_restart_pextrude s11/s12) and law 4 closes three
// (moment_restart_pextrude_ui s12/s13, nav_undo_restart_pextrude_ui s12); 96 since the S4
// review (9020): the law-4 seed on a bare activation redo closes nav_undo_restart_pextrude
// s11–s13 and an unjudged tool-off classmate (PF-B) closes nav_redo_restart_pextrude s12–s14
// and its _ui s12/s13 (each `attrs`, ours had the extra classmate); 55 since S7 (9120): law 6
// folds the operation a restart ends, so the undo ladders of fold_restart_pextrude(_ui) and
// nav_redo_restart_pextrude(_ui) after the press match (41 fields).
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
    // S5 (task 9170, law 3): 55 -> 49 — the six of moment_restart_pextrude(_ui) after the
    // cut are parity (Q5 c1: the restart row survives, the refire after it leaves).
    // 49 -> 46 (plan §21-B/D): fold_restart_pextrude_ui/s12_R (refused, vcount) is a modal
    // point, not judged; moment_restart_pextrude_ui/s10_Z.redoRows counts the UI pair once.
    assert(points == 8 && fields == 46, "fixture family inset holds " ~ points.to!string
        ~ " middle-restart points / " ~ fields.to!string ~ " divergent fields after them, "
        ~ "frozen at 8 / 46");
}

// VertexMerge's first haul merges 3 → 2 at the reference, 3 → 1 here (gap row 486, S3 fix
// 8950): the generator's four `KERNEL_SEEDS` (each `s02_drag`, every other field parity) and
// the later `vcount` fields carrying the seed's (2, 1) pair. Stationary; the exact set of
// this family (`freeze_fixture.py --print-lists`: `LIST kernelOwned n=32`, 2026-10-02: these
// 26 + EdgeExtrude's 6, pinned by the autoact suite). S5 (task 9170, law 3): + the two
// `s07_R` — the second redo is refused at both ends now, the (2, 1) pair stays.
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
        foreach (lab; ["s02_drag", "s04_Z", "s06_R", "s07_R"])
            want ~= cell ~ "/" ~ lab ~ ".vcount";
    foreach (cell, arm; ["vmerge_dormant": "s08_arm", "vmerge_dormant_ui": "s08_armui"])
        foreach (lab; ["s02_drag", "s03_W", "s04_Z", "s06_R", "s07_R", arm, "s09_drag", "s10_Z",
                       "s11_R"])
            want ~= cell ~ "/" ~ lab ~ ".vcount";
    import std.algorithm : sort;
    kernel.sort();
    want.sort();
    assert(want.length == 26 && kernel == want, "fixture: the kernel-owned fields of the "
        ~ "inset family " ~ kernel.to!string ~ " are not VertexMerge's 26");
}

// The later cells' ladders, before any cell (task 8950, S3 fix 2), so a regenerated fixture
// cannot drop the judged checkpoints. Capture 8960 (findings §16): a headless apply after a
// scripted write stacks, Z1 takes the apply alone, Z2 reopens post mode — the fields of
// s04…s06 are judged (`pinApplyLadder`); ours reopens post mode at Z1 (the write records no
// row here, the P3 row of activation/command-close wave V4). Capture 8980 (§17): a typed UI
// command KEEPS PolyExtrude's attributes and leaves the tool not armed; ours keeps them on
// the free Z/R route (parity) and zeroes them where the operation is still open at the
// command (no Z/R, the handle route) — declared, owner S7; `armed` at the command matches
// since law 6 (S7: the command close ends the post mode).
unittest {
    const fx = parseJSON(kFixture);
    foreach (cell; ["doapply_after_sa_smooth", "doapply_after_sa_pextrude", "doapply_after_sa_inset"])
        pinApplyLadder(fx, cell);
    foreach (cell, uc; ["cmdattrs_nozr_pextrude": "s03_UC", "cmdattrs_zr_pextrude_free": "s05_UC",
                        "cmdattrs_zr_pextrude_handle": "s06_UC"]) {
        const ctx = "8980 " ~ cell ~ "/" ~ uc;
        auto a = frozenField(fx, cell, uc, "attrs");
        auto armed = frozenField(fx, cell, uc, "armed");
        // KEEP: the command's attributes equal the checkpoint before it (the redone haul)
        const prev = cell == "cmdattrs_nozr_pextrude" ? "s02" : cell == "cmdattrs_zr_pextrude_free"
            ? "s04" : "s05";
        assert(classHas(a, prev), ctx ~ ": the fixture's command does not keep the attributes: "
            ~ a["ref"].toString);
        // law 6, C2 (S7, 9120): the command ends the operation and the post mode
        assert(armed["ref"].type == JSONType.false_ && ("ours" in armed) is null,
            ctx ~ ": `armed` at the command is not the reference's false, matched (law 6, C2): "
            ~ armed.toString);
        assert(("ours" in a) is null || a["owner"].str == "S7", ctx ~ ": the attributes at the "
            ~ "command diverge under " ~ a["owner"].str ~ ", not S7");
    }
    assert(("ours" in frozenField(fx, "cmdattrs_zr_pextrude_free", "s05_UC", "attrs")) is null,
        "8980: the free Z/R route's attributes at the command are no longer parity");
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

// Task 8950 (re-review): every PolyExtrude haul of the late 8960/8980 cells declares its
// `aim` (the reference has no handle before the first haul), so a dropped declaration
// fails here and not only in the generator's `--check`.
unittest {
    import std.algorithm : startsWith;
    size_t cells, hauls;
    foreach (c; parseJSON(kFixture)["cells"].array) {
        const id = c["id"].str;
        if (!id.startsWith("cmdattrs_") && id != "doapply_after_sa_pextrude") continue;
        ++cells;
        foreach (st; c["steps"].array)
            if (st["op"].str == "haul") {
                ++hauls;
                assert("aim" in st, "fixture: " ~ id ~ "/" ~ st["label"].str
                    ~ " is a PolyExtrude haul with no `aim` declaration");
            }
    }
    assert(cells == 4 && hauls > 0, "fixture: the late PolyExtrude cells are "
        ~ cells.to!string ~ " with " ~ hauls.to!string ~ " hauls, frozen at 4 with at least one");
}

// Task 9020 (wave S4), law 4's orphan (model doc §R9): the reference redoes each row of
// param_between_moment_inset_script after the script activation came back (s09_R) and
// reads `inset 0.0` on every R — the rows' instance is gone. The fixture field is V4's
// (plan §16.5: its class holds a V4 classmate), so the VALUE is pinned here: ours s10, s11,
// s12 read the attributes of s09. Positive control: the rows themselves changed the image.
unittest {
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    if ((only.length && only != "orphan_redo_values")
        || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    JSONValue cell;
    foreach (c; parseJSON(kFixture)["cells"].array)
        if (c["id"].str == "param_between_moment_inset_script") cell = c;
    assert(cell.type == JSONType.object, "fixture holds no param_between_moment_inset_script");
    const run = playCell(cell);
    const(Obs)* at(string label) {
        foreach (ref o; run.obs) if (o.label == label) return &o;
        assert(false, "orphan redo: no checkpoint " ~ label);
    }
    assert(at("s10_R").image != at("s09_R").image && at("s12_R").image != at("s10_R").image,
        "rig VOID orphan redo: the redone rows changed no image");
    foreach (lab; ["s10_R", "s11_R", "s12_R"])
        assert(at(lab).attrs == at("s09_R").attrs, "law 4 (orphan): the redo " ~ lab
            ~ " wrote the attributes of a row another instance recorded: " ~ at(lab).attrs
            ~ ", the re-created tool read " ~ at("s09_R").attrs ~ " at s09_R");
    import http_client : postJson;
    postJson("/api/command", "tool.set " ~ rigOf(cell["variant"].str).tool ~ " off");
}

unittest { // every cell was played and compared (a skipped cell is not a green one)
    import std.process : environment;
    if (environment.get("VIBE3D_CELL", "").length || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    assert(cellsCompared == kCellCount, "the suite compared " ~ cellsCompared.to!string
        ~ " cells of the family's " ~ kCellCount.to!string);
}
