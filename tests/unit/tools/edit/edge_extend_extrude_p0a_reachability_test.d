// Edge Extend / Edge Extrude — task 1905 Stage P0-a, the DEGENERATE-DELTA
// fallback's reachability, measured under the TOOL's own calling convention.
//
// WHAT THIS FILE IS FOR. `edge_extend.d`'s `commitEdit()` and its
// `edge_extrude.d` twin each re-run their kernel inside a RECORDING
// `MeshEditBatch` (`MeshEditBatch(*mesh, MeshEditScope.Geometry |
// MeshEditScope.Marks)` — never `.unrecorded`, which is the COMMAND's shape,
// not the tool's) and then branch on `delta.isEmpty`: non-empty takes the
// delta path, empty falls into a block whose own comment says it has "NO
// WITNESS IN EITHER LANE" (measured at 1903 Stage N with an `assert(false)`
// probe on the `edge_extrude.d` site). Until P0-a's instrument commit, the
// KERNEL's own return value (`extendEdgesByMask`/`extrudeEdgesByMask`,
// `size_t` = the number of edges the kernel actually touched) was discarded
// at the call site, so the tool could not tell "the kernel touched nothing"
// (`affected == 0`) apart from "the kernel touched something and the batch
// recorded none of it" (`affected > 0 && delta.isEmpty`) — see D2 and Б12 in
// doc/tasks/work/1905-tool-gesture-writes-through-session.md.
//
// This file answers the ONLY question the instrument commit needs answered
// to be worth landing: is `affected` a RELIABLE proxy for `delta.isEmpty`
// under the tool's own calling convention, or can the two diverge (which is
// exactly the state the degenerate-delta fallback is defending against)?
// It does that by reproducing `commitEdit()`'s exact kernel-call SHAPE
// (recording batch, same scope flags, `MeshEditBatch.extend/extrudeEdgesByMask`
// via the same free functions the tool calls) rather than driving the `Tool`
// class end to end: `EdgeExtendTool`/`EdgeExtrudeTool` need a live `GpuMesh*`
// (`commitEdit()` calls `refreshCaches()` → `refreshDisplay()` →
// `gpu.upload()`), and no file under `tests/unit/` constructs a `GpuMesh` —
// this binary has no GL context. `tests/unit/tools/edit/edge_extend_pivot_test.d`
// establishes the same idiom already (its "interactive case" unittest calls
// the free kernel function directly, distinguished from the "command case"
// only by which scope/pivot it is fed) — this file follows it rather than
// inventing a new one.
//
// THREE STANDS, both kernels:
//   A. a HAND-BUILT empty operand mask (`bool[]` of all `false`, matching
//      `mask.length == ed.edges.length`) — the literal "empty operand mask"
//      the plan asks for. `affected == 0` and `delta.isEmpty` both hold.
//   B. the TOOL's OWN mask derivation (`Mesh.operandEdgeMask()`, what
//      `currentMask()` calls) over a mesh with ZERO edges — the only mesh
//      state on which `operandEdgeMask()` can itself produce an empty mask,
//      because on any mesh WITH edges it falls back to "every visible edge"
//      when nothing is selected (`mesh.d`'s own doc comment on it: "the
//      selected edges when any are selected, ELSE EVERY VISIBLE edge"). This
//      is a MEASURED finding worth recording plainly: the tool can reach
//      `affected == 0` via a real user selection ONLY by having no edges to
//      select in the first place, never by "the user selected nothing".
//   C. a REALISTIC non-empty mask (one selected edge on a cube) at the
//      TOOL'S OWN reset defaults (extend: inset=0, shift=0, offset=0,
//      rotate=0, scale=1, segments=1; extrude: non-zero extrude/width — see
//      the note on stand D below) — the healthy path. `affected > 0` and
//      `!delta.isEmpty` both hold, i.e. the degenerate fallback is NOT
//      reached under ordinary tool operation.
//
// A FOURTH, extrude-only finding (stand D): `extrudeEdgesByMask` has a
// SECOND early return the plan's mask-only framing does not mention —
// `if (width < 1e-6f) return 0;` — a PARAMETER-driven no-op, independent of
// the mask. `EdgeExtrudeTool`'s own reset defaults are `extrude_ = width_ =
// 0.0f`, so an untouched, freshly-activated extrude tool sits exactly on
// this guard; the tool's own `if (extrude_ == 0.0f && width_ == 0.0f) return
// true; // no-op success` (`edge_extrude.d:303`) is presumed to keep such a
// session from ever reaching `commitEdit()` with a built preview, but that
// presumption is NOT checked by this file (it would need the `Tool` class,
// see above) — recorded here as a finding for whoever answers P0-a's
// disposition, not acted on.
//
// NO PRODUCTION BEHAVIOUR IS ASSERTED TO CHANGE BY THIS FILE — it measures
// the kernel property the instrument commit exists to make visible; it does
// not decide what the tool should do with `affected` (D2's product half is
// parked, owner's call).
//
// MUTATION DRILL (not a standing part of this file — see the P0-a task
// card's report for the exact line/message pair): stand C is discriminating
// because `mesh_ops/extrude.d`'s `if (exEdges.length == 0) return 0;` (the
// extend kernel) and its extrude twin's `if (exEdges.length == 0) return 0;`
// are the ONLY things standing between "a real selection" and "affected ==
// 0"; corrupting either guard's return value reddens the matching stand C
// cell with its own message, and reverting restores green.
module tests.unit.tools.edit.edge_extend_extrude_p0a_reachability_test;

import mesh;
import math : Vec3;
import std.conv : to;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A mask of `false` the same length as `m.edges` — the literal "empty
/// operand mask" (stand A). Distinct from `operandEdgeMask()`'s fallback,
/// which this file measures separately (stand B).
private bool[] handBuiltEmptyMask(ref Mesh m) {
    bool[] mask;
    mask.length = m.edges.length;
    return mask;
}

/// A cube with edge 0 selected — the smallest realistic non-empty operand
/// set, read back through the SAME `operandEdgeMask()` the tool's
/// `currentMask()` calls, not a hand-rolled mask.
private Mesh cubeWithOneEdgeSelected() {
    Mesh m = makeCube();
    if (m.edgeMarks.length < m.edges.length) m.resizeEdgeSelection();
    assert(m.edges.length > 0, "makeCube() must produce a mesh with edges");
    m.selectEdge(0);
    return m;
}

// ---------------------------------------------------------------------------
// EXTEND
// ---------------------------------------------------------------------------

unittest // P0-a extend, stand A: a hand-built empty operand mask
{
    auto m = makeCube();
    auto mask = handBuiltEmptyMask(m);

    auto ed = MeshEditBatch(m, kExtrudeEditScope);
    size_t affected = ed.extendEdgesByMask(mask, 0.1f, 0.0f,
        Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1, Vec3(0, 0, 0));
    auto delta = ed.close();

    assert(affected == 0,
        "extendEdgesByMask over an explicit all-false mask must report 0 "
      ~ "edges touched — got " ~ affected.to!string);
    assert(delta.isEmpty,
        "extendEdgesByMask over an explicit all-false mask recorded a "
      ~ "non-empty delta — the kernel mutated something with nothing "
      ~ "selected");
    assert((affected == 0) == delta.isEmpty,
        "affected and delta.isEmpty disagree on stand A — this is exactly "
      ~ "the state the degenerate-delta fallback exists to catch");
}

unittest // P0-a extend, stand B: operandEdgeMask()'s OWN empty case needs an edgeless mesh
{
    Mesh m;   // no vertices, no faces, no edges — default Mesh.init
    auto mask = m.operandEdgeMask();
    assert(mask.length == 0,
        "operandEdgeMask() on an edgeless mesh must itself be empty — got "
      ~ "length " ~ mask.length.to!string);

    auto ed = MeshEditBatch(m, kExtrudeEditScope);
    size_t affected = ed.extendEdgesByMask(mask, 0.1f, 0.0f,
        Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1, Vec3(0, 0, 0));
    auto delta = ed.close();

    assert(affected == 0,
        "extendEdgesByMask over an edgeless mesh's own operand mask must "
      ~ "report 0 edges touched");
    assert(delta.isEmpty,
        "extendEdgesByMask over an edgeless mesh's own operand mask "
      ~ "recorded a non-empty delta");
}

unittest // P0-a extend, stand C: the tool's own reset defaults over a real selection
{
    auto m = cubeWithOneEdgeSelected();
    auto mask = m.operandEdgeMask();
    size_t selected = 0;
    foreach (sel; mask) if (sel) ++selected;
    assert(selected == 1,
        "rig must select exactly one edge — this cell measures the "
      ~ "smallest realistic non-empty operand");

    // EXACT EdgeExtendTool reset defaults (edge_extend.d: inset_=0.0f,
    // shift_=0.0f, offset*=0, rotate*=0, scale*=1, segments_=1).
    auto ed = MeshEditBatch(m, kExtrudeEditScope);
    size_t affected = ed.extendEdgesByMask(mask, 0.0f, 0.0f,
        Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1, Vec3(0, 0, 0));
    auto delta = ed.close();

    assert(affected > 0,
        "MUTATION TARGET (stand C, extend): extendEdgesByMask over one real "
      ~ "selected edge at the tool's own reset defaults must report > 0 "
      ~ "edges touched, got 0 — the healthy path must not look degenerate");
    assert(!delta.isEmpty,
        "extendEdgesByMask over one real selected edge at the tool's reset "
      ~ "defaults recorded an EMPTY delta despite affected > 0 — this IS "
      ~ "the degenerate-delta fallback's condition, reached under ordinary "
      ~ "tool operation");
    assert((affected == 0) == delta.isEmpty,
        "affected and delta.isEmpty disagree on stand C");
}

// ---------------------------------------------------------------------------
// EXTRUDE
// ---------------------------------------------------------------------------

unittest // P0-a extrude, stand A: a hand-built empty operand mask
{
    auto m = makeCube();
    auto mask = handBuiltEmptyMask(m);

    auto ed = MeshEditBatch(m, kExtrudeEditScope);
    size_t affected = ed.extrudeEdgesByMask(mask, 0.5f, 0.2f);
    auto delta = ed.close();

    assert(affected == 0,
        "extrudeEdgesByMask over an explicit all-false mask must report 0 "
      ~ "edges touched");
    assert(delta.isEmpty,
        "extrudeEdgesByMask over an explicit all-false mask recorded a "
      ~ "non-empty delta");
    assert((affected == 0) == delta.isEmpty,
        "affected and delta.isEmpty disagree on stand A (extrude)");
}

unittest // P0-a extrude, stand B: operandEdgeMask()'s OWN empty case needs an edgeless mesh
{
    Mesh m;
    auto mask = m.operandEdgeMask();
    assert(mask.length == 0,
        "operandEdgeMask() on an edgeless mesh must itself be empty");

    auto ed = MeshEditBatch(m, kExtrudeEditScope);
    size_t affected = ed.extrudeEdgesByMask(mask, 0.5f, 0.2f);
    auto delta = ed.close();

    assert(affected == 0,
        "extrudeEdgesByMask over an edgeless mesh's own operand mask must "
      ~ "report 0 edges touched");
    assert(delta.isEmpty,
        "extrudeEdgesByMask over an edgeless mesh's own operand mask "
      ~ "recorded a non-empty delta");
}

unittest // P0-a extrude, stand C: a real selection at NON-ZERO extrude/width
{
    auto m = cubeWithOneEdgeSelected();
    auto mask = m.operandEdgeMask();
    size_t selected = 0;
    foreach (sel; mask) if (sel) ++selected;
    assert(selected == 1, "rig must select exactly one edge");

    // NOT the tool's reset defaults (extrude_=width_=0, see stand D below) —
    // a realistic post-drag pair, matching what a committed gesture actually
    // carries into commitEdit().
    auto ed = MeshEditBatch(m, kExtrudeEditScope);
    size_t affected = ed.extrudeEdgesByMask(mask, 0.5f, 0.2f);
    auto delta = ed.close();

    assert(affected > 0,
        "MUTATION TARGET (stand C, extrude): extrudeEdgesByMask over one "
      ~ "real selected edge at a realistic non-zero extrude/width must "
      ~ "report > 0 edges touched, got 0");
    assert(!delta.isEmpty,
        "extrudeEdgesByMask over one real selected edge at a realistic "
      ~ "non-zero extrude/width recorded an EMPTY delta despite "
      ~ "affected > 0");
    assert((affected == 0) == delta.isEmpty,
        "affected and delta.isEmpty disagree on stand C (extrude)");
}

unittest // P0-a extrude, stand D (FINDING, not the plan's mask-only framing):
         // width==0 is a SECOND, parameter-driven reason for affected == 0,
         // independent of the mask
{
    auto m = cubeWithOneEdgeSelected();
    auto mask = m.operandEdgeMask();
    size_t selected = 0;
    foreach (sel; mask) if (sel) ++selected;
    assert(selected == 1, "rig must select exactly one edge");

    // EdgeExtrudeTool's OWN reset defaults: extrude_ = width_ = 0.0f.
    auto ed = MeshEditBatch(m, kExtrudeEditScope);
    size_t affected = ed.extrudeEdgesByMask(mask, 0.0f, 0.0f);
    auto delta = ed.close();

    assert(affected == 0,
        "FINDING: extrudeEdgesByMask with width == 0 must no-op even over "
      ~ "a real, non-empty selection (mesh_ops/extrude.d's early "
      ~ "`if (width < 1e-6f) return 0;`) — if this ever reads > 0 the guard "
      ~ "moved and the tool's own untouched-defaults case needs re-checking "
      ~ "against EdgeExtrudeTool's `:303` no-op-success short-circuit");
    assert(delta.isEmpty,
        "extrudeEdgesByMask with width == 0 recorded a non-empty delta "
      ~ "despite the early return");
}
