module tests.unit.weightmap_state_test;

import weightmap_view : currentWeightMapName, setCurrentWeightMap, resolveWeightMap;
import vibe3d.mesh.core.mesh : Mesh;

// ---------------------------------------------------------------------------
// Unittests — the current-map selection and its resolver (Stage 1).
//
// The LAW's own coverage is the golden fixture in
// tests/unit/weightmap_color_test.d, which asserts `weightSurfaceColor`
// against measured bytes. What is checked here is the state and the resolver:
// the two things that decide WHETHER a colour is computed at all.
// ---------------------------------------------------------------------------

unittest {
    import vibe3d.mesh.core.mesh : makeCube, MapDomain;

    // Save/restore: this is process-global session state and the unittest
    // runner shares a process with every other module's blocks.
    string saved = currentWeightMapName();
    scope(exit) setCurrentWeightMap(saved);

    setCurrentWeightMap("");
    assert(currentWeightMapName().length == 0,
        "the shipped state is 'no map selected'");

    setCurrentWeightMap("wmA");
    assert(currentWeightMapName() == "wmA",
        "selecting a map must be readable back — a no-op setter is the "
        ~ "failure this asserts against");

    setCurrentWeightMap("");
    assert(currentWeightMapName().length == 0,
        "the empty name deselects; it is not rejected as invalid");

    // --- the resolver ---
    Mesh m = makeCube();
    assert(resolveWeightMap(m, "") is null,
        "an empty name resolves to nothing without touching the mesh");
    assert(resolveWeightMap(m, "wmA") is null,
        "a name no map carries resolves to null — this is the state that "
        ~ "renders the neutral, and it is reached by doing nothing");

    assert(m.addWeightMap("wmA") !is null, "fixture: the map must be created");
    auto got = resolveWeightMap(m, "wmA");
    assert(got !is null, "a Point/dim-1 map under the selected name resolves");
    assert(got.name == "wmA" && got.domain == MapDomain.Point && got.dim == 1);
    assert(got.data.length == m.vertices.length,
        "a resolved weight map is one float per vertex — the colour uploader "
        ~ "indexes it by vertex index and nothing else bounds that read");

    // THE TWO HALVES OF THE PREDICATE, SEPARATELY. Each case below is built so
    // that the OTHER half of the check cannot rescue it — a case that both
    // halves reject proves neither of them is live. (Measured: a PolyVertex
    // dim-2 case is rejected by the DIMENSION alone, so with it as the only
    // domain case, deleting the domain test left this block green.)

    // Wrong domain, RIGHT dimension. `MapDomain.Edge` dim 1 is not a
    // hypothetical: it is the shape of the per-edge crease channel, which a
    // mesh can carry at the same time under any name. Indexing an edge
    // channel by VERTEX index is an out-of-range read on most meshes and a
    // silently wrong colour on the rest.
    Mesh other = makeCube();
    assert(other.addMeshMap("wmA", 1, MapDomain.Edge) !is null,
        "fixture: the same name, the right dim, the WRONG domain");
    assert(resolveWeightMap(other, "wmA") is null,
        "a same-named dim-1 map on another DOMAIN must not resolve as a "
        ~ "weight map — the domain half of the predicate is what rejects it");

    // RIGHT domain, wrong dimension.
    Mesh third = makeCube();
    assert(third.addMeshMap("wmA", 3, MapDomain.Point) !is null,
        "fixture: the right domain, the WRONG dimension");
    assert(resolveWeightMap(third, "wmA") is null,
        "a Point map of dim != 1 is not a weight map either — the dimension "
        ~ "half of the predicate is what rejects it");
}
