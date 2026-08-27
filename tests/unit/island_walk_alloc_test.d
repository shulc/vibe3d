// The island/component walk's allocation bound (task 2130).
//
// WHAT THIS PINS, AND WHY A GEOMETRY TEST CANNOT. Four depth-first walks in
// this tree were written as
//
//     size_t[] stack = [fi];
//     while (stack.length) {
//         auto cur = stack[$ - 1];
//         stack = stack[0 .. $ - 1];      // shrink the slice
//         ...  stack ~= nb;               // append to the shrunk slice
//     }
//
// In D, `~=` extends a GC block in place only while `ptr + length` equals the
// used-length recorded in that block. `stack = stack[0 .. $ - 1]` breaks that
// equality, so the FIRST push after EVERY pop reallocates and copies the whole
// stack. The traversal is correct — it visits the same faces in the same order
// and returns the same components — so every assertion about the RESULT is
// green on the slow code and witnesses nothing. The only observable is
// ALLOCATED BYTES, which is what this module measures.
//
// THE INSTRUMENT. `GC.allocatedInCurrentThread` (task 2070) is a thread-local
// running COUNTER, not a sample: it is exact, needs no warm-up, and its
// run-to-run spread was measured at 0.04% against RSS's 40-400%. A unittest
// runs on the main thread, so bracketing the call reads that call's own
// allocation and nothing else.
//
// WHY `faceComponentsOf` IS THE CELL. Of the four sites it is the only one
// reachable from a unit lane: it is a `static` over two plain arrays, so the
// walk can be driven with a synthetic adjacency and no Mesh, no GL and no
// document. Nothing else allocates inside it, so the bound is about the walk
// rather than about geometry the walk happens to sit next to. The other three
// sites (extrudeFacesByMask, smoothShiftFacesByMask, extrudePathStep_) are
// private inside their kernels and are measured instead by the ops lane's
// per-command `gcAllocBytes` column.
//
// EVERY BLOCK IS SEPARATE ON PURPOSE. druntime aborts a module at its FIRST
// failing assert, so blocks merged for brevity would hide each other under a
// mutation; split, each one names its own reason.
module tests.unit.island_walk_alloc_test;

import core.memory : GC;
import std.format : format;
import mesh : Mesh;

// R x R quads with 8-neighbour (shared-vertex) adjacency — the relation
// `Mesh.faceAdjacencySharingVertex` produces for a quad grid, built directly
// so the fixture costs nothing and holds no Mesh. All faces wanted, so this is
// ONE component and the walk is one long DFS rather than R*R trivial ones.
private int[][] gridAdj(int R) {
    auto adj = new int[][](R * R);
    foreach (r; 0 .. R) foreach (c; 0 .. R) {
        int[] nb;
        foreach (dr; -1 .. 2) foreach (dc; -1 .. 2) {
            if (dr == 0 && dc == 0) continue;
            immutable int rr = r + dr, cc = c + dc;
            if (rr < 0 || rr >= R || cc < 0 || cc >= R) continue;
            nb ~= rr * R + cc;
        }
        adj[r * R + c] = nb;
    }
    return adj;
}

// BLOCK ORDER IS LOAD-BEARING. druntime aborts a module at its FIRST
// failing assert, so the cheap identity checks are declared BEFORE the
// expensive measurement: on the broken code the order pin and the
// component-identity pin must both be seen GREEN, and only then the
// allocation bound RED. Declared the other way round, a wrong frozen
// order would hide behind the allocation failure and only surface after
// the fix, where it would be indistinguishable from the fix having
// changed the order.

unittest { // the rig really is one big component — anti-vacuity for the bound below
    // A bound on allocated bytes is trivially satisfied by a walk that does
    // nothing. Before believing the number, prove the traversal is the shape
    // the bound is about: ONE component containing EVERY face, i.e. a single
    // DFS that pushes and pops R*R times rather than R*R one-element walks
    // (which would never grow a stack and could not exhibit the defect).
    enum int R = 200;
    auto adj = gridAdj(R);
    auto want = new bool[](R * R);
    want[] = true;
    auto comps = Mesh.faceComponentsOf(want, adj);
    assert(comps.length == 1,
        format("the alloc rig must be ONE component or it cannot exhibit the "
             ~ "quadratic push/pop; got %d", comps.length));
    assert(comps[0].length == R * R,
        format("the single component must hold every face; got %d of %d",
               comps[0].length, R * R));
}

unittest { // the traversal ORDER is frozen — a faster walk must not renumber
    // `faceComponentsOf` documents its components as "arbitrary-order", but
    // `select.fill`, `remesh_job` and `fillSelectionHoles` consume them, and a
    // reordering would move downstream results silently. So the order is
    // pinned here rather than left to the doc comment: this exact sequence is
    // what the shipped LIFO walk produced BEFORE task 2130 touched it, and the
    // fix is required to reproduce it byte for byte.
    //
    // It is a discriminating sequence on purpose — neither sorted nor the
    // natural face order — so a pop discipline that changed from LIFO to FIFO,
    // or a push order that reversed, cannot land on it by chance.
    auto adj = gridAdj(3);
    auto want = new bool[](9);
    want[] = true;
    auto comps = Mesh.faceComponentsOf(want, adj);
    assert(comps.length == 1);
    immutable uint[] expected = [0, 4, 8, 7, 6, 5, 2, 3, 1];
    assert(comps[0] == expected,
        format("the component walk's visit order changed: expected %s, got %s. "
             ~ "Island numbering and region splits ride on this order — if the "
             ~ "change is intended, re-derive every consumer, do not re-bless "
             ~ "this line.", expected, comps[0]));
}

unittest { // component IDENTITY across a gap — the walk still separates islands
    // A cheap guard that the allocation work above did not buy its speed by
    // merging components: two disjoint chains must stay two components, in
    // ascending start order.
    auto adj = new int[][](6);
    adj[0] = [1];  adj[1] = [0, 2];  adj[2] = [1];
    adj[3] = [4];  adj[4] = [3, 5];  adj[5] = [4];
    auto want = new bool[](6);
    want[] = true;
    auto comps = Mesh.faceComponentsOf(want, adj);
    assert(comps.length == 2, format("two chains must stay two components; got %d",
                                     comps.length));
    assert(comps[0] == [0u, 1u, 2u], format("first component: %s", comps[0]));
    assert(comps[1] == [3u, 4u, 5u], format("second component: %s", comps[1]));
}
unittest { // THE WITNESS: the component walk must not allocate quadratically
    // BOUND: 8 MiB for a 40 000-face single-component walk.
    //
    // Measured on this rig, 2026-08-27, with the same instrument:
    //   shrink-then-append (before the fix) ....  770 469 328 B  (734.8 MB)
    //   explicit stack pointer (after) .........      368 496 B  (  0.35 MB)
    //
    // The bound sits between them by orders of magnitude in BOTH directions —
    // 22x of headroom over the fixed code (so ordinary growth, a different GC
    // page size or an extra scratch array cannot redden it by accident) and
    // 88x under the broken code (so the defect cannot creep back under it).
    // It is NOT derived from the measurement it judges: it is a round number
    // chosen inside a 2000x gap.
    enum int R = 200;
    enum ulong kBoundBytes = 8UL * 1024 * 1024;

    auto adj = gridAdj(R);
    auto want = new bool[](R * R);
    want[] = true;

    // Bracket ONLY the call — the fixture above is fixture, not walk.
    immutable ulong before = GC.allocatedInCurrentThread;
    auto comps = Mesh.faceComponentsOf(want, adj);
    immutable ulong used = GC.allocatedInCurrentThread - before;

    // Keep the result live so nothing can be elided out of the bracket.
    assert(comps.length == 1);

    assert(used < kBoundBytes,
        format("faceComponentsOf allocated %s B (%.2f MB) walking %d faces in "
             ~ "one component; the bound is %s B (%.2f MB). This is the "
             ~ "shrink-then-append defect (task 2130): `stack = stack[0 .. $-1]` "
             ~ "breaks the GC's in-place-append invariant, so the first push "
             ~ "after every pop reallocates and copies the whole stack. Use an "
             ~ "explicit stack pointer — never shrink the slice.",
               used, used / (1024.0 * 1024.0), R * R,
               kBoundBytes, kBoundBytes / (1024.0 * 1024.0)));
}

