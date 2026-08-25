// render_ipr_bus_witness_test — the IPR SUBSCRIBES to the change bus and does
// NOT poll a `mesh_dirty` epoch (task 1906 stage 2e,
// `doc/bus_sync_listeners_plan.md` §3.5 row 22).
//
// WHY THIS IS A TEXT CENSUS AND NOT A BEHAVIOURAL TEST. `source/render/
// render_mvp.d` is `version (WithRender)`: it is excluded from the default
// `modeling` build and from BOTH gate lanes, so no routine change compiles it,
// let alone runs it. Reading it is the only instrument the lane that DOES run
// has for a file that lane cannot build.
//
// WHY IT IS NEEDED AT ALL, given the `static assert` already in that file.
// Because that assert pins the row's PREMISE, not its DECISION, and the two
// come apart — measured at the 2e review fold, not reasoned about:
//
//     premise   no `mesh_dirty` watcher mask covers the IPR's trigger set
//     decision  therefore the IPR keeps a plain bus subscription and does not
//               key on an epoch
//
// Reverse the DECISION — delete the `changeBus.onMeshChanged` registration,
// poll `g_displayEpochs.epochFor` in its place — and the premise is untouched:
// the static assert still holds, `dmd -o- -c -version=WithRender` is still
// exit 0, and the version-poll census stays green because an epoch compare
// names no version counter. Nothing in the tree went red. A decision recorded
// in a plan table and guarded by nothing is a decision that gets undone by the
// next person who finds the subscription surprising.
//
// WHAT IT ASSERTS. Two halves, and the reversal above breaks both, which is
// the point — each is the negative of the other's failure mode:
//
//   1. the registration EXISTS (`changeBus.onMeshChanged(`);
//   2. no epoch TABLE is named (`g_displayEpochs` / `g_geomEpochs` /
//      `g_topoEpochs`).
//
// Half 2 is about the tables, NOT the masks. `render_mvp.d` legitimately names
// `DisplayEpochMask` / `GeomEpochMask` / `TopoEpochMask` — that is the static
// assert reading the premise — and naming a mask is not polling an epoch. The
// distinction is the whole reason the masks were hoisted to named enums at 2e.
//
// COMMENTS ARE STRIPPED FIRST, with the version-poll census's stripper (one
// stripper, so a fix to it reaches both). That is not tidiness: the note above
// the static assert discusses the epoch tables at length and BY NAME, so on
// raw text half 2 would be red for the prose that explains why it is green.
// The failure mode is real and this file would have hit it on day one.
module tests.unit.render_ipr_bus_witness_test;

import std.algorithm : canFind;
import std.file      : exists, readText;
import std.format    : format;
import std.path      : buildPath, dirName;

import tests.unit.version_poll_census_test : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    const string path = buildPath(repoRoot, "source", "render", "render_mvp.d");
    assert(path.exists, format(
        "%s is gone. If the IPR moved, move this witness with it — do not "
      ~ "delete it: it is the only check in either gate lane that sees task "
      ~ "1906 §3.5 row 22's decision at all (the file is version (WithRender) "
      ~ "and neither lane compiles it).", path));

    const string code = blankNonCode(readText(path));

    // Half 1 FIRST, and it doubles as the anti-vacuity floor: if the stripper
    // ever ate the file, or the path stopped resolving to real content, this
    // is what says so — before half 2 can pass for having nothing to read.
    assert(code.canFind("changeBus.onMeshChanged("), format(
        "task 1906 §3.5 row 22: %s no longer registers a change-bus "
      ~ "subscriber. The IPR's freshness signal IS that subscription — it "
      ~ "REACTS (ORing classes into two accumulators cleared at two different "
      ~ "moments), which is why it took no `mesh_dirty` epoch. If the IPR "
      ~ "genuinely moved to another mechanism, re-make row 22's argument in "
      ~ "doc/bus_sync_listeners_plan.md §3.5 and rewrite this witness; if this "
      ~ "went red by accident, the subscription was deleted.", path));

    // Half 2. The TABLES, not the masks: naming `DisplayEpochMask` in the
    // static assert is the premise being read and is expected here.
    static immutable string[] kEpochTables =
        ["g_displayEpochs", "g_geomEpochs", "g_topoEpochs"];
    foreach (t; kEpochTables) {
        assert(!code.canFind(t), format(
            "task 1906 §3.5 row 22: %s now names the epoch table `%s` in "
          ~ "CODE. Row 22 decided the IPR does NOT key on a `mesh_dirty` "
          ~ "epoch, on two independent grounds: no watcher mask covers its "
          ~ "trigger set (`Marks` and `Material` are the classes that fall "
          ~ "out), and the shape is wrong anyway — `mesh_dirty` serves "
          ~ "consumers that COMPARE at a lazy recompute, keyed by ONE mesh "
          ~ "address, while the IPR REACTS and its subject is the flattened "
          ~ "DOCUMENT. Both grounds have to be re-made in §3.5 before this "
          ~ "assert comes out. (Comments were stripped, so the note in that "
          ~ "file explaining all of this cannot be what tripped this.)",
            path, t));
    }
}
