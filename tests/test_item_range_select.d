// Task 1880 — `layer.select mode:range`, the item list's Shift+click.
//
// ---------------------------------------------------------------------------
// The assertion that would be worth nothing here
// ---------------------------------------------------------------------------
// "the range selected more than one item" is satisfied by four different wrong
// implementations at once: select-everything, select-from-zero, select-from-
// the-focus, and select-from-the-primary. Each is attractive (each produces a
// multi-selection that looks right on the common click) and each answers a
// DIFFERENT set on the rig below. So no row reads "several got selected";
// every row reads the exact membership, as an index list.
//
// ---------------------------------------------------------------------------
// The rig, and why each part of it is load-bearing
// ---------------------------------------------------------------------------
//   * FIVE layers. With three, "the span from the anchor" and "everything from
//     index 0" agree too often; five leaves room for an anchor that is neither
//     the first nor the last row, with layers on BOTH sides of it.
//   * The anchor is layer 1 — not 0, not the last. `select-from-zero` then
//     answers a set that is one item bigger, and `select-to-the-end` answers a
//     different one again.
//   * R2 ranges DOWNWARD (anchor 1, click 3) and R3 ranges UPWARD (anchor 1,
//     click 0) from THE SAME anchor without an intervening plain click. One
//     direction alone cannot separate "the anchor is the first selected item"
//     from "the anchor is the last row touched": on a single downward range
//     those are the same row. R3 is where they part company — an
//     implementation anchored on the focus re-anchors at 3 and answers
//     {0,1,2,3}, where the correct answer is {0,1}.
//   * R4 ranges downward AGAIN, to prove the anchor survived R3 as well. A
//     walking anchor that survived one direction can still walk on the other.
//
// ---------------------------------------------------------------------------
// Why the anchor is `firstSelectedItem` and not something else — READ, not
// guessed
// ---------------------------------------------------------------------------
// The reference's tree-view API has NO range mode. `ILxTreeView::Select(mode)`
// takes exactly `PRIMARY` / `ADD` / `REMOVE` / `CLEAR`, with `BATCH_BEGIN` /
// `BATCH_END` around a group. So a Shift+click there is a PRIMARY on the anchor
// followed by an ADD per row — which means (a) the range REPLACES the selection
// rather than unioning into it, and (b) the anchor is whichever row last took
// `SELECT_PRIMARY`, i.e. after any range it is the FIRST element of the
// selection. R3 is the row that pins exactly that.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION — the mutation, the row that reddened, and the value it
// observed. Run in isolation, one at a time: druntime stops a module at its
// first failed assert, so two reasons cannot both be read from one run.
// ---------------------------------------------------------------------------
//   * anchor `firstSelectedItem` -> `focusedItem`
//       -> R3 "an UPWARD range from the same anchor must give {0,1} — got
//          {0,1,2,3}". The downward rows R2/R4 stay GREEN under this mutation,
//          which is why R3 is not padding.
//   * the range UNIONS instead of replacing (drop the `Set(anchor)`, use
//     `Add`)
//       -> R3 "…got {0,1,2,3}" as well, by a different route — so R3 is run
//          twice, once per mutation, and the distinguishing row for the two is
//          R5 (undo), which the union mutation leaves green.
//   * the span walks `doc.layers` without the `isSceneItem` filter
//       -> R6 "an item the Items list does not draw must not join the span —
//          index 3 is a image". R6 builds the ONLY rig that can show this: an
//          image RESOURCE (`isSceneItem` false, so the panel draws no row for
//          it) sitting at a document index INSIDE the span. Without it every
//          layer is a row and the filter is unobservable — the check would be
//          green with the filter deleted.
//   * `mode:range` with nothing selected does nothing instead of acting as a
//     plain click
//       -> R1 "a range with no anchor must select exactly the clicked row —
//          got {}".
//   * the walk runs anchor->target in the wrong direction (so the CLICKED row
//     is not touched last)
//       -> R7 "the clicked row must end as the focus — focus is 1, not 3".
//   * the whole arm falls through to `selModeFromToken("range")`
//       -> R2 fails on the command itself (`status:error`), reported by `cmd`.

import std.net.curl;
import std.json;
import std.conv     : to;
import std.format   : format;
import std.algorithm : sort;
import std.file     : mkdirRecurse, write, tempDir;
import std.path     : buildPath;

void main() {}

enum string BASE = "http://localhost:8080";

private JSONValue getJson(string p) { return parseJSON(cast(string) get(BASE ~ p)); }

private JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

/// The selected layer indices, ascending — the whole answer this file asserts,
/// never "how many".
private int[] selected() {
    int[] xs;
    foreach (l; getJson("/api/layers")["layers"].array)
        if (l["selected"].type == JSONType.TRUE)
            xs ~= cast(int) l["index"].integer;
    sort(xs);
    return xs;
}

/// The anchor a subsequent range must reuse.
///
/// Read through `primary` deliberately, and the rigs below are ALL-MESH for
/// exactly that reason: `primary` is the mesh edit target (`canBePrimary`
/// filtered) while the anchor is `firstSelectedItem` (no kind filter), and the
/// two coincide only on an all-mesh selection. R6, which is the one rig with a
/// non-mesh item in it, does not read this — it asserts membership instead.
private int primaryIndex() {
    foreach (l; getJson("/api/layers")["layers"].array)
        if (l["selected"].type == JSONType.TRUE
            && l["primary"].type == JSONType.TRUE)
            return cast(int) l["index"].integer;
    return -1;
}

private int focused() {
    foreach (l; getJson("/api/layers")["layers"].array)
        if (l["focused"].type == JSONType.TRUE)
            return cast(int) l["index"].integer;
    return -1;
}

/// A tiny 24-bit BMP on disk, so R6 can make a real image RESOURCE. Same shape
/// as `tests/test_fixture_layer_main_latched.d`'s writer; kept local rather
/// than shared because it is four lines of header and one loop.
private string writeBmp(string name, int w, int h) {
    auto dir = buildPath(tempDir(), "vibe3d_range_select");
    mkdirRecurse(dir);
    auto path = buildPath(dir, name);
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

private string show(int[] xs) {
    string s = "{";
    foreach (i, x; xs) { if (i) s ~= ","; s ~= to!string(x); }
    return s ~ "}";
}

/// Five layers, item selection type current, nothing selected.
private void rig() {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    foreach (i; 0 .. 4) cmd("layer.add");
    cmd("select.item");
    cmd("layer.select mode:clear");
    assert(selected().length == 0, "rig: expected an empty selection to start");
    cmd("history.clear");
}

// ===========================================================================

unittest {  // R1 — a range with NO anchor is a plain click
    rig();
    cmd("layer.select index:2 mode:range");
    assert(selected() == [2],
        "a range with no anchor must select exactly the clicked row, like a "
        ~ "tree's first click — got " ~ show(selected()));
}

unittest {  // R2 — downward range from the anchor
    rig();
    cmd("layer.select index:1 mode:set");
    cmd("layer.select index:3 mode:range");
    assert(selected() == [1, 2, 3],
        "a range from anchor 1 down to 3 must be exactly {1,2,3} — got "
        ~ show(selected()));
    assert(primaryIndex() == 1,
        format("the anchor must stay the FIRST element of the selection — "
               ~ "got %d", primaryIndex()));
}

unittest {  // R3 — the discriminating row: UPWARD from the SAME anchor
    rig();
    cmd("layer.select index:1 mode:set");
    cmd("layer.select index:3 mode:range");   // anchor 1, focus now 3
    cmd("layer.select index:0 mode:range");   // must re-range from 1, not 3
    assert(selected() == [0, 1],
        "an UPWARD range from the same anchor must give {0,1}. Anchoring on "
        ~ "the FOCUS (which the previous range moved to 3) answers {0,1,2,3}, "
        ~ "and a range that unions instead of replacing answers {0,1,2,3} too "
        ~ "— got " ~ show(selected()));
}

unittest {  // R4 — and downward again, so the anchor survived BOTH directions
    rig();
    cmd("layer.select index:1 mode:set");
    cmd("layer.select index:3 mode:range");
    cmd("layer.select index:0 mode:range");
    cmd("layer.select index:4 mode:range");
    assert(selected() == [1, 2, 3, 4],
        "a third range, downward, must still anchor at 1 — got "
        ~ show(selected()));
}

unittest {  // R5 — ONE undo entry for the whole span, not one per row
    rig();
    cmd("layer.select index:1 mode:set");
    immutable int undoBefore =
        cast(int) getJson("/api/history")["undo"].array.length;
    cmd("layer.select index:4 mode:range");
    immutable int undoAfter =
        cast(int) getJson("/api/history")["undo"].array.length;
    assert(undoAfter - undoBefore == 1,
        format("a range spanning four rows must land as ONE history entry "
               ~ "(the reference wraps its PRIMARY+ADD burst in "
               ~ "BATCH_BEGIN/BATCH_END for the same reason) — the stack grew "
               ~ "by %d", undoAfter - undoBefore));
    auto top = getJson("/api/history")["undo"].array[$ - 1];
    assert(top["command"].str == "layer.select"
        && top["args"].str == "index:4 mode:range",
        "and it must record the range itself, replayable — got "
        ~ top["command"].str ~ " `" ~ top["args"].str ~ "`");
}

unittest {  // R6 — a resource item inside the span is NOT a row, so not swept in
    // THE ONLY RIG THAT CAN EXHIBIT THIS. An image is a document RESOURCE:
    // `kItemKindTable` gives ItemKind.Image `isSceneItem == false`, so the
    // Items panel draws no row for it, and a span that crossed it would select
    // something the user cannot see or deselect from that list. On an all-mesh
    // document every layer is a row, the filter is never exercised, and this
    // check would stay green with the filter deleted.
    //
    // Layout built below: [mesh0, mesh1, mesh2, IMAGE3, mesh4]. The span 1..4
    // therefore crosses index 3.
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    foreach (i; 0 .. 2) cmd("layer.add");
    {
        auto path = writeBmp("range_span.bmp", 3, 2);
        cmd(`{"id":"image.load","path":` ~ JSONValue(path).toString ~ `}`);
    }
    cmd("layer.add");
    cmd("select.item");

    auto rows = getJson("/api/layers")["layers"].array;
    assert(rows.length == 5, format("rig: expected 5 items, got %d", rows.length));
    assert(rows[3]["type"].str != "mesh",
        "rig premise: index 3 must be the non-mesh resource, got "
        ~ rows[3]["type"].str
        ~ " — without it this case cannot exhibit the filter at all");

    cmd("layer.select index:1 mode:set");
    cmd("layer.select index:4 mode:range");

    auto sel = selected();
    auto after = getJson("/api/layers")["layers"].array;
    foreach (i; sel)
        assert(after[i]["type"].str == "mesh",
            format("an item the Items list does not draw must not join the "
                   ~ "span — index %d is a %s", i, after[i]["type"].str));
    assert(sel == [1, 2, 4],
        "the span 1..4 skips the resource at 3, so it is exactly {1,2,4} — got "
        ~ show(sel));
}

unittest {  // R7 — the CLICKED row ends as the focus, the anchor as the first
    rig();
    cmd("layer.select index:1 mode:set");
    cmd("layer.select index:3 mode:range");
    assert(focused() == 3,
        format("the clicked row must end as the focus (it is touched last) — "
               ~ "focus is %d", focused()));
    assert(primaryIndex() == 1,
        format("and the anchor as the first element — got %d",
               primaryIndex()));
}
