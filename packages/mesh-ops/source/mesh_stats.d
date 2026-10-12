module mesh_stats;

import mesh;

// ---------------------------------------------------------------------------
// THE STATISTICS QUERY KERNEL (task 1100 Stage 0).
//
// WHY THIS MODULE EXISTS. `select.byStat.{vertex,edge,polygon}` (task 1061)
// are `Command`s: each `apply()` builds a per-element `want` mask from a
// predicate, composes it with the current selection, and writes the selection
// back. There was no count-only entry point anywhere — so the only way for a
// panel to answer "how many vertices have exactly two edges" was to RUN the
// selection command and look at what got selected, which destroys the user's
// selection every frame the panel draws.
//
// This module is the predicate half, lifted out whole. It has TWO drivers over
// ONE implementation of each predicate:
//
//   * `*StatMask`  — the mask the commands compose with the selection;
//   * `*StatCount` — the fused count the Statistics panel reads, walking once
//     and accumulating `num` and `sel` with no allocation at all.
//
// Both call the same `*Matches` function, so there is exactly one copy of each
// predicate in the codebase. That property is what the task asks to design
// against, and it is checked structurally: stubbing the three `*Matches`
// bodies to `return false` must redden `by_stat.d`'s own unittests (its list of
// which arms redden, and which three legitimately do not, is in
// `doc/statistics_panel_plan.md` §0.5).
//
// ---------------------------------------------------------------------------
// `const` IS THE PROOF, NOT A DECORATION
// ---------------------------------------------------------------------------
// Every parameter that names the mesh here is `const(Mesh)*` / `const ref
// Mesh`. `Command`'s constructor takes a MUTABLE `Mesh*`, so a "count" written
// as construct-apply-count-revert does not COMPILE against these signatures.
// A runtime fingerprint samples for that mistake; a const parameter forbids it.
// The one path const cannot close is the panel's command-dispatch delegate —
// a clickable column has to be able to fire a command — and that layer is
// pinned by a mesh fingerprint around a real draw frame instead
// (`tests/unit/ui/stat_panel_widget_test.d`).
//
// Consequences the kernel lives with, deliberately:
//
//   * it cannot call `mesh.syncSelection()` (`mesh.d:1297`), because that is a
//     mutation — it resizes ten arrays. Every mutating command already calls
//     it and the frame path calls it too, so in practice the marks a reader
//     sees are synced; where they are not, `sel` is low by exactly the unsynced
//     tail (`isVertexSelected` and friends return false out of bounds) and that
//     is pinned as a property in `tests/unit/mesh_stats_test.d`, not left to be
//     rediscovered as a bug.
//   * it never touches the allocating `@property` selection views
//     (`mesh.selectedVertices` and friends) — indexing one in a loop is O(n²).
//
// ---------------------------------------------------------------------------
// `wantSel` IS A CORRECTNESS GATE, NOT AN OPTIMISATION
// ---------------------------------------------------------------------------
// The panel prints a `Sel` number only for the section matching the current
// selection type (measured; `doc/statistics_panel_plan.md` §4/L7). `wantSel`
// false must therefore not merely discard `sel` — it must not READ the marks
// at all, and it must leave `selKnown` false so the row model renders the
// measured gate placeholder rather than a number. A driver that computed `sel`
// unconditionally would publish a number for a section whose marks may not
// even be sized yet, and the day the gate widened, that wrong number would
// ship.
// ---------------------------------------------------------------------------

/// Shared `compare` vocabulary. `more`/`less` are both STRICT.
///
/// Moved here from `commands/select/by_stat.d` with the predicates it selects
/// between; `by_stat.d` re-exports it (and the three `*Stat` enums) with a
/// `public import`, so no external caller changed. Each component keeps its
/// OWN test enum, which is what makes an illegal `(component, test)` pair
/// unrepresentable rather than a runtime check.
enum Compare { all, equal, less, more }

bool matchCompare(Compare c, int actual, int value) {
    final switch (c) {
        case Compare.all:   return true;
        case Compare.equal: return actual == value;
        case Compare.less:  return actual < value;
        case Compare.more:  return actual > value;
    }
}

enum VertexStat  { edgeCount, polygonCount, weightMap }
enum EdgeStat    { polygonCount, materialBoundary, partBoundary }
enum PolygonStat { vertexCount }

/// One row's two numbers. `sel` is meaningful only when `selKnown` — see the
/// `wantSel` note in the module header.
struct StatCount {
    long num;
    long sel;
    bool selKnown;
}

/// The per-refresh derived data every row family reads, built ONCE rather than
/// once per row — the `AnalyzeContext` precedent (`source/mesh_analysis.d:47`).
///
/// Filled ONCE, by `buildStatContext`, and never afterwards: this is passed
/// `ref const`, D's `const` is transitive, and a const view cannot fill
/// anything — so "lazily filled" and `ref const` cannot both be true. WHAT is
/// filled is the caller's declared `StatNeed`; `filled` records it, and a
/// driver that reads an unbuilt field trips a `debug` assert rather than
/// answering a confident zero.
///
/// `.init` (a null `mesh`, four empty arrays) is the ABSENT context, and the
/// row model branches on `ctx.mesh is null` rather than on the array lengths:
/// an empty mesh has empty arrays too, and "no edit target" and "an empty
/// mesh" must render differently (`—` versus `0`).
struct StatContext {
    const(Mesh)* mesh;
    uint[]       vertEdge;    ///< `Mesh.vertexEdgeCounts()`
    uint[]       vertPoly;    ///< `Mesh.vertexPolygonCounts()`
    int[]        edgePoly;    ///< `Mesh.edgePolygonCounts()`
    uint[][]     edgeFaces;   ///< per-edge adjacent FACE indices (identity, not a count)
    uint         filled;      ///< which of the four above were actually built
                              ///< (`StatNeed`) — read by the drivers' asserts
}

/// WHICH derived arrays a refresh is going to read.
///
/// Not an optimisation flag — a scope. MEASURED (Stage 5): on a 99 856-face
/// grid with the panel in its ordinary state (sections open, categories
/// closed) the whole rebuild cost 8.4 ms, of which 8.2 ms was building a
/// context that NO EMITTED ROW READ — every leaf that needs one of these
/// arrays sits inside a collapsed category. "Compute only what is on screen"
/// is the pre-designed remedy for exactly that, and this is its mechanism.
///
/// The `Command` path uses it too, and there it FIXES A REGRESSION rather than
/// tuning one: extracting the predicates gave every `select.byStat.*` a full
/// context, so a vertex-count selection on a dense mesh paid for a per-edge
/// adjacency it never looks at.
enum StatNeed : uint {
    none      = 0,
    vertEdge  = 1 << 0,
    vertPoly  = 1 << 1,
    edgePoly  = 1 << 2,
    edgeFaces = 1 << 3,
    all       = vertEdge | vertPoly | edgePoly | edgeFaces,
}

/// Build the context for one refresh, filling exactly what `need` asks for.
///
/// A field that was NOT asked for stays empty, and reading it would answer a
/// confident zero — the silent-wrong-number failure this whole task is shaped
/// to avoid. Two things stop that: `filled` records what was built and the
/// count/mask drivers assert against it (`debug`, so the release frame path
/// pays nothing), and `stat_rows_test.d` emits every expand state twice — once
/// with a need-derived context and once with a full one — and compares every
/// row, so a tree that grows a reader without growing its need is caught by
/// value rather than by review.
StatContext buildStatContext(const ref Mesh m, StatNeed need = StatNeed.all) {
    StatContext c;
    c.mesh   = &m;
    c.filled = need;
    if (need & StatNeed.vertEdge)  c.vertEdge  = m.vertexEdgeCounts();
    if (need & StatNeed.vertPoly)  c.vertPoly  = m.vertexPolygonCounts();
    if (need & StatNeed.edgePoly)  c.edgePoly  = m.edgePolygonCounts();
    if (need & StatNeed.edgeFaces) c.edgeFaces = buildEdgeFaceLists(m);
    return c;
}

/// Per-edge adjacent-face lists, built the same way `SelectBoundary` and
/// `edgePolygonCounts` do (a fresh `edgeKey` -> index table, independent of
/// `edgeIndexMap`'s validity stamp) — but keeping full FACE IDENTITY per edge,
/// not just a count, because the tag-boundary predicate needs to read each
/// adjacent face's own tag.
///
/// Moved from `SelectByStatEdge.buildEdgeFaceLists` (`by_stat.d:468` at task
/// 1061) and `const`-qualified — and then given the SECOND ARM
/// `edgePolygonCounts` has had all along, because the measurement said to.
///
/// MEASURED (task 1100 Stage 5, before this arm existed): the hashed build was
/// **67 ms of the panel's 84 ms rebuild** on a 99 856-face / 200 344-edge grid,
/// and the same 67 ms was paid by every `select.byStat.*` command on such a
/// mesh, including the two components that never read this array. The hash is
/// the whole cost: 200k keyed inserts plus 400k lookups.
///
/// The dart arm reads the same adjacency straight off the half-edge loops, in
/// their CSR layout (`mesh.d:162` — face `fi` owns loops
/// `faceLoop[fi] .. faceLoop[fi] + arity`), under EXACTLY the validity
/// condition `edgePolygonCounts` uses. Same answer, no hashing, and it makes
/// this panel's cost genuinely state-dependent: mid-edit, with the loops
/// invalid, the hashed arm is what runs.
uint[][] buildEdgeFaceLists(const ref Mesh m) {
    const size_t ne = m.edges.length;
    const size_t nf = m.faces.length;
    auto edgeFaces = new uint[][](ne);
    if (ne == 0 || nf == 0) return edgeFaces;

    // Enumerate every (edge, face) incidence ONCE, arm chosen once. A template
    // rather than a delegate: this body runs per CORNER — ~400 000 times on the
    // perf grid — and an indirect call per corner is a cost with no answer in
    // it.
    void each(alias F)() {
        if (m.loopsValid() && m.loopEdge.length == m.loops.length
                           && m.faceLoop.length == m.faces.length) {
            // The DART arm: the incidence is already in the half-edge loops,
            // in CSR layout (`mesh.d:162`).
            foreach (fi; 0 .. nf) {
                const(uint)[] f = m.faces[fi];
                if (f.length == 0) continue;
                const size_t base = m.faceLoop[fi];
                if (base + f.length > m.loopEdge.length) continue;
                foreach (c; 0 .. f.length) {
                    const uint e = m.loopEdge[base + c];
                    if (e < ne) F(e, cast(uint) fi);
                }
            }
        } else {
            // The HASHED fallback: correct whatever the loops are doing.
            uint[ulong] idx;
            foreach (i; 0 .. ne)
                idx[edgeKey(m.edges[i][0], m.edges[i][1])] = cast(uint) i;
            foreach (fi; 0 .. nf) {
                const(uint)[] f = m.faces[fi];
                if (f.length == 0) continue;
                foreach (k; 0 .. f.length) {
                    auto p = edgeKey(f[k], f[(k + 1) % f.length]) in idx;
                    if (p is null) continue;
                    F(*p, cast(uint) fi);
                }
            }
        }
    }

    // TWO PASSES INTO ONE FLAT BUFFER, and this is where the time went.
    //
    // MEASURED (Stage 5): with a `~=` per incidence — one dynamic array per
    // edge, each grown as it filled — this function cost 47-67 ms on a
    // 200 344-edge grid, and swapping the hash for the dart arm changed
    // NOTHING, because the hash was never the cost: 400 000 appends across
    // 200 000 separate GC arrays were. Counting first and slicing one buffer
    // removes every one of those allocations, and the arms then differ the way
    // `edgePolygonCounts`' do.
    auto counts = new uint[](ne);
    each!((uint e, uint fi) { ++counts[e]; })();

    size_t total = 0;
    foreach (c; counts) total += c;
    auto flat = new uint[](total);
    auto cursor = new size_t[](ne);
    size_t at = 0;
    foreach (ei; 0 .. ne) {
        cursor[ei] = at;
        edgeFaces[ei] = flat[at .. at + counts[ei]];
        at += counts[ei];
    }
    each!((uint e, uint fi) { flat[cursor[e]++] = fi; })();
    return edgeFaces;
}

// ---------------------------------------------------------------------------
// The weight-map data slice, hoisted OUT of the per-vertex loop.
//
// `mesh.vertexWeight(name, vi)` (`mesh.d:7151`) does a linear name scan of
// `meshMaps` per call, and task 1061's command called it inside the per-vertex
// loop — O(V × maps). Taking the slice once makes the loop O(V). The answer is
// unchanged in every arm: `vertexWeight` returns 0.0f for a missing map, a
// wrong-domain map and an out-of-range index alike, which is exactly what an
// empty (or short) slice reads as below.
// ---------------------------------------------------------------------------
private const(float)[] weightData(ref const StatContext c, string map) {
    if (c.mesh is null) return null;
    auto mm = c.mesh.meshMap(map);
    if (mm is null) return null;
    if (mm.domain != MapDomain.Point || mm.dim != 1) return null;
    return mm.data;
}

// ---------------------------------------------------------------------------
// THE PREDICATES. Private, one per component; everything else in this module
// is a loop around one of them.
//
// ---------------------------------------------------------------------------
// The weight-map predicate's negative arm — an UNMEASURED extrapolation
// ---------------------------------------------------------------------------
// `VertexStat.weightMap`: select a vertex iff its weight-map value is non-zero
// (`!= 0.0f`). Every measured value in the capture's `vertex_by_vmap` cells —
// rollup and raw dump alike — is 0.0, 0.5 or 1.0; there is not one negative
// literal anywhere in either. So "non-zero" is the capture author's
// generalisation from `{0} vs {positive}`, and `!= 0` is not discriminated
// from `> 0` by anything MEASURED.
//
// It IS discriminated by a test of ours: `by_stat.d`'s unittest 4b sets a
// weight of `-1.0f` and asserts the vertex comes back, so substituting
// `> 0.0f` here reddens it. (That case landed after the sentence which used to
// stand in this block — "the substitution left the whole test suite green" —
// and which was therefore telling a future reader this arm was unpinned when
// it is pinned. Corrected here, task 1100.) What remains genuinely unmeasured
// is the REFERENCE's answer on a negative weight, not ours: no fixture case
// may assert a negative-weight vertex against a reference number.
//
// ---------------------------------------------------------------------------
// The tag-border predicate — an UNMEASURED extrapolation on 3+ polygons
// ---------------------------------------------------------------------------
// `EdgeStat.materialBoundary` / `.partBoundary`: select an edge iff it has AT
// LEAST 2 adjacent polygons AND those polygons carry AT LEAST 2 DISTINCT tags.
// Every measured edge in `edge_boundary_tagged_open_cube` carries at most TWO
// adjacent polygons, so what the capture pins is: 2 polygons/same tag → out;
// 2 polygons/different tags → in; 1 polygon (the tagged face's own open edge,
// bordering nothing else) → out. The rule below is the smallest rule
// consistent with those three cells; its answer on a NON-MANIFOLD edge with
// 3+ tagged polygons (e.g. tags A, A, B) is an extrapolation, not parity.
// ---------------------------------------------------------------------------

private bool vertexMatches(ref const StatContext c, VertexStat t, Compare cmp,
                           int value, const(float)[] mapData, size_t vi) {
    final switch (t) {
        case VertexStat.edgeCount:
            debug assert(c.filled & StatNeed.vertEdge,
                "vertexMatches read `vertEdge`, which this context was not "
                ~ "asked to build — an unbuilt array answers a confident zero");
            return vi < c.vertEdge.length
                && matchCompare(cmp, cast(int) c.vertEdge[vi], value);
        case VertexStat.polygonCount:
            debug assert(c.filled & StatNeed.vertPoly,
                "vertexMatches read `vertPoly`, unbuilt in this context");
            return vi < c.vertPoly.length
                && matchCompare(cmp, cast(int) c.vertPoly[vi], value);
        case VertexStat.weightMap:
            // The measured predicate is the VALUE, not entry presence: a 0.0
            // write is a real, present value. The NEGATIVE arm of `!= 0.0f` is
            // an unmeasured extrapolation — see `by_stat.d`'s header, and
            // unittest 4b there, which pins that `> 0.0f` is not what we do.
            return vi < mapData.length && mapData[vi] != 0.0f;
    }
}

private bool edgeMatches(ref const StatContext c, EdgeStat t, Compare cmp,
                         int value, size_t ei) {
    final switch (t) {
        case EdgeStat.polygonCount:
            debug assert(c.filled & StatNeed.edgePoly,
                "edgeMatches read `edgePoly`, unbuilt in this context");
            return ei < c.edgePoly.length
                && matchCompare(cmp, c.edgePoly[ei], value);
        case EdgeStat.materialBoundary:
        case EdgeStat.partBoundary: {
            debug assert(c.filled & StatNeed.edgeFaces,
                "edgeMatches read `edgeFaces`, unbuilt in this context");
            if (ei >= c.edgeFaces.length) return false;
            const(uint)[] adj = c.edgeFaces[ei];
            if (adj.length < 2) return false;      // own open edge: excluded
            // `faceAttrOr`'s contract (see select.byTag): the per-face tag
            // arrays may legitimately be SHORTER than faces[]; a short entry
            // reads as 0. Read-only over the tags.
            const bool isPart = (t == EdgeStat.partBoundary);
            const(uint)[] arr = isPart ? c.mesh.facePart : c.mesh.faceMaterial;
            const uint first = adj[0] < arr.length ? arr[adj[0]] : 0u;
            foreach (fi; adj[1 .. $]) {
                const uint tag = fi < arr.length ? arr[fi] : 0u;
                if (tag != first) return true;     // at least 2 distinct tags
            }
            return false;
        }
    }
}

private bool polygonMatches(ref const StatContext c, PolygonStat t, Compare cmp,
                            int value, size_t fi) {
    final switch (t) {
        case PolygonStat.vertexCount:
            return fi < c.mesh.faces.length
                && matchCompare(cmp, cast(int) c.mesh.faces[fi].length, value);
    }
}

// ---------------------------------------------------------------------------
// Driver 1 — the MASK. What the selection commands compose with the selection.
// ---------------------------------------------------------------------------

bool[] vertexStatMask(ref const StatContext c, VertexStat t, Compare cmp,
                      int value, string map) {
    if (c.mesh is null) return null;
    const size_t n = c.mesh.vertices.length;
    auto want = new bool[](n);
    const(float)[] md = t == VertexStat.weightMap ? weightData(c, map) : null;
    foreach (vi; 0 .. n) want[vi] = vertexMatches(c, t, cmp, value, md, vi);
    return want;
}

bool[] edgeStatMask(ref const StatContext c, EdgeStat t, Compare cmp, int value) {
    if (c.mesh is null) return null;
    const size_t n = c.mesh.edges.length;
    auto want = new bool[](n);
    foreach (ei; 0 .. n) want[ei] = edgeMatches(c, t, cmp, value, ei);
    return want;
}

bool[] polygonStatMask(ref const StatContext c, PolygonStat t, Compare cmp,
                       int value) {
    if (c.mesh is null) return null;
    const size_t n = c.mesh.faces.length;
    auto want = new bool[](n);
    foreach (fi; 0 .. n) want[fi] = polygonMatches(c, t, cmp, value, fi);
    return want;
}

// ---------------------------------------------------------------------------
// Driver 2 — the fused COUNT. What the panel reads.
//
// One walk, two accumulators, ZERO allocation: the tree has ~100 rows, and a
// mask driver alone would allocate a `bool[n]` per row — on a 500k-vertex mesh
// that is tens of megabytes of churn per refresh for two integers per row.
// ---------------------------------------------------------------------------

StatCount vertexStatCount(ref const StatContext c, VertexStat t, Compare cmp,
                          int value, string map, bool wantSel) {
    StatCount r;
    r.selKnown = wantSel;
    if (c.mesh is null) { r.selKnown = false; return r; }
    const size_t n = c.mesh.vertices.length;
    const(float)[] md = t == VertexStat.weightMap ? weightData(c, map) : null;
    foreach (vi; 0 .. n) {
        if (!vertexMatches(c, t, cmp, value, md, vi)) continue;
        ++r.num;
        if (wantSel && c.mesh.isVertexSelected(vi)) ++r.sel;
    }
    return r;
}

StatCount edgeStatCount(ref const StatContext c, EdgeStat t, Compare cmp,
                        int value, bool wantSel) {
    StatCount r;
    r.selKnown = wantSel;
    if (c.mesh is null) { r.selKnown = false; return r; }
    const size_t n = c.mesh.edges.length;
    foreach (ei; 0 .. n) {
        if (!edgeMatches(c, t, cmp, value, ei)) continue;
        ++r.num;
        if (wantSel && c.mesh.isEdgeSelected(ei)) ++r.sel;
    }
    return r;
}

StatCount polygonStatCount(ref const StatContext c, PolygonStat t, Compare cmp,
                           int value, bool wantSel) {
    StatCount r;
    r.selKnown = wantSel;
    if (c.mesh is null) { r.selKnown = false; return r; }
    const size_t n = c.mesh.faces.length;
    foreach (fi; 0 .. n) {
        if (!polygonMatches(c, t, cmp, value, fi)) continue;
        ++r.num;
        if (wantSel && c.mesh.isFaceSelected(fi)) ++r.sel;
    }
    return r;
}
