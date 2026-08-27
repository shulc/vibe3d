// ===========================================================================
// Task 1903 L0.P1 — the `finalize` carve-out, witnesses W1/W2/W6/W8/W9/W10.
//
// The change under test: `MeshEditDelta.apply`/`revert` compute ONE boolean —
// "this log moves no index space, and (if it restores an edge selection) the
// edge map is usable" — and `finalize` then skips the corner carry,
// `rebuildEdges` and `buildLoops`, re-issuing per kind the display class the
// rebuild used to publish incidentally. Plan: `doc/mesh_edit_seam_plan.md`
// §L0.P1.
//
// AT LANDING THE FAST PATH HAS NO PRODUCTION CALLER. `recordSetPos`'s two
// production callers both sit in kernels that also record a face-moving kind
// in the same log, and `recordSelectionDelta` / `recordSubpatchDelta` /
// `recordHideDelta` / `recordMaterialDelta` have no production caller at all.
// So the cells in this file, its two siblings and the two in-module blocks in
// `source/mesh_edit_delta.d` are the ONLY things that drive the fast branch
// today. That is a declared prerequisite step, not an oversight.
//
// WHY W2 RUNS THREE KINDS AND NOT TWO. A drop-free `Reindex` — a pure
// permutation — preserves the vertex count, the face count, the corner total
// AND `structVersion`, so it slips every one of `finalize`'s four always-on
// backstops. The GEOMETRY DIFF is its only witness, and it is also W1's
// potency control: the same counters that must read ZERO in W1 must read ONE
// here, through the same instrument, or W1's zeros are a dead cell.
// ===========================================================================
module tests.unit.mesh_edit_delta_carveout_test;

import std.algorithm.searching : count, canFind;
import std.file   : readText;
import std.format : format;
import std.path   : buildPath, dirName;

import mesh;
import math : Vec3;
import mesh_edit_delta;
import mesh_planes : rewriteFaces, FaceSource, kNoSource;

// ---------------------------------------------------------------------------
// Shared instruments.
// ---------------------------------------------------------------------------

/// EVERY index-space structure a replay is supposed to leave correct, as one
/// string. `edges` is in here deliberately: it is the plane the skipped
/// `rebuildEdges` owns, and it is the ONLY thing a drop-free `Reindex`
/// misclassification damages.
private string dumpGeometry(ref Mesh m) {
    auto s = format("V=%d F=%d E=%d\n", m.vertices.length, m.faces.length,
                    m.edges.length);
    foreach (i, ref v; m.vertices)
        s ~= format("v%d %.6f %.6f %.6f\n", i, v.x, v.y, v.z);
    foreach (i, ref f; m.faces)
        s ~= format("f%d %s\n", i, f);
    foreach (i, ref e; m.edges)
        s ~= format("e%d %d %d\n", i, e[0], e[1]);
    return s;
}

private struct Counters { ulong mv, tv; size_t reb, loop, hide; }

private Counters read(ref Mesh m) {
    Counters c;
    c.mv = m.mutationVersion; c.tv = m.topologyVersion;
    c.reb = g_rebuildEdgesRuns; c.loop = g_buildLoopsRuns; c.hide = g_hideDeriveRuns;
    return c;
}

private Counters delta(Counters a, Counters b) {
    Counters d;
    d.mv = b.mv - a.mv; d.tv = b.tv - a.tv;
    d.reb = b.reb - a.reb; d.loop = b.loop - a.loop; d.hide = b.hide - a.hide;
    return d;
}

private string fmtc(Counters d) {
    return format("mutationVersion +%d  topologyVersion +%d  rebuildEdges %d  "
                ~ "buildLoops %d  hideDerive %d", d.mv, d.tv, d.reb, d.loop, d.hide);
}

// ---------------------------------------------------------------------------
// W1 — THE PRIMARY. P0-1's R1 cell, with the numbers the carve-out is for.
//
// All FIVE quantities are asserted as ONE message, deliberately: they move
// together, so no single-counter coincidence can hold this green. The
// pre-change row, measured by task 2060, was `+2 / +2 / 1 / 1 / 2`.
// ---------------------------------------------------------------------------
unittest // W1 — a Position-scoped SetPos revert takes the fast path
{
    Mesh m = makeGridPlane(4);
    m.resetSelection();

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Position);
        ed.setVertexPos(3, Vec3(9, 9, 9));
        d = ed.close();
    }
    assert(d.log.length == 1 && d.log[0].kind == MeshOpEntry.Kind.SetPos,
        format("stand: the batch must record exactly one SetPos entry, got %d "
             ~ "entries — a second kind would change which path is taken and "
             ~ "this cell would stop measuring the carve-out", d.log.length));

    const a = read(m);
    d.revert(m);
    const got = delta(a, read(m));

    const want = "mutationVersion +1  topologyVersion +0  rebuildEdges 0  "
               ~ "buildLoops 0  hideDerive 1";
    assert(fmtc(got) == want, format(
        "W1: a Position-scoped SetPos revert did not take the fast path.\n"
      ~ "   expected  %s\n   measured  %s\n"
      ~ "The pre-carve-out row (task 2060, cell R1) was `mutationVersion +2  "
      ~ "topologyVersion +2  rebuildEdges 1  buildLoops 1  hideDerive 2`; if "
      ~ "that is what you are reading, `indexSpaceStable` refused a log it "
      ~ "should have accepted. `topologyVersion +1` alone means the tail bump "
      ~ "fired for a kind that does not owe it, or the rebuild's own "
      ~ "commitChange(Polygons) is still running.", want, fmtc(got)));
}

// ---------------------------------------------------------------------------
// W2 — THE INVERSE, and W1's potency control. Three kinds, three blocks, so
// that three separate mutations can each be attributed: druntime stops a
// module at its FIRST failed assert, and one block per kind is what buys the
// attribution back.
// ---------------------------------------------------------------------------

unittest // W2a — a RemoveFaces log takes the SLOW path and round-trips
{
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();
    const string pre = dumpGeometry(m);

    MeshEditTracker tracker;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    bool[] mask = new bool[](m.faces.length);
    mask[2] = true;
    // `keepOrphans` / `keepFloatingEdges`, and they are the WHOLE POINT of the
    // stand rather than a convenience. A plain `deleteFacesByMask` also
    // compacts the vertex array and records `RemoveVerts` + `Reindex` beside
    // the `RemoveFaces` — MEASURED, and it makes the cell undiscriminating:
    // the log stays unstable through those two whatever `RemoveFaces` is
    // classified as, so a mutation of the RemoveFaces arm leaves it green.
    const removed = m.deleteFacesByMask(mask, /*keepOrphans=*/true,
                                        /*keepFloatingEdges=*/true);
    MeshEditDelta d = m.endEditBatch();
    assert(removed == 1, "stand: exactly one face must be dropped");

    foreach (i, ref e; d.log)
        assert(e.kind == MeshOpEntry.Kind.RemoveFaces, format(
            "stand: entry %d is %s — the log must carry RemoveFaces and "
          ~ "NOTHING ELSE, or a second unstable kind decides the path and this "
          ~ "cell stops measuring the RemoveFaces ruling", i, e.kind));
    assert(d.log.length >= 1, "stand: the batch must have recorded something");
    assert(dumpGeometry(m) != pre, "stand: the delete must have moved geometry");

    const a = read(m);
    d.revert(m);
    const got = delta(a, read(m));

    assert(dumpGeometry(m) == pre, format(
        "W2a: a RemoveFaces revert did not restore the geometry byte for byte. "
      ~ "If `edges` is the only difference, `indexSpaceStable` classified "
      ~ "RemoveFaces STABLE and the skipped rebuildEdges is exactly what would "
      ~ "have repaired it.\n--- expected ---\n%s\n--- measured ---\n%s",
        pre, dumpGeometry(m)));
    assert(got.reb == 1 && got.loop == 1, format(
        "W2a: the slow path must run the rebuild pair exactly once — %s. This "
      ~ "is also W1's POTENCY CONTROL: the same counters read ZERO there, and "
      ~ "if they read zero here too the instrument is dead and W1 proves "
      ~ "nothing.", fmtc(got)));
    assert(got.tv > 0, format(
        "W2a: a face-moving revert must move topologyVersion — %s", fmtc(got)));
}

unittest // W2b — a FaceReindex log takes the SLOW path and round-trips
{
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();
    const string pre = dumpGeometry(m);

    // Drop face 4 through `rewriteFaces` — the only producer of `FaceReindex`,
    // and only with an explicitly armed recorder (no production site arms it).
    uint[][] newFaces;
    uint[]   oldOfNew;
    foreach (fi; 0 .. m.faces.length) {
        if (fi == 4) continue;
        newFaces ~= m.faces[fi].dup;
        oldOfNew ~= cast(uint) fi;
    }

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    {
        auto rw = m.beginCornerRewrite();
        rewriteFaces(m, newFaces, FaceSource(oldOfNew), &rw);
    }
    m.rebuildEdges();
    m.buildLoops();
    MeshEditDelta d = m.endEditBatch();

    bool sawReindex = false;
    foreach (ref e; d.log)
        if (e.kind == MeshOpEntry.Kind.FaceReindex) sawReindex = true;
    assert(sawReindex, "stand: the armed recorder must produce a FaceReindex entry");
    assert(dumpGeometry(m) != pre, "stand: the rewrite must have moved geometry");

    const a = read(m);
    d.revert(m);
    const got = delta(a, read(m));

    assert(dumpGeometry(m) == pre, format(
        "W2b: a FaceReindex revert did not restore the geometry byte for byte "
      ~ "— `indexSpaceStable` classified FaceReindex STABLE and `edges`/`loops` "
      ~ "were never re-derived.\n--- expected ---\n%s\n--- measured ---\n%s",
        pre, dumpGeometry(m)));
    assert(got.reb == 1 && got.loop == 1, format(
        "W2b: the slow path must run the rebuild pair exactly once — %s",
        fmtc(got)));
    assert(got.tv > 0, format(
        "W2b: a face-moving revert must move topologyVersion — %s", fmtc(got)));
}

unittest // W2c — a DROP-FREE Reindex permutation: the geometry diff is its only witness
{
    // A pure permutation of the vertex array. It changes NO count: the vertex
    // count, the face count, the corner total and `structVersion` all survive
    // it, so it slips every one of `finalize`'s four always-on backstops. Only
    // `edges` — which holds vertex INDEX pairs and is re-derived by the skipped
    // `rebuildEdges` — can show the damage.
    Mesh m = makeGridPlane(2);
    m.resetSelection();
    m.buildLoops();
    const string pre = dumpGeometry(m);
    const size_t nV = m.vertices.length;

    // old -> new: rotate every vertex index by one. No `~0u`, so nothing drops.
    uint[] perm = new uint[](nV);
    foreach (i; 0 .. nV) perm[i] = cast(uint)((i + 1) % nV);

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Points;
    MeshOpEntry e;
    e.kind = MeshOpEntry.Kind.Reindex;
    e.perm = perm;
    d.log = [e];

    // The reference post-apply state, built by hand. THE ROUND TRIP ALONE IS
    // VACUOUS HERE and that was measured, not guessed: with `Reindex`
    // classified stable BOTH directions take the fast path, so `edges` is
    // never rebuilt in either — it still holds the original vertex pairs when
    // the revert puts the original faces back, and the round trip reads
    // byte-identical while the mesh was wrong the whole time in between. The
    // POST-APPLY compare is what sees it.
    string post;
    {
        Mesh r = makeGridPlane(2);
        r.resetSelection();
        Vec3[] nv = new Vec3[](nV);
        foreach (i; 0 .. nV) nv[perm[i]] = r.vertices[i];
        r.vertices = nv;
        foreach (ref f; r.faces) {
            f = f.dup;
            foreach (ref vi; f) vi = perm[vi];
        }
        r.rebuildEdges();
        r.buildLoops();
        post = dumpGeometry(r);
    }
    assert(post != pre, "stand: the permutation must move something");

    d.apply(m);
    assert(m.vertices.length == nV,
        "stand: a drop-free permutation must preserve the vertex count — if it "
      ~ "does not, this cell is testing a DROP and the point is lost");
    assert(dumpGeometry(m) == post, format(
        "W2c: after a drop-free Reindex APPLY the mesh does not match what a "
      ~ "correct replay owes. THIS IS THE CELL THAT MATTERS MOST: a pure "
      ~ "permutation keeps vertices.length, faces.length, the corner total AND "
      ~ "structVersion, so `finalize`'s four backstops are all green under the "
      ~ "bug, and only `edges` — which the skipped rebuildEdges owns — carries "
      ~ "the damage.\n--- expected ---\n%s\n--- measured ---\n%s",
        post, dumpGeometry(m)));

    const a = read(m);
    d.revert(m);
    const got = delta(a, read(m));

    assert(dumpGeometry(m) == pre, format(
        "W2c: the revert did not restore the pre-op geometry byte for byte.\n"
      ~ "--- expected ---\n%s\n--- measured ---\n%s", pre, dumpGeometry(m)));
    assert(got.reb == 1 && got.loop == 1, format(
        "W2c: the slow path must run the rebuild pair exactly once — %s",
        fmtc(got)));
}

// ---------------------------------------------------------------------------
// W6 — undo -> redo -> undo, over an EQUAL-ARITY `ReshapeFaces`.
//
// `ReshapeFaces` at equal arity is the hole the length compares cannot see: it
// changes which VERTEX each corner points at while keeping every count, so
// `finalize`'s vertices/faces/corner-total asserts are all green under a
// misclassification. `renumbersCorners` answers FALSE for it (deliberately —
// per-corner values are addressed by (face, corner) and stay valid), so the
// corner-drop assert is green too.
//
// NOT A WITNESS, AND SAID SO: `loopsValid()` / `edgeMapUsable()` are asserted
// below because a slow-path replay owes them, but they are GREEN under the bug
// — `structVersion` does not move on the fast path, so the stamps go on
// agreeing with it while describing a `faces` array that changed. The
// geometry diff is the discriminator; the stamps are a slow-path obligation.
// ---------------------------------------------------------------------------
unittest // W6 — a ReshapeFaces log survives undo, redo and undo again
{
    Mesh m = makeGridPlane(2);
    m.resetSelection();
    m.buildLoops();
    const uint spare = m.addVertex(Vec3(50, 50, 0));
    m.buildLoops();

    const uint[] beforeList = m.faces[0].dup;
    assert(beforeList.length == 4, "stand: a grid face is a quad");
    uint[] afterList = beforeList.dup;
    afterList[3] = spare;               // EQUAL arity, different vertex set

    const string pre = dumpGeometry(m);

    // The reference post-apply state, produced by hand so the comparison is
    // against what a CORRECT replay owes and not against the replay's own
    // output.
    // Built FROM SCRATCH, never copied from `m`: a `Mesh` is a struct and a
    // plain copy shares every array buffer with the original, so a
    // `rebuildEdges()` on the copy would write through into `m.edges`.
    string post;
    {
        Mesh r = makeGridPlane(2);
        r.resetSelection();
        r.buildLoops();
        cast(void) r.addVertex(Vec3(50, 50, 0));
        r.faces[0] = afterList.dup;
        r.rebuildEdges();
        r.buildLoops();
        post = dumpGeometry(r);
    }
    assert(post != pre, "stand: the reshape must change the edge set, or this "
                      ~ "cell cannot see a stale `edges` at all");

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Polygons;
    MeshOpEntry e;
    e.kind            = MeshOpEntry.Kind.ReshapeFaces;
    e.fIdx            = [FaceIdx.assumeFaceSpace(0)];
    e.faceListsBefore = [beforeList.dup];
    e.faceListsAfter  = [afterList.dup];
    d.log = [e];

    static struct Step { string name; bool forward; string want; }
    const Step[] steps = [
        Step("apply  (do)",   true,  post),
        Step("revert (undo)", false, pre),
        Step("apply  (redo)", true,  post),
        Step("revert (undo)", false, pre),
    ];

    foreach (i, ref st; steps) {
        if (st.forward) d.apply(m); else d.revert(m);
        assert(dumpGeometry(m) == st.want, format(
            "W6: after step %d (%s) the mesh does not match what a correct "
          ~ "replay owes. An equal-arity ReshapeFaces classified STABLE leaves "
          ~ "`edges` and the loops family describing the PREVIOUS winding, and "
          ~ "the next forward replay then runs over a loop array `buildLoops` "
          ~ "never re-laid.\n--- expected ---\n%s\n--- measured ---\n%s",
            i, st.name, st.want, dumpGeometry(m)));
        assert(m.loopsValid() && m.edgeMapUsable(), format(
            "W6: after step %d (%s) the loops family or the edge map reads "
          ~ "invalid. (This clause is a slow-path OBLIGATION, not the "
          ~ "discriminator: on the fast path `structVersion` does not move, so "
          ~ "both stamps stay Valid while describing stale data.)", i, st.name));
    }
}

// ---------------------------------------------------------------------------
// W8 — the predicate reads the entry KINDS, never the declared `scope_`.
// ---------------------------------------------------------------------------
unittest // W8 — a Position-scoped log carrying a FaceReindex takes the SLOW path
{
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();
    const string pre = dumpGeometry(m);

    uint[][] newFaces;
    uint[]   oldOfNew;
    foreach (fi; 0 .. m.faces.length) {
        if (fi == 1) continue;
        newFaces ~= m.faces[fi].dup;
        oldOfNew ~= cast(uint) fi;
    }

    MeshEditTracker tracker;
    tracker.wantsFaceReindex = true;
    m.beginEditBatch(&tracker, MeshEditScope.Polygons);
    {
        auto rw = m.beginCornerRewrite();
        rewriteFaces(m, newFaces, FaceSource(oldOfNew), &rw);
    }
    m.rebuildEdges();
    m.buildLoops();
    MeshEditDelta d = m.endEditBatch();

    // THE CELL: a scope that says "only positions moved" over a log that moves
    // faces. `scope_` is a DECLARATION; the log is the fact.
    d.scope_ = MeshEditScope.Position;
    assert(!(d.scope_ & MeshEditScope.Geometry),
        "stand: the declared scope must carry no Geometry class, or the "
      ~ "mutation this cell exists for (`return !(scope_ & Geometry)`) would "
      ~ "answer the same as the real predicate and prove nothing");

    const a = read(m);
    d.revert(m);
    const got = delta(a, read(m));

    assert(got.reb == 1 && got.loop == 1, format(
        "W8: the predicate answered from `scope_` instead of from the entry "
      ~ "KINDS. A Position-scoped log carrying a FaceReindex must take the "
      ~ "full path — %s", fmtc(got)));
    assert(dumpGeometry(m) == pre, format(
        "W8: the FaceReindex reverse ran against a loop array nobody re-laid.\n"
      ~ "--- expected ---\n%s\n--- measured ---\n%s", pre, dumpGeometry(m)));
}

// ---------------------------------------------------------------------------
// W9 — the edge-map term, and why it is asserted as a SET and not as a throw.
//
// The stand is the importer shape: `addFaceFast` fills `edges` from the
// caller's scratch lookup and DEFERS the canonical map to a terminal
// `buildLoops()`. Between the two, `edgeMapUsable()` is false. Today's path
// repairs the map inside `finalize`; a fast path would not, and
// `applyEdgeSelByEnds`' own precondition (`assertEdgeMapValid`) is a `debug`
// assert that the `run_test.d` lane does not compile — so under that lane, and
// under `-release`, the failure is SILENT and lands as a wrong selection.
// Hence: assert the resulting SET.
// ---------------------------------------------------------------------------
unittest // W9 — an EdgeSelByEnds log over an unusable edge map takes the SLOW path
{
    Mesh m;
    uint[ulong] scratch;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1),
                  Vec3(2, 0, 0), Vec3(2, 0, 1)];
    m.addFaceFast(scratch, [0u, 1u, 2u, 3u]);
    m.addFaceFast(scratch, [1u, 4u, 5u, 2u]);
    assert(!m.edgeMapUsable(),
        "stand: addFaceFast defers the canonical map, so it must read unusable "
      ~ "— without that this cell measures the ordinary case");
    m.vertexMarks.length = m.vertices.length;
    m.faceMarks.length   = m.faces.length;
    m.edgeMarks.length   = m.edges.length;

    // An all-STABLE log: nothing here moves an index space, so the ONLY thing
    // keeping it off the fast path is the edge-map term.
    MeshEditDelta d;
    d.scope_ = MeshEditScope.Marks;
    MeshOpEntry e;
    e.kind           = MeshOpEntry.Kind.EdgeSelByEnds;
    e.edgeEndsBefore = [1u, 2u];        // the shared edge
    e.edgeEndsAfter  = [1u, 2u];
    d.log = [e];
    assert(!(d.scope_ & MeshEditScope.Geometry),
        "stand: a Marks-only scope, so nothing but the log can decide the path");

    const a = read(m);
    d.revert(m);
    const got = delta(a, read(m));

    // THE SET, both ways, and it is asserted BEFORE anything is resolved
    // through the map: the plan's ruling is "assert the SET, not the absence
    // of a throw", and a cell that reddened on `edgeIndex` returning ~0u would
    // be reporting the map's state rather than the selection's.
    size_t selected = 0;
    foreach (i, w; m.edgeMarks) if (w & Mesh.Marks.Select) ++selected;
    assert(selected == 1, format(
        "W9: the restored edge selection has %d edge(s), the recorded set has "
      ~ "1. With the `edgeMapUsable` term dropped from the predicate the "
      ~ "endpoint pair is resolved through a map the deferred append never "
      ~ "populated, so the restore silently selects the wrong edges or none at "
      ~ "all. Asserted as a SET and not as a throw on purpose: the guard that "
      ~ "would throw (`assertEdgeMapValid`) is `debug`-only and the run_test.d "
      ~ "lane does not compile it.", selected));

    const uint ei = m.edgeIndex(1, 2);
    assert(ei != ~0u,
        "the repaired map must know edge (1,2) — if it does not, the rebuild "
      ~ "was skipped and the map is still the deferred, empty one");
    assert((m.edgeMarks[ei] & Mesh.Marks.Select) != 0, format(
        "W9: the restored edge selection is not exactly the recorded set — "
      ~ "%d edge(s) selected, edge (1,2) is index %d and reads %s. With the "
      ~ "`edgeMapUsable` term dropped from the predicate, the endpoint pair is "
      ~ "resolved through a map the deferred append never populated, so the "
      ~ "restore silently selects the wrong edges or none at all. This is "
      ~ "asserted as a SET and not as a throw on purpose.",
        selected, ei, "unselected"));
    assert(got.reb == 1 && got.loop == 1, format(
        "W9: an all-stable log over an UNUSABLE edge map must still take the "
      ~ "slow path, because the slow path is what repairs the map — %s",
        fmtc(got)));
}

// ---------------------------------------------------------------------------
// W10 — the per-corner plane survives the skipped carry.
//
// Proves the step-1 skip is a real decision and not dead code: on an all-stable
// log the carry degenerates to an identity gather, so skipping it must be
// byte-identical — and the way to show that is to put a populated per-corner
// plane under it.
// ---------------------------------------------------------------------------
unittest // W10 — a PolyVertex (UV) map is untouched by a fast-path revert
{
    Mesh m = makeGridPlane(2);
    m.resetSelection();
    m.buildLoops();

    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null && uv.data.length > 0,
        "stand: the UV map must register and describe some corners, or the "
      ~ "comparison below is between two empty arrays");
    foreach (i; 0 .. uv.data.length) uv.data[i] = cast(float)(i + 1);
    const float[] preUv = uv.data.dup;

    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Position);
        ed.setVertexPos(0, Vec3(7, 7, 7));
        d = ed.close();
    }
    const a = read(m);
    d.revert(m);
    const got = delta(a, read(m));
    assert(got.reb == 0, format(
        "stand: this cell only means something on the FAST path — %s", fmtc(got)));

    auto post = m.meshMap(kUvMapName);
    assert(post !is null,
        "W10: the per-corner map was UNREGISTERED by a fast-path revert");
    assert(post.data == preUv, format(
        "W10: the per-corner plane changed across a fast-path revert. The "
      ~ "skipped `carry.commit` is an identity gather on an index-space-stable "
      ~ "log; if these values are zero the fast path dropped the plane "
      ~ "instead.\n   expected %s\n   measured %s", preUv, post.data));
}


// ---------------------------------------------------------------------------
// W7-TEXT — the fast-path asserts are PLAIN, and this is a SOURCE CENSUS
// because no behavioural cell in either gate lane can say so.
//
// THE MEASUREMENT THAT MADE THIS NECESSARY (2026-08-27). Plan §P1.4 rules that
// W7 must be observed red under `./run_test.d --no-build`, on the premise that
// that lane compiles `source/**` with `dmd -unittest -i` and no `-debug`, so a
// `debug assert` vanishes there. The lane really does define no `-debug` — but
// it never RUNS a `source/**` unittest at all: a source-backed test LINKS the
// prebuilt `libvibe3d_test.a` (`run_test.d :: buildProjectLib`) and the `-i`
// line beside it is the fallback for when that lib fails to build. Planting an
// unconditional hard failure in `mesh_edit_delta`'s own W3 census left
// `./run_test.d test_falloff_combine` GREEN.
//
// And the other gate, `dub test --config=tests`, goes through
// `--build=unittest`, whose buildType DOES define `-debug` — so there a
// `debug assert` throws exactly like a plain one.
//
// Between them: a `debug assert` in `finalize`'s fast branch would be a check
// that no gate can distinguish from a real one. A text census can, it runs in
// the lane that runs, and its mutation (`assert(` -> `debug assert(` on any of
// the five) reddens it by name.
//
// THE VACUITY FLOOR IS PART OF THE CHECK, not decoration: a scanner that lost
// its place finds no `debug assert` either, and would pass for the wrong
// reason. So the cell also asserts it can still SEE the asserts it is judging.
// ---------------------------------------------------------------------------
private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest // W7-TEXT — no `debug assert` in finalize's fast branch
{
    const src = readText(buildPath(repoRoot, "source", "mesh_edit_delta.d"));

    // The fast branch: from `finalize`'s signature to the end of the
    // `if (fast) { … }` block, which the `// Per-corner (PolyVertex) map carry`
    // comment immediately follows.
    enum string kOpen  = "private void finalize(ref Mesh m, MeshEditScope scope_,";
    enum string kClose = "    // Per-corner (PolyVertex) map carry (task 0689) — FIRST,";
    const size_t a = src.canFind(kOpen) ? src.indexOfSub(kOpen) : size_t.max;
    assert(a != size_t.max, format(
        "W7-TEXT: `%s` is no longer in source/mesh_edit_delta.d — the scanner "
      ~ "has lost its place and this cell is vacuous. Fix the anchor, do not "
      ~ "delete the cell.", kOpen));
    const size_t b = src[a .. $].canFind(kClose)
                   ? a + src[a .. $].indexOfSub(kClose) : size_t.max;
    assert(b != size_t.max && b > a, format(
        "W7-TEXT: the closing anchor `%s` was not found after the opening one "
      ~ "— same diagnosis as above.", kClose));

    // Comments are STRIPPED before counting, and that is not cosmetic: the
    // block being judged carries a comment explaining why the spelling is
    // plain, and that comment contains the words `debug assert`. Without the
    // strip this cell reddens on its own subject matter's documentation.
    const region = stripLineComments(src[a .. b]);

    // The FLOOR, asserted first: the region must still contain the asserts
    // this cell judges. Five plain ones ship (three length compares, the
    // corner-provenance one and the renumbersCorners tie-in) plus the two
    // above the branch; the floor sits below that so a legitimate edit can
    // retire one without touching this file, and far enough above zero to
    // catch a dead scanner.
    const size_t plain = region.count("assert(") - region.count("debug assert(");
    assert(plain >= 5, format(
        "W7-TEXT: the scanner sees only %d plain assert(s) in `finalize`'s "
      ~ "fast branch. It has almost certainly lost its place, which would make "
      ~ "the check below pass for the wrong reason (a scanner that finds "
      ~ "nothing finds no `debug assert` either).", plain));

    const size_t dbg = region.count("debug assert");
    assert(dbg == 0, format(
        "W7-TEXT: `finalize`'s fast branch contains %d `debug assert`. A "
      ~ "`debug assert` there is a check NEITHER GATE CAN SEE: the suite lane "
      ~ "(`./run_test.d`) compiles source with no `-debug` AND never runs a "
      ~ "`source/**` unittest at all — it links the prebuilt "
      ~ "libvibe3d_test.a — while `dub test --config=tests` defines `-debug`, "
      ~ "so there it throws exactly like a plain assert and the difference is "
      ~ "invisible. Precedent for the plain spelling: mesh.d's "
      ~ "`assert(g_deliveryDepth > 0, …)` inside commitStamps.", dbg));
}

/// Drop `//` line comments. Line-based and deliberately simple: the region it
/// runs over is one function header plus a handful of asserts, with no `//`
/// inside any string literal there — and the vacuity floor above is what
/// notices if that ever stops being true.
private string stripLineComments(string src) {
    import std.string : splitLines, indexOf;
    string out_;
    foreach (line; src.splitLines) {
        const ptrdiff_t c = line.indexOf("//");
        out_ ~= (c >= 0 ? line[0 .. c] : line) ~ "\n";
    }
    return out_;
}

/// `std.string.indexOf` returns a `ptrdiff_t` and is easy to misread at a call
/// site that also uses `canFind`; this names the intent and keeps the two
/// halves of each lookup above reading the same way.
private size_t indexOfSub(string hay, string needle) {
    import std.string : indexOf;
    const ptrdiff_t i = hay.indexOf(needle);
    assert(i >= 0, "indexOfSub called for a needle canFind already refused");
    return cast(size_t) i;
}
