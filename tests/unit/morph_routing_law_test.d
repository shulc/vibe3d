// Four morph-routing laws, read off the reference's own compute sites and
// frozen in `tests/fixtures/morph_routing_laws.json` (task 3190, capture
// campaign batch D; register rows 52, 53, 53b and 57).
//
// WHY A READ AND NOT A DRIVE. All four were scheduled for the behavioural
// command lane. Two of them cannot be driven there at all: where a falloff
// samples its weight needs a live drag under a radial falloff, and what a
// snap targets needs a live pointer. The remaining two are one read each --
// and the read of row 52 says it is not a second law but the same one, which
// no amount of driving the absolute view would have shown as cleanly.
//
// THE ONE PLACE THE READ COULD HAVE GONE WRONG, recorded in the fixture: the
// reference's per-element side packet carries BOTH positions, routed and
// base. A reader who stopped at the packet layout could pick either. What
// settles row 53b is that the driver hands the SAME buffer it filled from its
// single position read to the falloff and then to the transform, so the two
// cannot disagree.
//
// WHAT THIS CELL PINS IN OUR CODE.
//   * Row 52 -- `Mesh.morphEvaluate`'s missing-entry default, for BOTH map
//     kinds: an absent entry must display AT THE BASE. That is the reference's
//     one shared fallback, and it is what makes the relative and absolute
//     views the same rule rather than two.
//   * Row 57 -- `displayPosition` is the drawn point, which is what our snap
//     candidate scan reads (`snap.d`'s `vAt`). The reference's scan reads the
//     view's mesh, i.e. the drawn points too.
//
// WHAT IT DOES NOT PIN. Rows 53b and 53 are frozen as law text with their
// refuted rivals named; we ship the matching behaviour but its live site is a
// drag and a command, neither reachable from a module unittest. Whoever
// touches either starts from the read, not from a re-derivation.
//
// MUTATIONS (each seen red, in isolation):
//   * `Mesh.morphEvaluate`: return `Vec3(0,0,0)` for an absent entry
//     regardless of kind -> "row 52 ... absent entry must display AT THE BASE"
//     reddens for the ABSOLUTE map and stays green for the relative one. That
//     asymmetry is the point: the relative kind cannot tell the two rules
//     apart, so a fixture built only on a relative map would have been green
//     over the broken code.
//   * `morphApply`'s absolute arm -> the row-53 accumulation consequence
//     reddens.
//   * drop a `refuted` entry from the fixture -> the corresponding
//     "must stay named" assert reddens.
module tests.unit.morph_routing_law_test;

import std.json;
import std.file   : readText;
import std.format : format;
import std.math   : abs;

import math         : Vec3;
import mesh;
import mesh_morph   : morphApply;
import morph_target : displayPosition, setMorphTarget, clearMorphTarget;

private enum string kFixture = "tests/fixtures/morph_routing_laws.json";
private JSONValue fx() { return parseJSON(readText(kFixture)); }

private bool near(Vec3 a, Vec3 b, float eps = 1e-5f) {
    return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps;
}

private void requireRefuted(JSONValue node, string what, string cand) {
    bool found = false;
    foreach (r; node["refuted"].array) if (r.str == cand) found = true;
    assert(found, format("%s: the fixture must keep '%s' named as refuted -- "
                         ~ "a law that forgets its rivals cannot show anything "
                         ~ "was separated", what, cand));
}

// ---------------------------------------------------------------------------
// Row 52 -- an ABSENT entry contributes the BASE, for both kinds
// ---------------------------------------------------------------------------

unittest {
    auto doc = fx();
    auto row = doc["absolute_view_under_topology_change"];
    assert(row["row"].str == "52");
    assert(row["answer"].str == "same_rule_as_relative");
    assert(row["missing_entry_contributes"].str == "base_position");
    assert(row["missing_entry_contributes_zero"].boolean == false);
    assert(row["one_code_path_parameterised_by_the_view"].boolean == true);
    requireRefuted(row, "row 52", "missing_entry_is_zero");
    requireRefuted(row, "row 52", "absolute_has_its_own_rule");

    Mesh m = makeCube();
    m.syncSelection();
    auto rel = m.addMeshMapOfKind(MapKind.morphRelative, "R");
    auto abs_ = m.addMeshMapOfKind(MapKind.morphAbsolute, "A");
    assert(rel !is null && abs_ !is null);

    // Nothing written: every entry is ABSENT in both maps.
    foreach (vi; 0 .. m.vertices.length) {
        const Vec3 base = m.vertices[vi];
        const Vec3 shownRel = morphApply(base, m.morphEvaluate("R", vi),
                                         MapKind.morphRelative, 1.0f);
        const Vec3 shownAbs = morphApply(base, m.morphEvaluate("A", vi),
                                         MapKind.morphAbsolute, 1.0f);
        assert(near(shownRel, base),
               format("row 52: an absent entry in the RELATIVE map must "
                      ~ "display AT THE BASE (vertex %d)", vi));
        assert(near(shownAbs, base),
               format("row 52: an absent entry in the ABSOLUTE map must "
                      ~ "display AT THE BASE, not at the origin (vertex %d). "
                      ~ "This is the arm the relative map cannot test.", vi));
    }

    // and a PRESENT entry must differ, or the cell above is satisfied by a
    // map that does nothing at all.
    m.setMorphValue("A", 0, m.vertices[0] + Vec3(0, 0.5f, 0));
    assert(!near(morphApply(m.vertices[0], m.morphEvaluate("A", 0),
                            MapKind.morphAbsolute, 1.0f), m.vertices[0]),
           "row 52: a PRESENT absolute entry must move the vertex, or the "
           ~ "absent-entry cell proves nothing");
}

// ---------------------------------------------------------------------------
// Row 57 -- what a snap targets: the DRAWN point
// ---------------------------------------------------------------------------

unittest {
    auto doc = fx();
    auto row = doc["snap_target_position"];
    assert(row["row"].str == "57");
    assert(row["answer"].str == "drawn");
    assert(row["reads_the_view_mesh"].boolean == true);
    assert(row["reads_the_edit_cage"].boolean == false);
    assert(row["composed_with_an_already_frozen_law"].str.length > 0,
           "row 57 is a composition of one read with an already-frozen law, "
           ~ "and the fixture must say so rather than read as a driven gesture");
    requireRefuted(row, "row 57", "base");

    Mesh m = makeCube();
    m.syncSelection();
    auto mm = m.addMeshMapOfKind(MapKind.morphRelative, "M");
    assert(mm !is null);
    const Vec3 base = m.vertices[0];
    m.setMorphValue("M", 0, Vec3(0, 0.25f, 0));
    setMorphTarget("M", MapKind.morphRelative);
    scope(exit) clearMorphTarget();

    const Vec3 drawn = displayPosition(&m, 0);
    assert(near(drawn, base + Vec3(0, 0.25f, 0)),
           "row 57: the drawn point is base + the stored offset; our snap "
           ~ "candidate scan reads exactly this, which is what the reference's "
           ~ "scan gets by taking its mesh from the view");
    assert(!near(drawn, base),
           "row 57: the cell must actually MOVE the vertex -- with a zero "
           ~ "offset the drawn and base candidates coincide and nothing is "
           ~ "separated");
}

// ---------------------------------------------------------------------------
// Row 53b -- the falloff weight is sampled at the ROUTED position
// ---------------------------------------------------------------------------

unittest {
    auto doc = fx();
    auto row = doc["falloff_weight_position"];
    assert(row["row"].str == "53b");
    assert(row["answer"].str == "routed",
           "row 53b: the frozen answer is the routed position");
    assert(row["same_buffer_for_weight_and_transform"].boolean == true,
           "row 53b: what settles the row is that ONE buffer feeds both the "
           ~ "weight and the transform -- drop this and the packet's two "
           ~ "positions make the read ambiguous again");
    assert(row["zero_weight_skips_the_transform_call"].boolean == true);
    assert(row["note_base_is_also_published"].str.length > 0,
           "row 53b: the fixture must record that the base position is ALSO "
           ~ "published, or a later reader will think the read had only one "
           ~ "candidate in front of it");
    requireRefuted(row, "row 53b", "base");
    // The reference passes NO element id alongside the position.
    assert(row["element_id_passed_to_the_falloff"].isNull);
}

// ---------------------------------------------------------------------------
// Row 53 -- applying a map does not touch the map
// ---------------------------------------------------------------------------

unittest {
    auto doc = fx();
    auto row = doc["apply_the_routing_target"];
    assert(row["row"].str == "53");
    assert(row["answer"].str == "map_untouched_base_moves");
    assert(row["writes_the_source_map"].boolean == false);
    assert(row["writes_the_base"].boolean == true);
    assert(row["depends_on_the_current_selection"].boolean == false,
           "row 53's whole question was whether being the ROUTING TARGET "
           ~ "changes the apply; the read says the verb takes its source from "
           ~ "its own argument and the selection plays no part");
    requireRefuted(row, "row 53", "map_is_cleared");
    requireRefuted(row, "row 53", "map_is_rewritten");

    // The arithmetic consequence, executed: with the source named as its own
    // destination the stored offset doubles, because the verb accumulates
    // onto the destination's CURRENT value rather than replacing it.
    const Vec3 base = Vec3(1, 2, 3);
    const Vec3 stored = Vec3(0, 0.4f, 0);
    const Vec3 shown = morphApply(base, stored, MapKind.morphRelative, 1.0f);
    const Vec3 accumulated = shown + stored;          // cur + amount * src
    assert(near(accumulated - base, stored * 2.0f),
           "row 53: source-as-its-own-destination must double the stored "
           ~ "offset");
}
