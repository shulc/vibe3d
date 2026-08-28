// batchless_control_helpers — the ONE name of the still-batchless command that
// ten suite tests use as the positive control for
// `changeBus.unbatchedGeometryCommits`.
//
// WHY A SHARED CONSTANT AND NOT TEN LITERALS. Every one of those tests asserts
// some counter did NOT move, and a dead counter satisfies that for free — so
// each runs one command that DOES move it, in the same process. That command
// has to be one task 1903 has not migrated yet, and task 1903 is migrating all
// of them. The control has therefore been re-based FIVE times:
//
//   1. `mesh.flip`      — until stage L2-a gave it a batch
//   2. `mesh.addVertex` — until stage L2-g
//   3. `mesh.subdivide` — until stage L5's own commit
//   4. `mesh.triple`    — until stage L10-P0, which gave a batch to all NINE
//                         remaining topo-misc commands at once
//   5. `mesh.clone`     — until stage L6-P0, which gave a batch to all FIVE
//                         members of the duplication family. Stage L10-P0 had
//                         picked it over `mesh.array`/`mesh.mirror` on the
//                         ground that those three were "one family with one
//                         migration stage (L6) ahead of them"; `mesh.clone` is
//                         in that same family, so the pick spent the sixth
//                         re-base anyway. Named here because the reasoning was
//                         right and the reading of the roster was wrong, and
//                         the next picker should check the FAMILY, not the
//                         command.
//   6. `mesh.edgeSlice` — this one
//
// The fourth re-base is what produced this file. `mesh.triple` was written as a
// literal in TEN test files, and stage L10-P0 turned all ten red in one run —
// nine of them in the full suite, one (`test_fix_orientation`) already carrying
// the comment that predicted it. Editing ten files to change one word is not a
// fix; it is the same edit deferred to the sixth re-base. So the name lives
// here once, and the sixth re-base is a one-line change.
//
// THE RULE, unchanged from where it was first written down
// (`tests/test_fix_orientation.d`): when this control goes quiet, NAME ANOTHER
// STILL-BATCHLESS COMMAND. Never delete the control — it is the only thing
// standing between those tests' assertions and a dead counter. Find a
// replacement with:
//
//     grep -L MeshEditBatch source/commands/mesh/*.d
//
// and confirm by measurement, not by reading: drive it through
// `/api/command` on a fresh reset and check `/api/changes`'s
// `unbatchedGeometryCommits` actually moves. Several batchless commands refuse
// on a default cube and tick nothing.
module batchless_control_helpers;

/// The command id. MEASURED on 2026-08-28 through `/api/command` on this
/// build, port 8860: `mesh.edgeSlice` with the body below ticks **4**, and it
/// ticks 4 from a VERTEX-mode, an EDGE-mode and a POLYGON-mode selection
/// alike, which matters because the ten call sites reach it in all three. On
/// the same build after stage L6-P0: `mesh.clone` 0, `mesh.array` 0,
/// `mesh.mirror` 0, `mesh.duplicate` refuses on a bare cube; `mesh.remove` 0;
/// `mesh.hide` and `mesh.move_vertex` apply but tick 0, because the counter is
/// GEOMETRY-class only and those publish Marks and Position.
///
/// THIS ONE TAKES PARAMETERS, which the previous five did not, so
/// `kBatchlessControlJson` is now the ONLY correct way to post it —
/// `mesh.edgeSlice` refuses outright without a two-element `edges` list
/// (`edge_slice.d`: `if (edges_.length != 2) return false;`) and a refused
/// command ticks nothing, which would make all ten controls silently dead.
/// The two call sites that used to post the bare id
/// (`tests/test_axis_slice.d`, `tests/test_reduce.d`) were changed to post the
/// body; `kBatchlessControlCommand` survives for the assertion MESSAGES only.
enum string kBatchlessControlCommand = "mesh.edgeSlice";

/// The JSON body for `/api/command`. POST THIS, never the bare id — see above.
/// Edges 0 and 2 of a default cube are opposite edges of the same face, which
/// is what `mesh.edgeSlice` needs; `tA`/`tB` are its defaults, spelled out so a
/// future change to those defaults cannot silently move what this control
/// does.
enum string kBatchlessControlJson =
    `{"id":"` ~ kBatchlessControlCommand
  ~ `","params":{"edges":[0,2],"tA":0.5,"tB":0.5}}`;

/// The shared half of every one of those ten assertion messages, so a red says
/// the same thing everywhere and names the one place to edit.
enum string kBatchlessControlWhy =
    "positive control: an UNBATCHED command must tick "
  ~ "unbatchedGeometryCommits, and " ~ kBatchlessControlCommand ~ " ticked ";

/// ditto — the tail.
enum string kBatchlessControlFix =
    ". Either the counter is dead — in which case the assertion(s) this "
  ~ "control guards pass for free — or " ~ kBatchlessControlCommand
  ~ " has been migrated and the control needs re-basing onto another "
  ~ "still-batchless command. It is TWO lines and both are in "
  ~ "tests/batchless_control_helpers.d: `kBatchlessControlCommand` and the "
  ~ "params inside `kBatchlessControlJson` (task 1903 §3.2 L2, M-DM). Find a "
  ~ "candidate with `grep -rL MeshEditBatch source/commands/`, keep only the "
  ~ "ones that publish MeshEditScope.Geometry, and CONFIRM BY MEASUREMENT "
  ~ "over /api/command — several batchless commands refuse on a default cube, "
  ~ "and two more (mesh.hide, mesh.move_vertex) apply and still tick 0 "
  ~ "because they publish Marks and Position rather than Geometry.";
