// Task 0643 — clicking in the viewport selects the ITEM under the cursor while
// the current selection type is Item.
//
// WHAT MAKES AN ASSERTION HERE WORTH ANYTHING.
//
// "An item got selected" is satisfied by an implementation that selects the
// first layer, the last layer, every layer, or the one that was already
// primary. So the rig is built so that each of those reads a DIFFERENT number
// through the assertions below:
//
//   * THREE items, not one. On a one-item scene "the item under the cursor was
//     selected" and "every item was selected" render the same answer, and the
//     0647 capture had to be rebuilt once for exactly that reason. Three items
//     are spread along X and `assertRigSane` PROVES their screen footprints are
//     disjoint rather than assuming it, so "the cursor is over that one and not
//     over these two" is a claim this file is entitled to make.
//   * The clicked item is the MIDDLE one, index 1 of three. `layers[0]`,
//     `layers[$-1]` and "the item that was already primary" (index 2, where
//     `layer.duplicate` leaves it) are then three distinct wrong answers, each
//     with its own number.
//   * The depth flow runs TWO ARMS, near-at-index-0 and near-at-index-1. With
//     one arm, "nearest", "first" and "last" agree whenever the layer array's
//     order happens to match the depth order — which is how 0647's own depth
//     mutation measured GREEN the first time. One arm refutes first-hit, the
//     other refutes last-hit, and only depth passes both.
//
// THE OTHER HALF OF THE TASK is what must NOT happen. Under Item, the click
// must not run the geometry path at all: no bare-LMB clear of the geometry
// selection, no element pick, and no promotion of the geometry selection type
// back to the front (the recorded R3 trap — a mis-click silently turning the
// item mode into vertex mode). Those are asserted as preserved VALUES, not as
// the absence of an effect: U1 puts a real face selection on a layer first and
// reads it back afterwards.
//
// VERIFIED BY MUTATION. Each was applied to a green tree, built, and run; the
// assertion named is the one that fired, with the value it OBSERVED. They land
// on SEVEN different assertions, which is the point — these are not seven
// spellings of one check.
//
//   * the item branch removed from `handleMouseButtonDown` (i.e. the state
//     before this task: the click still picks geometry)
//       -> U1(c) "the click must make the item under the cursor primary — the
//          app reports primary 2".
//   * the branch selects `document.activeIndex` instead of the ray's hit
//       -> U1(c) primary 2 again. A different wrong implementation reading the
//          same number, which is why the clicked item is the MIDDLE one: it
//          separates both of these from "the first layer" (0) as well.
//   * the item ray keeps the LAST hit rather than the nearest
//       -> U4 arm 2 (near at index 0) "near at index 0, far at index 1 … the
//          app reports item 1".
//   * the item ray keeps the FIRST hit rather than the nearest
//       -> U4 arm 1 (near at index 1) "near at index 1, far at index 0 … the
//          app reports item 0".
//     Both arms are needed and neither is padding: with one arm, an index order
//     that happens to match the depth order makes first, last and nearest
//     indistinguishable — which is how 0647's own depth mutation measured GREEN.
//   * the early `return` dropped, so the geometry path runs after the item
//     select
//       -> U1(e) "the item click must not also pick GEOMETRY — the newly
//          primary item 1 came away with faces [1] selected".
//     NOTE: this mutation is INVISIBLE to U1's "the geometry selection on item 2
//     survived" assertion, because by the time the geometry path runs the
//     primary has already moved and the clear lands on the OTHER layer. The
//     assertion that catches it had to be added for it.
//   * a miss clears the geometry selection (what falling through to the
//     bare-LMB branch does)
//       -> U3 "a click on empty space must not touch the geometry selection
//          either — [1] became []".
//   * a miss does NOTHING (the pre-0654 branch)
//       -> U3 "a click on empty space EMPTIES the item selection — selected
//          [2]".
//   * a miss empties the SET but leaves `primary` latched (the forbidden
//     third state)
//       -> U3 "…and leaves NO primary — /api/layers reports active 2".
//   * the miss branch ignores the modifiers
//       -> U3 "a CTRL-click on empty space removes nothing — selected []".
//   * `mode` fixed to "set" (the modifiers ignored)
//       -> U2 "shift-click ADDS to the item set — got [0], want [0, 1]".
//   * the plane tier skipped (planes not pickable — the state 0647 left)
//       -> U5(a) "the click inside the backdrop's quad must select it —
//          selected false, focused 0".
//   * the plane treated as an INFINITE plane (the quad extent not tested)
//       -> U5(b) "the point 1.4 half-extents out is off the rectangle — the app
//          reports item 2 under it".
//     The same mutation also reddens `image_plane.d`'s own unittest at the U
//     boundary, so the law and its caller are pinned independently.
//   * the ranking merged into one nearest-t compare across both kinds
//       -> U5(c) "a mesh under the cursor wins over a NEARER backdrop … the app
//          focused item 2".
//   * the backdrop's border never painted (a pickable item with no cue)
//       -> U6 "a 13-pixel column across its top edge carries 0 such pixels".
//   * the border drawn one pixel wide, like a mesh's edges
//       -> U6 "…carries 1 such pixels" where the fixture says 2.

import std.net.curl;
import std.json;
import std.format  : format;
import std.math    : sqrt, round;
import std.file    : mkdirRecurse, write;
import std.path    : buildPath;
import std.algorithm : min, max;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, DHVec3 = Vec3;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

private void cmd(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
}

/// The picks below run on the event-playback thread and the reads on the HTTP
/// one; a frame between them is what makes the second see the first.
private void settle() { Thread.sleep(400.msecs); }

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)c["vpX"].integer,  cast(int)c["vpY"].integer,
                cast(int)c["width"].integer, cast(int)c["height"].integer);
}

/// SDL modifier bits, spelled out because a wrong constant here would make a
/// modifier flow silently assert the BARE-click behaviour and pass.
private enum uint kModNone  = 0;
private enum uint kModShift = 1;    // KMOD_LSHIFT
private enum uint kModCtrl  = 64;   // KMOD_LCTRL

/// A full LMB click at a WINDOW pixel: park the pointer there, press, release.
///
/// The motion first is not decoration — it is how the app's own hover state
/// reaches the pixel, so `hoveredItem` is meaningful next to the click's
/// result and a disagreement between them is visible rather than hidden.
/// `mod` drives `SDL_GetModState()` through the player (see `EventPlayer`),
/// which is what the press handler reads.
private void clickAt(Cell c, int wx, int wy, uint mod = kModNone) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 3)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
            ~ `"state":0,"mod":%u}` ~ "\n", 30.0 + i * 10.0, wx, wy, mod);
    log ~= format(
        `{"t":80.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,`
        ~ `"clicks":1,"mod":%u}` ~ "\n", wx, wy, mod);
    log ~= format(
        `{"t":120.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,`
        ~ `"clicks":1,"mod":%u}` ~ "\n", wx, wy, mod);
    playAndWait(log);
    settle();
}

// ---------------------------------------------------------------------------
// Reading the app's answer
// ---------------------------------------------------------------------------

/// The `layers` index of the primary — the single distinguished selected item,
/// and the one an item click is supposed to move.
private int primaryIndex() {
    return cast(int)getJson("/api/layers")["active"].integer;
}

/// Which layers are selected, as indices. The SET matters as much as the
/// primary: "selected everything" and "selected the right one" share a primary
/// whenever the right one happens to be selected last.
private int[] selectedItems() {
    int[] outp;
    foreach (i, l; getJson("/api/layers")["layers"].array)
        if (l["selected"].type == JSONType.true_) outp ~= cast(int)i;
    return outp;
}

private int hoveredItem() {
    return cast(int)getJson("/api/layers")["hoveredItem"].integer;
}

/// Which layer holds the item-selection FOCUS.
///
/// NOT the same thing as the primary, and the difference is the whole reason
/// this accessor exists. `primary` is the MESH EDIT TARGET, and a backdrop has
/// `canBePrimary == false` (`document.d`'s kind table) — so selecting one
/// leaves the primary on whatever mesh layer held it, and a `set` keeps a
/// primary-eligible layer selected alongside it to hold the "always a valid
/// primary" invariant. `focused` is the item the user last acted on, and it is
/// therefore the observable for "the click selected the backdrop". Asserting
/// `primary` there would demand behaviour the document model forbids.
private int focusedItem() {
    foreach (i, l; getJson("/api/layers")["layers"].array)
        if (l["focused"].type == JSONType.true_) return cast(int)i;
    return -1;
}

private bool itemSelected(int index) {
    return getJson("/api/layers")["layers"].array[index]["selected"].type
           == JSONType.true_;
}

/// The PRIMARY layer's selected faces. `/api/selection` reads the primary's
/// mesh, so this answers a question about whichever layer is primary NOW —
/// which is why U1 re-selects the layer it made the selection on before
/// reading it back.
private int[] selectedFaces() {
    int[] outp;
    foreach (v; getJson("/api/selection")["selectedFaces"].array)
        outp ~= cast(int)v.integer;
    return outp;
}

private string selType() { return getJson("/api/selection")["selType"].str; }
private string editModeName() { return getJson("/api/selection")["mode"].str; }

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

private struct Box {
    int x0, y0, x1, y1;
    int cx() const { return (x0 + x1) / 2; }
    int cy() const { return (y0 + y1) / 2; }
    bool disjointFrom(const Box o) const {
        return x1 < o.x0 || o.x1 < x0 || y1 < o.y0 || o.y1 < y0;
    }
}

/// Three unit cubes spread along X, seen three-quarter on, with the Item
/// selection type current.
///
/// `layer.duplicate` leaves the LAST layer selected and primary. The test
/// asserts that rather than arranging it, so the starting state is the app's
/// own — and it means the item the flows click (index 1) is neither the
/// already-primary one nor an end of the array.
private void buildRig() {
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd("layer.attr 0 pos.x -4");
    cmd("layer.attr 2 pos.x 4");
    post(baseUrl ~ "/api/camera?viewport=0", `{"distance":12.0}`);
    settle();
}

/// Where each item's cube lands on screen, computed from the live camera
/// through the same projection every drag test uses — so a camera change moves
/// the probes with it and no pixel below is a magic number.
private Box[] itemBoxes() {
    auto layers = getJson("/api/layers")["layers"].array;
    auto camS   = fetchCamera(baseUrl);
    auto vp     = viewportFromCamera(camS);

    Box[] boxes;
    foreach (li, l; layers) {
        auto pos = l["xform"]["pos"].array;
        auto scl = l["xform"]["scl"].array;
        Box b;
        b.x0 = int.max; b.y0 = int.max; b.x1 = int.min; b.y1 = int.min;
        foreach (sx; [-0.5f, 0.5f])
        foreach (sy; [-0.5f, 0.5f])
        foreach (sz; [-0.5f, 0.5f]) {
            auto world = DHVec3(
                cast(float)(pos[0].floating + sx * scl[0].floating),
                cast(float)(pos[1].floating + sy * scl[1].floating),
                cast(float)(pos[2].floating + sz * scl[2].floating));
            float px, py;
            assert(projectToWindow(world, vp, px, py),
                format("rig: item %d has a corner behind the camera", li));
            immutable int fx = cast(int)round(px);
            immutable int fy = cast(int)round(py);
            b.x0 = min(b.x0, fx); b.x1 = max(b.x1, fx);
            b.y0 = min(b.y0, fy); b.y1 = max(b.y1, fy);
        }
        boxes ~= b;
    }
    return boxes;
}

/// The rig decides something only if the items are separable on screen.
private void assertRigSane(const Box[] b) {
    foreach (i; 0 .. b.length)
        foreach (j; i + 1 .. b.length)
            assert(b[i].disjointFrom(b[j]),
                format("rig: items %d and %d overlap on screen "
                       ~ "([%d,%d]x[%d,%d] vs [%d,%d]x[%d,%d]) — with overlapping "
                       ~ "footprints 'the cursor is not over that one' is not a "
                       ~ "claim this rig can make",
                       i, j, b[i].x0, b[i].x1, b[i].y0, b[i].y1,
                       b[j].x0, b[j].x1, b[j].y0, b[j].y1));
}

// ---------------------------------------------------------------------------
// U1 — the click selects the item under the cursor, and the geometry side of
//      the app is not touched.
//
// Both halves in one flow deliberately: the geometry selection is MADE here,
// through the very click path the item branch pre-empts, so the "unchanged"
// assertion at the end is about a real, non-empty value that the pre-0643
// behaviour would have wiped. The geometry click is also the task's own
// CONTROL — the same gesture in a geometry type must select a face and must
// NOT move the primary.
// ---------------------------------------------------------------------------
unittest {
    buildRig();
    auto boxes = itemBoxes();
    assertRigSane(boxes);
    auto c = cell();

    assert(primaryIndex() == 2 && selectedItems() == [2],
        format("rig precondition: `layer.duplicate` leaves the last item "
               ~ "selected and primary — primary %d, selected %s",
               primaryIndex(), selectedItems()));

    // ---- (a) the CONTROL: a geometry-mode click picks a FACE and leaves the
    //      primary alone. Item 2 is the primary, so it is the layer the element
    //      pickers address; clicking any other item's footprint would pick
    //      nothing at all and prove nothing.
    cmd(`{"id":"select.polygon"}`);
    settle();
    assert(selType() == "polygon", "the geometry door must set the polygon type");
    clickAt(c, boxes[2].cx, boxes[2].cy);
    auto faces = selectedFaces();
    assert(faces.length > 0,
        "control: a click on the primary item's footprint in POLYGON mode must "
        ~ "select a face; none was selected, so every 'the geometry selection "
        ~ "survived' assertion below would be a statement about an empty set");
    assert(primaryIndex() == 2,
        format("control: a GEOMETRY click must not move the primary — it moved "
               ~ "to %d. Without this, U1(c) below could pass on an "
               ~ "implementation that moves the primary on every click in every "
               ~ "mode.", primaryIndex()));

    // ---- (b) the round-trip precondition. U1(e) reads layer 2's face
    //      selection back after making layer 1 primary, so it must first be
    //      true that a primary round-trip preserves it AT ALL. Without this the
    //      final assertion could fail (or pass) for a reason that has nothing
    //      to do with the click path.
    cmd(`{"id":"layer.select","index":1,"mode":"set"}`);
    cmd(`{"id":"layer.select","index":2,"mode":"set"}`);
    settle();
    assert(selectedFaces() == faces,
        format("rig: switching the primary away and back must preserve a "
               ~ "layer's face selection — %s became %s. U1(e) is not "
               ~ "meaningful otherwise.", faces, selectedFaces()));

    // ---- (c) THE CLICK. Into Item mode, then click the MIDDLE item.
    cmd(`{"id":"select.item"}`);
    settle();
    immutable string modeBefore = editModeName();
    assert(selType() == "item", "the item door must set the item type");

    clickAt(c, boxes[1].cx, boxes[1].cy);

    assert(hoveredItem() == 1,
        format("the cursor was placed inside item 1's footprint; the app "
               ~ "reports item %d under it — the ray and the click disagree, "
               ~ "so the failure below is about the ray, not the selection",
               hoveredItem()));
    assert(primaryIndex() == 1,
        format("the click must make the item under the cursor primary — the "
               ~ "app reports primary %d. 2 is 'the click still picks geometry' "
               ~ "or 'it re-selects whatever was already primary'; 0 is 'the "
               ~ "first layer in the array'.", primaryIndex()));

    // ---- (d) the SET, not just the primary. A bare click is exclusive.
    assert(selectedItems() == [1],
        format("a bare click SETS the item selection — selected %s. [0,1,2] is "
               ~ "'every item lit', and any superset means the click added "
               ~ "instead of replacing.", selectedItems()));

    // ---- (e) the geometry side is untouched. Three independent values.
    //
    //      The first is the sharpest, and it is the one that catches a branch
    //      that runs but forgets to RETURN: the geometry path would then pick
    //      an element on the item it just selected, so the newly primary item
    //      would come away with a face selection it never had. Reading its
    //      (now current) face set is therefore a direct statement that the
    //      element pick did not run.
    assert(selectedFaces().length == 0,
        format("the item click must not also pick GEOMETRY — the newly primary "
               ~ "item 1 came away with faces %s selected. That is the geometry "
               ~ "path running after the item branch, i.e. a missing early "
               ~ "return.", selectedFaces()));
    assert(selType() == "item",
        format("the click must leave the ITEM type current — it reads '%s'. A "
               ~ "geometry type here is the recorded R3 trap: a viewport click "
               ~ "silently turning the item mode back into a geometry mode.",
               selType()));
    assert(editModeName() == modeBefore,
        format("the remembered geometry type must not move either — '%s' "
               ~ "became '%s'", modeBefore, editModeName()));

    cmd(`{"id":"layer.select","index":2,"mode":"set"}`);
    settle();
    assert(selectedFaces() == faces,
        format("the geometry selection made on item 2 must survive an item "
               ~ "click elsewhere — layer 2's faces went from %s to %s. This is "
               ~ "about the item the click LEFT: a branch that clears the "
               ~ "current mode's selection before switching (which is what the "
               ~ "bare-LMB branch does) empties it here. The item the click "
               ~ "ARRIVED at is covered by the first assertion above; a missing "
               ~ "early return shows up there, not here, because by then the "
               ~ "primary has already moved and the clear lands on the other "
               ~ "layer.", faces, selectedFaces()));
}

// ---------------------------------------------------------------------------
// U2 — the modifiers, through `layer.select`'s own modes.
//
// Each step asserts the whole SET, because "shift added item 0" and "shift
// replaced the selection with item 0" agree on everything except the set. The
// last step also pins the document invariant: removing the only selected item
// is refused, so a ctrl-click cannot empty the scene's selection.
// ---------------------------------------------------------------------------
unittest {
    buildRig();
    auto boxes = itemBoxes();
    assertRigSane(boxes);
    auto c = cell();
    cmd(`{"id":"select.item"}`);
    settle();

    // Bare click on the middle item — the exclusive baseline.
    clickAt(c, boxes[1].cx, boxes[1].cy);
    assert(selectedItems() == [1],
        format("bare click sets: %s", selectedItems()));

    // Shift ADDS. Item 0, so the resulting set is not a contiguous accident of
    // whichever item was clicked last.
    clickAt(c, boxes[0].cx, boxes[0].cy, kModShift);
    assert(selectedItems() == [0, 1],
        format("shift-click ADDS to the item set — got %s, want [0, 1]. [0] "
               ~ "alone means the modifier was ignored and the click set.",
               selectedItems()));
    // TASK 0671: a shift-ADD appends to the selection queue; the edit target is
    // the queue's HEAD, so it stays on item 1 (the bare click). This line used
    // to read `== 0`.
    assert(primaryIndex() == 1,
        format("the edit target stays on the first-selected item — got %d",
               primaryIndex()));

    // Ctrl REMOVES, and it removes the one under the cursor, not an arbitrary
    // member: item 0 is the newest add here, so removing it also exercises the
    // arm where the deselected item enters its kind's history bucket.
    clickAt(c, boxes[0].cx, boxes[0].cy, kModCtrl);
    assert(selectedItems() == [1],
        format("ctrl-click REMOVES the item under the cursor — got %s, want [1]",
               selectedItems()));
    assert(primaryIndex() == 1,
        format("…and the edit target is unchanged, it was never on item 0 — "
               ~ "got %d", primaryIndex()));

    // …and the LAST selected item CAN be removed (task 0654).
    //
    // INTENT CHANGE. This step used to assert the opposite — "removing the only
    // selected item is refused (the document keeps at least one selected)" —
    // because the ≥1-selected invariant made the empty set unrepresentable.
    // 0653 measured the reference doing exactly this, the owner decided we
    // follow it, and 0654 retired the invariant. The old assertion pinned a
    // constraint that no longer exists.
    clickAt(c, boxes[1].cx, boxes[1].cy, kModCtrl);
    assert(selectedItems() == [],
        format("ctrl-clicking the only selected item EMPTIES the item "
               ~ "selection — got %s. [1] is the retired refusal.",
               selectedItems()));
    // TASK 0671 — the SELECTION empties; the EDIT TARGET does not go with it.
    // 0653 measured the first half and this line inferred the second. 0670 read
    // the mechanism: deselecting moves the item into its kind's
    // recently-deselected cache, and the edit target is the head of a walk over
    // [current ++ that cache] (frozen: tests/fixtures/edit_target_legality.json,
    // cell `target_set_nothing_selected`). So it stays on item 1, the item that
    // was just deselected.
    assert(primaryIndex() == 1,
        format("…and the edit target stays LATCHED on the item just "
               ~ "deselected — /api/layers reports active %d. 0 is the "
               ~ "substitution this must never make (a real layer silently "
               ~ "promoted into an emptied selection); -1 is the pre-0671 "
               ~ "model, which inferred this half instead of measuring it.",
               primaryIndex()));
}

// ---------------------------------------------------------------------------
// U3 — a click on empty space EMPTIES the item selection (task 0654), and
// still does not touch the geometry selection.
//
// INTENT CHANGE. This case used to assert that a miss changed nothing, and
// said why: "there is no representable 'no item selected' state to fall into".
// That premise is what 0654 removed — 0653 measured the reference emptying on a
// miss and the owner decided we follow it — so the do-nothing claim is now
// pinning the absence of the feature. The SECOND claim is unchanged and still
// load-bearing: emptying the ITEM selection must not drag the GEOMETRY
// selection with it, which is exactly what falling through to the bare-LMB
// branch would do.
// ---------------------------------------------------------------------------
unittest {
    buildRig();
    auto boxes = itemBoxes();
    assertRigSane(boxes);
    auto c = cell();

    // A real face selection on the primary (item 2), made in polygon mode.
    cmd(`{"id":"select.polygon"}`);
    settle();
    clickAt(c, boxes[2].cx, boxes[2].cy);
    auto faces = selectedFaces();
    assert(faces.length > 0, "precondition: a face is selected on item 2");

    cmd(`{"id":"select.item"}`);
    settle();
    assert(primaryIndex() == 2 && selectedItems() == [2],
        "precondition: item 2 is the sole selection");

    // The GAP between two items, not the far corner of the view: a cursor off
    // the edge of everything is a weaker statement than a cursor in a hole.
    immutable int gapX = (boxes[0].x1 + boxes[1].x0) / 2;
    clickAt(c, gapX, boxes[1].cy);

    assert(hoveredItem() == -1,
        format("the gap between two items is empty space — the app reports "
               ~ "item %d there, so this flow is not clicking on nothing",
               hoveredItem()));
    assert(selectedItems() == [],
        format("a click on empty space EMPTIES the item selection — selected "
               ~ "%s. [2] is the retired do-nothing branch.", selectedItems()));
    // TASK 0671 — the latch is what the reference does, so this asserts it.
    // The empty-space click empties the SELECTION; the mesh it deselected keeps
    // a non-zero selection state and stays the edit target.
    assert(primaryIndex() == 2,
        format("…and the edit target stays LATCHED on item 2 — /api/layers "
               ~ "reports active %d. 0 is 'layer 0 was substituted'; -1 is the "
               ~ "pre-0671 model, which inferred that the target went with the "
               ~ "selection instead of measuring it.", primaryIndex()));
    assert(selType() == "item", "…and the type stays Item");

    // The GEOMETRY selection survived the emptying. It has to be read back
    // through item 2: `/api/selection`'s `selectedFaces` reports the FOREGROUND
    // mesh's selection, and with nothing selected there is no foreground mesh —
    // so an empty reading here would be ambiguous between "the clear ran" and
    // "there is nothing to report". Re-selecting the item first makes the
    // reading about the stored selection and nothing else.
    cmd(`{"id":"layer.select","index":2,"mode":"set"}`);
    settle();
    assert(selectedFaces() == faces,
        format("a click on empty space must not touch the geometry selection "
               ~ "either — %s became %s. That clear is what the bare-LMB "
               ~ "branch does in a geometry mode, and it must not happen under "
               ~ "Items.", faces, selectedFaces()));

    // A MODIFIED miss does not empty. Ctrl/shift are set-editing chords, so a
    // mis-aimed ctrl-click must not destroy the set the user is building.
    // (Item 2 is selected again, from the read-back just above.)
    clickAt(c, gapX, boxes[1].cy, kModCtrl);
    assert(selectedItems() == [2],
        format("a CTRL-click on empty space removes nothing — selected %s. "
               ~ "[] means the miss branch ignored the modifiers.",
               selectedItems()));
    clickAt(c, gapX, boxes[1].cy, kModShift);
    assert(selectedItems() == [2],
        format("a SHIFT-click on empty space adds nothing — selected %s",
               selectedItems()));
}

// ---------------------------------------------------------------------------
// U4 — along one ray, the click selects the FRONT-most item.
//
// TWO ARMS, and the reason is a mutation that came out INERT in 0647: with the
// near item at a fixed index, "keep the nearest", "keep the first" and "keep
// the last" can all agree, because the layer array is walked in index order. So
// the same assertions run with the near item at index 0 and then at index 1 —
// index-order-first fails one, index-order-last fails the other, and only a
// depth compare passes both.
// ---------------------------------------------------------------------------
private void rayArm(size_t nearIdx, size_t farIdx) {
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd(`{"id":"select.item"}`);
    post(baseUrl ~ "/api/camera?viewport=0", `{"distance":12.0}`);
    settle();

    // The FAR item stays at the origin and starts as the sole selection; the
    // NEAR item moves 3 m toward the eye along the same ray and shrinks to 0.4
    // so it sits strictly inside the far one's footprint.
    cmd(format(`{"id":"layer.select","index":%d,"mode":"set"}`, farIdx));
    auto camS = fetchCamera(baseUrl);
    immutable float len = sqrt(camS.eye.x * camS.eye.x
                             + camS.eye.y * camS.eye.y
                             + camS.eye.z * camS.eye.z);
    assert(len > 1e-3f, "the camera must not sit on the focus point");
    immutable float k = 3.0f / len;
    cmd(format("layer.attr %d pos.x %.5f", nearIdx, camS.eye.x * k));
    cmd(format("layer.attr %d pos.y %.5f", nearIdx, camS.eye.y * k));
    cmd(format("layer.attr %d pos.z %.5f", nearIdx, camS.eye.z * k));
    foreach (ax; ["x", "y", "z"])
        cmd(format("layer.attr %d scl.%s 0.4", nearIdx, ax));
    settle();

    auto boxes = itemBoxes();
    assert(boxes.length == 2, format("rig: two items, got %d", boxes.length));
    auto c = cell();
    const nb = boxes[nearIdx], fb = boxes[farIdx];
    assert(nb.x0 > fb.x0 && nb.x1 < fb.x1 && nb.y0 > fb.y0 && nb.y1 < fb.y1,
        format("rig: the near item ([%d,%d]x[%d,%d]) must sit inside the far "
               ~ "one ([%d,%d]x[%d,%d]) — otherwise the click is not on a pixel "
               ~ "both items cover and the depth rule is not under test",
               nb.x0, nb.x1, nb.y0, nb.y1, fb.x0, fb.x1, fb.y0, fb.y1));
    assert(primaryIndex() == cast(int)farIdx,
        format("rig: the FAR item starts primary, so 'the primary moved' is "
               ~ "the observable — primary is %d", primaryIndex()));

    clickAt(c, nb.cx, nb.cy);

    assert(primaryIndex() == cast(int)nearIdx,
        format("near at index %d, far at index %d: the front-most item along "
               ~ "the ray is the one selected — the app reports item %d. "
               ~ "Reading %d means the ray resolves by ARRAY ORDER, not by "
               ~ "depth.", nearIdx, farIdx, primaryIndex(), farIdx));
    assert(selectedItems() == [cast(int)nearIdx],
        format("…and it is the ONLY one selected — got %s. Both items lit "
               ~ "means the ray returned every hit instead of the nearest.",
               selectedItems()));
}

unittest {
    rayArm(/*near=*/1, /*far=*/0);   // depth order agrees with index order
    rayArm(/*near=*/0, /*far=*/1);   // …and now it disagrees
}

// ---------------------------------------------------------------------------
// U5 — the BACKDROP, an item with no mesh.
//
// This is the part a BVH cannot answer and the reason the task exists in this
// shape: a reference image plane carries no geometry, so it is hit-tested as a
// ray against its quad. Three claims, each with its own wrong implementation:
//
//   (a) a click inside the rectangle selects the plane      — planes pickable
//   (b) a click outside it selects nothing                  — the EXTENT is real
//   (c) a mesh under the cursor wins over a NEARER plane    — the ranking
//
// (c) is the one that is a decision rather than a measurement, and it is
// derived rather than invented: `drawImagePlane` disables the depth test, and
// runs first, so geometry is painted over a backdrop no matter where the two
// sit in the world. A picker that let the nearer plane win would highlight an
// item that is not visible at that pixel.
//
// WHAT COUNTS AS A HIT INSIDE THE RECTANGLE is the whole quad, transparent
// pixels included — stated in `image_plane.rayHitsPlaneQuad` with the reason.
// The 0647 capture measured that the reference highlights a backdrop's BORDER
// and never tints its image, which says nothing about the interior, so this
// takes the simpler of the two candidate rules. This flow uses an opaque image,
// so it does not depend on that choice either way.
// ---------------------------------------------------------------------------

private immutable scratch = "/tmp/vibe3d_itemclick";

/// A small opaque 24-bit BMP. Its CONTENT does not matter here — only its pixel
/// dimensions do, because they set the quad's extent through `pixelSize`.
private string opaqueBmp(string name, int w, int h) {
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
    foreach (r; 0 .. h) {
        foreach (x; 0 .. w) { b ~= cast(ubyte)200; b ~= cast(ubyte)80; b ~= cast(ubyte)40; }
        foreach (_; 0 .. rowBytes - cast(size_t)(w * 3)) b ~= cast(ubyte) 0;
    }
    write(path, b);
    return path;
}

private struct Quad { DHVec3 center, halfU, halfV; }

private Quad planeQuad(int index) {
    auto pl = getJson(format("/api/imageplane?index=%d&cell=0", index));
    assert("error" !in pl, "placement: " ~ pl.toString);
    assert(pl["drawn"].type == JSONType.true_,
        "FIXTURE: the backdrop must be DRAWN in this cell, else the ray is "
        ~ "asked about something invisible: " ~ pl.toString);
    DHVec3 v(string k) {
        auto a = pl[k].array;
        return DHVec3(cast(float)a[0].floating, cast(float)a[1].floating,
                      cast(float)a[2].floating);
    }
    return Quad(v("center"), v("halfU"), v("halfV"));
}

/// Project a world point to a WINDOW pixel through the live camera.
private int[2] toWindow(DHVec3 world) {
    auto vp = viewportFromCamera(fetchCamera(baseUrl));
    float px, py;
    assert(projectToWindow(world, vp, px, py), "point is behind the camera");
    return [cast(int)round(px), cast(int)round(py)];
}

/// Layers: [0] cube, [1] clip, [2] plane. Written as literals at the commands
/// below because they are ARGUMENTS to them.
private void buildPlaneRig(float planeX, float planeZ, float pixelSize) {
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    auto file = opaqueBmp("ref.bmp", 64, 32);
    cmd(`{"id":"image.load","path":` ~ JSONValue(file).toString ~ `}`);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer",
        `{"kind":"imagePlane","name":"backdrop"}`));
    assert(r["status"].str == "ok", "plane injection failed: " ~ r.toString);
    cmd(`{"id":"imagePlane.setImage","index":2,"image":1}`);
    // The quad is 64 x 32 px times `pixelSize`. The two flows want different
    // sizes and both reasons are geometric, not cosmetic: the extent flow needs
    // an OUTSIDE that is still on screen (small), and the ranking flow needs the
    // quad to genuinely cover the pixel the cube sits on, which for a plane
    // pushed 3 m toward the eye means covering the point where the eye-to-origin
    // ray crosses z = 3 — about (1.6, 1.4), i.e. outside a 3.2 x 1.6 m quad.
    cmd(format("layer.attr 2 pixelSize %.5f", pixelSize));
    cmd(format("layer.attr 2 pos.x %.5f", planeX));
    cmd(format("layer.attr 2 pos.z %.5f", planeZ));
    cmd(`{"id":"select.item"}`);
    post(baseUrl ~ "/api/camera?viewport=0", `{"distance":12.0}`);
    settle();
}

// (a) inside the rectangle, (b) outside it.
unittest {
    // The plane stands well to the side of the cube, so neither flow can be
    // answered by the cube.
    buildPlaneRig(/*x=*/4.0f, /*z=*/0.0f, /*pixelSize=*/0.05f);
    auto c = cell();

    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    settle();
    assert(focusedItem() == 0 && !itemSelected(2),
        format("rig: the CUBE starts focused and the backdrop unselected, so "
               ~ "'the backdrop became the selected item' is the observable — "
               ~ "focused %d, backdrop selected %s",
               focusedItem(), itemSelected(2)));

    auto q = planeQuad(2);

    // (a) dead centre of the quad.
    auto inside = toWindow(q.center);
    clickAt(c, inside[0], inside[1]);
    assert(itemSelected(2) && focusedItem() == 2,
        format("the click inside the backdrop's quad must select it — selected "
               ~ "%s, focused %d. Unselected means an item with NO MESH is not "
               ~ "pickable at all, which is the state before this task: a BVH "
               ~ "ray has nothing to hit.", itemSelected(2), focusedItem()));
    assert(hoveredItem() == 2,
        format("the ray reports the backdrop under the cursor too — got %d",
               hoveredItem()));
    // This row has been inverted twice. It read "the MESH EDIT TARGET does not
    // move" (pre-0668, because the mesh was SPARED from the exclusive select);
    // then "the edit target goes with it" (0668, which made the select truly
    // exclusive and had nowhere to put the target); and now the two answers
    // that were traded are both true at once — the cube leaves the SELECTION
    // and keeps the TARGET, because a backdrop's select flushes the backdrop
    // bucket and the mesh sits in the mesh one.
    assert(primaryIndex() == 0,
        format("…and the MESH EDIT TARGET stays on the cube — read %d. -1 is "
               ~ "0668's answer, which cost the target to buy the set.",
               primaryIndex()));
    assert(!itemSelected(0),
        "…while the cube IS deselected: 0668's half of the answer, kept, and "
        ~ "what makes the set match the reference's");

    // (b) 1.4 half-extents along U: outside the rectangle, and still on the
    //     plane's own infinite surface. An implementation that intersects the
    //     PLANE without testing the quad's extent selects the backdrop here.
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    settle();
    assert(!itemSelected(2), "precondition: the backdrop is deselected again");
    auto outside = toWindow(DHVec3(q.center.x + 1.4f * q.halfU.x,
                                   q.center.y + 1.4f * q.halfU.y,
                                   q.center.z + 1.4f * q.halfU.z));
    clickAt(c, outside[0], outside[1]);
    assert(hoveredItem() == -1,
        format("the point 1.4 half-extents out is off the rectangle — the app "
               ~ "reports item %d under it", hoveredItem()));
    // The claim under test is the EXTENT: the backdrop must not be selected by
    // a click that is on its infinite surface but off its rectangle.
    assert(!itemSelected(2),
        format("a click outside the backdrop's rectangle must not select it — "
               ~ "backdrop selected %s. The plane's EXTENT is part of the hit "
               ~ "test, not just its infinite surface.", itemSelected(2)));
    // …and, task 0654, the miss EMPTIES the selection rather than leaving the
    // previous focus standing. This half used to read `focusedItem() == 0` —
    // an intent change, not a repair: a viewport miss in Items mode now clears
    // the item selection (0653 measured the reference doing it; the ≥1-selected
    // invariant that made "nothing selected" unrepresentable is gone). The
    // extent claim above is unaffected either way, which is why it is now its
    // own assertion.
    assert(focusedItem() == -1,
        format("…and a miss empties the item selection — focused %d. 0 is the "
               ~ "retired do-nothing branch leaving the prior focus standing.",
               focusedItem()));
}

// (c) a mesh wins over a NEARER backdrop, because geometry is painted over it.
unittest {
    // The plane sits at the origin in X and 3 m toward +Z; the default camera
    // looks from +Z, so the plane is BETWEEN the eye and the cube. Nearest-t
    // across both kinds would therefore answer "the plane"; the shipped rule
    // answers "the cube", because that is what the pixel shows.
    buildPlaneRig(/*x=*/0.0f, /*z=*/3.0f, /*pixelSize=*/0.15f);
    auto c = cell();

    auto camS = fetchCamera(baseUrl);
    assert(camS.eye.z > 0.5f,
        format("rig: the camera must look from +Z for the plane at z=+3 to be "
               ~ "in FRONT of the cube — eye is (%f, %f, %f)",
               camS.eye.x, camS.eye.y, camS.eye.z));

    // The cube's centre — a pixel both items cover.
    auto at = toWindow(DHVec3(0, 0, 0));

    // The claim rests on the plane actually covering that pixel, so PROVE it:
    // move the cube out of the way, click the same pixel, and see the backdrop
    // answer. Without this the flow below could pass because the plane never
    // covered the pixel at all.
    cmd("layer.attr 0 pos.x 40");
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    settle();
    clickAt(c, at[0], at[1]);
    assert(hoveredItem() == 2 && itemSelected(2),
        format("rig: with the cube moved away that pixel is over the backdrop "
               ~ "— hovered %d, backdrop selected %s",
               hoveredItem(), itemSelected(2)));

    // Cube back, backdrop made the focused item, and now the same pixel again.
    cmd("layer.attr 0 pos.x 0");
    cmd(`{"id":"layer.select","index":2,"mode":"set"}`);
    settle();
    assert(focusedItem() == 2 && itemSelected(2),
        "rig: the BACKDROP is the focused item, so 'the cube won' is a change");

    clickAt(c, at[0], at[1]);
    assert(focusedItem() == 0,
        format("a mesh under the cursor wins over a NEARER backdrop, because "
               ~ "geometry is PAINTED over it (the plane draws first, with the "
               ~ "depth test off, so every later pass wins regardless of world "
               ~ "position) — the app focused item %d. 2 means the two kinds "
               ~ "were merged into one nearest-t compare, and the user would be "
               ~ "selecting an item they cannot see at that pixel.",
               focusedItem()));
    assert(!itemSelected(2),
        "…and the backdrop is deselected by the exclusive click");
    assert(hoveredItem() == 0,
        format("the hover ray must agree with the click — it reports %d",
               hoveredItem()));
}

// ---------------------------------------------------------------------------
// U6 — a pickable backdrop is a PAINTED backdrop.
//
// Task 0647 wrote an invariant into the highlight pass: nothing can be hovered
// that cannot be painted, or painted that cannot be hovered. Making planes
// pickable would have falsified it silently — an item you can select with no
// cue that it is under the cursor — so the pass grew a border for them, and
// this flow is what keeps the two halves together.
//
// Every number here is READ from `tests/fixtures/item_hover_highlight.json`,
// the 0647 capture: a plane's highlight is its rectangular BORDER, two pixels
// wide (a mesh's edges are one), its image area is never tinted, and the three
// (selected, hovered) states are the same three colours a mesh gets. A retyped
// constant would be a second copy of that measurement free to disagree with it.
//
// The colours are asserted EXACTLY, not within a window, and that is legal
// rather than lucky: this pass draws opaque with anti-aliasing switched off, so
// a painted pixel carries the uniform's value and nothing else.
// ---------------------------------------------------------------------------
private enum string kHoverFixtureJson = import("fixtures/item_hover_highlight.json");

private int[3] rgbOf(JSONValue v) {
    auto a = v["rgb"].array;
    return [cast(int)a[0].integer, cast(int)a[1].integer, cast(int)a[2].integer];
}

/// Probe a vertical run of FBO pixels and return how many carry EXACTLY `want`.
private int columnHits(int fx, int fy0, int fy1, int[3] want) {
    string q = "/api/viewport/probe?cell=0&points=";
    foreach (y; fy0 .. fy1) {
        if (y > fy0) q ~= ";";
        q ~= format("%d,%d", fx, y);
    }
    auto j = getJson(q);
    assert("error" !in j, "probe failed: " ~ j.toString);
    // The --test single-rendered-cell trap: a probe at a never-filled FBO reads
    // zeros, and every count below would then be a zero that means nothing.
    assert(j["renders"].type == JSONType.true_,
        "the probed cell is not rendered under --test; the reading is void");
    int n = 0;
    foreach (e; j["points"].array) {
        if ("error" in e) continue;
        if (cast(int)e["r"].integer == want[0]
         && cast(int)e["g"].integer == want[1]
         && cast(int)e["b"].integer == want[2]) ++n;
    }
    return n;
}

unittest {
    auto fx   = parseJSON(kHoverFixtureJson)["cases"]["image_plane_item_with_no_mesh"];
    immutable pre  = rgbOf(fx["hovered_unselected"]);
    immutable selH = rgbOf(fx["selected_and_hovered"]);
    immutable int borderPx = cast(int)fx["border_width_px"].integer;
    assert(fx["highlights"].type == JSONType.true_
        && fx["target"].str == "rectangular_border"
        && fx["image_area_filled"].type == JSONType.false_,
        "the fixture must say a backdrop highlights as a border with an "
        ~ "untinted image — that is what this flow checks we implement");

    buildPlaneRig(/*x=*/4.0f, /*z=*/0.0f, /*pixelSize=*/0.05f);
    auto c = cell();
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    settle();
    assert(!itemSelected(2), "precondition: the backdrop starts unselected");

    auto q = planeQuad(2);
    auto ctr = toWindow(q.center);
    auto top = toWindow(DHVec3(q.center.x + q.halfV.x,
                               q.center.y + q.halfV.y,
                               q.center.z + q.halfV.z));

    // Park the pointer on the backdrop WITHOUT clicking: hovered, unselected.
    clickAt(c, ctr[0], ctr[1], kModCtrl);   // ctrl = remove; it is not selected,
                                            // so this is a no-op that leaves the
                                            // pointer parked on it.
    assert(hoveredItem() == 2 && !itemSelected(2),
        format("precondition: the backdrop is hovered and still unselected — "
               ~ "hovered %d, selected %s", hoveredItem(), itemSelected(2)));

    // A short column across the top edge. The border is the only thing on it
    // that can be this colour.
    immutable int fx0 = top[0] - c.vx;
    immutable int fy0 = top[1] - c.vy - 6, fy1 = top[1] - c.vy + 7;
    immutable int hovHits = columnHits(fx0, fy0, fy1, pre);
    assert(hovHits >= borderPx,
        format("hovering a backdrop must paint its border in the pre-highlight "
               ~ "colour (%d,%d,%d) — a %d-pixel column across its top edge "
               ~ "carries %d such pixels. Zero means an item that can be picked "
               ~ "gives the user no cue at all; %d instead of %d means it was "
               ~ "drawn with a mesh's one-pixel line.",
               pre[0], pre[1], pre[2], fy1 - fy0, hovHits, hovHits, borderPx));
    assert(hovHits <= borderPx + 2,
        format("…and it is a BORDER, not a fill — %d painted pixels on a "
               ~ "%d-pixel column crossing one edge", hovHits, fy1 - fy0));

    // The image area is untouched: the whole point of a border.
    assert(columnHits(ctr[0] - c.vx, ctr[1] - c.vy, ctr[1] - c.vy + 1, pre) == 0,
        "the backdrop's IMAGE must not be tinted — the pixel at its centre "
        ~ "carries the highlight colour, which is a filled quad, not a border");

    // Now select it with the pointer where it already is: the third state.
    clickAt(c, ctr[0], ctr[1]);
    assert(itemSelected(2) && hoveredItem() == 2,
        "the click selects the backdrop and the pointer stays on it");
    assert(columnHits(fx0, fy0, fy1, selH) == hovHits,
        format("selected AND hovered paints the SAME border in its own colour "
               ~ "(%d,%d,%d) — %d pixels then, %d now",
               selH[0], selH[1], selH[2], hovHits,
               columnHits(fx0, fy0, fy1, selH)));
    assert(columnHits(fx0, fy0, fy1, pre) == 0,
        "…and no longer the plain hover colour: the third state is its own, "
        ~ "not a repeat of the second");
}
