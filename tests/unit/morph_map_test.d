// The measured morph law, driven straight from the frozen capture fixture
// with ZERO vibe3d feature surface in the loop (task 1069, plan Stage 2).
//
// A red here is the LAW being wrong, not the wiring: the only code under test
// is `source/mesh_morph.d`'s two pure functions. Everything that needs a
// `Mesh`, a command, a file or a drag is asserted in Stage 3-7's own tests.
//
// Every number comes from `tests/fixtures/morph_maps.json`, which is the
// scrubbed copy of the capture. Prose in that file was rewritten for
// neutrality; not one numeric value was touched.
module tests.unit.morph_map_test;

import std.json;
import std.file   : readText;
import std.math   : abs;
import std.format : format;

import math       : Vec3;
import mesh       : MapKind;
import mesh_morph : morphApply, morphRoutedStore;

// ---------------------------------------------------------------------------
// Fixture plumbing
// ---------------------------------------------------------------------------

private double asDouble(JSONValue v) {
    final switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        case JSONType.string:   case JSONType.array:  case JSONType.object:
        case JSONType.true_:    case JSONType.false_: case JSONType.null_:
            assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private Vec3 asVec3(JSONValue v) {
    assert(v.type == JSONType.array && v.array.length == 3,
        "fixture: expected a 3-element array, got " ~ v.toString);
    return Vec3(cast(float) asDouble(v.array[0]),
                cast(float) asDouble(v.array[1]),
                cast(float) asDouble(v.array[2]));
}

// Self-contained provenance vocabulary check. `tests/fixture_helpers.d` is
// not importable from `tests/unit` (dub's `tests` config compiles only
// `source` + `tests/unit`), so this repeats the check locally — the same
// thing `edge_crease_weight_test.d` does and for the same reason.
private void checkProvenance(JSONValue fx) {
    assert("provenance" in fx, "morph_maps fixture has no 'provenance' block");
    auto prov = fx["provenance"];
    static immutable string[] kSources = ["live-capture", "simulated", "analytic", "unknown"];
    static immutable string[] kMethods = ["capture-drag", "command", "from-trace",
                                          "rr-memory", "self-drive", "closed-form",
                                          "hand", "unknown"];
    bool oneOf(string v, const string[] allowed) {
        foreach (a; allowed) if (v == a) return true;
        return false;
    }
    assert("source" in prov && prov["source"].type == JSONType.string
        && oneOf(prov["source"].str, kSources),
        "morph_maps fixture: provenance.source missing/invalid");
    assert("method" in prov && prov["method"].type == JSONType.string
        && oneOf(prov["method"].str, kMethods),
        "morph_maps fixture: provenance.method missing/invalid");
}

private JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) {
        // Hard fail on a missing file — no try/catch. A fixture test that
        // silently skips when its fixture is gone is the inert-assertion
        // failure mode this project has been bitten by.
        cached = parseJSON(readText("tests/fixtures/morph_maps.json"));
        checkProvenance(cached);
        loaded = true;
    }
    return cached;
}

private JSONValue caseOf(string name) {
    auto fx = fixture();
    assert(name in fx["cases"], "morph_maps fixture: no case '" ~ name ~ "'");
    return fx["cases"][name];
}

/// The base box every case starts from: axis-aligned, deliberately asymmetric
/// and ORIGIN-FREE, so "store a delta" and "store a position" can never
/// coincide on any vertex.
private Vec3[] baseMesh() {
    Vec3[] v;
    foreach (e; fixture()["_base_mesh"]["vertices"].array) v ~= asVec3(e);
    return v;
}

private Vec3[] caseVertices(string name, size_t meshIdx = 0) {
    Vec3[] v;
    foreach (e; caseOf(name)["meshes"].array[meshIdx]["vertices"].array) v ~= asVec3(e);
    return v;
}

private struct Entry { Vec3 pos, value; }

private struct FixtureMap {
    string  name;
    MapKind kind;
    Entry[] entries;
}

private FixtureMap caseMap(string name, string mapName, size_t meshIdx = 0) {
    auto maps = caseOf(name)["meshes"].array[meshIdx]["morph_maps"];
    assert(mapName in maps,
        format("case '%s' has no map '%s'", name, mapName));
    auto m = maps[mapName];
    FixtureMap r;
    r.name = mapName;
    // The fixture's `type` was re-keyed to the neutral kind names during the
    // scrub; anything else means the scrub or the fixture drifted.
    switch (m["type"].str) {
        case "relative": r.kind = MapKind.morphRelative; break;
        case "absolute": r.kind = MapKind.morphAbsolute; break;
        default: assert(false, "fixture: unknown map kind '" ~ m["type"].str ~ "'");
    }
    foreach (e; m["entries"].array)
        r.entries ~= Entry(asVec3(e["pos"]), asVec3(e["value"]));
    assert(r.entries.length == cast(size_t) m["entry_count"].integer,
        format("case '%s' map '%s': entry_count %d disagrees with %d listed entries",
               name, mapName, m["entry_count"].integer, r.entries.length));
    return r;
}

// ---------------------------------------------------------------------------
// Tolerance. ONE rule for every numeric assertion in this file:
//
//     |got - want|  <=  1e-6 + 1e-6 * |want|
//
// Justified by the capture's OWN residual: `apply_x100` reports
// (25.799994, -8.800002, 6.599995) where exact arithmetic gives
// (25.8, -8.8, 6.6) — a worst residual of 6e-6 at magnitude 25.8, about 3 ULP
// of float32 there and not reproducible by a single float32 add, so the
// reference accumulates through a path we do not model. The rule allows
// 2.7e-5 at that magnitude and 1.9e-6 at 0.925, i.e. it does NOT slacken the
// small cases. What it costs: it cannot see an error below 2.7e-5 at
// coordinate 25.8. The smallest gap between the truth and any REJECTED
// candidate anywhere in this set is 0.05 (`deformer_strength_2` against a
// clamp at 1.0) — about 1800x the tolerance there.
// ---------------------------------------------------------------------------
private bool near(double got, double want) {
    return abs(got - want) <= 1e-6 + 1e-6 * abs(want);
}

private void assertNear(Vec3 got, Vec3 want, string what) {
    assert(near(got.x, want.x) && near(got.y, want.y) && near(got.z, want.z),
        format("%s: got (%.7f,%.7f,%.7f) want (%.7f,%.7f,%.7f)",
               what, got.x, got.y, got.z, want.x, want.y, want.z));
}

/// Index of `p` in `verts` under the tolerance rule. The fixture keys entries
/// on GEOMETRY, never on index, so an entry is matched to its vertex by
/// position — never by assuming the arrays line up.
private size_t indexOfPos(const Vec3[] verts, Vec3 p, string what) {
    foreach (i, v; verts)
        if (near(v.x, p.x) && near(v.y, p.y) && near(v.z, p.z)) return i;
    assert(false, format("%s: no vertex at (%.7f,%.7f,%.7f)", what, p.x, p.y, p.z));
}

// ---------------------------------------------------------------------------
// Fixture integrity — assert the discriminating cases actually discriminate
// before trusting anything they say.
// ---------------------------------------------------------------------------

// The base box has no vertex at the origin and no zero coordinate, which is
// what stops "delta" and "absolute position" coinciding on any vertex. If a
// future edit ever regularises this mesh, every kind test in the suite goes
// quietly vacuous — so it is asserted, not assumed.
unittest {
    auto b = baseMesh();
    assert(b.length == 8, "the capture's base mesh is an 8-vertex box");
    foreach (i, v; b) {
        assert(!(near(v.x, 0) && near(v.y, 0) && near(v.z, 0)),
            format("base vertex %d is at the ORIGIN -- delta and absolute "
                 ~ "would coincide there and every kind case goes vacuous", i));
        assert(!near(v.x, 0) && !near(v.y, 0) && !near(v.z, 0),
            format("base vertex %d has a ZERO coordinate -- a per-axis "
                 ~ "delta/absolute confusion would be invisible on that axis", i));
    }
}

// `base_scale_leaves_delta` is the L1 discriminator, and it only discriminates
// because a x2 scale predicts something DIFFERENT from what was measured. A
// translate alone cannot separate "store a delta" from "store a position and
// re-derive it"; the scale can. Assert the separation exists.
unittest {
    auto storedAfterScale = caseMap("base_scale_leaves_delta", "M").entries[0].value;
    auto storedBefore     = caseMap("edit_routes_into_selected_morph", "M").entries[0].value;

    assertNear(storedAfterScale, storedBefore,
        "a later base SCALE must leave the stored delta untouched");

    // The rejected candidate: storing in the transformed frame would double it.
    auto doubled = storedBefore * 2.0f;
    assert(!(near(storedAfterScale.x, doubled.x)
          && near(storedAfterScale.y, doubled.y)
          && near(storedAfterScale.z, doubled.z)),
        "the x2-scale case does not separate the candidates -- the measured "
      ~ "value equals the 'stored in the transformed frame' prediction, so "
      ~ "this case proves nothing");

    // ...and the base really did scale, or the case never exercised anything.
    auto scaled = caseVertices("base_scale_leaves_delta");
    auto b = baseMesh();
    assertNear(scaled[0], b[0] * 2.0f, "the base was actually scaled x2");
}

// ---------------------------------------------------------------------------
// L4 — apply is exactly linear and UNCLAMPED, for both kinds.
// ---------------------------------------------------------------------------

private void assertApplyCase(string caseName, string mapName, float amount,
                             bool smokeOnly = false) {
    auto b   = baseMesh();
    auto got = caseVertices(caseName);
    auto fm  = caseMap(caseName, mapName);
    assert(got.length == b.length,
        caseName ~ ": an apply must not change the vertex count");

    bool[] touched;
    touched.length = b.length;

    foreach (e; fm.entries) {
        // The entry's `pos` is the POST-apply position of its vertex, so it
        // locates the vertex in `got`; the pre-apply base at the same slot is
        // what the law is evaluated from.
        const size_t i = indexOfPos(got, e.pos, caseName ~ " entry");
        touched[i] = true;
        assertNear(morphApply(b[i], e.value, fm.kind, amount), got[i],
            format("%s: vertex %d under morphApply(base, stored, %s, %g)",
                   caseName, i, fm.kind, amount));
    }
    foreach (i, v; got)
        if (!touched[i])
            assertNear(v, b[i], format("%s: vertex %d has no entry and must "
                                     ~ "not have moved", caseName, i));
    if (smokeOnly) return;
    // A discriminating case must actually move something, or it is asserting
    // that nothing happened.
    bool moved = false;
    foreach (i, v; got)
        if (!near(v.x, b[i].x) || !near(v.y, b[i].y) || !near(v.z, b[i].z))
            moved = true;
    assert(moved, caseName ~ ": nothing moved -- this case discriminates nothing");
}

unittest { // p' = p + a*delta at a = 0.5, 1.5, -0.5, 100 — the discriminating four
    assertApplyCase("apply_half",     "M",  0.5f);
    assertApplyCase("apply_over",     "M",  1.5f);   // a clamp to <=1 reddens here
    assertApplyCase("apply_negative", "M", -0.5f);   // a clamp to >=0 reddens here
    assertApplyCase("apply_x100",     "M", 100.0f);  // any clamp reddens here
}

unittest { // the two SMOKE cases, labelled as discriminating nothing
    // At a == 1 every candidate law returns p+d, and at a == 0 every candidate
    // returns p. They are kept because they are cheap regressions, and they
    // are named here so nobody mistakes them for evidence.
    assertApplyCase("apply_full", "M", 1.0f, /*smokeOnly=*/false);
    // deformer_strength_0 leaves the mesh at the base: assert exactly that.
    auto b   = baseMesh();
    auto got = caseVertices("deformer_strength_0");
    foreach (i, v; got)
        assertNear(v, b[i], "deformer_strength_0: strength 0 leaves the base alone");
}

unittest { // the golden multi-entry apply
    assertApplyCase("golden_apply_05", "M", 0.5f);
    // ...and it really is three entries on three different vertices.
    auto fm = caseMap("golden_apply_05", "M");
    assert(fm.entries.length == 3, "golden_apply_05 carries three entries");
}

unittest { // the ABSOLUTE kind: lerp(base, target, a), and the target is NOT
           // re-snapshotted by the apply
    assertApplyCase("absolute_apply_half_keeps_target", "S", 0.5f);

    auto b  = baseMesh();
    auto fm = caseMap("absolute_apply_half_keeps_target", "S");
    assert(fm.kind == MapKind.morphAbsolute);
    assert(fm.entries.length == 8, "the absolute kind is created DENSE");

    // Every stored target still equals what it was BEFORE the apply: seven of
    // them are the untouched base positions and one is the moved target. If
    // apply re-snapshotted, the seven would still match (they did not move)
    // but the eighth would have become the post-apply 0.925... position.
    auto pre = caseMap("absolute_stores_position", "S");
    foreach (e; fm.entries) {
        const size_t i = indexOfPos(caseVertices("absolute_apply_half_keeps_target"),
                                    e.pos, "absolute apply entry");
        bool matched = false;
        foreach (pe; pre.entries) {
            const size_t j = indexOfPos(caseVertices("absolute_stores_position"),
                                        pe.pos, "absolute pre entry");
            if (j != i) continue;
            matched = true;
            assertNear(e.value, pe.value,
                format("vertex %d: the stored ABSOLUTE target must survive an "
                     ~ "apply unchanged -- a re-snapshot would move it to the "
                     ~ "post-apply position", i));
        }
        assert(matched, format("no pre-apply entry for vertex %d", i));
    }

    // The decisive half: treating the absolute value as a DELTA would put
    // vertex 6 at 0.8 + 0.5*1.05 = 1.325, not at 0.925. Assert the two
    // predictions differ, so the case discriminates.
    const size_t vi = 6;
    auto asDelta    = morphApply(b[vi], fm.entries[vi].value, MapKind.morphRelative, 0.5f);
    auto asAbsolute = morphApply(b[vi], fm.entries[vi].value, MapKind.morphAbsolute, 0.5f);
    assert(!near(asDelta.x, asAbsolute.x),
        "the absolute case does not separate the two kinds on this vertex");
}

unittest { // a later base translate leaves an ABSOLUTE target alone, and the
           // relative twin leaves the DELTA alone
    auto rel = caseMap("base_translate_leaves_delta", "M").entries[0].value;
    assertNear(rel, caseMap("edit_routes_into_selected_morph", "M").entries[0].value,
        "a later base translate must leave the stored DELTA untouched");

    auto absAfter = caseMap("absolute_base_translate_keeps_target", "S");
    auto absPre   = caseMap("absolute_stores_position", "S");
    // Vertex 6 is the one carrying a non-identity target in both cases.
    Vec3 target(FixtureMap fm, Vec3[] verts) {
        foreach (e; fm.entries) {
            const size_t i = indexOfPos(verts, e.pos, "absolute entry");
            if (i == 6) return e.value;
        }
        assert(false, "no entry for vertex 6");
    }
    assertNear(target(absAfter, caseVertices("absolute_base_translate_keeps_target")),
               target(absPre,   caseVertices("absolute_stores_position")),
        "a later base translate must leave the stored ABSOLUTE target untouched -- "
      ~ "storing a delta for the absolute kind would move with the base");
}

// ---------------------------------------------------------------------------
// L4 second half — two morphs ADD rather than override, and our single
// destructive `apply` composes by being run twice.
// ---------------------------------------------------------------------------
unittest {
    auto b   = baseMesh();
    auto got = caseVertices("deformer_two_morphs_add");
    auto M   = caseMap("deformer_two_morphs_add", "M");
    auto N   = caseMap("deformer_two_morphs_add", "N");
    const size_t vi = indexOfPos(got, M.entries[0].pos, "two-morphs entry");

    auto once  = morphApply(b[vi],  M.entries[0].value, M.kind, 1.0f);
    auto twice = morphApply(once,   N.entries[0].value, N.kind, 1.0f);
    assertNear(twice, got[vi],
        "two morphs must ADD: applying M then N reaches the measured position");

    // The rejected candidate — applying each from a STASHED base, i.e. the
    // second overriding the first — lands somewhere else. Assert the two
    // predictions differ, so this case discriminates.
    auto overridden = morphApply(b[vi], N.entries[0].value, N.kind, 1.0f);
    assert(!near(overridden.x, twice.x) || !near(overridden.z, twice.z),
        "the two-morph case does not separate 'add' from 'override'");
}

// Cross-check C1 — the capture reached (0.925, 1.15, 1.625) through TWO
// different mechanisms (a direct apply at 0.5 and the deformer at strength
// 0.5). That agreement is what licenses asserting our single `apply` against
// the deformer-captured strengths in `deformer_strength_2` / `_neg`.
unittest {
    auto direct   = caseVertices("apply_half");
    auto deformer = caseVertices("deformer_strength_half");
    assert(direct.length == deformer.length);
    foreach (i; 0 .. direct.length)
        assertNear(deformer[i], direct[i],
            format("C1: the two mechanisms disagree at vertex %d, so the "
                 ~ "deformer-captured strengths may NOT be asserted against "
                 ~ "our single apply", i));

    // With C1 established, the unclamped strengths measured through the
    // deformer are law for `apply` too.
    assertApplyCase("deformer_strength_2",   "M",  2.0f);
    assertApplyCase("deformer_strength_neg", "M", -1.0f);
}

// ---------------------------------------------------------------------------
// The routed store, and its round-trip identity with apply.
// ---------------------------------------------------------------------------
unittest {
    auto b  = baseMesh();
    auto fm = caseMap("edit_routes_into_selected_morph", "M");
    const Vec3 base   = b[6];
    const Vec3 stored = fm.entries[0].value;

    // The routed write: the kernel moved the vertex to base+delta, and the map
    // must receive the DELTA.
    const Vec3 moved = base + stored;
    assertNear(morphRoutedStore(base, moved, MapKind.morphRelative), stored,
        "relative: the routed store is (moved - base)");
    assertNear(morphRoutedStore(base, moved, MapKind.morphAbsolute), moved,
        "absolute: the routed store is the POSITION itself");

    // Round trip, both kinds. This identity is what makes "apply, then store
    // the result again" a no-op, and it is the property the routing seam
    // leans on when a gesture re-fires from the run baseline.
    foreach (kind; [MapKind.morphRelative, MapKind.morphAbsolute]) {
        const Vec3 s = (kind == MapKind.morphRelative) ? stored : moved;
        assertNear(morphRoutedStore(base, morphApply(base, s, kind, 1.0f), kind), s,
            format("%s: morphRoutedStore o morphApply must be the identity", kind));
    }

    // The TRUE base is what the store subtracts. Subtracting the RUN baseline
    // instead (base + an already-stored delta) loses the accumulated part —
    // the exact corruption the accumulate case exists to catch — so assert the
    // two are actually different, or the trap is invisible on this fixture.
    const Vec3 runBaseline = base + stored;
    assert(!near(morphRoutedStore(runBaseline, moved, MapKind.morphRelative).x, stored.x),
        "this fixture cannot see the true-base-vs-run-baseline confusion");
}

// A non-morph kind is not given an invented rule: apply returns the base.
unittest {
    const Vec3 b = Vec3(1, 2, 3);
    foreach (k; [MapKind.unclassified, MapKind.uv,
                 MapKind.vertexWeight, MapKind.creaseWeight])
        assertNear(morphApply(b, Vec3(9, 9, 9), k, 1.0f), b,
            "a non-morph kind must not be given a morph rule");
}

// ---------------------------------------------------------------------------
// Presence is a STORAGE fact, and the fixture's entry lists are literally the
// presence sets (make_fixture.py filters on the presence read, not on a
// nonzero test). These two cases are the reason the presence channel exists.
// ---------------------------------------------------------------------------
unittest {
    // 8 vertices selected and moved by (0,0,0) -> 8 entries, every one zero.
    // A "skip the write when the delta is zero" implementation gives 0.
    auto zero = caseMap("zero_move_creates_entries", "M");
    assert(zero.entries.length == 8,
        "a zero-magnitude move still creates an entry for every SELECTED vertex");
    foreach (e; zero.entries)
        assertNear(e.value, Vec3(0, 0, 0), "each such entry stores zero");

    // 4 selected -> exactly 4. Entries follow the SELECTION, not the mesh.
    auto four = caseMap("entries_follow_the_selection", "M");
    assert(four.entries.length == 4,
        "entries follow the selection: 4 selected must give 4 entries, not 8");

    // +D then -D leaves the entry PRESENT with value 0 — an entry that
    // returns to zero is not erased.
    auto survived = caseMap("zero_delta_entry_survives", "M");
    assert(survived.entries.length == 1,
        "an entry that returns to zero must survive as an entry");
    assertNear(survived.entries[0].value, Vec3(0, 0, 0), "...with value zero");

    // The relative kind is created EMPTY; the absolute kind is created DENSE.
    assert(caseMap("relative_empty_at_creation", "M").entries.length == 0,
        "the relative kind is created with NO entries");
    assert(caseMap("absolute_dense_at_creation", "S").entries.length == 8,
        "the absolute kind is created dense -- a snapshot of every base position");
    auto b = baseMesh();
    auto dense = caseMap("absolute_dense_at_creation", "S");
    auto verts = caseVertices("absolute_dense_at_creation");
    foreach (e; dense.entries) {
        const size_t i = indexOfPos(verts, e.pos, "dense creation entry");
        assertNear(e.value, b[i],
            "a freshly created absolute entry stores the vertex's own base position");
    }
}
