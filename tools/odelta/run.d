// tools/odelta/run.d — the O(Δ) measurement of task 1903 (plan §8).
//
// Three cells, run in process against the real kernels. It PRINTS; it does not
// gate. There is no threshold here and no red: Cell A carries an estimate with
// slack, Cell B is the honest break-even control, and Cell C is an input to an
// owner decision. A measurement with a pass mark is a test wearing a lab coat.
//
// ---------------------------------------------------------------------------
// HOW TO RUN IT. It is not part of `dub build` (`tools/` is outside
// `sourcePaths`) and it is not part of either gate. The recipe below is the one
// that LINKS — the project's own import paths, lflags, libs AND linker-files,
// all four taken from `dub describe`. Paste it into a shell as-is:
//
//     cd <worktree>
//     CF=""
//     for k in import-paths:-I= string-import-paths:-J= versions:-version=; do
//       kind=${k%%:*}; pre=${k##*:}
//       while read -r l; do [ -n "$l" ] && CF="$CF $pre$l"; done \
//         < <(dub describe --config=modeling --data=$kind --data-list)
//     done
//     LT=""
//     while read -r l; do [ -n "$l" ] && LT="$LT -L$l";    done \
//       < <(dub describe --config=modeling --data=lflags       --data-list)
//     while read -r l; do [ -n "$l" ] && LT="$LT -L-l$l";  done \
//       < <(dub describe --config=modeling --data=libs         --data-list)
//     while read -r l; do [ -n "$l" ] && LT="$LT $l";      done \
//       < <(dub describe --config=modeling --data=linker-files --data-list)
//     dmd -i -I=source -I=. $CF tools/odelta/run.d $LT -of=/tmp/odelta
//     /tmp/odelta --json tests/fixtures/undo_parity/odelta_baseline.json
//
// `-I=.` is load-bearing: the stand below is `tests/unit/fixtures.d` ITSELF
// (module `tests.unit.fixtures`), not a copy of it. Dropping the `linker-files`
// loop is what leaves ~20 `undefined reference to osdc_*` — the OpenSubdiv
// objects are neither an `lflags` nor a `libs` entry.
//
// `-release` IS FORBIDDEN, and this is not a style preference. It compiles out
// the array bounds check, and the bounds check is what found the defect Cell
// B-now exists to report: reverting a `FaceReindex`-disarmed replay of
// `extrudeFacesByMask` writes PAST THE END of `vertLoop` in `Mesh.buildLoops`
// (`source/mesh.d`, the `vertLoop[loops[idx].vert] = idx` seed pass — the faces
// still reference the extruded vertices while `vertices` has been restored to
// its pre-extrude length). Under `-release` that same run prints a tidy
// "roundTrips NO" and reads as a merely LOSSY record. An instrument that hides
// an out-of-bounds heap write is not an instrument. The byte numbers are array
// lengths, not code, so nothing is lost by measuring bounds-checked; the
// milliseconds are informational either way and are labelled so in the frozen
// JSON — and they are SERIAL times, because `main` pins the task pool so the
// allocation column can be reproducible; see the note there.
//
// ---------------------------------------------------------------------------
// WHAT THE THREE CELLS ARE, AND WHAT EACH IS FOR (plan §8.1).
//
// * CELL A — THE DISCRIMINATOR: a LOCAL edit on a LARGE mesh, through an op
//   that is O(Δ) by construction. A 316x316 grid (99 856 faces — the size task
//   0680 measured, so the numbers are comparable) and a 3-face `mesh.delete`
//   (`Kind.RemoveFaces`).
//
//   IT IS A CLAIM ABOUT BYTES ONLY. Expect snapshot O(mesh) ≈ tens of MB and
//   delta ≈ single-digit KB — an ESTIMATE WITH SLACK, not a derived floor, so a
//   60x reading is not a defect.
//
//   TIME IS NOT PREDICTED TO MOVE, and saying so is half the value of the cell.
//   Undo is O(mesh) on BOTH paths: `mesh_edit_delta.finalize` always rebuilds
//   edges + loops and then commits, which re-derives over the whole mesh.
//   Record is O(mesh) on both too: `deleteFacesByMask` goes through
//   `mesh_planes.rewriteFaces`, whose plane carry and `newFaces` build are
//   whole-array REGARDLESS of recording. A time ratio near 1 is the CORRECT
//   reading here.
//
//   Revision 1 of the plan specified `extrude 3 faces on 100k` for this cell,
//   and that would have condemned a correct delta: `extrudeFacesByMask` is an
//   `&rw` `rewriteFaces` site, so a `FaceReindex` entry there dups the whole
//   post-rewrite face array by design and the ratio reads ~1x. That op is now
//   Cell C, measured on its own terms.
//
// * CELL B — THE HONEST CONTROL: the near-total remesh. A 100x100 grid (10 000
//   faces), extrude ALL of them. Expect delta >= snapshot. Green here is not a
//   win; it is the break-even reading the owner draws the decline line from.
//
//   It runs TWICE. `B-armed` arms `wantsFaceReindex` and is the reading to
//   score. `B-now` is today's production shape — `FaceReindex` DISARMED — and
//   it deliberately DOES NOT REVERT: see `Revert.refuse` below for the
//   out-of-bounds write that is why, and what a migrated kernel owes.
//
// * CELL C — THE `&rw` WHOLE-ARRAY COST: extrude 3 faces on the 316x316 grid
//   with `wantsFaceReindex` ARMED in a driver-local scope (no production
//   recorder sets it). No prediction, no threshold. It answers the owner
//   question recorded verbatim in the task card: should the two `&rw` ops be
//   re-expressed as `ReshapeFaces + AddFaces` — O(Δ), but losing the
//   one-implementation replay guarantee `rewriteFaces` gives — or is the
//   whole-array cost acceptable because those ops are not the interactive hot
//   path?
//
// ---------------------------------------------------------------------------
// THE STAND IS `tests/unit/fixtures.d :: makeTaggedGridFull(n)` — THE FIXTURE
// ITSELF, not a copy of it, so the two cannot drift. That is not decoration:
// on a fixture with empty maps and no selection sets, `MeshSnapshot.capture`
// duplicates far less than it really does — no `meshMaps[].data`, no
// `edgeSetMask` AA, a one-entry surface registry — and the ratio then lies IN
// THE SNAPSHOT'S FAVOUR, i.e. against the thing this task is trying to justify.
//
// ONE DELIBERATE DEVIATION FROM THE FIXTURE, and it is recorded rather than
// hidden: the driver CLEARS the Hide bit the stand sets on face 5. Reason:
// `EditBatchFrame.deferSafe` is armed `!anyHideBitSet()`, so with anything
// hidden every in-batch Geometry commit runs `refreshHiddenDerived` INLINE over
// the whole mesh (task 1330 BLOCKER 2, deliberately). On 99 856 faces that adds
// an O(faces) derive per commit to BOTH paths equally — it does not move the
// ratio, it moves both absolute times by the same large factor, and it belongs
// to 1330's deferral question rather than to this one. It changes NEITHER
// byteSize by a single byte: `faceMarks` is a whole array in the snapshot and
// the Hide bit is one bit inside a word the delta carries anyway.
module tools.odelta.run;

import core.memory   : GC;
import core.time     : MonoTime, Duration;
import std.stdio     : writefln, writeln;
import std.array     : appender;
import std.file      : write;

import mesh;
import math            : Vec3;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;
import snapshot        : MeshSnapshot;

import tests.unit.fixtures : makeTaggedGridFull;

// ---------------------------------------------------------------------------
// The stand.
// ---------------------------------------------------------------------------

/// `makeTaggedGridFull(n)` with the Hide bit cleared — see the module header
/// for why the bit goes and why it costs the measurement nothing.
///
/// The fixture is CALLED, never re-stated. An earlier revision of this driver
/// carried a hand copy of the tagging with four weak assertions pinning it, and
/// a copy that drifts stops the measured snapshot size from describing the
/// fixture the parity tests use — silently, since both sides still "work". The
/// assertions below stay as the stand's own non-vacuity: a fixture edit that
/// emptied a plane would make the snapshot look smaller than it is and bias
/// every ratio in this file.
private Mesh buildStand(int n)
{
    Mesh m = makeTaggedGridFull(n);

    m.setFaceHidden(5, false);
    // `Mesh.anyHideBitSet()` is private to `mesh`, so the predicate is
    // re-stated here over the three mark planes it reads. Asserted rather than
    // assumed: the fixture is free to hide a different element later, and the
    // deviation's whole justification is that NOTHING is hidden.
    uint anyMark = 0;
    foreach (w; m.faceMarks)   anyMark |= w;
    foreach (w; m.vertexMarks) anyMark |= w;
    foreach (w; m.edgeMarks)   anyMark |= w;
    assert((anyMark & Mesh.Marks.Hide) == 0,
        "stand: a Hide bit is still set — every in-batch Geometry commit will "
      ~ "then run refreshHiddenDerived over the whole mesh (task 1330), which "
      ~ "inflates both paths' times by a large constant");

    assert(m.meshMaps.length == 2,  "stand: a corner map AND a point map");
    assert(m.edgeSetMask.length > 0, "stand: the ulong[ulong] plane");
    assert(m.surfaces.length == 2,   "stand: two surfaces");
    assert(m.vertexSelectionOrderCounter != 0 && m.edgeSelectionOrderCounter != 0
        && m.faceSelectionOrderCounter   != 0, "stand: all three order counters");
    return m;
}

// ---------------------------------------------------------------------------
// Instruments.
// ---------------------------------------------------------------------------

/// Did the undo put the element counts back? PRINTED, not asserted — and it is
/// the line that keeps the byte number honest. A delta whose kernel is only
/// partly hooked records FEWER bytes precisely because it records less of the
/// edit, so "smaller" and "incomplete" produce the same number. The snapshot
/// path restores by construction and is the control.
private enum RoundTrip {
    yes,
    no,
    /// The cell did not call `revert` at all. Distinguished from `no` because
    /// the two mean opposite things about the code: `no` is a measured lossy
    /// record, `notAttempted` is a refusal to run a replay that is UNSAFE in
    /// this tree.
    notAttempted,
}

private string label(RoundTrip r)
{
    final switch (r) {
        case RoundTrip.yes:          return "yes";
        case RoundTrip.no:           return "NO";
        case RoundTrip.notAttempted: return "not revertible today — "
                                          ~ "FaceReindex disarmed on an rw op";
    }
}

private string jsonWord(RoundTrip r)
{
    final switch (r) {
        case RoundTrip.yes:          return "yes";
        case RoundTrip.no:           return "no";
        case RoundTrip.notAttempted: return "not-attempted";
    }
}

/// May this cell play the inverse log back?
private enum Revert {
    /// Normal: revert and report whether the element counts return.
    attempt,
    /// DO NOT REVERT — and it is a named prerequisite, not a workaround.
    ///
    /// `extrudeFacesByMask` is an `&rw` `rewriteFaces` site and no PRODUCTION
    /// recorder arms `wantsFaceReindex` (plan §7.1), so today's op-log for that
    /// op is missing the entry that re-establishes the face array. Reverting it
    /// restores `vertices` to its pre-extrude length while `faces` still
    /// reference the extruded vertices, and `mesh_edit_delta.finalize` →
    /// `Mesh.buildLoops` then writes PAST THE END of `vertLoop`:
    ///
    ///     core.exception.ArrayIndexError@source/mesh.d(13243):
    ///         index [10201] is out of bounds for array of length 10201
    ///       ← Mesh.buildLoops
    ///       ← mesh_edit_delta.finalize
    ///       ← MeshEditDelta.revert
    ///
    /// That is an out-of-bounds heap WRITE, not a lossy record, and `-release`
    /// hides it (see the module header). So the obligation is on the MIGRATION,
    /// and it is recorded on the task card against Stage J / L8: a kernel
    /// migrated onto an `&rw` `rewriteFaces` site must either ARM `FaceReindex`
    /// or REFUSE to record — it may not ship a delta whose revert is
    /// memory-unsafe.
    refuse,
}

private struct Reading {
    size_t    recordBytes;    // what the undo record holds
    double    recordMs;       // wall time of the mutating op INCLUDING recording
    double    undoMs;         // wall time of the revert; NaN when not attempted
    size_t    allocBytes;     // GC bytes allocated across the record
    size_t    gcCollections;  // collections across the record
    RoundTrip roundTripped;
}

private double msSince(MonoTime t0)
{
    immutable Duration d = MonoTime.currTime - t0;
    return d.total!"usecs" / 1000.0;
}

/// GC bytes ALLOCATED, not the live set.
///
/// `GC.stats().usedSize` — what this read before — is the size of the LIVE
/// HEAP, so a collection between the two samples makes the difference NEGATIVE
/// and the column is then whatever the collector happened to decide. Measured,
/// on the committed baseline: cell C's delta printed 94 392 672 on one run and
/// 0 on a rerun, and cell B's snapshot printed 0 for a capture that dups
/// ~1.5 MB. Clamping the negative to 0 (which the earlier body did) turns that
/// into a plausible-looking number, which is worse than a negative one.
///
/// `allocatedInCurrentThread` is MONOTONE, so the difference is the allocation
/// the measured section actually performed, and it cannot go backwards.
///
/// IT COUNTS THIS THREAD, WHICH IS WHY `main` PINS THE TASK POOL. See the note
/// there: with workers running, this counter is missing whatever they
/// allocated AND the share is decided by work-stealing, so the column measures
/// the scheduler. Measured both ways, cell A's delta: 30 952 496 / 34 171 952
/// on two parallel runs, 29 277 232 / 29 277 232 on two pinned ones.
private size_t gcAllocated()
{
    return GC.stats().allocatedInCurrentThread;
}

private size_t gcCollections()
{
    static if (__traits(compiles, GC.profileStats().numCollections))
        return GC.profileStats().numCollections;
    else
        return 0;
}

/// Run `op` on a fresh stand with the SNAPSHOT undo mechanism.
private Reading measureSnapshot(int n, void delegate(ref Mesh) op)
{
    Mesh m = buildStand(n);
    Reading r;

    immutable size_t v0 = m.vertices.length, f0 = m.faces.length;
    immutable size_t a0 = gcAllocated();
    immutable size_t nc0 = gcCollections();
    auto t0 = MonoTime.currTime;
    auto snap = MeshSnapshot.capture(m);
    op(m);
    r.recordMs = msSince(t0);
    r.allocBytes    = gcAllocated() - a0;   // monotone: never negative
    r.gcCollections = gcCollections() - nc0;
    r.recordBytes   = snap.byteSize();

    auto t1 = MonoTime.currTime;
    snap.restore(m);
    r.undoMs = msSince(t1);
    r.roundTripped = (m.vertices.length == v0 && m.faces.length == f0)
                   ? RoundTrip.yes : RoundTrip.no;
    return r;
}

/// Run `op` on a fresh stand with the OP-LOG undo mechanism.
/// `armFaceReindex` opts the driver-local tracker into `Kind.FaceReindex`
/// entries — no production recorder does (plan §7.1), which is exactly what
/// Cell C is measuring the cost of.
private Reading measureDelta(int n, uint declared, bool armFaceReindex,
                             Revert revert, void delegate(ref Mesh) op)
{
    Mesh m = buildStand(n);
    Reading r;

    immutable size_t v0 = m.vertices.length, f0 = m.faces.length;
    immutable size_t a0 = gcAllocated();
    immutable size_t nc0 = gcCollections();
    auto t0 = MonoTime.currTime;
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(m, declared);
        if (armFaceReindex) ed.rec().wantsFaceReindex = true;
        op(ed.mesh);
        d = ed.close();
    }
    r.recordMs = msSince(t0);
    r.allocBytes    = gcAllocated() - a0;
    r.gcCollections = gcCollections() - nc0;
    r.recordBytes   = d.byteSize();

    if (revert == Revert.refuse) {
        r.undoMs       = double.nan;
        r.roundTripped = RoundTrip.notAttempted;
        return r;
    }

    auto t1 = MonoTime.currTime;
    cast(void) d.revert(m);
    r.undoMs = msSince(t1);
    r.roundTripped = (m.vertices.length == v0 && m.faces.length == f0)
                   ? RoundTrip.yes : RoundTrip.no;
    return r;
}

/// Every row `report` printed, in order — the body of the frozen baseline.
private string[] g_jsonRows;

private void report(string cell, string what, int n, size_t faces,
                    Reading snap, Reading delta)
{
    import std.format : format;
    import std.math   : isNaN;
    g_jsonRows ~= format(
        `{"cell": "%s", "grid": %d, "faces": %d, ` ~
        `"snapshotBytes": %d, "deltaBytes": %d, ` ~
        `"snapshotRecordMs": %.2f, "deltaRecordMs": %.2f, ` ~
        `"snapshotUndoMs": %.2f, "deltaUndoMs": %s, ` ~
        `"snapshotAllocBytes": %d, "deltaAllocBytes": %d, ` ~
        `"snapshotCollections": %d, "deltaCollections": %d, ` ~
        `"deltaRoundTrip": "%s"}`,
        cell, n, faces, snap.recordBytes, delta.recordBytes,
        snap.recordMs, delta.recordMs, snap.undoMs,
        // JSON has no NaN. `null` is the honest spelling of "not measured";
        // a 0 here would read as an instant undo.
        delta.undoMs.isNaN ? "null" : format("%.2f", delta.undoMs),
        snap.allocBytes, delta.allocBytes,
        snap.gcCollections, delta.gcCollections,
        jsonWord(delta.roundTripped));
    writeln("--------------------------------------------------------------");
    writefln("CELL %s — %s", cell, what);
    writefln("  stand: makeTaggedGridFull(%d) = %d faces", n, faces);
    writefln("  bytes   snapshot %12d   delta %12d   ratio %8.2fx",
             snap.recordBytes, delta.recordBytes,
             delta.recordBytes == 0 ? 0.0
                                    : cast(double)snap.recordBytes
                                    / cast(double)delta.recordBytes);
    writefln("  record  snapshot %9.2f ms   delta %9.2f ms   ratio %8.2fx",
             snap.recordMs, delta.recordMs,
             delta.recordMs == 0 ? 0.0 : snap.recordMs / delta.recordMs);
    if (delta.undoMs.isNaN)
        writefln("  undo    snapshot %9.2f ms   delta   NOT ATTEMPTED",
                 snap.undoMs);
    else
        writefln("  undo    snapshot %9.2f ms   delta %9.2f ms   ratio %8.2fx",
                 snap.undoMs, delta.undoMs,
                 delta.undoMs == 0 ? 0.0 : snap.undoMs / delta.undoMs);
    writefln("  gc      snapshot %9d B alloc / %d coll   delta %9d B alloc / %d coll",
             snap.allocBytes, snap.gcCollections,
             delta.allocBytes, delta.gcCollections);
    writefln("  undo restores element counts?  snapshot %s   delta %s",
             label(snap.roundTripped), label(delta.roundTripped));
    final switch (delta.roundTripped) {
        case RoundTrip.yes: break;
        case RoundTrip.no:
            writeln("    ^ the delta is an INCOMPLETE record of this op — its "
                  ~ "byte number is a LOWER BOUND on what a fully-hooked "
                  ~ "kernel will hold, not a measurement of the finished "
                  ~ "thing.");
            break;
        case RoundTrip.notAttempted:
            writeln("    ^ this cell REFUSES to revert. With FaceReindex "
                  ~ "disarmed the replay of an &rw rewriteFaces op writes PAST "
                  ~ "THE END of vertLoop in Mesh.buildLoops (an out-of-bounds "
                  ~ "heap write, hidden by -release). The byte number is a "
                  ~ "LOWER BOUND on a fully-hooked kernel, and arming or "
                  ~ "refusing is an obligation on the migration — see the "
                  ~ "Revert.refuse comment and the task card (Stage J / L8).");
            break;
    }
}

// ---------------------------------------------------------------------------

void main(string[] args)
{
    // `--json <path>` freezes the run (plan §8.3). WHAT THAT FILE IS AND IS
    // NOT: the BYTES are deterministic and are the pinned quantity; the
    // MILLISECONDS are wall time on whatever host ran it and are informational
    // — a lane that compared them would be comparing loadavg. The file says so
    // per field, in its own `fieldNotes` block, because a reader who takes the
    // whole file as pinned will "fix" a millisecond. Nothing reads the file as
    // a gate today, and that is stated rather than implied: the executable
    // regression on the byte side is the O(Delta) scaling cell in
    // `tests/unit/byte_size_test.d`, which is cheap enough to run in the unit
    // lane. This file is the record of a measurement, so the next change
    // re-checks against it instead of re-deriving it.
    // THE TASK POOL IS PINNED TO THE CALLING THREAD, and it is the allocation
    // column that requires it. `Mesh.buildLoops` (and it is not the only one)
    // runs its fill pass through `std.parallelism.parallel` above
    // `PARALLEL_BUILD_MIN`, while `GC.stats().allocatedInCurrentThread` counts
    // only THIS thread — so with workers running the column is both INCOMPLETE
    // (a worker's allocation is invisible) and UNSTABLE (how many iterations
    // the calling thread keeps is a work-stealing decision). Measured: cell A's
    // delta read 30 952 496 and then 34 171 952 across two parallel runs of the
    // same binary, and 29 277 232 twice with the pool pinned.
    //
    // What it costs: the millisecond columns become SERIAL times. They were
    // already labelled informational (they are wall time on the measuring
    // host), both paths pay the same serialisation so the ratio is untouched,
    // and NO BYTE MOVES — the byte columns are array lengths.
    // What it HIDES: an allocation that exists only because workers exist
    // (a per-worker buffer) is invisible to a pinned run — nothing on the
    // measured paths allocates per worker today, but the column does not
    // rule that out.
    import std.parallelism : defaultPoolThreads;
    defaultPoolThreads(0);

    string jsonPath;
    foreach (i, a; args)
        if (a == "--json" && i + 1 < args.length) jsonPath = args[i + 1];

    // ---- CELL A: 3-face delete on a 99 856-face grid ----------------------
    // Three faces that SHARE NO VERTEX, so the delete strands none. That is
    // the load-bearing property and it is not incidental:
    // `Mesh.compactUnreferenced` returns BEFORE the tracker hook when nothing
    // was removed, so a delete that strands no vertex carries no O(V) `perm`
    // entry at all.
    //
    // They are not "interior" faces, and the earlier comment here said they
    // were: on a row-major grid (`fi = row * n + col`) the indices `len/4`,
    // `len/2` and `3*len/4` are all exact multiples of `n` at n = 316, i.e.
    // COLUMN 0 — the boundary column. Three rows apart is what makes them
    // share no vertex; being interior is not required and is not the case.
    enum int nA = 316;
    static void delete3(ref Mesh m) {
        bool[] mask = new bool[](m.faces.length);
        mask[m.faces.length / 4]     = true;
        mask[m.faces.length / 2]     = true;
        mask[m.faces.length * 3 / 4] = true;
        cast(void) m.deleteFacesByMask(mask);
    }
    {
        auto snap  = measureSnapshot(nA, (ref Mesh m) => delete3(m));
        auto delta = measureDelta(nA, MeshEditScope.Polygons | MeshEditScope.Marks,
                                  false, Revert.attempt, (ref Mesh m) => delete3(m));
        auto probe = buildStand(nA);
        report("A", "LOCAL edit on a LARGE mesh — mesh.delete of 3 faces "
                  ~ "(the discriminator; BYTES only, time predicted ~1x)",
               nA, probe.faces.length, snap, delta);
    }

    // ---- CELL B: extrude ALL faces on a 10 000-face grid -------------------
    enum int nB = 100;
    static void extrudeAll(ref Mesh m) {
        bool[] mask = new bool[](m.faces.length);
        mask[] = true;
        cast(void) m.extrudeFacesByMask(mask, 0.25f);
    }
    {
        auto snap  = measureSnapshot(nB, (ref Mesh m) => extrudeAll(m));
        auto probe = buildStand(nB);
        // TWO readings, because one of them is not yet a measurement of the
        // finished thing. `extrudeFacesByMask` is an `&rw` `rewriteFaces` site
        // and no PRODUCTION recorder arms `wantsFaceReindex` yet (plan §7.1),
        // so today's delta for this op is an INCOMPLETE record — it records
        // fewer bytes because it records less of the edit. B-now is what the
        // tree does today; B-armed is the reading the plan's "delta >=
        // snapshot" prediction is actually about, and it is the one to score.
        //
        // B-now does NOT revert: its replay is memory-unsafe in this tree, and
        // `Revert.refuse` carries the stack and the obligation.
        auto deltaNow = measureDelta(nB, MeshEditScope.Polygons | MeshEditScope.Points
                                       | MeshEditScope.Marks,
                                     false, Revert.refuse, (ref Mesh m) => extrudeAll(m));
        report("B-now", "near-total remesh — extrude ALL faces, FaceReindex "
                      ~ "DISARMED (today's production shape; revert REFUSED)",
               nB, probe.faces.length, snap, deltaNow);

        auto deltaArmed = measureDelta(nB, MeshEditScope.Polygons | MeshEditScope.Points
                                         | MeshEditScope.Marks,
                                       true, Revert.attempt, (ref Mesh m) => extrudeAll(m));
        report("B-armed", "near-total remesh — extrude ALL faces, FaceReindex "
                        ~ "ARMED (the honest control; delta >= snapshot is the "
                        ~ "EXPECTED reading, and green here is a break-even "
                        ~ "point, not a win)",
               nB, probe.faces.length, snap, deltaArmed);
    }

    // ---- CELL C: 3-face extrude on the big grid, FaceReindex ARMED ---------
    // Same three victims as Cell A, and the same property: they share no
    // vertex. See the note there about what they are not.
    static void extrude3(ref Mesh m) {
        bool[] mask = new bool[](m.faces.length);
        mask[m.faces.length / 4]     = true;
        mask[m.faces.length / 2]     = true;
        mask[m.faces.length * 3 / 4] = true;
        cast(void) m.extrudeFacesByMask(mask, 0.25f);
    }
    {
        auto snap  = measureSnapshot(nA, (ref Mesh m) => extrude3(m));
        auto delta = measureDelta(nA, MeshEditScope.Polygons | MeshEditScope.Points
                                    | MeshEditScope.Marks,
                                  true, Revert.attempt, (ref Mesh m) => extrude3(m));
        auto probe = buildStand(nA);
        report("C", "the &rw whole-array cost — extrude 3 faces with "
                  ~ "wantsFaceReindex ARMED (no prediction, no threshold)",
               nA, probe.faces.length, snap, delta);
        writeln();
        writeln("  OWNER QUESTION (open): a FaceReindex entry over a whole-mesh");
        writeln("  rewrite costs O(mesh) even for a 3-face edit. Should the two");
        writeln("  &rw ops (extrudeFacesByMask, insertEdgeLoopsMulti) be");
        writeln("  re-expressed as ReshapeFaces + AddFaces — which is O(Delta)");
        writeln("  but loses the one-implementation replay guarantee");
        writeln("  rewriteFaces gives — or is the whole-array cost acceptable");
        writeln("  because those ops are not the interactive hot path?");
    }

    if (jsonPath.length) {
        auto j = appender!string();
        j ~= "{\n";
        j ~= `  "what": "task 1903 plan section 8 — the O(Delta) measurement",` ~ "\n";
        j ~= `  "build": "dmd -i, BOUNDS-CHECKED. -release is FORBIDDEN for this instrument: it compiles out the array bounds check that found the B-now out-of-bounds write. See tools/odelta/run.d.",` ~ "\n";
        j ~= `  "pinned": "the byte and alloc columns and deltaRoundTrip; the ms and collection columns are NOT — see fieldNotes",` ~ "\n";
        j ~= "  \"fieldNotes\": {\n";
        j ~= `    "snapshotBytes":       "PINNED — MeshSnapshot.byteSize(), array lengths, deterministic",` ~ "\n";
        j ~= `    "deltaBytes":          "PINNED — MeshEditDelta.byteSize(), array lengths, deterministic",` ~ "\n";
        j ~= `    "snapshotRecordMs":    "INFORMATIONAL — SERIAL wall time on the measuring host (the driver pins the task pool); a lane comparing it compares loadavg",` ~ "\n";
        j ~= `    "deltaRecordMs":       "INFORMATIONAL — wall time",` ~ "\n";
        j ~= `    "snapshotUndoMs":      "INFORMATIONAL — wall time",` ~ "\n";
        j ~= `    "deltaUndoMs":         "INFORMATIONAL — wall time; null means the cell refused to revert (see deltaRoundTrip)",` ~ "\n";
        j ~= `    "snapshotAllocBytes":  "PINNED — GC.stats().allocatedInCurrentThread across the record; monotone, reproduces run to run. NOT the live set.",` ~ "\n";
        j ~= `    "deltaAllocBytes":     "PINNED — same counter, delta path",` ~ "\n";
        j ~= `    "snapshotCollections": "INFORMATIONAL — GC.profileStats().numCollections; when the collector runs is not a property of the edit",` ~ "\n";
        j ~= `    "deltaCollections":    "INFORMATIONAL — same",` ~ "\n";
        j ~= `    "deltaRoundTrip":      "PINNED — yes | no | not-attempted. `~
             `no means a measured lossy record; not-attempted means the replay is unsafe in this tree and the cell refused."` ~ "\n";
        j ~= "  },\n";
        j ~= `  "stand": "tests/unit/fixtures.d :: makeTaggedGridFull(n), Hide bit cleared — see tools/odelta/run.d",` ~ "\n";
        j ~= "  \"cells\": [\n";
        foreach (i, row; g_jsonRows) {
            j ~= "    " ~ row;
            if (i + 1 < g_jsonRows.length) j ~= ",";
            j ~= "\n";
        }
        j ~= "  ]\n}\n";
        write(jsonPath, j.data);
        writefln("\nfrozen: %s", jsonPath);
    }
}
