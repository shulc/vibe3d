// mesh_dirty_cliff_series_test — WHERE THE SLOT-CEILING CLIFF ACTUALLY IS
// (task 1932, closing task 1906's item 4 at the LAW tier).
//
// THE QUESTION THIS FILE ANSWERS, AND ONLY THIS FILE CAN. The eviction cliff
// `source/mesh_dirty.d` describes is produced by a CHAIN of two independent
// 32-slot tables — `MeshBirthTable.kSlots` (`B`) and `MeshDirtyEpochs.kSlots`
// (`D`) — and today they happen to share the literal 32. An earlier draft of
// this measurement wrote the cliff as `2*D`, which is correct ONLY while
// `B == D`; nothing enforces that equality, and a caller who raises `D`
// alone (the change the card actually asks about) would silently invalidate
// a `2*D`-shaped assertion without it ever going red. This file drives
// `noteMeshBirth`/`noteMeshChange` directly with NO document, NO app, NO
// `BgGpu` — the ONLY tier where `epochFor` can be read straight off the
// watcher, so a mutation to either table is a mutation to a NAMED formula
// here, not to an inferred rate on a suite stand (that stand is
// `tests/test_bus_layer_scale_rebuild_rate.d` — it measures the COST, this
// file measures the LAW, and neither substitutes for the other).
//
// TWO MODES, BECAUSE THE TWO FORMULAS DIVERGE EXACTLY WHEN `B != D`:
//
//   * Mode A — BIRTHS ONLY. `noteMeshBirth` on N distinct addresses, nothing
//     ever published. The birth table absorbs the first `B` for free
//     (`MeshBirthTable.observe`'s free-slot arm returns `false`, so
//     `noteMeshBirth` never calls `noteMeshChange` at all); births
//     `B+1 .. B+D` fill the (now full-table) `noteMeshChange(addr, uint.max)`
//     arm, inserting into every watcher without evicting; birth `B+D+1` is
//     the first that evicts a WATCHER slot and moves `evicted_`. First shift:
//     **`B + D + 1`**.
//   * Mode B — BIRTH + PUBLISH. Every address is born AND immediately
//     published (`noteMeshChange(addr, Position)`), so the WATCHER fills
//     directly — the birth table's own ceiling never enters the count.
//     First shift: **`D + 1`**, independent of `B`.
//
// THE DISCRIMINATING TABLE (three hypotheses, three DIFFERENT number pairs
// whenever `B != D` — this is what makes the measurement able to tell them
// apart rather than just confirm one):
//
//   observed (A, B)        | conclusion
//   ------------------------+---------------------------------------------
//   (B+D+1, D+1)            | the module header's chain is right: the
//                           | eviction cliff is owned by `D`, chained
//                           | through `B`'s free-slot arm
//   (B+1, B+1)              | `observe()`'s free-slot arm reads wrong —
//                           | both modes would bottleneck on `B` alone
//   (2*D+1 while B != D)    | the OLD (wrong) reading: the watcher counts
//                           | something else, re-read `note()` before
//                           | trusting this file's own formulas
//   neither mode shifts by  | `resetMeshDirtyStateForTest()` is broken, or
//   `B + 2*D`               | the churn addresses collided — fix the RIG,
//                           | not the conclusion
//
// ZERO literal `32`, ZERO `2*D` AS A CLIFF LOCATION — both ceilings are read
// through `meshBirthSlotCeiling()`/`meshDirtySlotCeiling()`, never assumed.
// `B + 2*D` appears exactly once, as the SWEEP WIDTH (how far to look), which
// is deliberately wider than either formula so the cliff stays inside the
// window even if `B != D` or `D` is raised.
module tests.unit.mesh_dirty_cliff_series_test;

import mesh_dirty : g_geomEpochs, noteMeshBirth, noteMeshChange,
                     meshDirtySlotCeiling, meshBirthSlotCeiling,
                     meshBirthsRecorded, resetMeshDirtyStateForTest;
import mesh_edit_delta : MeshEditScope;
import std.format : format;

// An address range far from every other cell's constants in this module
// (`0x1000`/`0x2000`/`0xE0_0000`/`0x00ABA000`/`0xB0_1906_2D`) — collisions
// would not corrupt the LAW (each measurement resets first), only the
// diagnostic addresses printed on failure, and distinctness keeps those
// readable.
private enum size_t kChurnBase = 0x00_DC00_0000;
private enum size_t kChurnStride = 0x40;
private enum size_t kBgAddr = 0x00_DBFF_0000;   // never born, never published

/// Mode A: births only. Returns the 1-based N at which `epochFor(kBgAddr)`
/// first differs from its post-reset baseline, or -1 if it never does within
/// `upTo` births.
private int firstShiftModeA(int upTo) {
    resetMeshDirtyStateForTest();
    const ulong baseline = g_geomEpochs.epochFor(kBgAddr);
    foreach (i; 1 .. upTo + 1) {
        noteMeshBirth(kChurnBase + i * kChurnStride, 100_000UL + i);
        if (g_geomEpochs.epochFor(kBgAddr) != baseline) return i;
    }
    return -1;
}

/// Mode B: birth + publish. Same shape, but the watcher fills directly.
private int firstShiftModeB(int upTo) {
    resetMeshDirtyStateForTest();
    const ulong baseline = g_geomEpochs.epochFor(kBgAddr);
    foreach (i; 1 .. upTo + 1) {
        const size_t a = kChurnBase + i * kChurnStride;
        noteMeshBirth(a, 200_000UL + i);
        noteMeshChange(a, MeshEditScope.Position);
        if (g_geomEpochs.epochFor(kBgAddr) != baseline) return i;
    }
    return -1;
}

/// The discriminating message, built once so both cells below say the same
/// thing about what a wrong number means.
private string hypothesisMessage(string modeLabel, int observed, int expected,
                                  int B, int D)
{
    return format(
        "task 1932 mode %s: first eviction-driven epoch shift observed at "
      ~ "N=%d, expected N=%d (B=%d, D=%d, sweep to B+2*D=%d).\n"
      ~ "  Read against the discriminating table:\n"
      ~ "    (B+D+1, D+1) for (A, B) -> the header's chain is right\n"
      ~ "    (B+1, B+1)             -> observe()'s free-slot arm is wrong\n"
      ~ "    2*D+1 while B!=D       -> re-read note(), do not trust 2*D\n"
      ~ "    neither shifts by B+2*D -> the RIG is broken (reset or churn "
      ~ "addresses), not the law",
        modeLabel, observed, expected, B, D, B + 2 * D);
}

unittest {
    const int B = meshBirthSlotCeiling();
    const int D = meshDirtySlotCeiling();
    const int upTo = B + 2 * D;

    // PREMISE: the two ceilings this file reads are the ones the module
    // actually uses — a scanner that read a stale build artifact or a
    // shadowed symbol would fail here instead of producing a confusing
    // formula mismatch below.
    assert(B > 0 && D > 0, format(
        "meshBirthSlotCeiling()/meshDirtySlotCeiling() returned non-positive "
      ~ "values (B=%d, D=%d) — the accessors are broken, not the cliff", B, D));

    const int shiftA = firstShiftModeA(upTo);
    assert(shiftA == B + D + 1,
        hypothesisMessage("A (births only)", shiftA, B + D + 1, B, D));

    const int shiftB = firstShiftModeB(upTo);
    assert(shiftB == D + 1,
        hypothesisMessage("B (birth + publish)", shiftB, D + 1, B, D));
}

// ---------------------------------------------------------------------------
// THE RESET SEAM'S OWN CONTROL. `firstShiftModeA` opens with
// `resetMeshDirtyStateForTest()` precisely so this file's own measurement is
// independent of how many `Layer`s every OTHER module in this test binary
// constructed before this one ran (`mesh_dirty.d`'s own header: "the unit
// binary constructs a Layer at ~248 sites"). Proving the seam actually
// clears the state — rather than merely compiling — needs two measurements
// in the SAME process where a broken reset could not coincidentally agree:
// if `resetMeshDirtyStateForTest()` were a no-op, the second call's "reset"
// would leave the FIRST sweep's now-evicted tables in place, so the second
// sweep's births would hit the birth table's FULL arm on attempt ONE and
// shift the watcher almost immediately — nowhere near `B + D + 1` twice in a
// row.
//
// Mutation this is the red for: empty out `resetMeshDirtyStateForTest`'s
// body in `source/mesh_dirty.d`. The premise assert fires on the SECOND
// call, reporting the corrupted N.
// ---------------------------------------------------------------------------
unittest {
    const int B = meshBirthSlotCeiling();
    const int D = meshDirtySlotCeiling();
    const int upTo = B + 2 * D;

    const int first  = firstShiftModeA(upTo);
    const int second = firstShiftModeA(upTo);
    assert(first == second, format(
        "the reset seam control: two identical mode-A sweeps in the same "
      ~ "process produced DIFFERENT first-shift N (%d then %d). "
      ~ "resetMeshDirtyStateForTest() is not clearing every table it owns — "
      ~ "the second sweep started from state the first sweep left behind",
        first, second));
    assert(first == B + D + 1, format(
        "PREMISE for the control above: a single mode-A sweep must land on "
      ~ "B+D+1=%d to be a meaningful control; got %d, which means the main "
      ~ "cell above already failed for a different reason", B + D + 1, first));
}

// ---------------------------------------------------------------------------
// `meshBirthsRecorded()`'s own consumer (R3-3): with the suite-tier stand's N
// fixed rather than derived from this counter (task 1932 review round 3,
// R3-1), nothing on the suite tier reads it any more. It still needs ONE
// consumer, or it is exactly the "presence bit with no consumer" shape that
// got `surfBvhRebuilds` deleted from this same card's §4.2 — this cell is
// that consumer, checked at the tier where the counter's own claim (flat,
// NON-saturating, exactly one increment per `observe()` call) can be
// verified directly rather than assumed.
// ---------------------------------------------------------------------------
unittest {
    // TASK 1932 (review fix 1) — THE RESET SEAM MUST NOT HAND-LIST THE
    // WATCHERS. `resetMeshDirtyStateForTest` sweeps `allWatchers()`; this cell
    // refuses a `__gshared MeshDirtyEpochs` declared in `mesh_dirty.d` that
    // `allWatchers()` does not carry. Without it, a watcher added in another
    // lane (task 2000's `g_settledGeomEpochs`) merges textually clean and the
    // seam is silently incomplete — nothing else in either lane would redden.
    //
    // Text scan, deliberately: the declarations are `__gshared` globals, so
    // there is no reflection that enumerates them, and a count taken from the
    // same list the body uses would be the check that cannot come out
    // differently.
    import std.file    : readText;
    import std.path    : buildPath, dirName;
    import std.algorithm : count, canFind;
    import std.string  : splitLines, strip, startsWith, indexOf;
    import std.format  : format;

    enum string kRepoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    const src = readText(buildPath(kRepoRoot, "source", "mesh_dirty.d"));

    string[] declared;
    foreach (ln; src.splitLines) {
        const t = ln.strip;
        if (!t.startsWith("__gshared MeshDirtyEpochs ")) continue;
        auto rest = t["__gshared MeshDirtyEpochs ".length .. $].strip;
        const cut = rest.indexOf(' ');
        declared ~= (cut < 0 ? rest : rest[0 .. cut]);
    }
    assert(declared.length >= 3, format(
        "PREMISE: the scan found %d `__gshared MeshDirtyEpochs` declarations in "
      ~ "source/mesh_dirty.d; this module declares at least three (display / "
      ~ "geometry / topology), so a smaller number means the scan broke, not "
      ~ "that the watchers went away", declared.length));

    // The body of `allWatchers()` — the one list everything else sweeps.
    const bodyStart = src.indexOf("MeshDirtyEpochs*[] allWatchers()");
    assert(bodyStart >= 0, "PREMISE: allWatchers() must exist in mesh_dirty.d");
    const bodyEnd = src.indexOf("\n}", bodyStart);
    const listing = src[bodyStart .. bodyEnd];

    foreach (name; declared)
        assert(listing.canFind("&" ~ name), format(
            "task 1932: `__gshared MeshDirtyEpochs %s` is declared in "
          ~ "source/mesh_dirty.d but `allWatchers()` does not carry it, so "
          ~ "`resetMeshDirtyStateForTest()` leaves it dirty and every cell that "
          ~ "resets between sweeps reads another module's leftovers. Add "
          ~ "`&%s` to allWatchers() in the same change that declares the "
          ~ "watcher (this is exactly what a parallel lane adding a fourth "
          ~ "watcher merges through cleanly).", name, name));
}

unittest {
    resetMeshDirtyStateForTest();
    assert(meshBirthsRecorded() == 0,
        "PREMISE: resetMeshDirtyStateForTest() must zero the birth counter too");

    // MUST exceed the BIRTH ceiling, or a saturating counter reads correct by
    // accident: at B = 32 a literal 50 catches saturation, at B = 64 it does
    // not — and §4.5 steers the owner to RAISE a ceiling. Derived, and the
    // relation is asserted rather than assumed.
    const int kN = meshBirthSlotCeiling() + 18;
    assert(kN > meshBirthSlotCeiling(),
        "PREMISE: this cell needs kN above the birth ceiling, or a saturating "
      ~ "counter reads correct by accident");
    foreach (i; 1 .. kN + 1)
        noteMeshBirth(kChurnBase + i * kChurnStride, 300_000UL + i);

    assert(meshBirthsRecorded() == kN, format(
        "meshBirthsRecorded() must count every observe() call exactly once "
      ~ "and NOT saturate at the table ceiling — got %d after %d births",
        meshBirthsRecorded(), kN));
}
