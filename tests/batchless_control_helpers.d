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
//   5. `mesh.clone`     — this one
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

/// The command id. MEASURED on 2026-08-28 through `/api/command` on a fresh
/// reset with face 0 selected: `mesh.clone` ticks **2**, against
/// `mesh.triple` 0, `mesh.quadruple` 0 and `mesh.detriangulate` 0 after stage
/// L10-P0, and `mesh.array` 6 / `mesh.mirror` 7 as the other live candidates.
///
/// `mesh.clone` was chosen over those two because `array` / `radialArray` /
/// `mirror` are one family with one migration stage (L6) ahead of them, which
/// would spend the sixth re-base and the seventh on the same commit.
enum string kBatchlessControlCommand = "mesh.clone";

/// The JSON body for `/api/command`, for the tests that post one.
enum string kBatchlessControlJson = `{"id":"` ~ kBatchlessControlCommand ~ `"}`;

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
  ~ "still-batchless command. It is ONE line: "
  ~ "`kBatchlessControlCommand` in tests/batchless_control_helpers.d "
  ~ "(task 1903 §3.2 L2, M-DM).";
