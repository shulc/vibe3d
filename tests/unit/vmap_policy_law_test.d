// Two vertex-map POLICY laws, frozen from the reference and checked against
// the code we actually ship (task 3190, capture campaign batch D).
//
// Reads `tests/fixtures/selset_weld_membership.json` (register row 39) and
// `tests/fixtures/vertex_map_selection_rename.json` (row 46).
//
// WHY THIS CELL EXISTS. Both rows were scheduled for the behavioural command
// lane on the stated ground that a POLICY question -- "what does the editor
// do when two tagged things become one", "does a binding follow a rename" --
// has no formula to read. Both had one.
//
//   * Row 39 is not a collision policy at all. Each selection set is its own
//     named map over the edge domain, and the weld's re-key copies per named
//     map, additively, never clearing the destination. The union is
//     STRUCTURAL. A behavioural cell can show that the answer IS union; only
//     the read shows that drop and first-wins were never candidates, and that
//     is the difference between "we match on this stand" and "we match".
//   * Row 46's read named a second candidate the obvious stand cannot see --
//     a per-kind memo beside the by-name lookup, invalidated by a selection
//     event but not by a rename -- and named the degeneracy that would have
//     hidden the real answer: with only ONE map of the kind, "the selection
//     followed the rename" and "the selection fell back to the only map"
//     are the same observation.
//
// WHAT IT PINS IN OUR CODE.
//   * `selSetRekeyEdges`'s collision arm (`|=`) and its collapse arm
//     (`na == nb` -> drop) are both reference behaviour, not the conservative
//     vibe3d choice the register recorded them as.
//   * `resolveWeightMap` resolving a stale name to null -- and NOT to some
//     other map of the kind -- is reference behaviour too.
//
// MUTATIONS (each seen red, in isolation -- druntime stops a module at its
// first failed assert, so they must be run one at a time):
//   * `selSetRekeyEdges`: replace `*p |= mask` with first-wins
//     (`if (nk !in fresh) fresh[nk] = mask;`) -> the DISCRIMINATING cell
//     reddens with "row 39 ... expected both sets"; the CONTROL cell stays
//     green. That asymmetry is the proof the discriminating cell was chosen
//     rather than fitted.
//   * `selSetRekeyEdges`: delete the `if (na == nb) continue;` guard -> the
//     collapse cell reddens.
//   * `resolveWeightMap`: make a missing name fall back to the first Point
//     dim-1 map -> the rename cell reddens with "expected NO current map".
module tests.unit.vmap_policy_law_test;

import std.json;
import std.file   : readText;
import std.format : format;
import std.algorithm : canFind, sort;

import math         : Vec3;
import mesh;
import mesh_selsets;
import weightmap_view : resolveWeightMap;

private enum string kWeld   = "tests/fixtures/selset_weld_membership.json";
private enum string kRename = "tests/fixtures/vertex_map_selection_rename.json";

private JSONValue fx(string p) { return parseJSON(readText(p)); }

private JSONValue cellNamed(JSONValue doc, string name) {
    foreach (c; doc["cells"].array)
        if (c["cell"].str == name) return c;
    assert(false, "fixture has no cell named " ~ name);
}

// ---------------------------------------------------------------------------
// Row 39 -- the stand, rebuilt from the fixture's own numbers.
// ---------------------------------------------------------------------------

private Mesh standFromFixture(JSONValue doc) {
    Mesh m;
    foreach (v; doc["stand"]["vertices"].array) {
        auto a = v.array;
        m.addVertex(Vec3(cast(float) a[0].floating,
                         cast(float) a[1].floating,
                         cast(float) a[2].floating));
    }
    foreach (f; doc["stand"]["faces"].array) {
        uint[] idx;
        foreach (i; f.array) idx ~= cast(uint) i.integer;
        m.addFace(idx);
    }
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// Select exactly the edge (a,b) and hand the parallel bool array over.
private bool[] onlyEdge(ref Mesh m, uint a, uint b) {
    auto sel = new bool[](m.edges.length);
    const int ei = m.edgeIndex(a, b);
    assert(ei >= 0, format("stand has no edge (%d,%d)", a, b));
    sel[cast(size_t) ei] = true;
    return sel;
}

unittest { // row 39 -- DISCRIMINATING: two edges, two different sets, one survivor
    auto doc = fx(kWeld);
    assert(doc["law"]["answer"].str == "union",
           "row 39: the frozen answer must be union");
    assert(doc["law"]["refuted"].array.length == 3,
           "row 39: all three rivals must stay named in the fixture -- a "
           ~ "fixture that forgets what was refuted cannot show the cell "
           ~ "separated anything");

    auto cell = cellNamed(doc, "two_sets_DISCRIMINATING");
    assert(cell["discriminating"].boolean);

    Mesh m = standFromFixture(doc);
    auto tagged = doc["stand"]["tagged_edges"];
    const uint a0 = cast(uint) tagged["a"].array[0].integer;
    const uint a1 = cast(uint) tagged["a"].array[1].integer;
    const uint b0 = cast(uint) tagged["b"].array[0].integer;
    const uint b1 = cast(uint) tagged["b"].array[1].integer;

    selSetEditEdge(m, "S1", SetEditMode.add, onlyEdge(m, a0, a1));
    selSetEditEdge(m, "S2", SetEditMode.add, onlyEdge(m, b0, b1));

    // The weld the reference ran: the two 2 mm-apart end vertices merge, so
    // b0 -> a0 and b1 -> a1; nothing else moves.
    const ulong survivor = edgeKey(a0, a1);
    selSetRekeyEdges(m, (uint v) {
        if (v == b0) return a0;
        if (v == b1) return a1;
        return v;
    });

    auto p = survivor in m.edgeSetMask;
    assert(p !is null,
           "row 39 two_sets_DISCRIMINATING: the surviving edge must still "
           ~ "carry membership; got none (drop)");
    const ulong mask = *p;
    // Slot order is assignment order: S1 = bit 0, S2 = bit 1.
    assert((mask & 1UL) != 0 && (mask & 2UL) != 0,
           format("row 39 two_sets_DISCRIMINATING: expected both sets on the "
                  ~ "survivor (reference: %s), got mask 0x%x -- one bit is "
                  ~ "first-wins, zero bits is drop",
                  cell["sets_after_by_position"].toString, mask));
}

unittest { // row 39 -- CONTROL: both edges in ONE set. Cannot separate.
    auto doc = fx(kWeld);
    auto cell = cellNamed(doc, "one_set_CONTROL_cannot_separate");
    assert(!cell["discriminating"].boolean,
           "the control must be marked as such in the fixture");

    Mesh m = standFromFixture(doc);
    auto tagged = doc["stand"]["tagged_edges"];
    const uint a0 = cast(uint) tagged["a"].array[0].integer;
    const uint a1 = cast(uint) tagged["a"].array[1].integer;
    const uint b0 = cast(uint) tagged["b"].array[0].integer;
    const uint b1 = cast(uint) tagged["b"].array[1].integer;

    auto both = new bool[](m.edges.length);
    both[cast(size_t) m.edgeIndex(a0, a1)] = true;
    both[cast(size_t) m.edgeIndex(b0, b1)] = true;
    selSetEditEdge(m, "S1", SetEditMode.add, both);

    selSetRekeyEdges(m, (uint v) {
        if (v == b0) return a0;
        if (v == b1) return a1;
        return v;
    });

    auto p = edgeKey(a0, a1) in m.edgeSetMask;
    assert(p !is null && (*p & 1UL) != 0,
           "row 39 one_set_CONTROL: the survivor must be in S1 -- union, "
           ~ "first-wins and drop-on-collision all say so, which is exactly "
           ~ "why this cell proves nothing on its own and is frozen anyway");
}

unittest { // row 39 -- the collapse arm the read also settled
    auto doc = fx(kWeld);
    assert(doc["law"]["collapsed_to_a_point_is_dropped"].str.length > 0,
           "the fixture must state the collapse rule");
    assert(doc["law"]["copy_clears_destination"].boolean == false);

    Mesh m = standFromFixture(doc);
    auto tagged = doc["stand"]["tagged_edges"];
    const uint a0 = cast(uint) tagged["a"].array[0].integer;
    const uint a1 = cast(uint) tagged["a"].array[1].integer;
    selSetEditEdge(m, "S1", SetEditMode.add, onlyEdge(m, a0, a1));

    // Weld the tagged edge's OWN two endpoints together: it collapses to a
    // point. The reference skips such an edge entirely and its membership
    // goes with it.
    selSetRekeyEdges(m, (uint v) => (v == a1) ? a0 : v);
    assert(m.edgeSetMask.length == 0,
           "row 39: an edge whose endpoints weld to the same survivor must "
           ~ "lose its membership, not re-key onto a degenerate key");
}

// ---------------------------------------------------------------------------
// Row 46 -- the current weight map does NOT follow a rename
// ---------------------------------------------------------------------------

unittest { // row 46 -- DISCRIMINATING: rename the CURRENT map, two maps present
    auto doc = fx(kRename);
    assert(doc["law"]["answer"].str == "does_not_follow");
    assert(doc["law"]["binding"].str == "by_name");
    assert(doc["law"]["falls_back_to_another_map_of_the_kind"].boolean == false);

    auto cell = cellNamed(doc, "rename_the_CURRENT_map_DISCRIMINATING");
    assert(cell["discriminating"].boolean);
    assert(doc["stand"]["maps"].array.length == 2,
           "row 46: the stand MUST carry two maps of the kind -- with one, "
           ~ "'followed the rename' and 'fell back to the only map' are the "
           ~ "same observation");

    Mesh m = makeCube();
    m.syncSelection();
    foreach (mm; doc["stand"]["maps"].array)
        m.addWeightMap(mm["name"].str);

    const string current = cell["select"].str;               // "W1"
    assert(resolveWeightMap(m, current) !is null,
           "row 46: the selected map must resolve BEFORE the rename -- a cell "
           ~ "that starts unresolved could not tell the two candidates apart");

    // The rename: the map OBJECT is renamed; the by-name binding is not
    // rewritten, exactly as the reference's rename verb behaves.
    auto obj = m.meshMap(cell["rename"]["old"].str);
    assert(obj !is null);
    obj.name = cell["rename"]["new"].str;

    assert(cell["current_after"].array.length == 0,
           "fixture: the reference reported NO current map after the rename");
    assert(resolveWeightMap(m, current) is null,
           format("row 46: after renaming the current map, the stored name "
                  ~ "must resolve to NOTHING (reference: %s). Resolving to "
                  ~ "another map of the kind is the refuted fallback "
                  ~ "candidate.", cell["current_after"].toString));
    // and the other map is still there, unselected -- so "nothing resolved"
    // is not merely "nothing existed".
    assert(resolveWeightMap(m, "W2") !is null,
           "row 46: the OTHER map must still exist, or the cell degenerates "
           ~ "into 'there was nothing to fall back to'");
}

unittest { // row 46 -- CONTROL: rename a map that is NOT current
    auto doc = fx(kRename);
    auto cell = cellNamed(doc, "rename_a_NON_current_map_CONTROL_cannot_separate");
    assert(!cell["discriminating"].boolean);

    Mesh m = makeCube();
    m.syncSelection();
    foreach (mm; doc["stand"]["maps"].array)
        m.addWeightMap(mm["name"].str);

    const string current = cell["select"].str;
    auto obj = m.meshMap(cell["rename"]["old"].str);          // "W2"
    assert(obj !is null);
    obj.name = cell["rename"]["new"].str;

    assert(cell["current_after"].array == [JSONValue(current)]);
    assert(resolveWeightMap(m, current) !is null,
           "row 46 CONTROL: renaming a NON-current map must leave the current "
           ~ "one resolving -- every candidate agrees here, which is what "
           ~ "makes this the control and not the measurement");
}
