// Frozen reference behaviour — the mesh EDIT TARGET and the ITEM SELECTION
// are independent, and BOTH of the states that independence makes
// representable are legal.
// Fixture: tests/fixtures/edit_target_legality.json.
//
// ---------------------------------------------------------------------------
// WHY THIS FILE EXISTS AND `test_fixture_layer_main_latched.d` DOES NOT SUFFICE
// ---------------------------------------------------------------------------
// That fixture measures ONE law: the target survives selecting a non-mesh
// item. Two completely different implementations reproduce it —
//
//   (P) a latched POINTER kept outside the item selection, moved whenever a
//       mesh is selected and otherwise left alone;
//   (H) selectedness is three-valued (current / recently-deselected /
//       neither), the deselect cache is bucketed by item KIND, and the target
//       is the head of a walk over [current ++ history].
//
// — and (P) is the one everybody infers. This file is where they part company.
// Every cell below is a state (P) answers differently:
//
//   * `target_set_nothing_selected` — drop the WHOLE selection. (P) keeps the
//     pointer because nothing selected a mesh. (H) keeps the target because
//     the mesh moved into the mesh bucket. Same answer, and it is the LAST one
//     they agree on; it is here as the legality row, not as a discriminator.
//   * `selection_nonempty_no_target` step 3 — DELETE the mesh holding the
//     target. (P) has a dangling pointer to sweep and a policy to invent for
//     the sweep; (H) enumerates `layers`, so the item stops being an answer
//     with no cooperation from the delete path at all. Step 4 then selects a
//     non-mesh item into that state: (P) implementations that repair a
//     dangling pointer by rehoming onto "some mesh" answer mesh A here, which
//     is a layer the user never picked.
//   * `flush_is_per_item_kind` step 2 — select a SECOND mesh. (P) moves the
//     pointer and the first mesh is background. (H) flushes the mesh bucket,
//     which is why the first mesh loses its state ENTIRELY rather than
//     accumulating into a second foreground layer. `foreground_count == 1` is
//     what says which happened.
//   * `flush_is_per_item_kind` step 3 — `add` the first mesh BACK. The target
//     is the EARLIER of the two selected meshes, not the newest. (P) as
//     usually written ("selecting a mesh moves the latch") answers mesh A.
//     This row is the reason the current selection has to be an ordered queue
//     at all.
//   * `hidden_mesh_keeps_the_target` — hide the target. A model in which
//     foreground means `visible && selected` cannot represent this row: it has
//     to hand the target on or refuse the hide, and the reference does neither.
//
// ---------------------------------------------------------------------------
// THE ASSERTION THAT WOULD BE WORTH NOTHING
// ---------------------------------------------------------------------------
// "there is an edit target" passes today, and passed before this task. Every
// row below reads WHICH item it is, by index, in a rig where the naive and the
// correct model name different ones — and each cell carries at least one
// CONTROL row where the target is required to MOVE, so a constant or frozen
// read is red rather than quietly agreeable.

import std.net.curl;
import std.json;
import std.algorithm : sort, canFind;
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

/// Everything one `/api/layers` read says about the two halves, so a row can
/// never assert the target against one instant and the selection against
/// another.
struct DocState {
    long   editTarget = -1;     ///< the `primary` row, -1 for none
    long   focused    = -1;
    long[] selected;            ///< ascending
    long[] foreground;          ///< ascending; the classifier, not `selected`
    long[] background;
    size_t layerCount;
    string[] names;
}

DocState docState() {
    DocState s;
    foreach (l; getJson("/api/layers")["layers"].array) {
        immutable long i = l["index"].integer;
        ++s.layerCount;
        s.names ~= l["name"].str;
        if (l["selected"].type   == JSONType.true_) s.selected   ~= i;
        if (l["foreground"].type == JSONType.true_) s.foreground ~= i;
        if (l["background"].type == JSONType.true_) s.background ~= i;
        if (l["primary"].type    == JSONType.true_) s.editTarget = i;
        if ("focused" in l && l["focused"].type == JSONType.true_) s.focused = i;
    }
    return s;
}

// A minimal uncompressed 24-bit BMP — the non-mesh item these cells need is
// created by loading an image, and the loader wants a real file. Mirrors
// tests/test_fixture_layer_main_latched.d's helper.
immutable scratch = "/tmp/vibe3d_edit_target_legality";

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

/// Two mesh layers, nothing else. Layer 0 == "mesh A", layer 1 == "mesh B".
void twoMeshRig() {
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"layer.add"}`);
    auto st = docState();
    assert(st.layerCount == 2, format("rig: two mesh layers, got %d", st.layerCount));
}

/// The named cell out of the fixture, so a row cannot be asserted against a
/// cell that was renamed or removed.
JSONValue cellOf(JSONValue fx, string id) {
    foreach (c; fx["cells"].array) if (c["id"].str == id) return c;
    assert(false, "fixture has no cell '" ~ id ~ "'");
}

/// The `foreground_count` a row declares, or -1 when it declares none.
long declaredForegroundCount(JSONValue row) {
    return ("foreground_count" in row) ? row["foreground_count"].integer : -1;
}

unittest {
    enum string fixtureJson = import("fixtures/edit_target_legality.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "edit_target_legality");
    assert(fx["classification"]["verdict"].str == "match",
        "this file asserts PARITY on every cell — if the fixture's verdict is "
        ~ "not \"match\" it is describing a gap nobody has closed, and the rows "
        ~ "below would be pinning the wrong engine's answers");

    // =======================================================================
    // CELL 1 — flush_is_per_item_kind
    //
    // The rule that decides when a target is GIVEN UP, plus the queue-order
    // law. Run first because the other cells lean on its step 2 (a mesh that
    // has lost the target reads BACKGROUND, not as a second foreground layer).
    // =======================================================================
    {
        auto cell = cellOf(fx, "flush_is_per_item_kind");
        auto rows = cell["rows"].array;
        twoMeshRig();

        // --- step 1: select mesh A ------------------------------------------
        cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
        auto s1 = docState();
        assert(s1.editTarget == 0, format("step 1: target must be mesh A, got %d", s1.editTarget));
        assert(s1.selected == [0L], format("step 1: selection {A}, got %s", s1.selected.to!string));
        assert(s1.foreground == [0L],
            format("step 1: exactly one foreground layer (A), got %s", s1.foreground.to!string));
        assert(declaredForegroundCount(rows[0]) == 1, "fixture row 1 declares one foreground layer");

        // --- step 2: select mesh B exclusively — THE FLUSH ------------------
        cmd(`{"id":"layer.select","index":1,"mode":"set"}`);
        auto s2 = docState();
        assert(s2.editTarget == 1,
            format("step 2 CONTROL: selecting another mesh MOVES the target to B, got %d — "
                 ~ "a constant or frozen read fails here and makes every other row vacuous",
                   s2.editTarget));
        assert(s2.foreground == [1L],
            format("step 2: the count stays ONE. Mesh A does not become a second foreground "
                 ~ "layer — selecting a mesh FLUSHES the mesh history bucket, so A loses its "
                 ~ "selection state entirely. got foreground %s. An implementation that "
                 ~ "APPENDS to the history instead of flushing it reads [0,1] here.",
                   s2.foreground.to!string));
        assert(s2.background == [0L],
            format("step 2: …and A falls all the way back to BACKGROUND, got %s",
                   s2.background.to!string));
        assert(declaredForegroundCount(rows[1]) == 1, "fixture row 2 declares one foreground layer");

        // --- step 3: ADD mesh A back — THE ORDER LAW ------------------------
        cmd(`{"id":"layer.select","index":0,"mode":"add"}`);
        auto s3 = docState();
        assert(s3.selected == [0L, 1L],
            format("step 3: `add` EXTENDS the selection to both meshes, got %s",
                   s3.selected.to!string));
        assert(s3.foreground == [0L, 1L],
            format("step 3: two foreground layers are representable, got %s",
                   s3.foreground.to!string));
        assert(declaredForegroundCount(rows[2]) == 2, "fixture row 3 declares two foreground layers");
        assert(s3.editTarget == 1,
            format("step 3: THE ROW. The target is the FIRST of the two foreground layers, "
                 ~ "which here is the EARLIER-selected mesh B — not the one just added and "
                 ~ "not the lower layer index. got %d. Reading 0 means the target follows "
                 ~ "the newest selection (the usual latched-pointer reading) or `layers` "
                 ~ "order (a walk over the layer list instead of the selection queue); both "
                 ~ "answer 0 and both are wrong.", s3.editTarget));
        {
            // The fixture states the order explicitly; assert against it rather
            // than against a number written twice.
            auto order = rows[2]["foreground_order"].array;
            assert(order.length == 2 && order[0].str == "mesh B" && order[1].str == "mesh A",
                "fixture row 3 declares the foreground ORDER (B then A) — this test reads "
                ~ "the target off the head of that order, so a fixture edit that reversed "
                ~ "it without touching `edit_target` would be silently contradictory");
        }
        assert(s3.focused == 0,
            format("step 3: …while the FOCUS is on the newest touch, mesh A, got %d — this "
                 ~ "is what separates 'the target did not follow the add' from 'the add did "
                 ~ "nothing at all'", s3.focused));
    }

    // =======================================================================
    // CELL 2 — target_set_nothing_selected
    //
    // The first legal extreme. Dropping the whole item selection does not drop
    // the edit target.
    // =======================================================================
    {
        auto cell = cellOf(fx, "target_set_nothing_selected");
        auto rows = cell["rows"].array;
        twoMeshRig();

        cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
        assert(docState().editTarget == 0, "step 1: target on mesh A");

        cmd(`{"id":"layer.select","mode":"clear"}`);
        auto s2 = docState();
        assert(s2.selected.length == 0,
            format("step 2: the item selection really is empty, got %s", s2.selected.to!string));
        assert(s2.focused == -1, "step 2: …and so is the focus, which is the selection's pointer");
        assert(s2.editTarget == 0,
            format("step 2: THE MEASUREMENT — an empty item selection with a LIVE edit "
                 ~ "target is a legal state, and the target is still mesh A. got %d.",
                   s2.editTarget));
        assert(s2.foreground == [0L],
            format("step 2: …and it is FOREGROUND while unselected, got %s. A model deriving "
                 ~ "foreground from `selected` reads [] here and draws the layer it is "
                 ~ "editing as a dimmed, read-only background layer.", s2.foreground.to!string));
        assert(declaredForegroundCount(rows[1]) == 1, "fixture row 2 declares one foreground layer");

        cmd(`{"id":"layer.select","index":1,"mode":"set"}`);
        cmd(`{"id":"layer.select","mode":"clear"}`);
        auto s3 = docState();
        assert(s3.selected.length == 0, "step 3: emptied again");
        assert(s3.editTarget == 1,
            format("step 3 CONTROL: the retained target follows whichever mesh was selected "
                 ~ "LAST — mesh B now, got %d. Without this row 'the target survived' would "
                 ~ "be equally consistent with a value pinned to layer 0.", s3.editTarget));
    }

    // =======================================================================
    // CELL 3 — selection_nonempty_no_target
    //
    // The other legal extreme, and the cell a latched POINTER cannot reach
    // without inventing a dangling-pointer policy.
    // =======================================================================
    {
        auto cell = cellOf(fx, "selection_nonempty_no_target");
        auto rows = cell["rows"].array;
        twoMeshRig();

        cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
        cmd(`{"id":"layer.select","index":1,"mode":"set"}`);   // flushes A out
        auto s2 = docState();
        assert(s2.editTarget == 1 && s2.background == [0L],
            "precondition (= cell 1 step 2): B holds the target and A is background");

        // --- step 3: delete mesh B, the holder ------------------------------
        cmd(`{"id":"layer.delete","index":1}`);
        auto s3 = docState();
        assert(s3.layerCount == 1, format("step 3: one layer left, got %d", s3.layerCount));
        assert(s3.selected.length == 0,
            format("step 3: nothing is selected, got %s — a non-empty set here "
                 ~ "is a delete that RE-SELECTED a survivor, which is the "
                 ~ "pre-0671 behaviour and the reason there was always a target",
                   s3.selected.to!string));
        assert(s3.editTarget == -1,
            format("step 3: THE STATE — a scene that HAS a mesh layer and has NO edit "
                 ~ "target, got %d. Mesh A's state was flushed at step 2 and the item that "
                 ~ "held the target has left the document, so the walk is empty. An "
                 ~ "implementation that repairs a dangling target by rehoming onto 'some "
                 ~ "mesh' reads 0 here — a layer the user never picked.", s3.editTarget));
        assert(s3.foreground.length == 0,
            format("step 3: …and no foreground layer either, got %s", s3.foreground.to!string));
        assert(s3.background == [0L],
            format("step 3: the surviving mesh is BACKGROUND, got %s — it must still be "
                 ~ "drawn, dimmed, rather than vanish", s3.background.to!string));
        assert(declaredForegroundCount(rows[2]) == 0, "fixture row 3 declares no foreground layer");

        // --- step 4: add a non-mesh item and select it ----------------------
        {
            auto path = writeBmp("legality.bmp", 3, 2);
            cmd(`{"id":"image.load","path":` ~ JSONValue(path).toString ~ `}`);
        }
        auto after = getJson("/api/layers")["layers"].array;
        assert(after.length == 2, format("step 4: the image item was added, got %d rows",
                                         after.length));
        assert(after[1]["type"].str != "mesh",
            "step 4: item 1 must be a NON-mesh item, got " ~ after[1]["type"].str);
        cmd(`{"id":"layer.select","index":1,"mode":"set"}`);
        auto s4 = docState();
        assert(s4.selected == [1L],
            format("step 4: the item selection is NON-EMPTY, got %s", s4.selected.to!string));
        assert(s4.editTarget == -1,
            format("step 4: THE MEASUREMENT — a non-empty item selection with NO edit "
                 ~ "target, got %d. Selecting a non-mesh item cannot create one: it is not "
                 ~ "a candidate, not a rejected candidate.", s4.editTarget));
        assert(declaredForegroundCount(rows[3]) == 0, "fixture row 4 declares no foreground layer");

        // --- step 5: CONTROL — select mesh A --------------------------------
        cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
        auto s5 = docState();
        assert(s5.editTarget == 0,
            format("step 5 CONTROL: the read recovers immediately, got %d — so steps 3 and "
                 ~ "4 were a real absence and not a stuck or broken reading", s5.editTarget));
        assert(s5.foreground == [0L],
            format("step 5: …and the mesh is foreground again, got %s", s5.foreground.to!string));
        assert(declaredForegroundCount(rows[4]) == 1, "fixture row 5 declares one foreground layer");
    }

    // =======================================================================
    // CELL 4 — hidden_mesh_keeps_the_target
    //
    // Visibility and targethood are independent.
    // =======================================================================
    {
        auto cell = cellOf(fx, "hidden_mesh_keeps_the_target");
        auto rows = cell["rows"].array;
        twoMeshRig();

        cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
        assert(docState().editTarget == 0, "step 1: target on mesh A");

        // --- step 2: hide mesh A --------------------------------------------
        cmd(`{"id":"layer.setVisible","index":0,"value":false}`);
        auto s2 = docState();
        assert(getJson("/api/layers")["layers"].array[0]["visible"].type == JSONType.false_,
            "step 2: the hide really took — otherwise the row below is vacuous");
        assert(s2.editTarget == 0,
            format("step 2: THE MEASUREMENT — a hidden layer is still the edit target, got "
                 ~ "%d. A model where foreground means `visible && selected` cannot hold "
                 ~ "this: it has to hand the target to mesh B (reads 1) or refuse the hide.",
                   s2.editTarget));
        assert(s2.selected == [0L],
            format("step 2: …and hiding does not deselect it either, got %s",
                   s2.selected.to!string));
        assert(s2.background.length == 0 || !s2.background.canFind(0L),
            "step 2: the hidden target must NOT read as background — a dimmed, read-only, "
            ~ "snappable layer that the toolpipe writes to is the one state that must stay "
            ~ "unrepresentable");
        assert(declaredForegroundCount(rows[1]) == 1, "fixture row 2 declares one foreground layer");

        // --- step 3: CONTROL — select mesh B while A stays hidden ------------
        cmd(`{"id":"layer.select","index":1,"mode":"set"}`);
        auto s3 = docState();
        assert(s3.editTarget == 1,
            format("step 3 CONTROL: the target still moves normally, got %d — so step 2 is "
                 ~ "not a frozen read", s3.editTarget));
        assert(s3.foreground == [1L],
            format("step 3: …and the hidden former target is not a layer at all now: its "
                 ~ "bucket was flushed, so it is neither foreground nor background. got "
                 ~ "foreground %s", s3.foreground.to!string));
        assert(s3.background.length == 0,
            format("step 3: a hidden item with no selection state is the reference's 'none "
                 ~ "of those' state, got background %s", s3.background.to!string));
    }

    // =======================================================================
    // The structural fact the whole cell set rests on.
    // =======================================================================
    {
        assert("layer_list_holds_meshes_only" in fx,
            "the fixture records WHY a non-mesh selection cannot move the target");
        twoMeshRig();
        cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
        auto path = writeBmp("legality2.bmp", 2, 2);
        cmd(`{"id":"image.load","path":` ~ JSONValue(path).toString ~ `}`);
        auto rows = getJson("/api/layers")["layers"].array;
        size_t nonMesh = 0;
        foreach (l; rows) if (l["type"].str != "mesh") ++nonMesh;
        assert(nonMesh >= 1, "precondition: a non-mesh item is present");
        auto st = docState();
        assert(st.foreground == [0L],
            format("with a non-mesh item present the FOREGROUND list still holds only the "
                 ~ "mesh, got %s — a non-mesh item is not a foreground layer even when it "
                 ~ "is the selected one", st.foreground.to!string));
        cmd(format(`{"id":"layer.select","index":%d,"mode":"set"}`, rows.length - 1));
        auto st2 = docState();
        assert(st2.editTarget == 0,
            format("…and selecting it leaves the mesh latched, got %d", st2.editTarget));
        assert(st2.selected == [cast(long)(rows.length - 1)],
            format("…while the SELECTED set is that item ALONE, got %s. BOTH halves at "
                 ~ "once: this is the pair task 0668 could only hold one of.",
                   st2.selected.to!string));
    }
}
