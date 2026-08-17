module weightmap_view;

// ---------------------------------------------------------------------------
// The weight-map display mode's own state and law (task 1090).
//
// Two things live here and nothing else:
//
//   * WHICH weight map the session is showing — a NAME, session-scope,
//     resolved lazily against whichever mesh a pass happens to be drawing;
//   * the COLOUR a weight value paints — the measured ramp, as ONE function.
//
// WHY THE NAME AND NOT A POINTER OR AN INDEX. Maps are per-mesh, so a pointer
// or an index would name a map on ONE mesh and would have to be re-derived (or
// invalidated) every time the primary layer changed, a map was created, or a
// map was removed. A name needs none of that: it either resolves on the mesh
// in front of us or it does not, and "does not" is a state we have measured
// (it renders the neutral, exactly as a zero weight does — see
// `weightSurfaceColor`). That is the whole of the lifetime story.
//
// WHY SESSION-SCOPE AND NOT PER-VIEWPORT. Two cells of a Quad layout showing
// two different maps is not a state the mode has; only the STYLE is per-cell.
// A per-cell map name would also not survive `resolveDrawPlan`'s purity, which
// is what makes the display plan testable.
// ---------------------------------------------------------------------------

import math : Vec3;
import mesh : Mesh, MeshMap, MapDomain;

// ---------------------------------------------------------------------------
// The current weight map
// ---------------------------------------------------------------------------

/// The session's current weight map, by NAME. Empty == none selected.
///
/// A module-level global behind accessors, the established shape for
/// cross-cutting session state that a command writes and a render pass reads
/// (`hover_state.g_hoveredItem` is the same shape for the same reason). It is
/// deliberately NOT on `Document` and not persisted: the LIFETIME of a map
/// selection across a save/load has never been measured, and a format bump for
/// an unmeasured question is a guess written into a file.
private __gshared string g_currentWeightMap = "";

// ---------------------------------------------------------------------------
// THE THREAD CONTRACT the three `@trusted` accessors below rest on.
// Read this before adding a fourth caller.
//
// `g_currentWeightMap` IS MAIN-THREAD-ONLY, and each `@trusted` below is a
// promise to `@safe` callers that rests on THAT CONTRACT — not on the type,
// which offers no protection at all. What is shared is a `string`: a FAT
// pointer, `ptr` + `length`, sixteen bytes with no atomicity between the two
// halves. A read racing a write is therefore a genuine TORN read — the new
// pointer with the old length is an out-of-range slice, not a merely stale
// name. (`hover_state.g_hoveredItem` is NOT precedent for this: it is a bare
// single-word `__gshared int` with no accessors and no `@trusted` on it, so it
// makes no promise to anybody and its worst case is one stale index — whereas
// these three functions hand a `@safe` caller a slice and vouch for it.)
//
// The contract holds today because every party is on the main thread, which
// was verified by reading the handler BODIES:
//
//   WRITER   `commands/mesh/weightmap.d`'s `WeightmapSelect.apply` — the only
//            call to `setCurrentWeightMap` outside tests. It arrives either
//            from the UI (dispatched on the frame loop) or from
//            `/api/command`, which answers through `commandBridge`.
//   READERS  · the render pass — `ui/viewport_render.d`, both the background
//              and the foreground `uploadWeightColors` call;
//            · the viewport dirty key — `app.d`'s `weightMapKey` term, via
//              `currentWeightMapKey`;
//            · the display endpoint — `http_providers.d`'s viewport-display
//              provider, which the HTTP thread reaches only through
//              `vpDisplayBridge`, so the READ happens on the main thread even
//              though the request did not arrive on it.
//
// NOTHING ENFORCES THIS. `http_server.d`'s route table says of its `Answered`
// column, in as many words, that it "is DATA, not an assertion" — the compiler
// cannot see whether a handler reaches a bridge. So a future endpoint that
// answered straight on the HTTP thread and called `currentWeightMapName()`
// would compile silently and break the contract with nothing here to catch it.
// If that is ever wanted, the fix is a lock or an atomically published
// `immutable` — never a wider attribute here.
//
// (The unittests in this module and in `tests/unit/dirty_key_weightmap_test.d`
// also write it; the runner is single-threaded and they save/restore.)
// ---------------------------------------------------------------------------

/// The name of the map the weight display mode is showing. Empty == none.
///
/// Main-thread only — see THE THREAD CONTRACT above for what the `@trusted`
/// is promising and what it is resting on.
string currentWeightMapName() nothrow @trusted @nogc {
    return g_currentWeightMap;
}

/// Select the current weight map by name. `""` deselects.
///
/// Deliberately does NOT check that the name exists on any mesh. The selection
/// is a NAME and resolution is lazy — refusing an absent name would make
/// "select, then create" impossible and would invent a lifetime rule nobody
/// has measured. An unresolvable name renders the neutral, which is the same
/// thing "no map selected" renders, which is what was measured.
///
/// Main-thread only — see THE THREAD CONTRACT above. This is the WRITE half of
/// it, and the one the torn read would be racing.
void setCurrentWeightMap(string name) nothrow @trusted {
    g_currentWeightMap = (name is null) ? "" : name;
}

/// A digest of a weight-map name, for the viewport dirty key.
///
/// FNV-1a over the name's bytes, the same fold `app.d` already uses for its
/// other digest key terms. Pure and named — NOT written inline at the stamping
/// site — for one reason: a unit test can then assert that two different names
/// really do produce two different keys, which is the only part of the term
/// that is testable at all. The term's LIVE effect is unreachable from the
/// test harness (`--test` short-circuits the dirty-key compare), so if this
/// were four lines inside the frame loop there would be nothing to check and
/// nothing a mutation could redden.
ulong weightMapKeyFor(string name) pure nothrow @safe @nogc {
    ulong h = 0xcbf2_9ce4_8422_2325UL;
    foreach (ch; cast(const(ubyte)[])name) {
        h ^= ch;
        h *= 0x0000_0100_0000_01b3UL;
    }
    return h;
}

/// The digest of the CURRENT map name — what the dirty key stamps.
///
/// Reads through the same accessor the render pass calls, so the key cannot
/// key on a different name than the one that was drawn.
///
/// Main-thread only — see THE THREAD CONTRACT above; its caller is the frame
/// loop's dirty-key stamp.
ulong currentWeightMapKey() nothrow @trusted @nogc {
    return weightMapKeyFor(g_currentWeightMap);
}

/// Name → the weight map on THIS mesh, or null.
///
/// THE one resolver: callers never scan `meshMaps` themselves, so "what counts
/// as a weight map" is written down once. A weight map is a `MapDomain.Point`,
/// `dim == 1` channel — the same predicate `Mesh.weightMapNames` enumerates.
/// A same-named map of any other domain or dimension (a per-corner UV, a
/// per-edge crease) is NOT one and resolves to null, which renders the
/// neutral rather than reinterpreting somebody else's floats as weights.
const(MeshMap)* resolveWeightMap(ref const Mesh m, string name) {
    if (name.length == 0) return null;
    const(MeshMap)* mm = m.meshMap(name);
    if (mm is null) return null;
    if (mm.domain != MapDomain.Point || mm.dim != 1) return null;
    return mm;
}

// ---------------------------------------------------------------------------
// The colour law
// ---------------------------------------------------------------------------

/// The three colours of the ramp, as ONE record — so a later re-measurement of
/// any one of them is a substitution rather than a restructure.
struct WeightRamp {
    Vec3 neutral;
    Vec3 positive;
    Vec3 negative;
}

/// The GREEN component of the neutral. MEASURED.
///
/// Twelve cells were built so that this value and its only serious rival
/// (`140/255 = 0.5490196`) predict a DIFFERENT byte, and all twelve
/// predictions were written down before the run: `0.55` fits ELEVEN of them,
/// the rival fits ONE. So the neutral is not a byte triple — which the RED
/// channel had already said independently, at `w = 0.05`, where the measured
/// 134 is what `0.5` gives (`133.875`) and not what `127/255` gives
/// (`133.4 → 133`).
///
/// THE SINGLE DISSENTING CELL IS NOT ABOUT THIS NUMBER, and the control that
/// says so is BLUE: blue's neutral is `0.5`, was never in dispute, is exact on
/// thirteen cells — and fails at its OWN thinnest rounding margin exactly as
/// green fails at its. Two channels, two different constants, one shared
/// anomaly ⇒ the residual belongs to the reference's float→byte conversion,
/// not to a constant. It is registered as a ≤1 LSB divergence at two NAMED
/// weights and asserted as a LIST in `tests/unit/weightmap_color_test.d`; it
/// is deliberately NOT absorbed by a fitted offset here, because a fitted
/// `0.5496` in this file would be a number no human would write, presented as
/// the measured law — and the blue control says it is the wrong explanation
/// anyway.
///
/// Do not "improve" this by re-measuring on a gradient: the two candidates
/// differ by at most `0.25·(1−t)` LSB, so a rig whose own positional noise is
/// a full LSB cannot see the question at all. It takes UNIFORM-weight cells.
enum float kWeightNeutralG = 0.55f;

/// The measured ramp. Zero (and "no map") is the neutral; the sign picks the
/// extreme; the magnitude blends toward it.
enum WeightRamp kWeightRamp = WeightRamp(
    Vec3(0.5f, kWeightNeutralG, 0.5f),
    Vec3(1.0f, 0.0f, 0.0f),
    Vec3(0.0f, 0.0f, 1.0f));

/// The blend factor: `min(|w|, 1)`.
///
/// Named apart from the ramp so the two can be re-measured apart. CLAMPED, not
/// continued — `|w| = 1`, `1.5` and `2` all render the same measured extreme.
///
/// NaN lands on 0, i.e. on the NEUTRAL. The reference is reported to paint a
/// non-finite weight magenta, but that reading is STATIC — nobody has seen
/// those pixels, and this feature has already had a static read overturned by
/// a measurement. So a non-finite weight renders a colour we HAVE measured
/// instead of one we have not. Registered as an open gap.
float rampT(float w) pure nothrow @safe @nogc {
    // `w != w` is the NaN test, and it comes FIRST so the clamp below cannot
    // be reached with a NaN in hand: comparisons against NaN are all false, so
    // an unguarded `(a > 1) ? 1 : a` would return the NaN and put it in the
    // vertex buffer, where it is a black or undefined fragment rather than a
    // neutral one.
    if (w != w) return 0.0f;
    immutable float a = (w < 0.0f) ? -w : w;
    return (a > 1.0f) ? 1.0f : a;
}

/// THE measured law: the surface colour for a per-vertex weight.
///
/// ```
/// t   = min(|w|, 1)
/// E   = positive if w > 0 else negative
/// rgb = neutral + (E − neutral)·t
/// ```
///
/// UNLIT: no light term, no material, no gamma. The mode REPLACES the surface
/// pass; it does not tint a shaded one.
///
/// SINGLE SOURCE OF TRUTH, and that is why this is a CPU function at all
/// rather than four lines of GLSL: this function fills the GPU colour buffer,
/// and the golden fixture asserts THIS function, so the value the test checks
/// is literally the value the rasteriser receives. Two implementations of one
/// measured law would leave the unit test asserting the one the screen does
/// not use.
///
/// Evaluated PER VERTEX; the rasteriser then interpolates the COLOUR. That
/// ordering was MEASURED (two 41-sample gradient cells separated the
/// candidates by 140 and 46 levels) — it is not a shader convenience. Do not
/// "simplify" it into an interpolated weight clamped per fragment: an edge
/// from `w = -1` to `w = +1` then passes through the neutral instead of
/// through purple, and an edge from `0.5` to `2.0` grows a flat plateau. Both
/// were looked for and neither is there.
Vec3 weightSurfaceColor(float w) pure nothrow @safe @nogc {
    immutable float t = rampT(w);
    // `w > 0` and not `>= 0`: at exactly zero both branches give the neutral
    // (t == 0), so the boundary is unobservable and the sign test costs
    // nothing to get "wrong". -0.0f likewise lands on t == 0.
    immutable Vec3 e = (w > 0.0f) ? kWeightRamp.positive : kWeightRamp.negative;
    immutable Vec3 n = kWeightRamp.neutral;
    return Vec3(n.x + (e.x - n.x) * t,
                n.y + (e.y - n.y) * t,
                n.z + (e.z - n.z) * t);
}

// ---------------------------------------------------------------------------
// Unittests — the current-map selection and its resolver (Stage 1).
//
// The LAW's own coverage is the golden fixture in
// tests/unit/weightmap_color_test.d, which asserts `weightSurfaceColor`
// against measured bytes. What is checked here is the state and the resolver:
// the two things that decide WHETHER a colour is computed at all.
// ---------------------------------------------------------------------------

unittest {
    import mesh : makeCube, MapDomain;

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
