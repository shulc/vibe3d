// ---------------------------------------------------------------------------
// http_json — the JSON bodies the HTTP layer hands back, and the escaper they
// are assembled with.
//
// Split out of http_server.d by task 0720 (audit №4, D5). The routing table
// and the socket plumbing are one concern; turning a Mesh into the bytes
// `/api/model` returns is another, and it is the half that is worth reading on
// its own — `meshToJsonDetailed` alone is the wire contract of the most-asserted
// endpoint in the suite.
//
// One visibility note, because the rule is "do not widen to make a split
// possible": `jsonEsc` WAS module-private in http_server.d and is public here.
// It had to travel — `meshToJsonDetailed` escapes surface names with it — and
// leaving a second copy behind would have re-created exactly the duplication
// wave 1 removed. It is the escaper of the module named for JSON; that is the
// one place it can live without a copy.
// ---------------------------------------------------------------------------
module http_json;

import std.datetime : Clock;
import std.json;

import json_num : jsonNum;
import mesh : Mesh, Surface, MeshMap, MapDomain, MapKind;
import mesh_selsets : selSetNamesVertex, selSetNamesEdge, selSetNamesPolygon,
    selSetMembersVertex, selSetMembersEdge, selSetMembersPolygon;

// ---------------------------------------------------------------------------
// jsonEsc — escape `s` for embedding BETWEEN the quotes of a JSON string
// literal in a hand-assembled response body.
//
// The HTTP layer builds most of its error bodies by concatenation, and it used
// to escape them by hand: 45 of the 49 escape sites replaced the double-quote
// and NOTHING else (audit №4, D11). That is not a style problem. Exception
// messages there interpolate caller-controlled text verbatim —
// `unknown layer kind 'X'`, `unknown command id 'X'`, file paths from a failed
// load — so a single backslash in X emitted a body that is not JSON at all
// (`\z` is a hard parse error, `\b` parses as a BACKSPACE and silently
// changes the message), and a newline in a message broke it outright.
//
// std.json does the escaping, because it is the same escaper the correct
// sites in this tree already reach for and it covers control characters, not
// just the two everyone remembers. It returns a QUOTED literal; the slice
// drops the quotes so this stays a drop-in for the `.replace` it replaced —
// call sites keep supplying their own quotes.
// ---------------------------------------------------------------------------
string jsonEsc(string s) {
    auto lit = JSONValue(s).toString();
    return lit.length >= 2 ? lit[1 .. $ - 1] : "";
}

// `meshToJson(vertexCount, edgeCount, faceCount)` used to sit here — the
// counts-only body of the plain (non-detailed) model provider. Task 0720
// deleted it: the wiring inventory that produced `unwiredEndpoints()` showed
// `setModelDataProvider` had no caller anywhere in source/, tests/ or tools/,
// so its provider was permanently null, its arm of `/api/model`'s three-way
// election was unreachable, and this was its only caller.

/**
 * Convert detailed mesh data to JSON string
 *
 * Reads the mesh DIRECTLY — it used to take ten pre-built arrays, and every
 * caller had to manufacture all ten. Three of those were pure copies
 * (`m.edges`, a per-face `.dup` of every face, `m.surfaces.dup`) and are
 * simply gone; the per-face `.dup` was the worst of them, one small GC
 * allocation per face, i.e. half a million of them at this project's 500k-face
 * ceiling, for bytes this function only ever reads.
 *
 * The other three were NOT copies but PADDING, and that behaviour is
 * load-bearing, so it moved in here rather than being deleted — see the three
 * per-face loops below. `isSubpatch` / `faceMaterial` / `facePart` are all
 * lazily grown (the commands that write them resize on first write), so any of
 * them can legitimately be SHORTER than `faces.length` — a default cube has
 * `facePart.length == 0` and still reports six zeros. Every one of the three
 * therefore runs to `faces.length` and defaults out-of-range entries, which
 * also truncates should an array ever run long.
 *
 * Taking `ref const(Mesh)` (not slices) is what lets the subpatch flags read
 * through `isFaceSubpatch(fi)`: `Mesh.isSubpatch` is an `@property` that
 * materialises a fresh `bool[]` per call, so a slice-taking signature would
 * still have forced one allocation here. `isFaceSubpatch(fi)` is bounds-
 * checked internally and returns false when out of range — exactly the
 * padding rule, without the array.
 *
 * MUST run on the main thread. It walks the live mesh with no copy standing
 * between it and a concurrent edit; `/api/model` marshals it there through
 * `modelBridge` (see the routing at "/api/model"), which is the whole reason
 * dropping the copies is safe.
 */
string meshToJsonDetailed(ref const(Mesh) m) {
    import std.format : format;
    import std.array : appender;
    import std.math  : isFinite;

    auto json = appender!string();

    // ---- the `"nonFinite"` signal (task 1550) ----------------------------
    // `jsonNum` keeps the BODY parseable by printing `null` for a coordinate
    // that is not a number. On its own that is honest but mute: a client sees
    // a hole and cannot tell a corrupt mesh from a serialiser bug. So this
    // provider counts what it replaced and reports the FIRST one, in a fixed
    // walk order — vertices by ascending index with component 0/1/2 = x/y/z,
    // then surfaces — so the report is reproducible rather than
    // whichever-came-first.
    //
    // The block is emitted ALWAYS, `{"count":0}` on a healthy mesh included.
    // That is deliberate and is what makes it testable: a change that drops
    // the block reddens the HEALTHY case too, not only the poisoned one.
    //
    // The counting lives here and not in `jsonNum` on purpose — the helper is
    // a pure function of two arguments, shared by three layers, and giving it
    // a counter would give it state and a lifetime.
    size_t nonFiniteCount;
    bool   nfHaveFirst;
    string nfArray;
    size_t nfIndex;
    size_t nfComponent;
    string nfValue;

    void noteNonFinite(string arr, size_t idx, size_t comp, double v) {
        ++nonFiniteCount;
        if (nfHaveFirst) return;
        nfHaveFirst  = true;
        nfArray      = arr;
        nfIndex      = idx;
        nfComponent  = comp;
        nfValue      = format("%s", v);   // "inf" / "-inf" / "nan" / "-nan"
    }

    json ~= "{";
    json ~= format("\"vertexCount\": %d, ", m.vertices.length);
    json ~= format("\"edgeCount\": %d, ", m.edges.length);
    json ~= format("\"faceCount\": %d, ", m.faces.length);
    json ~= format("\"timestamp\": \"%s\", ", Clock.currTime.toISOExtString());

    // Add vertices array
    json ~= "\"vertices\": [";
    for (size_t i = 0; i < m.vertices.length; ++i) {
        if (i > 0) json ~= ", ";
        immutable double vx = m.vertices[i].x;
        immutable double vy = m.vertices[i].y;
        immutable double vz = m.vertices[i].z;
        if (!isFinite(vx)) noteNonFinite("vertices", i, 0, vx);
        if (!isFinite(vy)) noteNonFinite("vertices", i, 1, vy);
        if (!isFinite(vz)) noteNonFinite("vertices", i, 2, vz);
        json ~= format("[%s, %s, %s]",
                       jsonNum(vx, "%f"), jsonNum(vy, "%f"), jsonNum(vz, "%f"));
    }
    json ~= "], ";

    // Add edges array (each edge as a 2-element [a, b] vertex-index pair)
    json ~= "\"edges\": [";
    for (size_t i = 0; i < m.edges.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("[%d, %d]", m.edges[i][0], m.edges[i][1]);
    }
    json ~= "], ";

    // Add faces array
    json ~= "\"faces\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= "[";
        auto f = m.faces[i];
        for (size_t j = 0; j < f.length; ++j) {
            if (j > 0) json ~= ", ";
            json ~= format("%d", f[j]);
        }
        json ~= "]";
    }
    json ~= "], ";

    // Add per-face subpatch flags (parallel to faces[]).
    // PADDING RULE (was the caller's `subCopy`): one entry per FACE, false
    // where the marks array has not caught up with a face add.
    json ~= "\"isSubpatch\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isFaceSubpatch(i) ? "true" : "false";
    }
    json ~= "], ";

    // Per-element hide flags (task 0613 Stage 2) — the test observable for
    // every later hide-geometry stage. faceHidden is the AUTHORITATIVE
    // plane; vertexHidden/edgeHidden are DERIVED (§1.2 of
    // doc/hide_geometry_plan.md) but exposed the same way so a test can read
    // any of the three without knowing which plane is the source of truth.
    // Same non-allocating, bounds-checked accessor + padding-rule shape as
    // isSubpatch above.
    json ~= "\"faceHidden\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isFaceHidden(i) ? "true" : "false";
    }
    json ~= "], ";
    json ~= "\"vertexHidden\": [";
    for (size_t i = 0; i < m.vertices.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isVertexHidden(i) ? "true" : "false";
    }
    json ~= "], ";
    json ~= "\"edgeHidden\": [";
    for (size_t i = 0; i < m.edges.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isEdgeHidden(i) ? "true" : "false";
    }
    json ~= "], ";

    // Material Groups (MG2): the per-mesh surface registry and per-face
    // material indices into it. Exposed so render_diff and the LWO
    // surface-loader tests can verify what the parser produced.
    json ~= "\"surfaces\": [";
    for (size_t i = 0; i < m.surfaces.length; ++i) {
        if (i > 0) json ~= ", ";
        const s = m.surfaces[i];
        // Bind the name to a plain `string` first: reached through a
        // `const(Mesh)` it arrives as `const(string)`, which `replace` will
        // not deduce a template argument from.
        string name = s.name;
        // Component numbering, fixed so the `"nonFinite"` report is stable:
        // 0/1/2 = baseColor x/y/z, 3 = diffuseAmount, 4 = specularAmount,
        // 5 = glossiness, 6 = opacity.
        immutable double[7] sv = [s.baseColor.x, s.baseColor.y, s.baseColor.z,
                                  s.diffuseAmount, s.specularAmount,
                                  s.glossiness, s.opacity];
        foreach (ci, sc; sv)
            if (!isFinite(sc)) noteNonFinite("surfaces", i, ci, sc);
        json ~= format(
            "{\"name\":\"%s\",\"baseColor\":[%s,%s,%s],\"diffuseAmount\":%s," ~
            "\"specularAmount\":%s,\"glossiness\":%s,\"opacity\":%s}",
            jsonEsc(name),
            jsonNum(sv[0], "%f"), jsonNum(sv[1], "%f"), jsonNum(sv[2], "%f"),
            jsonNum(sv[3], "%f"), jsonNum(sv[4], "%f"), jsonNum(sv[5], "%f"),
            jsonNum(sv[6], "%f"));
    }
    json ~= "], ";
    // PADDING RULE (was the caller's `matCopy`): one entry per FACE, 0 where
    // faceMaterial has not caught up. Same for facePart / `partCopy` below.
    json ~= "\"faceMaterial\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("%d", i < m.faceMaterial.length ? m.faceMaterial[i] : 0u);
    }
    json ~= "], ";
    json ~= "\"facePart\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("%d", i < m.facePart.length ? m.facePart[i] : 0u);
    }
    json ~= "], ";

    // Selection sets (task 1060) — read-only, so tests (and any future UI)
    // can see the registry without going through a live-selection round
    // trip. Edge members are vertex-index PAIRS, per the storage decision
    // (mesh_selsets.d's doc comment / doc/selection_sets_plan.md §Q1.3):
    // the same encoding the `.v3d` writer uses.
    json ~= "\"selectionSets\": {\"vertex\": [";
    foreach (i, nm; selSetNamesVertex(m)) {
        if (i > 0) json ~= ", ";
        json ~= format("{\"name\":\"%s\",\"members\":[", jsonEsc(nm));
        auto members = selSetMembersVertex(m, nm);
        foreach (j, vi; members) { if (j > 0) json ~= ", "; json ~= format("%d", vi); }
        json ~= "]}";
    }
    json ~= "], \"edge\": [";
    foreach (i, nm; selSetNamesEdge(m)) {
        if (i > 0) json ~= ", ";
        json ~= format("{\"name\":\"%s\",\"members\":[", jsonEsc(nm));
        auto members = selSetMembersEdge(m, nm);
        foreach (j, pr; members) {
            if (j > 0) json ~= ", ";
            json ~= format("[%d, %d]", pr[0], pr[1]);
        }
        json ~= "]}";
    }
    json ~= "], \"polygon\": [";
    foreach (i, nm; selSetNamesPolygon(m)) {
        if (i > 0) json ~= ", ";
        json ~= format("{\"name\":\"%s\",\"members\":[", jsonEsc(nm));
        auto members = selSetMembersPolygon(m, nm);
        foreach (j, fi; members) { if (j > 0) json ~= ", "; json ~= format("%d", fi); }
        json ~= "]}";
    }
    json ~= "]}";

    // The signal, always present (see the block comment at the top of this
    // function). `value` is a STRING and not a number precisely because the
    // thing it reports cannot be written as a JSON number.
    json ~= format(", \"nonFinite\": {\"count\": %d", nonFiniteCount);
    if (nfHaveFirst)
        json ~= format(", \"first\": {\"array\": \"%s\", \"index\": %d, "
                       ~ "\"component\": %d, \"value\": \"%s\"}",
                       jsonEsc(nfArray), nfIndex, nfComponent, jsonEsc(nfValue));
    json ~= "}";

    json ~= "}";

    return json.data;
}

// ---------------------------------------------------------------------------
// meshPlanesJson — the PLANE-COMPLETE readback (task 1903 Stage B, plan §6.3).
//
// WHY A NEW DUMP AND NOT AN EXISTING ENDPOINT. Measured: no existing readback
// is plane-complete, and each is blind in a different place.
//   * `.v3d` (`source/io/native.d`) carries materials / parts / subpatch / sets
//     / maps / surfaces but NOT Select bits, Hide bits or selection order —
//     those are session state, not document state, and correctly so.
//   * `/api/model`'s `meshToJsonDetailed` above carries `isSubpatch` and the
//     three `*Hidden` planes but NOT materials, parts, sets, maps or order.
// A fixture assembled from three partial readbacks would leave exactly the
// planes the delta↔snapshot burn-in class is about uncovered in the seams.
//
// WHAT IT IS FOR. Each command family freezes its delta↔snapshot parity ONCE,
// as JSON, on the commit BEFORE it migrates — while the snapshot path simply IS
// the code. The surviving test then runs the DELTA path against that frozen
// JSON. When the hatch dies the fixture is the only remaining witness of what
// the snapshot path produced.
//
// ---------------------------------------------------------------------------
// EDGE PLANES ARE KEYED BY ENDPOINT PAIR, NEVER BY EDGE INDEX. This is the one
// design decision in the dump, and it is not a preference.
//
// `edgeMarks` and `edgeSelectionOrder` are index-keyed arrays, and a delta
// replay REBUILDS the edge array (`mesh_edit_delta.finalize` →
// `Mesh.rebuildEdges`). That is exactly why `MeshOpEntry.Kind.EdgeSelByEnds`
// exists and re-applies its selection "through `edgeIndexMap` AFTER finalize
// rebuilds edges". A dump that compared `edgeMarks[i]` against a frozen
// `edgeMarks[i]` would be comparing two different index spaces, and would fail
// for a reason that has nothing to do with the family under test — the worst
// kind of red, the one that gets a correct delta reverted.
//
// So the edge planes are emitted as `[(vLo,vHi) -> word]` pairs sorted by the
// pair. `edgeSetMask` needs no re-keying at all: its `ulong[ulong]` key is
// already `mesh.edgeKey(a, b)`, i.e. the two endpoints packed min-first, and it
// is decoded back to the same `[lo, hi]` shape so all three edge planes read in
// one index-free space.
//
// The claim is checked, not asserted: `tests/unit/plane_dump_test.d` permutes a
// mesh's edge index space with its per-edge data attached and requires the dump
// to compare EQUAL.
// ---------------------------------------------------------------------------

/// Capture provenance for a frozen parity fixture (plan §6.3, rule 2). Emitted
/// ALWAYS — empty strings included — so that a change which drops the block
/// reddens on the healthy case too, not only on a fixture that needed it. Same
/// rule as `meshToJsonDetailed`'s `"nonFinite"` block above.
struct PlaneDumpMeta {
    /// `git rev-parse HEAD` of the tree that PRODUCED the dump. A fixture whose
    /// `producedBy` is not an ancestor of the migration commit was captured
    /// after the fact — i.e. against the code it was meant to be independent
    /// of. The reviewer checks the ancestry; the test checks the field is there.
    string producedBy;
    /// Which undo path produced it. THREE values, not two (task 1903 L1's
    /// fixture freeze, 2026-08-27):
    ///
    ///   * `"snapshot"`    — `MeshSnapshot.restore` / `SelectionSnapshot.restore`:
    ///                       a whole-mesh (or whole-selection) dense capture
    ///                       held by the command;
    ///   * `"dense-inline"`— the command's own hand-rolled restore from a
    ///                       stored per-plane image (`origPos[]`,
    ///                       `origMaterial[]`, `origSubpatch[]`), replayed by
    ///                       its own `revert()`;
    ///   * `"delta"`       — `MeshEditDelta.revert`, what the surviving test
    ///                       runs after a family migrates.
    ///
    /// WHY THE THIRD VALUE EXISTS. The vocabulary was written as
    /// snapshot-or-delta on the reading that a family sits on one path.
    /// Measured at `a8cdb05d`, stage L0's sixteen commands did not: only
    /// `mesh.hide*` and `mesh.centerVertices` held a `MeshSnapshot`; the other
    /// fourteen restored from a per-command image, which is neither. Recording
    /// those as `"snapshot"` would put a false statement in the one field a
    /// reviewer reads to decide whether a fixture predates the code it is the
    /// oracle for — so the value is recorded PER CELL, and a family that mixes
    /// paths says so. L1's fixture is uniformly `"snapshot"` and that is
    /// honest: 26 of its 27 classes really do hold one.
    string path;
    /// The command family the fixture belongs to, e.g. "delete", "weld_merge".
    string family;
    /// The stand it was built on — "makeTaggedGridFull" for every fixture this
    /// task freezes. Recorded because a fixture captured on a cube is green
    /// under a delta that carries nothing.
    string stand;
}

/// Every plane the burn-in class covers, in a FIXED order, as JSON.
///
/// Read-only, and it walks the live mesh with no copy standing between it and a
/// concurrent edit — the same contract `meshToJsonDetailed` has, and the reason
/// `/api/mesh/planes` marshals it onto the main thread.
string meshPlanesJson(ref const(Mesh) m, in PlaneDumpMeta meta = PlaneDumpMeta.init) {
    import std.algorithm.sorting : sort;
    import std.array  : appender;
    import std.format : format;

    auto json = appender!string();

    json ~= "{";
    // Provenance first, so a fixture file is self-describing at its head.
    json ~= format("\"provenance\": {\"producedBy\": \"%s\", \"path\": \"%s\", "
                 ~ "\"family\": \"%s\", \"stand\": \"%s\"}, ",
                   jsonEsc(meta.producedBy), jsonEsc(meta.path),
                   jsonEsc(meta.family), jsonEsc(meta.stand));

    json ~= format("\"counts\": {\"vertices\": %d, \"edges\": %d, \"faces\": %d}, ",
                   m.vertices.length, m.edges.length, m.faces.length);

    // ---- geometry ---------------------------------------------------------
    json ~= "\"vertices\": [";
    foreach (i; 0 .. m.vertices.length) {
        if (i > 0) json ~= ", ";
        json ~= format("[%s, %s, %s]",
                       jsonNum(cast(double)m.vertices[i].x, "%.9g"),
                       jsonNum(cast(double)m.vertices[i].y, "%.9g"),
                       jsonNum(cast(double)m.vertices[i].z, "%.9g"));
    }
    json ~= "], ";

    json ~= "\"faces\": [";
    foreach (i; 0 .. m.faces.length) {
        if (i > 0) json ~= ", ";
        json ~= "[";
        auto f = m.faces[i];
        foreach (j; 0 .. f.length) {
            if (j > 0) json ~= ", ";
            json ~= format("%d", f[j]);
        }
        json ~= "]";
    }
    json ~= "], ";

    // ---- per-vertex / per-face mark WORDS ---------------------------------
    // Whole words, not decoded bits: `faceMarks` carries Select | Subpatch |
    // Hide | Lock together, so a bit added later is carried by this dump with
    // no change here — and a bit DROPPED by a migrated kernel shows up as a
    // different word rather than as a plane nobody thought to compare.
    static string uintArray(const(uint)[] a) {
        auto s = appender!string();
        s ~= "[";
        foreach (i, v; a) { if (i > 0) s ~= ", "; s ~= format("%d", v); }
        s ~= "]";
        return s.data;
    }
    static string intArray(const(int)[] a) {
        auto s = appender!string();
        s ~= "[";
        foreach (i, v; a) { if (i > 0) s ~= ", "; s ~= format("%d", v); }
        s ~= "]";
        return s.data;
    }
    static string ulongArray(const(ulong)[] a) {
        auto s = appender!string();
        s ~= "[";
        foreach (i, v; a) { if (i > 0) s ~= ", "; s ~= format("%d", v); }
        s ~= "]";
        return s.data;
    }
    static string nameArray(const(string)[] a) {
        auto s = appender!string();
        s ~= "[";
        foreach (i, v; a) { if (i > 0) s ~= ", "; s ~= format("\"%s\"", jsonEsc(v)); }
        s ~= "]";
        return s.data;
    }

    json ~= "\"vertexMarks\": " ~ uintArray(m.vertexMarks) ~ ", ";
    json ~= "\"faceMarks\": "   ~ uintArray(m.faceMarks)   ~ ", ";
    json ~= "\"vertexSelectionOrder\": " ~ intArray(m.vertexSelectionOrder) ~ ", ";
    json ~= "\"faceSelectionOrder\": "   ~ intArray(m.faceSelectionOrder)   ~ ", ";
    json ~= format("\"selectionOrderCounters\": {\"vertex\": %d, \"edge\": %d, "
                 ~ "\"face\": %d}, ",
                   m.vertexSelectionOrderCounter, m.edgeSelectionOrderCounter,
                   m.faceSelectionOrderCounter);

    // ---- the EDGE planes, endpoint-keyed ----------------------------------
    // One entry per live edge, `[lo, hi]` first so the sort below is the sort
    // of the KEY. `edgeMarks` / `edgeSelectionOrder` are read defensively —
    // `rebuildEdges` does not resize them, so a mesh caught mid-edit can carry
    // a shorter plane than its edge array, and a dump that indexed blindly
    // would throw rather than report.
    struct EdgeRow { uint lo, hi, marks; int order; }
    EdgeRow[] edgeRows;
    edgeRows.reserve(m.edges.length);
    foreach (ei; 0 .. m.edges.length) {
        const uint a = m.edges[ei][0], b = m.edges[ei][1];
        EdgeRow r;
        r.lo    = a < b ? a : b;
        r.hi    = a < b ? b : a;
        r.marks = ei < m.edgeMarks.length ? m.edgeMarks[ei] : 0u;
        r.order = ei < m.edgeSelectionOrder.length ? m.edgeSelectionOrder[ei] : 0;
        edgeRows ~= r;
    }
    edgeRows.sort!((x, y) => x.lo != y.lo ? x.lo < y.lo : x.hi < y.hi);
    json ~= "\"edgePlanes\": [";
    foreach (i, ref r; edgeRows) {
        if (i > 0) json ~= ", ";
        json ~= format("{\"ends\": [%d, %d], \"marks\": %d, \"order\": %d}",
                       r.lo, r.hi, r.marks, r.order);
    }
    json ~= "], ";

    // ---- material / part / surfaces ---------------------------------------
    json ~= "\"faceMaterial\": " ~ uintArray(m.faceMaterial) ~ ", ";
    json ~= "\"facePart\": "     ~ uintArray(m.facePart)     ~ ", ";
    json ~= "\"surfaces\": [";
    static assert(Surface.tupleof.length == 7,
        "a new Surface field must be emitted by meshPlanesJson too, not only "
        ~ "charged for in MeshSnapshot.byteSize()");
    foreach (i, ref s; m.surfaces) {
        if (i > 0) json ~= ", ";
        string name = s.name;
        json ~= format("{\"name\": \"%s\", \"baseColor\": [%s, %s, %s], "
                     ~ "\"diffuseAmount\": %s, \"specularAmount\": %s, "
                     ~ "\"glossiness\": %s, \"opacity\": %s}",
                       jsonEsc(name),
                       jsonNum(cast(double)s.baseColor.x, "%.9g"),
                       jsonNum(cast(double)s.baseColor.y, "%.9g"),
                       jsonNum(cast(double)s.baseColor.z, "%.9g"),
                       jsonNum(cast(double)s.diffuseAmount,  "%.9g"),
                       jsonNum(cast(double)s.specularAmount, "%.9g"),
                       jsonNum(cast(double)s.glossiness,     "%.9g"),
                       jsonNum(cast(double)s.opacity,        "%.9g"));
    }
    json ~= "], ";

    // ---- selection SETS: the two index planes and the AA -------------------
    json ~= "\"vertexSetNames\": "  ~ nameArray(m.vertexSetNames)  ~ ", ";
    json ~= "\"vertexSetMask\": "   ~ ulongArray(m.vertexSetMask)  ~ ", ";
    json ~= "\"polygonSetNames\": " ~ nameArray(m.polygonSetNames) ~ ", ";
    json ~= "\"faceSetMask\": "     ~ ulongArray(m.faceSetMask)    ~ ", ";
    json ~= "\"edgeSetNames\": "    ~ nameArray(m.edgeSetNames)    ~ ", ";
    // `edgeSetMask`'s key IS `mesh.edgeKey(a, b)` — the endpoints packed
    // min-first — so it is decoded, not re-keyed, and lands in the same
    // index-free space as `edgePlanes` above. Sorted by the pair, because AA
    // iteration order is unspecified and a fixture must be byte-stable.
    struct SetRow { uint lo, hi; ulong mask; }
    SetRow[] setRows;
    setRows.reserve(m.edgeSetMask.length);
    foreach (key, mask; m.edgeSetMask) {
        SetRow r;
        r.lo   = cast(uint)(key >>> 32);
        r.hi   = cast(uint)(key & 0xFFFF_FFFFUL);
        r.mask = mask;
        setRows ~= r;
    }
    setRows.sort!((x, y) => x.lo != y.lo ? x.lo < y.lo : x.hi < y.hi);
    json ~= "\"edgeSetMask\": [";
    foreach (i, ref r; setRows) {
        if (i > 0) json ~= ", ";
        json ~= format("{\"ends\": [%d, %d], \"mask\": %d}", r.lo, r.hi, r.mask);
    }
    json ~= "], ";

    // ---- the map registry: ALL SIX FIELDS of MeshMap ----------------------
    // `data` is dumped BY VALUE. A per-corner UV map is the plane the corner
    // provenance protocol carries rather than `kFacePlanes`, and it is the one
    // most easily zero-filled by a migrated kernel; a dump that reported only
    // the map's name and dim would read identically either way.
    //
    // `present` AND `kind` ARE CARRIED, AND THAT IS NOT COMPLETENESS FOR ITS
    // OWN SAKE. Both are channels a migrated kernel can drop into a LEGAL WRONG
    // ANSWER — the failure mode this dump exists to catch, and the one no
    // crash and no garbage value announces:
    //   * `present` is the per-element presence channel and EMPTY MEANS "ALL
    //     PRESENT" (`MeshMap.present`), so a carry that loses it resurrects
    //     every absent entry and reads as a healthy dense map. It is exactly
    //     the shape `MeshMap.dup`'s `static assert` was written against, it is
    //     carried EXPLICITLY through renumber / reindex / add / remove in
    //     `mesh_edit_delta.d`, and `MeshSnapshot.byteSize()` already charges
    //     for it — so the snapshot path pays for a plane the dump could not
    //     see. On a `morphAbsolute` map the difference is geometry: an absent
    //     entry means "stay at the base", a present zero does not.
    //   * `kind` is STORED, never inferred (`MapKind` — the two morph kinds
    //     have identical shape and neither reserves a name), so nothing else
    //     in the dump can stand in for it. It is written through the `final
    //     switch` below, which means a NEW `MapKind` stops the build here
    //     instead of silently printing an old name.
    json ~= "\"meshMaps\": [";
    // Tripwire for the DUMP's hand-written member list — the sibling in
    // MeshSnapshot.byteSize() (snapshot.d) guards only the charge, and a
    // plane that is charged for but not emitted is exactly what a parity
    // fixture cannot witness.
    static assert(MeshMap.tupleof.length == 6,
        "a new MeshMap field must be emitted by meshPlanesJson too, not only "
        ~ "charged for in MeshSnapshot.byteSize()");
    foreach (i, ref mm; m.meshMaps) {
        if (i > 0) json ~= ", ";
        string nm = mm.name;
        string domainStr;
        final switch (mm.domain) {
            case MapDomain.Point:      domainStr = "point";      break;
            case MapDomain.Edge:       domainStr = "edge";       break;
            case MapDomain.PolyVertex: domainStr = "polyvertex"; break;
        }
        string kindStr;
        final switch (mm.kind) {
            case MapKind.unclassified:   kindStr = "unclassified";   break;
            case MapKind.uv:             kindStr = "uv";             break;
            case MapKind.vertexWeight:   kindStr = "vertexWeight";   break;
            case MapKind.creaseWeight:   kindStr = "creaseWeight";   break;
            case MapKind.morphRelative:  kindStr = "morphRelative";  break;
            case MapKind.morphAbsolute:  kindStr = "morphAbsolute";  break;
        }
        json ~= format("{\"name\": \"%s\", \"domain\": \"%s\", \"kind\": \"%s\", "
                     ~ "\"dim\": %d, \"data\": [",
                       jsonEsc(nm), domainStr, kindStr, mm.dim);
        foreach (k, v; mm.data) {
            if (k > 0) json ~= ", ";
            json ~= jsonNum(cast(double)v, "%.9g");
        }
        // Emitted as the raw channel, `[]` included — NOT decoded through
        // `isPresent`, which would render the empty channel as a dense run of
        // 1s and make "all present by convention" indistinguishable from "all
        // present because somebody wrote them out".
        json ~= "], \"present\": [";
        foreach (k, v; mm.present) {
            if (k > 0) json ~= ", ";
            json ~= format("%d", v);
        }
        json ~= "]}";
    }
    json ~= "]";

    json ~= "}";
    return json.data;
}
