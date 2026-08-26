// The BYTE-IDENTITY DIFFERENTIAL harness for task 1903's track-1 conversions.
//
// WHY IT IS A COMMITTED FILE AND NOT A SCRATCH SCRIPT. Every track-1 stage owes
// the same measurement — "the converted kernel and the pre-conversion body
// produce the same mesh, plane for plane, over a corpus that can actually
// exhibit each of the family's branches" — and stages E4, F1 and F2 each wrote
// that harness from scratch, used it once, and deleted it before the outgoing
// measurement (памятка 14 requires the `*Old` probe itself to go; it does not
// require the comparator to go with it). Each stage's REVIEWER then wrote a
// third copy to check the writer's numbers. Stage G is the fourth family with
// this shape and Stage H is the fifth and largest, so the harness stops being
// throwaway here.
//
// WHAT IT IS NOT: a framework. There are five things every one of those copies
// contained, and this file is those five and nothing else —
//
//   1. `meshPlaneDiffs`      — the whole-`Mesh` bitwise comparator.
//   2. `SeamCell` / `runSeamDifferential` — the cell runner.
//   3. `movedCells`          — the reachability probe (памятка 29: zero the
//                              block's own AMPLITUDE and count the cells that
//                              move; do NOT count flags).
//   4. `controlReport`       — the negative-control runner, which reports how
//                              many cells a planted mutation reddens, because a
//                              control that reddens ZERO is DEAD and is fixed
//                              by the STAND, not by a threshold (памятка 28).
//   5. `kVersionFields`      — the excluded-and-PRINTED version/stamp set.
//
// THE `*Old` PROBE STAYS THE STAGE'S OWN. This file knows nothing about which
// family is being converted: a stage brings its own stands, its own
// `oldRun`/`newRun` delegates and its own controls. The probe module (the
// pre-conversion body re-mixed under `*Old` names) is temporary by памятка 14
// and is deleted before the outgoing measurement; this harness is not.
//
// WHY THE VERSION FIELDS ARE EXCLUDED — and why they are PRINTED rather than
// silently dropped (the shape Stage F2's reviewer asked for). The OLD body runs
// as a `Mesh` MEMBER on a bare mesh; the NEW one runs inside a
// `MeshEditBatch`, which is exactly a change in when the stamp lands. So
// `mutationVersion` & co. are GUARANTEED to differ and comparing them would
// make every cell red for the one reason the conversion is FOR. Dropping them
// quietly, though, is how a comparator stops being able to fail: printing the
// pair per cell keeps the exclusion auditable, and the batch-cell ladder
// (`mutationVersion` delta 1 vs the unbatched N) is asserted separately, in the
// family's own `tests/unit/mesh_ops/*_test.d`.
module tests.unit.mesh_ops.seam_differential;

version (unittest):

import mesh;
import math;
import std.format : format;
import std.traits : isFloatingPoint, isIntegral, isSomeString, isPointer,
                    isAssociativeArray, isDynamicArray, isStaticArray,
                    isAggregateType, isSomeChar, isBoolean;

// ---------------------------------------------------------------------------
// 1. THE COMPARATOR
// ---------------------------------------------------------------------------

/// One differing plane, named by the PATH that reaches it
/// (`vertices[12].x`, `meshMaps[0].data[7]`, `faces._store[3][1]`, …) with both
/// sides rendered. Floats are rendered with `%a`, the hex form, because that is
/// the only rendering in which "bit-exact" is a thing a reader can check: two
/// `%f` prints agree long after the bits have stopped agreeing, and `-0.0f`
/// against `0.0f` — the exact residue a "multiply by zero" refactor leaves —
/// prints identically in every decimal format.
struct PlaneDiff {
    string path;
    string lhs;
    string rhs;
    string toString() const { return format("%s: %s vs %s", path, lhs, rhs); }
}

/// The fields `meshPlaneDiffs` SKIPS, by identifier. Everything here is a
/// version counter, a derived-state stamp or delivery bookkeeping — state whose
/// whole purpose is to record WHEN something was published, which is the one
/// thing a batch changes on purpose.
///
/// It is a whitelist and not a predicate on purpose: a new `Mesh` field with a
/// version-ish NAME must be added here by a human who says why, rather than
/// disappearing from the comparison because it matched `*Version`.
static immutable string[] kVersionFields = [
    "mutationVersion", "topologyVersion", "structVersion", "marksVersion",
    "stampedVersion_", "loopsStamp", "edgeMapStamp", "_adjCsrStructVer",
    "undeliveredChanges_", "undeliveredSelDomains_",
];

private string fmtScalar(T)(in T v) {
    static if (isFloatingPoint!T)      return format("%a", v);
    else static if (isSomeString!T)    return format("%s", v);
    else                               return format("%s", v);
}

/// Bitwise equality for one value of any plain-old-data shape `Mesh` uses:
/// scalars (floats by BITS, so `NaN == NaN` and `-0.0f != 0.0f`), dynamic and
/// static arrays, associative arrays (compared by key SET and then by value),
/// and aggregates (recursed field by field through `.tupleof`, which reaches
/// `private` fields from outside the module — probed).
///
/// `out diffs` accumulates every difference rather than stopping at the first:
/// a conversion that moves ONE vertex and a conversion that rebuilds the whole
/// mesh should not look the same in the report.
void diffValue(T)(in T a, in T b, string path, ref PlaneDiff[] diffs,
                  size_t maxPerPath = 8) {
    static if (isPointer!T) {
        // A pointer plane is address-valued; comparing addresses across two
        // independently built meshes is meaningless. Report only null-ness,
        // which IS meaningful (an armed handle vs a disarmed one).
        if ((a is null) != (b is null))
            diffs ~= PlaneDiff(path ~ " (null-ness)",
                               a is null ? "null" : "non-null",
                               b is null ? "null" : "non-null");
    } else static if (isFloatingPoint!T) {
        static if (T.sizeof == 4) { auto ba = *cast(const uint*)&a,  bb = *cast(const uint*)&b; }
        else                      { auto ba = *cast(const ulong*)&a, bb = *cast(const ulong*)&b; }
        if (ba != bb) diffs ~= PlaneDiff(path, fmtScalar(a), fmtScalar(b));
    } else static if (isSomeString!T) {
        if (a != b) diffs ~= PlaneDiff(path, a.idup, b.idup);
    } else static if (isDynamicArray!T || isStaticArray!T) {
        if (a.length != b.length) {
            diffs ~= PlaneDiff(path ~ ".length",
                               format("%d", a.length), format("%d", b.length));
            return;   // element paths would be noise past a length change
        }
        size_t hitsHere = 0;
        foreach (i; 0 .. a.length) {
            immutable before = diffs.length;
            diffValue(a[i], b[i], format("%s[%d]", path, i), diffs, maxPerPath);
            if (diffs.length > before) {
                ++hitsHere;
                if (hitsHere >= maxPerPath) {
                    diffs ~= PlaneDiff(path ~ " (…)", "more elements differ",
                                       "report truncated");
                    return;
                }
            }
        }
    } else static if (isAssociativeArray!T) {
        if (a.length != b.length)
            diffs ~= PlaneDiff(path ~ ".length",
                               format("%d keys", a.length), format("%d keys", b.length));
        foreach (k, ref va; a) {
            auto p = k in b;
            if (p is null) {
                diffs ~= PlaneDiff(format("%s[%s]", path, k), "present", "absent");
                continue;
            }
            diffValue(va, *p, format("%s[%s]", path, k), diffs, maxPerPath);
        }
        foreach (k, ref vb; b)
            if ((k in a) is null)
                diffs ~= PlaneDiff(format("%s[%s]", path, k), "absent", "present");
    } else static if (isAggregateType!T) {
        static foreach (i; 0 .. T.tupleof.length)
            diffValue(a.tupleof[i], b.tupleof[i],
                      path ~ "." ~ __traits(identifier, T.tupleof[i]), diffs,
                      maxPerPath);
    } else {
        if (a != b) diffs ~= PlaneDiff(path, fmtScalar(a), fmtScalar(b));
    }
}

/// Every plane of two meshes, compared bitwise, with `kVersionFields` skipped.
/// Field order is `Mesh.tupleof`'s own, so a new field joins the comparison the
/// day it is declared — which is the property that makes this comparator able
/// to fail on a plane nobody thought to list.
PlaneDiff[] meshPlaneDiffs(ref const Mesh a, ref const Mesh b) {
    import std.algorithm : canFind;
    PlaneDiff[] diffs;
    static foreach (i; 0 .. Mesh.tupleof.length) {{
        enum string fname = __traits(identifier, Mesh.tupleof[i]);
        if (!kVersionFields.canFind(fname))
            diffValue(a.tupleof[i], b.tupleof[i], fname, diffs);
    }}
    return diffs;
}

/// The excluded set, rendered for a cell — the "PRINTED" half of
/// "excluded and printed".
string versionFieldReport(ref const Mesh a, ref const Mesh b) {
    import std.algorithm : canFind;
    import std.array : appender;
    auto app = appender!string();
    static foreach (i; 0 .. Mesh.tupleof.length) {{
        enum string fname = __traits(identifier, Mesh.tupleof[i]);
        if (kVersionFields.canFind(fname))
            app.put(format("%s %s/%s  ", fname, a.tupleof[i], b.tupleof[i]));
    }}
    return app.data;
}

// ---------------------------------------------------------------------------
// 2. THE CELL RUNNER
// ---------------------------------------------------------------------------

/// One differential cell: a stand builder plus the two runs to compare.
///
/// The stand is a DELEGATE and not a `Mesh` because both sides must start from
/// an independently built mesh: `Mesh` is a value type holding slices, and
/// handing the same one to both runs would let the first mutate the second's
/// input through a shared array. (Stage E2 hit exactly this on a copy that
/// looked deep and was not.)
struct SeamCell {
    string name;
    Mesh delegate()             stand;
    size_t delegate(ref Mesh m) oldRun;
    size_t delegate(ref Mesh m) newRun;
}

/// THE ONLY SUPPORTED WAY TO BUILD A CELL, and the reason it exists.
///
/// D closures capture the VARIABLE, not its value. A corpus built like this —
/// the shape everyone writes first — is one measurement repeated:
///
///     foreach (w; [0.05f, 0.1f, 0.2f])                       // WRONG
///         cells ~= SeamCell(format("w=%s", w),
///                           () => stand(),
///                           (ref Mesh m) => oldRun(m, w),    // all three see
///                           (ref Mesh m) => newRun(m, w));   // the LAST w
///
/// Stage G shipped that by accident: three cells named `w=0.05` / `0.1` / `0.2`
/// all ran `0.200000`, every assertion was green, and the report read a perfect
/// `3 cells / 0 differing`. Passing the spec through a FUNCTION parameter binds
/// it by value, which is what this factory is:
///
///     foreach (w; [0.05f, 0.1f, 0.2f])                       // RIGHT
///         cells ~= makeSeamCell(format("w=%s", w), w,
///                               &stand, &oldRun, &newRun);
///
/// `runSeamDifferential` also counts DISTINCT outcomes and `assertBitExact`
/// floors that count, so a collapsed corpus now fails loudly rather than
/// reading green — but the floor is the backstop, and this factory is the fix.
SeamCell makeSeamCell(Spec)(string name, Spec spec,
                            Mesh delegate() stand,
                            size_t delegate(ref Mesh, Spec) oldRun,
                            size_t delegate(ref Mesh, Spec) newRun) {
    // `spec` is a by-value parameter of THIS call, so each returned closure
    // owns its own copy; nothing is shared with the caller's loop variable.
    return SeamCell(name, stand,
                    (ref Mesh m) => oldRun(m, spec),
                    (ref Mesh m) => newRun(m, spec));
}

/// The no-spec form, for a cell whose stand IS its whole specification.
SeamCell makeSeamCell(string name, Mesh delegate() stand,
                      size_t delegate(ref Mesh) oldRun,
                      size_t delegate(ref Mesh) newRun) {
    return SeamCell(name, stand, oldRun, newRun);
}

/// What a corpus run answers.
struct SeamDiffResult {
    size_t cells;         /// how many cells ran
    size_t nontrivial;    /// how many returned a NON-ZERO count from `newRun`
    size_t differing;     /// how many differed on the return value or any plane
    size_t distinct;      /// how many DISTINCT post-`newRun` meshes the corpus
                          /// produced — the closure-collapse detector, below
    string[] firstDiffs;  /// up to `keepFirst` rendered failures, cell-named
}

/// Run every cell, both sides, and compare.
///
/// `nontrivial` is the anti-vacuity number and it belongs in the report beside
/// `cells`: a corpus of 400 cells where 400 refuse is a corpus that proves
/// nothing, and it is indistinguishable from a corpus of 400 that all agree if
/// only `differing == 0` is printed (памятка 19).
SeamDiffResult runSeamDifferential(SeamCell[] cells, size_t keepFirst = 12) {
    SeamDiffResult r;
    Mesh[] produced;
    foreach (ref c; cells) {
        ++r.cells;
        Mesh mo = c.stand();
        Mesh mn = c.stand();
        immutable size_t ro = c.oldRun(mo);
        immutable size_t rn = c.newRun(mn);
        if (rn != 0) ++r.nontrivial;

        // THE CLOSURE-COLLAPSE DETECTOR (памятка 46). A corpus whose cells were
        // built in a `foreach` BODY all capture the same loop variable, so every
        // cell runs the LAST spec — and every assertion here is then green over N
        // copies of one measurement, with the report reading a perfect
        // `N cells / 0 differing`. Stage G hit exactly that: three cells named
        // w=0.05 / 0.1 / 0.2 all ran 0.200000. Counting how many DISTINCT meshes
        // the corpus actually produced is what tells the two apart, and it costs
        // one comparison per cell against what came before.
        bool seen = false;
        foreach (ref q; produced)
            if (meshPlaneDiffs(q, mn).length == 0) { seen = true; break; }
        if (!seen) { produced ~= mn; ++r.distinct; }

        PlaneDiff[] diffs;
        if (ro != rn)
            diffs ~= PlaneDiff("<return value>", format("%d", ro), format("%d", rn));
        diffs ~= meshPlaneDiffs(mo, mn);
        if (diffs.length) {
            ++r.differing;
            if (r.firstDiffs.length < keepFirst) {
                string s = format("cell `%s`: %d plane(s) differ", c.name, diffs.length);
                foreach (d; diffs[0 .. diffs.length < 6 ? diffs.length : 6])
                    s ~= "\n    " ~ d.toString();
                s ~= format("\n    [version fields, EXCLUDED: %s]",
                            versionFieldReport(mo, mn));
                r.firstDiffs ~= s;
            }
        }
    }
    return r;
}

/// The bit-exactness assertion, with the anti-vacuity floor built in.
///
/// `minNontrivial` is not decoration: without it, a corpus whose stands all
/// refuse reports `differing == 0` and reads as a pass. That is the project's
/// own "a gate reports clean over an empty input" shape.
void assertBitExact(SeamDiffResult r, string what, size_t minNontrivial,
                    size_t minDistinct = 2) {
    import std.array : join;
    assert(r.cells < 2 || r.distinct >= minDistinct,
        format("%s: %d cells produced only %d DISTINCT outcome(s) (>= %d "
             ~ "required). A corpus built inside a `foreach` body captures the "
             ~ "loop variable, so every cell runs the LAST spec and this whole "
             ~ "report is one measurement repeated %d times — green, and "
             ~ "meaningless. Build each cell through `makeSeamCell`, which "
             ~ "takes its spec BY VALUE (памятка 46).",
               what, r.cells, r.distinct, minDistinct, r.cells));
    assert(r.nontrivial >= minNontrivial,
        format("%s: only %d of %d cells did any work (>= %d required). A corpus "
             ~ "that refuses everywhere reports zero differences for the wrong "
             ~ "reason — fix the STANDS, not this floor.",
               what, r.nontrivial, r.cells, minNontrivial));
    assert(r.differing == 0,
        format("%s: %d of %d cells differ between the pre-conversion body and "
             ~ "the converted one. A conversion that changes one byte is a bug, "
             ~ "not an improvement.\n%s",
               what, r.differing, r.cells, r.firstDiffs.join("\n")));
}

// ---------------------------------------------------------------------------
// 3. THE REACHABILITY PROBE (памятка 29)
// ---------------------------------------------------------------------------

/// How many cells of `a` produce a DIFFERENT mesh than the matching cell of
/// `b`, using each cell's `newRun`.
///
/// The intended use is amplitude zeroing: build the corpus twice, once with the
/// option under discussion at its real value and once at the value that makes
/// it a no-op, and count the cells that move. That number is what "this corpus
/// reaches the `group` path on N cells" means. Counting how many cells SET the
/// flag is a different and much larger number — on a stand where the flag's
/// input is empty it moves nothing, and F1 measured exactly that gap (99 cells
/// with `gap != 0` against the cells where Gap actually displaced a vertex).
size_t movedCells(SeamCell[] a, SeamCell[] b) {
    assert(a.length == b.length,
        "the two variants of a reachability probe must be the same corpus");
    size_t moved = 0;
    foreach (i; 0 .. a.length) {
        Mesh ma = a[i].stand();
        Mesh mb = b[i].stand();
        immutable ra = a[i].newRun(ma);
        immutable rb = b[i].newRun(mb);
        if (ra != rb || meshPlaneDiffs(ma, mb).length) ++moved;
    }
    return moved;
}

// ---------------------------------------------------------------------------
// 4. THE NEGATIVE-CONTROL RUNNER (памятка 28)
// ---------------------------------------------------------------------------

/// A control's verdict: how many cells a planted mutation of the OLD body
/// reddens, out of how many.
///
/// A control at ZERO is DEAD and the corpus, not the control, is what is wrong:
/// it means no cell in the corpus can tell the mutated law from the real one.
/// F2 shipped two such controls before catching them — both were a plane
/// carried onto a face the stand had HIDDEN, and `maskMinusHiddenFaces` drops
/// hidden faces from the mask, so "carry a zero" and "carry nothing" were the
/// same measurement. The fix is a stand whose tag sits on a face that is IN THE
/// MASK, NOT HIDDEN and NON-ZERO — never a lowered threshold.
struct ControlReport {
    string name;
    size_t reddened;
    size_t cells;
    string toString() const {
        return format("%-42s %4d / %d%s", name, reddened, cells,
                      reddened == 0 ? "   <<< DEAD CONTROL — FIX THE STAND" : "");
    }
}

/// Run one control: the caller has already planted the mutation in whatever
/// `oldRun` reaches, so this is `runSeamDifferential` read in the opposite
/// direction — a HIGH `differing` is the pass.
ControlReport controlReport(string name, SeamCell[] cells) {
    auto r = runSeamDifferential(cells, 0);
    return ControlReport(name, r.differing, r.cells);
}

/// The control table's own gate: a run in which EVERY control is dead is a run
/// that measured nothing, and printing `<<< DEAD CONTROL` beside each row does
/// not stop it from being read as a pass. The corpus has an anti-vacuity floor
/// (`assertBitExact`'s `minNontrivial`); until this existed, the controls had
/// none — which is the same defect one level up.
///
/// `maxDead` is not a tolerance for a control you could not be bothered to fix:
/// it is there because a control can be legitimately unreachable on a family
/// whose kernels decline that arm, and a stage that uses it must SAY which
/// control and why, in its card. Zero is the default for a reason.
void assertControlsLive(ControlReport[] controls, string what, size_t maxDead = 0) {
    import std.array : join;
    import std.algorithm : filter, map;
    import std.array : array;
    assert(controls.length > 0,
        what ~ ": no negative controls at all. A differential with no control "
             ~ "is a green that cannot come out differently.");
    auto dead = controls.filter!(c => c.reddened == 0).array;
    assert(dead.length <= maxDead,
        format("%s: %d of %d negative controls reddened NOTHING (at most %d "
             ~ "allowed). A dead control means the CORPUS cannot tell the "
             ~ "mutated law from the real one — fix the stand, never the "
             ~ "threshold (памятка 28).\n%s",
               what, dead.length, controls.length, maxDead,
               dead.map!(c => "    " ~ c.toString()).array.join("\n")));
}


// ===========================================================================
// THE HARNESS'S OWN TESTS — it must not be able to ship inert.
//
// Two things are proved here, and they are the two ways a comparator like this
// silently stops working: it stops SEEING a difference, and it starts seeing
// one everywhere (so a "0" from a control means nothing).
// ===========================================================================

version (unittest) private Mesh diffProbeStand() {
    Mesh m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.selectFace(0);
    m.selectVertex(3);
    m.setFaceSubpatch(1, true);
    m.faceMaterial.length = m.faces.length;
    m.faceMaterial[2] = 7;
    return m;
}

unittest { // the comparator catches a PLANTED SINGLE-BIT difference, on every
           // shape of plane Mesh carries — and names the plane it found.
    import std.algorithm : canFind, startsWith;

    // (0) The identity control FIRST. If two independently built stands already
    //     differ, every assertion below is measuring the stand, not the
    //     comparator.
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        auto d = meshPlaneDiffs(a, b);
        assert(d.length == 0,
            format("two freshly built copies of the probe stand already differ "
                 ~ "on %d plane(s) — the comparator cannot say anything about a "
                 ~ "conversion until this is 0. First: %s",
                   d.length, d.length ? d[0].toString() : "-"));
    }

    // (1) A FLOAT plane, one BIT. Not 1e-6, not "a small delta": the smallest
    //     representable change, which is what "bit-exact" claims to see and
    //     what an `%f`-based comparator cannot.
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        immutable uint bits = *cast(uint*)&b.vertices[2].x;
        immutable uint one  = bits ^ 1u;
        b.vertices[2].x = *cast(const float*)&one;
        auto d = meshPlaneDiffs(a, b);
        assert(d.length == 1 && d[0].path == "vertices[2].x",
            format("a ONE-BIT change to vertices[2].x produced %d diff(s) %s — "
                 ~ "expected exactly one, named `vertices[2].x`",
                   d.length, d.length ? d[0].path : ""));
    }

    // (1b) …and the -0.0f / +0.0f pair, which every decimal comparator misses
    //      and which is the exact residue a `v + dir*0` refactor leaves behind
    //      (памятка 10).
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        a.vertices[1].y =  0.0f;
        b.vertices[1].y = -0.0f;
        assert(a.vertices[1].y == b.vertices[1].y, "the two zeroes compare EQUAL under ==");
        auto d = meshPlaneDiffs(a, b);
        assert(d.length == 1 && d[0].path == "vertices[1].y",
            format("+0.0f vs -0.0f went unseen (%d diffs) — that is the whole "
                 ~ "reason this comparator reads BITS", d.length));
    }

    // (2) An INTEGER mark plane.
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        b.faceMarks[0] ^= Mesh.Marks.Select;
        auto d = meshPlaneDiffs(a, b);
        assert(d.length == 1 && d[0].path == "faceMarks[0]",
            format("a flipped Select bit produced %d diff(s) — expected one on "
                 ~ "faceMarks[0]", d.length));
    }

    // (3) A WINDING, inside the `FaceList` aggregate's PRIVATE store — the
    //     plane a comparator written over Mesh's public accessors would miss.
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        auto w = b.faces[3].dup;
        immutable t = w[0]; w[0] = w[1]; w[1] = t;
        b.faces[3] = w;
        auto d = meshPlaneDiffs(a, b);
        assert(d.length >= 1 && d[0].path.startsWith("faces."),
            format("a swapped winding produced %d diff(s) (%s) — expected a "
                 ~ "path under `faces.`", d.length, d.length ? d[0].path : ""));
    }

    // (4) An ASSOCIATIVE-ARRAY plane, both directions (a key only on one side,
    //     and a differing value under a shared key).
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        b.edgeIndexMap[0xDEAD_BEEFUL] = 99;
        auto d = meshPlaneDiffs(a, b);
        assert(d.length >= 1, "an extra edgeIndexMap key went unseen");
        Mesh c = diffProbeStand(), e = diffProbeStand();
        foreach (k, v; c.edgeIndexMap) { e.edgeIndexMap[k] = v + 1; break; }
        assert(meshPlaneDiffs(c, e).length >= 1,
            "a changed edgeIndexMap VALUE under a shared key went unseen");
    }

    // (5) A LENGTH change reports the length and does NOT then bury the reader
    //     in per-element noise.
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        b.vertices ~= Vec3(1, 2, 3);
        auto d = meshPlaneDiffs(a, b);
        assert(d.length == 1 && d[0].path == "vertices.length",
            format("an appended vertex produced %d diff(s) — expected exactly "
                 ~ "the one `vertices.length` row", d.length));
    }

    // (6) ONE OF THE THREE STAGE-G PARITY FIELDS, because they are `Mesh`
    //     members now (Stage G's recorded decision) and therefore inside
    //     `.tupleof` — which is what makes them part of every family's
    //     differential for free, instead of a plane somebody has to remember.
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        b.bevelCapOrphanPos_ ~= Vec3(0.5f, 0, 0);
        auto d = meshPlaneDiffs(a, b);
        assert(d.length == 1 && d[0].path == "bevelCapOrphanPos_.length",
            format("the edge-bevel parity field is not in the comparison "
                 ~ "(%d diffs) — Stage G's whole cap-parity claim rides on it",
                   d.length));
    }

    // (7) A VERSION field is EXCLUDED — and is still PRINTED, so the exclusion
    //     is auditable rather than a hole.
    {
        Mesh a = diffProbeStand(), b = diffProbeStand();
        b.mutationVersion += 17;
        assert(meshPlaneDiffs(a, b).length == 0,
            "mutationVersion is not excluded — every converted cell would be red "
          ~ "for the one reason the conversion exists");
        auto rep = versionFieldReport(a, b);
        import std.string : indexOf;
        assert(rep.indexOf("mutationVersion") >= 0,
            "the excluded version fields are not printed: `" ~ rep ~ "`");
    }
}

unittest { // the runner: a DEAD control reads 0, a live one does not, and the
           // anti-vacuity floor refuses a corpus that does no work.
    import std.exception : assertThrown;
    import core.exception : AssertError;

    static size_t bevelOneEdge(ref Mesh m, float w) {
        bool[] mask = new bool[](m.edges.length);
        foreach (i, ref e; m.edges)
            if ((e[0] == 6 && e[1] == 7) || (e[0] == 7 && e[1] == 6)) mask[i] = true;
        auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
        immutable n = ed.bevelEdgesByMask(mask, w, 0, false);
        ed.close();
        return n;
    }

    SeamCell[] same;
    foreach (w; [0.05f, 0.1f, 0.2f])
        same ~= makeSeamCell(format("identical w=%s", w), w,
                             () => diffProbeStand(),
                             (ref Mesh m, float ww) => bevelOneEdge(m, ww),
                             (ref Mesh m, float ww) => bevelOneEdge(m, ww));
    auto rSame = runSeamDifferential(same);
    assert(rSame.cells == 3 && rSame.nontrivial == 3 && rSame.differing == 0,
        format("running the SAME kernel on both sides must agree everywhere: "
             ~ "%d/%d cells, %d nontrivial, %d differing",
               rSame.cells, rSame.cells, rSame.nontrivial, rSame.differing));

    // THE CLOSURE COLLAPSE, PROVEN BOTH WAYS (памятка 46). The corpus above is
    // built through `makeSeamCell`, which binds the width by value; the one
    // below is the shape everyone writes first, and its three cells all run the
    // LAST width. Every assertion this file makes is green over BOTH — which is
    // exactly why `distinct` exists and why `assertBitExact` floors it.
    assert(rSame.distinct == 3, format(
        "a factory-built corpus of three DIFFERENT widths must produce three "
      ~ "distinct outcomes; got %d — the factory has stopped binding by value",
        rSame.distinct));
    {
        SeamCell[] collapsed;
        foreach (w; [0.05f, 0.1f, 0.2f])
            collapsed ~= SeamCell(format("collapsed w=%s", w), () => diffProbeStand(),
                                  (ref Mesh m) => bevelOneEdge(m, w),
                                  (ref Mesh m) => bevelOneEdge(m, w));
        auto rColl = runSeamDifferential(collapsed);
        assert(rColl.cells == 3 && rColl.differing == 0 && rColl.nontrivial == 3,
            "the collapsed corpus is green on every OLD assertion — that is the "
          ~ "whole hazard");
        assert(rColl.distinct == 1, format(
            "three cells built in a `foreach` body must collapse to ONE distinct "
          ~ "outcome (D captures the variable); got %d. If this is ever 3, the "
          ~ "language changed and памятка 46 needs re-measuring, not deleting",
            rColl.distinct));
        assertThrown!AssertError(
            assertBitExact(rColl, "a collapsed corpus", 1),
            "assertBitExact must REFUSE a corpus that produced one distinct "
          ~ "outcome from three specs — otherwise a whole stage reports a "
          ~ "perfect differential over one repeated measurement");
    }

    // A DEAD control reads 0 — and this is the assertion that makes a 0 in a
    // control table mean "the corpus cannot see this", not "the harness is
    // broken".
    auto dead = controlReport("a control that changes nothing", same);
    assert(dead.reddened == 0 && dead.cells == 3,
        format("a no-op control must redden ZERO cells; got %s", dead));
    import std.string : indexOf;
    assert(dead.toString().indexOf("DEAD CONTROL") >= 0,
        "a zero control must SAY it is dead in its own rendering: " ~ dead.toString());

    // A LIVE control does not.
    SeamCell[] live;
    foreach (w; [0.05f, 0.1f, 0.2f])
        live ~= makeSeamCell(format("live w=%s", w), w, () => diffProbeStand(),
                             (ref Mesh m, float ww) => bevelOneEdge(m, ww * 1.001f),  // the "mutation"
                             (ref Mesh m, float ww) => bevelOneEdge(m, ww));
    auto alive = controlReport("width x 1.001", live);
    assert(alive.reddened == 3,
        format("a live control must redden every cell it reaches; got %s", alive));
    assert(alive.toString().indexOf("DEAD CONTROL") < 0,
        "a live control must NOT be labelled dead: " ~ alive.toString());

    // The reachability probe: the SAME corpus against a zero-amplitude variant.
    SeamCell[] zeroAmp;
    foreach (w; [0.05f, 0.1f, 0.2f])
        zeroAmp ~= makeSeamCell(format("zero amplitude w=%s", w), w,
                                () => diffProbeStand(),
                                (ref Mesh m, float) => bevelOneEdge(m, 0.0f),
                                (ref Mesh m, float) => bevelOneEdge(m, 0.0f));
    assert(movedCells(same, zeroAmp) == 3,
        "the amplitude probe must see all three cells move when the width is zeroed");
    assert(movedCells(same, same) == 0,
        "the amplitude probe must see NOTHING move against itself");

    // The anti-vacuity floor refuses a corpus that did no work — which is what
    // a refusing stand looks like.
    SeamCell[] refusing;
    refusing ~= SeamCell("refused (width 0)", () => diffProbeStand(),
                         (ref Mesh m) => bevelOneEdge(m, 0.0f),
                         (ref Mesh m) => bevelOneEdge(m, 0.0f));
    auto rRef = runSeamDifferential(refusing);
    assert(rRef.differing == 0, "a refusal on both sides does not DIFFER — that is the trap");
    assertThrown!AssertError(assertBitExact(rRef, "a corpus that refuses", 1),
        "assertBitExact must refuse a corpus whose cells all declined: a green "
      ~ "over an empty input is the shape this floor exists to catch");
}
