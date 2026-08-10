// Frozen reference behaviour — the mesh EDIT TARGET is latched, not derived
// from the item selection. It tracks the last-selected MESH and is untouched
// by selecting a non-mesh item.
// Fixture: tests/fixtures/layer_main_latched.json.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
// An edit target derived from the item selection — the obvious reading, and
// the one that makes selecting a reference image drag the mesh. That
// implementation reads the NON-MESH item (index 2) at steps 3 and 5, where
// the correct one reads the last-selected mesh (index 1, then index 0).
//
// TWO GUARDS, because "the edit target did not move" is also what a broken
// or constant read reports:
//   * The CONTROL row (step 2) selects a different MESH and requires the edit
//     target to move. A constant read fails there.
//   * On EVERY step the item-selection FOCUS is required to have landed on the
//     last item the row names. Without this, "the edit target did not move"
//     could simply mean the select did nothing at all.
// Steps 3 and 5 latch onto DIFFERENT meshes, so the answer also cannot be a
// value pinned to one particular layer.
//
// WHY STEP 6 IS NOT A REPEAT OF STEPS 1/2/4
// -----------------------------------------
// Step 6's edit-target column cannot fail on its own: it opens with
// `set mesh A`, which already forces the edit target to mesh A, so an `add`
// that does nothing would read the right answer. It is the only row that
// issues an `add` at all — steps 1, 2 and 4 are exclusive `set`s on a mesh,
// steps 3 and 5 exclusive `set`s on the non-mesh item — so the FOCUS and SET
// columns asserted here are the only place a wrong `add` arm is visible:
//   * an `add` of a non-mesh item that is a no-op (its kind cannot be the edit
//     target, so "it cannot join the selection either" is the tempting wrong
//     reading) leaves the focus on mesh A;
//   * an `add` that behaves exclusively evicts mesh A from the set;
//   * an `add` that lets the non-mesh item take the edit target is caught by
//     the edit-target column, which IS live on this row.
// The SET is asserted only on the rows whose `set_asserted` is true — steps 3
// and 5 are the two where vibe3d's ≥1-primary-eligible invariant makes its set
// legitimately differ from the reference's (see the fixture's
// `secondary_difference_not_asserted`).

import std.net.curl;
import std.json;
import std.algorithm : sort;
import std.conv   : to;
import std.format : format;
import std.file   : mkdirRecurse, write;
import std.path   : buildPath;

import fixture_helpers : requireProvenance;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string) get(baseUrl ~ path)); }

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void postOk(string path, string body_) {
    auto j = parseJSON(cast(string) post(baseUrl ~ path, body_));
    assert(j["status"].str == "ok", path ~ " failed: " ~ j.toString);
}

// A minimal uncompressed 24-bit BMP, written rather than checked in — the
// non-mesh item this fixture needs is created by loading an image, and the
// loader wants a real file. Mirrors tests/test_image_commands.d's helper.
immutable scratch = "/tmp/vibe3d_latched_img";

string writeBmp(string name, int w, int h) {
    mkdirRecurse(scratch);
    auto path = buildPath(scratch, name);
    ubyte[] b;
    void u16(ushort v) { b ~= cast(ubyte)(v & 0xFF); b ~= cast(ubyte)((v >> 8) & 0xFF); }
    void u32(uint v) {
        b ~= cast(ubyte)(v & 0xFF);         b ~= cast(ubyte)((v >> 8)  & 0xFF);
        b ~= cast(ubyte)((v >> 16) & 0xFF); b ~= cast(ubyte)((v >> 24) & 0xFF);
    }
    immutable size_t rowBytes = cast(size_t)((w * 3 + 3) & ~3);
    immutable size_t pixBytes = rowBytes * h;
    b ~= cast(ubyte)'B'; b ~= cast(ubyte)'M';
    u32(cast(uint)(54 + pixBytes));
    u16(0); u16(0); u32(54); u32(40);
    u32(cast(uint) w); u32(cast(uint) h);
    u16(1); u16(24); u32(0); u32(cast(uint) pixBytes);
    u32(2835); u32(2835); u32(0); u32(0);
    foreach (y; 0 .. h) {
        foreach (x; 0 .. w) {
            b ~= cast(ubyte)(x * 7 + 3); b ~= cast(ubyte)(y * 11 + 5); b ~= cast(ubyte)(x * 3 + y);
        }
        foreach (_; 0 .. rowBytes - cast(size_t)(w * 3)) b ~= cast(ubyte) 0;
    }
    write(path, b);
    return path;
}

struct DocState { long primary = -1; long focused = -1; long[] selected; }

DocState docState() {
    DocState s;
    foreach (l; getJson("/api/layers")["layers"].array) {
        immutable long i = l["index"].integer;
        if (l["selected"].type == JSONType.true_) s.selected ~= i;
        if (l["primary"].type  == JSONType.true_) s.primary = i;
        if ("focused" in l && l["focused"].type == JSONType.true_) s.focused = i;
    }
    return s;
}

// The fixture's labels -> layer indices in the rig built below.
long indexOfLabel(JSONValue rig, string label) {
    foreach (string k, v; rig["labels"])
        if (v.str == label) return k.to!long;
    assert(false, "fixture rig has no label '" ~ label ~ "'");
}

unittest {
    enum string fixtureJson = import("fixtures/layer_main_latched.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "layer_main_latched");

    auto rig = fx["rig"];
    assert(rig["meshes"].integer == 2 && rig["non_mesh_items"].integer == 1,
           "fixture premise: two meshes are required — a one-mesh scene cannot "
           ~ "tell 'latched' from 'constant'");

    immutable long iMeshA   = indexOfLabel(rig, "mesh A");
    immutable long iMeshB   = indexOfLabel(rig, "mesh B");
    immutable long iNonMesh = indexOfLabel(rig, "non-mesh item");

    // ---- build the rig: two meshes, then a non-mesh item -------------------
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"layer.add"}`);
    {
        auto path = writeBmp("latched.bmp", 3, 2);
        cmd(`{"id":"image.load","path":` ~ JSONValue(path).toString ~ `}`);
    }

    {
        auto layers = getJson("/api/layers")["layers"].array;
        assert(layers.length == 3, format("rig has three items, got %d", layers.length));
        assert(layers[cast(size_t) iMeshA]["type"].str == "mesh", "item 0 is a mesh");
        assert(layers[cast(size_t) iMeshB]["type"].str == "mesh", "item 1 is a mesh");
        assert(layers[cast(size_t) iNonMesh]["type"].str != "mesh",
               "item 2 must be a NON-mesh item, got type "
               ~ layers[cast(size_t) iNonMesh]["type"].str);
    }

    // The six steps, in order. Each names the layer to select and how.
    static struct Step { size_t id; long[] setThenAdd; }
    immutable Step[] steps = [
        Step(1, [0]),
        Step(2, [1]),
        Step(3, [2]),
        Step(4, [0]),
        Step(5, [2]),
        Step(6, [0, 2]),
    ];

    long[] editTargetPerStep;

    foreach (st; steps) {
        foreach (i, idx; st.setThenAdd)
            cmd(format("layer.select index:%d mode:%s", idx, i == 0 ? "set" : "add"));

        auto row  = fx["rows"].array[st.id - 1];
        assert(row["step"].integer == st.id, "fixture rows are in step order");

        immutable long wantTarget = indexOfLabel(rig, row["edit_target"].str);
        auto got = docState();
        editTargetPerStep ~= got.primary;

        // TASK 0668 — the edit-target column is a MARKED DIVERGENCE on the two
        // rows that select the non-mesh item exclusively. The reference keeps
        // the target latched; we no longer have one to keep. Rows without a
        // `divergence` key are unchanged live-parity rows, control included.
        if (auto dk = "divergence" in row) {
            auto div = fx["classification"]["divergences"][dk.str];
            immutable string status = div["status"].str;
            assert(status == "open" || status == "closed",
                   format("step %d: divergence status must be exactly \"open\" or "
                          ~ "\"closed\", read \"%s\" — a typo must not silently pick "
                          ~ "the parity branch", st.id, status));
            immutable long frozenOurs = row["vibe3d_measured_edit_target"].integer;
            // `closed_by` must name a real CARD, not a phrase — a marker whose
            // closer is prose ("model M") sends the reader looking for a task
            // that may not exist. Four digits, and nothing else.
            immutable string closedBy = div["closed_by"].str;
            assert(closedBy.length == 4
                   && closedBy[0] >= '0' && closedBy[0] <= '9'
                   && closedBy[1] >= '0' && closedBy[1] <= '9'
                   && closedBy[2] >= '0' && closedBy[2] <= '9'
                   && closedBy[3] >= '0' && closedBy[3] <= '9',
                   format("step %d: `closed_by` must be a four-digit task number, "
                          ~ "read \"%s\" — a marker that names a phrase instead of a "
                          ~ "card cannot be looked up", st.id, closedBy));
            // The SET is what tells a real model-M landing from a REVERT of
            // task 0668: both restore the latched target, but only a real fix
            // keeps the reference's set (the non-mesh item alone). Computed
            // here so the retirement message below can name the right one —
            // "the gap closed" is the wrong instruction to hand someone who
            // has actually reintroduced the bug the owner reported.
            long[] refSel;
            foreach (lbl; row["item_selection"].array) refSel ~= indexOfLabel(rig, lbl.str);
            refSel.sort();
            immutable bool setMatches = got.selected == refSel;
            if (status == "open") {
                // (1) still differs — checked FIRST, so the day task 0670
                // lands this row says "the gap closed, retire me" rather
                // than reporting a regression.
                assert(got.primary != wantTarget,
                       setMatches
                       ? format("step %d: DIVERGENCE CLOSED — the edit target now stays "
                              ~ "latched on item %d exactly as the reference does, and "
                              ~ "the selected set still matches. Task %s has landed; flip "
                              ~ "`edit_target_unlatches_on_nonmesh_exclusive_select` to "
                              ~ "\"closed\" in the fixture and re-freeze "
                              ~ "`vibe3d_measured_edit_target` on rows 3 and 5.",
                              st.id, wantTarget, closedBy)
                       : format("step %d: the edit target is latched on item %d again, "
                              ~ "but the selected set is %s where the reference holds %s "
                              ~ "— that is task 0668 REVERTED, not task %s landed. The "
                              ~ "mesh is back in the selection, which is the defect the "
                              ~ "owner reported.",
                              st.id, wantTarget, got.selected.to!string,
                              refSel.to!string, closedBy));
                // (2) and still differs in the way we recorded, so an
                // unrelated regression is red too.
                assert(got.primary == frozenOurs,
                       format("step %d: vibe3d reads edit target %d, but the fixture "
                              ~ "froze %d for this open divergence. Neither the "
                              ~ "reference's answer nor ours — this is a regression, "
                              ~ "not a retirement.", st.id, got.primary, frozenOurs));
                // (3) marked means DIFFERENT numbers. Re-arming the flag to
                // silence a regression is then unsatisfiable.
                assert(frozenOurs != wantTarget,
                       format("step %d: a MARKED divergence must record different "
                              ~ "numbers; the fixture froze %d for both engines",
                              st.id, frozenOurs));
            } else {
                assert(got.primary == wantTarget,
                       format("step %d: the divergence is marked \"closed\", so this "
                              ~ "row demands parity — edit target %d, want %d",
                              st.id, got.primary, wantTarget));
                assert(frozenOurs == wantTarget,
                       format("step %d: a RETIRED divergence must record the SAME "
                              ~ "number for both engines; the fixture still holds %d "
                              ~ "against the reference's %d — that is the second half "
                              ~ "of the retiring edit", st.id, frozenOurs, wantTarget));
            }
        } else {
            assert(got.primary == wantTarget,
                   format("step %d (%s): edit target is item %d, want item %d. Reading %d "
                          ~ "would mean the edit target follows the item selection instead of "
                          ~ "latching onto the last-selected mesh.",
                          st.id, row["item_selection"].toString, got.primary, wantTarget,
                          iNonMesh));
        }

        // The selection really landed. The focus is the NEWEST touch, so it
        // must be on the last item the row names — on every row, not just the
        // two latching ones. Step 6 is the row this is load-bearing for: it
        // opens with a `set` that already puts the edit target where the row
        // wants it, so without this the row's `add` could do nothing at all
        // and still read the right edit target.
        immutable long wantFocus =
            indexOfLabel(rig, row["item_selection"].array[$ - 1].str);
        assert(got.focused == wantFocus,
               format("step %d (%s): the item-selection focus must land on the last item "
                      ~ "the row names (%d), got %d — without that this row cannot tell "
                      ~ "'the edit target stayed put' from 'the select was a no-op'",
                      st.id, row["item_selection"].toString, wantFocus, got.focused));

        // The selected SET, on the rows where the reference's set and ours
        // agree. Step 6 is the only multi-item one: it is what says the `add`
        // EXTENDED the selection instead of replacing it.
        if (row["set_asserted"].type == JSONType.true_) {
            long[] wantSel;
            foreach (lbl; row["item_selection"].array) wantSel ~= indexOfLabel(rig, lbl.str);
            wantSel.sort();
            assert(got.selected == wantSel,
                   format("step %d (%s): selected set is %s, want %s — this row's `add` "
                          ~ "must EXTEND the selection, not replace it",
                          st.id, row["item_selection"].toString,
                          got.selected.to!string, wantSel.to!string));
        } else {
            assert("set_not_asserted_why" in row,
                   format("step %d opts out of the set assertion, so the fixture must say "
                          ~ "why", st.id));
        }
    }

    // ---- the control row is what makes the rest mean anything ---------------
    assert(editTargetPerStep[0] != editTargetPerStep[1],
           format("CONTROL (step 2): selecting a different mesh must MOVE the edit target "
                  ~ "(%d -> %d). If it does not, this read is constant or broken and every "
                  ~ "'the edit target did not move' row below is vacuous.",
                  editTargetPerStep[0], editTargetPerStep[1]));
    assert(editTargetPerStep[0] == iMeshA && editTargetPerStep[1] == iMeshB,
           "CONTROL (step 2): the edit target must follow the mesh that was selected");

    // ---- and the two latching steps latch onto DIFFERENT meshes ------------
    //
    // TASK 0668: this cross-row check belongs to the marked divergence. Its
    // job is to prove the latched value is not pinned to one particular layer,
    // which presupposes there IS a latched value. While the divergence is
    // open both rows read the absent-sentinel, so the check inverts: BOTH must
    // report no edit target, which is a real assertion (a half-applied change
    // that unlatched only one of the two rows is red here) and it flips back
    // the day task 0670 lands.
    {
        immutable string status = fx["classification"]["divergences"]
            ["edit_target_unlatches_on_nonmesh_exclusive_select"]["status"].str;
        if (status == "open") {
            assert(editTargetPerStep[2] == -1 && editTargetPerStep[4] == -1,
                   format("steps 3 and 5 must BOTH report no edit target while the "
                          ~ "divergence is open (%d, %d) — one of them latching is a "
                          ~ "half-applied change, not a retirement",
                          editTargetPerStep[2], editTargetPerStep[4]));
        } else {
            assert(editTargetPerStep[2] != editTargetPerStep[4],
                   format("steps 3 and 5 must latch onto different meshes (%d vs %d) — "
                          ~ "otherwise the answer could be a value pinned to one "
                          ~ "particular layer rather than the last mesh selected",
                          editTargetPerStep[2], editTargetPerStep[4]));
        }
    }
}
