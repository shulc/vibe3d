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
//   6. `mesh.edgeSlice` — until stage L4-P0, which gave a batch to the two
//                         slice/cut commands that still held none
//                         (`mesh.edgeSlice`, `mesh.cut`)
//   7. `mesh.paste`     — this one, and it is the LAST one-of-its-kind: after
//                         L4 there is no batchless GEOMETRY-class command left
//                         that a single POST can drive. See "THE POOL IS
//                         EXHAUSTED" below.
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

/// THE POOL IS EXHAUSTED, and that is why this control is a SEQUENCE.
///
/// MEASURED on 2026-08-28 on this build, port 8880, over `/api/command`, after
/// stage L4-P0: `grep -rL 'MeshEditBatch\|beginEditBatch' source/commands/*/*.d`
/// leaves exactly THREE mesh-mutating candidates, and only one of them still
/// commits `MeshEditScope.Geometry` outside a frame:
///
///   * `mesh.cut`, `mesh.edgeSlice` — batched by L4-P0 itself (`mesh.cut` 2 -> 0,
///     `mesh.edgeSlice` 4 -> 0, measured before and after on that commit);
///   * `mesh.paste` — still batchless, ticks **2**;
///   * everything else measured on the same build ticks **0**:
///     `mesh.subpatch_toggle`, `mesh.hide`, `mesh.remove` (it opens a
///     handle-less `beginEditBatch`, which `grep -L MeshEditBatch` does not
///     see), `mesh.setMaterial`, `select.expand`, `select.fill.holes`,
///     `layer.duplicate`; and `mesh.move_vertex` / `mesh.vertex_new` refuse
///     outright on a bare cube.
///
/// `mesh.paste` REFUSES on an empty clipboard, so unlike all six predecessors it
/// cannot be driven by one POST — and the clipboard does NOT survive
/// `/api/reset` (measured: reset then paste refuses, even after a copy). The
/// control therefore becomes an ORDERED SEQUENCE, `kBatchlessControlSeq`, and
/// every call site posts EVERY element of it in order. That is the one-line
/// change at each of the ten sites; the EIGHTH re-base is again a change to
/// this file alone.
///
/// WHAT THE SEQUENCE DOES, and each element is load-bearing:
///
///   1. `select.typeFrom polygon` — `mesh.copy` refuses in Edges mode outright
///      and needs a live vertex selection in Vertices mode; in Polygons mode an
///      EMPTY selection means the whole mesh (`operandFaceMask`), so this is
///      what makes the control drivable from ANY starting mode. Measured: the
///      sequence ticks 2 starting from vertex, edge and polygon alike, which
///      matters because the ten call sites reach it in all three.
///   2. `mesh.copy` — fills the clipboard from the whole mesh. Ticks nothing:
///      it mutates no geometry.
///   3. `mesh.paste` — THE CONTROL. Ticks `unbatchedGeometryCommits` by 2.
///   4. `history.undo` — puts the mesh back. Measured: V 8 F 6 before and
///      after on a default cube, i.e. BYTE-RESTORED, which the six predecessors
///      never were (`mesh.edgeSlice` left the cube sliced and `mesh.triple`
///      left it triangulated). Two of the ten call sites — `test_reduce.d` and
///      `test_fix_orientation.d` — run their own measured command on whatever
///      mesh the control left behind, so this element is what keeps the
///      re-base from changing what those two measure.
///
/// The one side effect that SURVIVES the sequence is the edit MODE: it is
/// Polygons afterwards. Every call site either reloads its stand or sets its
/// own selection type before the assertion it cares about; that was checked
/// site by site when this re-base was taken.
enum string kBatchlessControlCommand = "mesh.paste";

/// The ordered bodies to POST, all of them, in order. The element that actually
/// ticks the counter is `kBatchlessControlJson`; the others are its
/// preconditions and its clean-up. Read the sequence, never one element.
///
/// POST EVERY ELEMENT. A site that posts only the last one measures a REFUSED
/// command, which ticks nothing — and a control that ticks nothing makes the
/// assertion it guards pass for free, which is the exact failure this file
/// exists to prevent.
enum string[] kBatchlessControlSeq = [
    `select.typeFrom polygon`,
    `mesh.copy`,
    `{"id":"mesh.paste"}`,
    `history.undo`,
];

/// The body of the element that ticks — kept as its own name because the
/// assertion MESSAGES quote it and because a site that wants to say "this is
/// the control" in a comment should have one thing to point at.
enum string kBatchlessControlJson = kBatchlessControlSeq[2];

/// The shared half of every one of those ten assertion messages, so a red says
/// the same thing everywhere and names the one place to edit.
enum string kBatchlessControlWhy =
    "positive control: an UNBATCHED command must tick "
  ~ "unbatchedGeometryCommits, and the " ~ kBatchlessControlCommand
  ~ " sequence ticked ";

/// ditto — the tail.
enum string kBatchlessControlFix =
    ". Either the counter is dead — in which case the assertion(s) this "
  ~ "control guards pass for free — or " ~ kBatchlessControlCommand
  ~ " has been migrated and the control needs re-basing onto another "
  ~ "still-batchless command. It is ONE line and it is in "
  ~ "tests/batchless_control_helpers.d: `kBatchlessControlSeq` (task 1903 "
  ~ "§3.2 L2, M-DM). Find a candidate with "
  ~ "`grep -rL 'MeshEditBatch\\|beginEditBatch' source/commands/*/*.d`, keep "
  ~ "only the ones that publish MeshEditScope.Geometry, and CONFIRM BY "
  ~ "MEASUREMENT over /api/command — several batchless commands refuse on a "
  ~ "default cube, and others (mesh.hide, mesh.move_vertex, mesh.setMaterial) "
  ~ "apply and still tick 0 because they publish Marks, Position or Material "
  ~ "rather than Geometry. If NOTHING is left, the control has to become "
  ~ "something other than a command and the ten assertions it guards each need "
  ~ "their own anti-vacuity channel — do not simply delete it. Another "
  ~ "possibility, and it is the cheaper one to check first: this site posted "
  ~ "only `kBatchlessControlJson` instead of every element of "
  ~ "`kBatchlessControlSeq`, so the control ran refused.";
