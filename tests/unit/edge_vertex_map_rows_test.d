// Frozen-fixture cell for how the reference editor's statistics panel builds
// the EDGE domain's vertex-map rows, and what makes one edge count for one row
// (capture campaign batch A', 2026-09-05). Read statically off the reference's
// own shipped libraries; zero engine boots.
//
// WHY IT EXISTS. This row had been wrong twice, in two different ways, and
// both are the shapes this repository pays for:
//
//   * it was once filed as "the symbol is not there, so the law needs a
//     behavioural lane". The symbols were there; the SEARCH TERMS were not
//     shipped names. A negative that comes from a query nobody validated is
//     not evidence.
//   * it then carried a NAMED HYPOTHESIS for the enumerator -- "the same
//     per-kind edge-domain capability flag the weld-time edge-map copy tests"
//     -- which nobody had read. The read refutes it: the flag admits three
//     map kinds and the panel lists ONE, so on any mesh carrying an edge
//     selection set the two candidates predict different rows.
//
// WHAT IT PINS, AND FROM WHICH SIDE. Two halves, and they redden for
// different reasons:
//
//   (A) the frozen law's own arithmetic and its refutation margin -- the
//       whitelist is a strict subset of the flag's set, and the difference is
//       non-empty. A cell that could not exhibit the difference would prove
//       nothing, so the margin is asserted, not just recorded.
//   (B) OUR side against it. Our map-kind registry must declare exactly the
//       edge-domain kinds the frozen law says the reference enumerates -- one,
//       the crease-weight map -- and our edge identity must be the UNORDERED
//       vertex pair, which is what makes an entry written for (a,b) findable
//       from (b,a). Both are computed from live code here, not restated.
//
// WHAT IT DOES NOT PIN. We ship no statistics row for this category yet (the
// rows render as a dash). This cell exists so that whoever implements them
// starts from the measured law rather than from the refuted predicate, and so
// that a second edge-domain map kind cannot join our registry silently and
// change what those rows would list.
//
// ORDERING. The assertions that must stay green (the fixture's own shape and
// the refutation margin) sit ABOVE the two that a mutation reddens, so one run
// buys both halves: druntime stops a module at its first failed assert, and
// everything above a red line is known to have run and passed.
//
// MUTATIONS THAT REDDEN IT (both run, and quoted in the task card with the
// assert MESSAGE as the identity -- the line number is only a pointer):
//   * `source/mesh.d`, `kindInfo(MapKind.creaseWeight)`: `MapDomain.Edge` ->
//     `MapDomain.Point` => block B1 reddens naming the count;
//   * `source/mesh.d`, `Mesh.edgeIndex`: pack the lookup key directed
//     (`a << 32 | b`) instead of calling the canonicalising `edgeKey`
//     => block B2 reddens naming the two lookups that must agree.
//
// An earlier revision of this header named the second site as `edgeKey` in
// `source/mesh_topo.d`. That is a DIFFERENT mutation and it was not the one
// that ran. Both were run in the fix round, both redden this same assert, and
// the printed values tell them apart -- which is worth knowing, because it
// says the assert discriminates two failure MODES rather than one:
//   * breaking the CALLER desynchronises one side only, so the reversed
//     lookup MISSES:  `(0,3) -> 0 but (3,0) -> 4294967295`;
//   * breaking `edgeKey` moves the map's keys too, so the reversed lookup HITS
//     THE WRONG EDGE:  `(0,3) -> 0 but (3,0) -> 11`.
// The second is the more dangerous shape in production and it is not a
// "lookup failed" -- it silently returns a real, wrong index.
//
// LANE: `dub test --config=tests`.
module tests.unit.edge_vertex_map_rows_test;

import std.algorithm : canFind, sort;
import std.array     : array;
import std.file      : readText;
import std.format    : format;
import std.json      : JSONType, JSONValue, parseJSON;
import std.path      : buildPath, dirName;

import mesh : MapDomain, MapKind, Mesh, kindInfo, makeCube;
import mesh_topo : edgeKey;

private enum string kFixturePath =
    buildPath(dirName(dirName(__FILE_FULL_PATH__)), "fixtures",
              "edge_vertex_map_rows.json");

private JSONValue fixture()
{
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) { cached = parseJSON(readText(kFixturePath)); loaded = true; }
    return cached;
}

private string[] strList(JSONValue v)
{
    assert(v.type == JSONType.array, "fixture: expected an array");
    string[] out_;
    foreach (e; v.array)
    {
        assert(e.type == JSONType.string, "fixture: expected a string element");
        out_ ~= e.str;
    }
    return out_;
}

// ---------------------------------------------------------------------------
// A. The frozen law, and the margin that makes its refutation mean something.
// ---------------------------------------------------------------------------
unittest
{
    auto f = fixture();

    // A0 -- population floor. A fixture that lost its blocks would make every
    // assertion below vacuous, so pin the shape first.
    assert(f["name"].str == "edge_vertex_map_rows",
           "fixture: wrong file loaded from " ~ kFixturePath);
    assert(f["provenance"]["method"].str == "static-read",
           "fixture: this law is a static read; a changed method invalidates "
           ~ "the whole 'no stand could have biased it' argument");

    auto cats = f["domain_categories"];
    const order = strList(cats["order"]);
    assert(cats["count"].integer == 4 && order.length == 4,
           format("fixture: the edge domain has four categories, got %d/%d",
                  cats["count"].integer, order.length));
    assert(order[cast(size_t) cats["vertex_map_category_index"].integer] == "vertexMap",
           "fixture: the vertex-map category index must name the vertex-map category");
    assert(order[cast(size_t) cats["selection_set_category_index"].integer] == "selectionSetRows",
           "fixture: selection sets are a SEPARATE category -- that separation "
           ~ "is exactly what the refuted candidate would have destroyed");

    // A1 -- the enumerator is a whitelist of kinds, of size one.
    auto en = f["row_enumeration"];
    assert(en["enumerator"].str == "hard_coded_kind_whitelist",
           "fixture: the enumerator is a whitelist, not a capability predicate");
    const white = strList(en["whitelisted_kinds"]);
    assert(en["whitelisted_kind_count"].integer == 1 && white.length == 1,
           format("fixture: the edge whitelist holds exactly one kind, got %d",
                  white.length));
    assert(white[0] == "subdivisionCreaseWeight",
           "fixture: the one whitelisted edge kind is the crease-weight map");

    // A2 -- THE MARGIN. The refuted candidate is only refuted if the two
    // candidates disagree on some reachable mesh. Assert the difference is
    // non-empty and that it is exactly what the fixture claims, rather than
    // trusting the verdict word.
    auto ref_ = f["refuted_enumerator_candidate"];
    assert(ref_["verdict"].str == "REFUTED", "fixture: the candidate is refuted");
    const flagAdmits  = ref_["kinds_admitted_by_the_flag"].integer;
    const whiteAdmits = ref_["kinds_admitted_by_the_whitelist"].integer;
    const extra       = strList(ref_["kinds_the_flag_admits_that_the_whitelist_does_not"]);
    assert(flagAdmits > whiteAdmits,
           "fixture: a refuted candidate whose set equals the winner's is not "
           ~ "refuted by anything");
    assert(extra.length == cast(size_t)(flagAdmits - whiteAdmits),
           format("fixture: the flag admits %d kinds and the whitelist %d, so "
                  ~ "%d kinds must be named as the difference; %d are",
                  flagAdmits, whiteAdmits, flagAdmits - whiteAdmits, extra.length));
    assert(extra.canFind("selectionSetMembership"),
           "fixture: the observable half of the refutation is that an edge "
           ~ "selection set would be double-listed");
    assert(ref_["map_kinds_with_the_edge_flag"].integer
               < ref_["map_kind_registry_size"].integer,
           "fixture: the edge flag must be a proper subset of the registry, or "
           ~ "the read misidentified the flag");

    // A3 -- the membership rule is unordered, and the reversal is in the
    // accessor. This is the half that makes the sibling category's single
    // forward lookup NOT an asymmetry.
    auto mem = f["edge_membership"];
    assert(mem["keyed_by"].str == "unordered_vertex_pair");
    assert(!mem["orientation_sensitive"].boolean);
    assert(mem["reversed_pair_tried_on_miss"].boolean);
}

// ---------------------------------------------------------------------------
// B1. Our map-kind registry against the frozen law.
// ---------------------------------------------------------------------------
unittest
{
    auto f = fixture();
    auto ours = f["ours"];

    string[] edgeKinds;
    size_t   registrySize = 0;
    foreach (k; __traits(allMembers, MapKind))
    {
        ++registrySize;
        const kind = __traits(getMember, MapKind, k);
        if (kindInfo(kind).domain == MapDomain.Edge)
            edgeKinds ~= k;
    }
    edgeKinds.sort();

    // Population floor first: a registry that lost every member would satisfy
    // "no unexpected edge kind" vacuously.
    assert(registrySize >= 4,
           format("MapKind registry has %d members -- too few for this cell to "
                  ~ "be measuring anything", registrySize));

    const wantCount = cast(size_t) ours["edge_domain_map_kind_count"].integer;
    const want      = strList(ours["edge_domain_map_kinds"]);

    // Second floor, on the FIXTURE side and above the two asserts it protects.
    // The count assert below is satisfied by 0 == 0, and the name loop after it
    // is then vacuous: an emptied `edge_domain_map_kinds` would let this block
    // pass while asserting nothing about any kind. Pin the population and pin
    // that the declared count and the declared list are the same size, so the
    // loop cannot be short-circuited by disagreeing halves either.
    assert(wantCount >= 1 && want.length == wantCount,
           format("the frozen law must name at least one Edge-domain kind and "
                  ~ "its count must match its list: count=%d, list=%s. With "
                  ~ "either empty this block asserts nothing.",
                  wantCount, want));

    assert(edgeKinds.length == wantCount,
           format("our MapKind registry declares %d Edge-domain kind(s) %s, "
                  ~ "the frozen law expects %d %s. The reference enumerates its "
                  ~ "edge vertex-map rows from a whitelist of exactly %d kind(s); "
                  ~ "a second Edge-domain kind here changes what our rows would "
                  ~ "list, so it needs a decision and a fixture update, not a "
                  ~ "silent addition.",
                  edgeKinds.length, edgeKinds, wantCount, want,
                  f["row_enumeration"]["whitelisted_kind_count"].integer));
    foreach (i, k; want)
        assert(edgeKinds[i] == k,
               format("our Edge-domain kinds %s do not match the frozen %s",
                      edgeKinds, want));
}

// ---------------------------------------------------------------------------
// B2. Our edge identity is the UNORDERED vertex pair.
// ---------------------------------------------------------------------------
unittest
{
    auto f = fixture();
    assert(!f["edge_membership"]["orientation_sensitive"].boolean);

    Mesh m = makeCube();

    // Population floor: a mesh with no edges makes the loop below vacuous.
    assert(m.edges.length >= 12,
           format("cube stand has %d edges -- the cell would iterate over "
                  ~ "nothing", m.edges.length));

    size_t checked = 0;
    foreach (ei, e; m.edges)
    {
        const a = e[0], b = e[1];
        assert(a != b, "degenerate edge in the stand");
        const fwd = m.edgeIndex(a, b);
        const rev = m.edgeIndex(b, a);
        assert(fwd == cast(uint) ei,
               format("edge %d does not find itself from (%d,%d)", ei, a, b));
        assert(fwd == rev,
               format("edge lookup is ORIENTATION SENSITIVE: (%d,%d) -> %d but "
                      ~ "(%d,%d) -> %d. The reference's edge maps are keyed by "
                      ~ "the unordered pair -- its accessor retries the reversed "
                      ~ "pair internally -- so an entry written from one end must "
                      ~ "be findable from the other.", a, b, fwd, b, a, rev));
        assert(edgeKey(a, b) == edgeKey(b, a),
               format("edgeKey is not canonical for (%d,%d)", a, b));
        ++checked;
    }
    assert(checked == m.edges.length);

    // And the crease weight -- the one Edge-domain map we ship -- reads back
    // through either endpoint order, which is the behavioural form of the law.
    const ei0 = m.edgeIndex(m.edges[0][0], m.edges[0][1]);
    assert(m.setCreaseWeight(ei0, 0.75f), "setCreaseWeight refused");
    const viaReverse = m.edgeIndex(m.edges[0][1], m.edges[0][0]);
    assert(m.edgeCreaseWeight(viaReverse) == 0.75f,
           "a crease weight written from one endpoint order must read back "
           ~ "from the other");
}
