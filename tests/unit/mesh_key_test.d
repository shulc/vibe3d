// Cells for `mesh.MeshKey` and its terms (task 4060) — the type that folded
// `MeshCacheKey` / `MeshStructKey` / `MeshTopoKey` into one template.
//
// OUT OF `source/mesh.d` ON PURPOSE: neither cell needs a `private` symbol of
// that module, which is the only admission ticket an in-module unittest has
// (CLAUDE.md, "Running Tests"; `tests/unit/unittest_source_ceiling_test.d`
// enforces it and reddened when these two blocks were first written there).
module tests.unit.mesh_key_test;

import mesh : Mesh, MeshKey, MeshTermMutation, MeshTermStruct, MeshTermTopology;

// A TERM'S `read` AND ITS `same` MUST NAME THE SAME COUNTER, and nothing in
// the language makes them (they are two hand-written lines, deliberately: the
// compare has to name the counter TEXTUALLY or `version_poll_census_test`
// stops seeing it). This cell is the thing that would notice a copy-paste
// term whose `read` says `topologyVersion` and whose `same` still says
// `mutationVersion` — a key that stamps one counter and compares another is
// permanently fresh.
//
// THE DISCRIMINATION IS BUILT, NOT ASSUMED: three EQUAL counters would make
// every cross-term line below pass for the wrong reason, so the counters are
// forced apart and that separation is asserted FIRST.
unittest {
    Mesh m;
    m.mutationVersion = 11;
    m.topologyVersion = 22;
    m.structVersion   = 33;
    assert(m.mutationVersion != m.topologyVersion
        && m.topologyVersion != m.structVersion
        && m.mutationVersion != m.structVersion,
        "the three counters must differ or the cross-term cells below are "
      ~ "vacuous — they would pass on a term that reads the wrong counter");

    // Each term agrees with itself…
    assert(MeshTermMutation.same(MeshTermMutation.read(m), m));
    assert(MeshTermStruct  .same(MeshTermStruct  .read(m), m));
    assert(MeshTermTopology.same(MeshTermTopology.read(m), m));

    // …and with nothing else, which is what makes the line above evidence.
    assert(!MeshTermMutation.same(MeshTermTopology.read(m), m));
    assert(!MeshTermStruct  .same(MeshTermMutation.read(m), m));
    assert(!MeshTermTopology.same(MeshTermStruct  .read(m), m));
}

// `agreesOn` is a SUBSET of `matches`, not a different question: a key that
// matches wholly agrees over any subset, and a subset that holds says nothing
// about the terms it left out. Both halves, because an `agreesOn` that quietly
// compared every term would pass the first and fail only the second.
//
// IT IS THE HELPER WITH PRODUCTION CALLERS — three of them
// (`SubpatchPreview.rebuildIfStale` twice, `ActionCenterStage
// .bboxMembershipCached`, `TransformTool.computeSelectionHash`) — and until
// this cell it was the one with no dedicated test, while its deleted sibling
// `matchesOnly` had two and no caller at all (task 4060 review).
//
// KEY AGAINST KEY, never key against mesh, is the whole point: the caller
// stamps `cur` ONCE and asks whether the stored key agrees with that one
// sample, so a counter that moves during the rebuild cannot be stamped in as
// already serviced.
unittest {
    alias K = MeshKey!(MeshTermMutation, MeshTermTopology);
    Mesh m;
    m.mutationVersion = 4;
    m.topologyVersion = 9;
    assert(m.mutationVersion != m.topologyVersion,
        "the two terms must differ or every subset line below is vacuous — "
      ~ "it would pass on a compare reading the wrong slot");

    K k;   k.stamp(m);
    K cur; cur.stamp(m);
    assert(k.matches(m));
    assert(k.agreesOn!MeshTermMutation(cur));
    assert(k.agreesOn!MeshTermTopology(cur));
    assert(k.agreesOn!(MeshTermMutation, MeshTermTopology)(cur));

    // Move ONE term and re-sample. The whole key refuses; the subset over the
    // OTHER term still holds — that is the property the subpatch preview's
    // stencil-layout fast path rides on.
    m.mutationVersion = 5;
    K moved; moved.stamp(m);
    assert(!k.matches(m), "the whole key must follow its mutation term");
    assert(!k.agreesOn!MeshTermMutation(moved));
    assert(k.agreesOn!MeshTermTopology(moved),
        "agreesOn must compare the named term only — if this fails it is "
      ~ "comparing every term and the fast path it exists for is dead code");

    // The address is compared either way. `other` carries EQUAL values in both
    // terms, so only the address can refuse it.
    Mesh other;
    other.mutationVersion = 4;
    other.topologyVersion = 9;
    K kOther; kOther.stamp(other);
    assert(kOther.agreesOn!MeshTermTopology(kOther),
        "a key must agree with itself, or the refusal below is not about the "
      ~ "address");
    assert(!k.agreesOn!MeshTermTopology(kOther),
        "a subset compare that drops the address is not a mesh key");
}
