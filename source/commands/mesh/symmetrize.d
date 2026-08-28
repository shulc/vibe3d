module commands.mesh.symmetrize;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math   : Vec3;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import toolpipe.packets : SymmetryPacket, SubjectPacket;
import symmetry : rebuildPairing, rebuildPairingTopological, applySymmetryMirror;

/// One-shot command that snaps a drifted-symmetric mesh back to exact symmetry by
/// ABSOLUTE-reflecting the driver side onto the partner side across an axis-aligned
/// plane.  Reuses `applySymmetryMirror` (the same absolute position-copy primitive
/// used during interactive deformation) with an all-true selection mask and
/// `baseSide` set to the caller-specified driver side.
///
/// Pairing is rebuilt locally — this command is self-contained and does not read
/// from any pipeline stage or SymmetryStage.  It therefore works headlessly via
/// `/api/command` with no toolpipe state required.
///
/// Undo is a positional snapshot (like MeshJitter / MeshTransform): `revert`
/// writes back the pre-apply positions.  No topology is ever changed — symmetrize
/// only moves vertex positions.
///
/// `topology:false` (default): spatial pairing — pairs each vertex with the mesh
/// vertex nearest to its mirror image within `epsilon`.  Works for small drift.
/// `topology:true`: connectivity-based pairing — walks mesh connectivity from
/// on-plane seam vertices; pairs large-drift meshes the spatial builder cannot.
/// Requires a connected on-plane seam (shared seam vertices between the two
/// halves); degrades to no-pairing (safe: nothing moves) on disconnected meshes.
///
/// On-plane vertices (within `epsilon` of the plane) are projected onto the plane.
/// Unpaired off-plane vertices are left untouched (safe degradation).
///
/// A no-op check diffs the pre-apply snapshot against the live positions after
/// `applySymmetryMirror` — no history entry is pushed when nothing actually moved
/// (avoids spurious undo stack growth on an already-symmetric mesh).
class MeshSymmetrize : Command, Operator {
    mixin OperatorActrCommon;

    // Param-backed schema fields — plain T so &field works.
    private string axis_     = "X";
    private string side_     = "positive";
    private bool   topology_ = false;
    private float  offset_   = 0.0f;
    private float  epsilon_  = 1e-4f;

    // Positional undo snapshot. Kept after task 1903 §L0-b as the TRACKER-OFF
    // ORACLE and as the movement gate's pre-image — `undo_` below serves the
    // default undo path.
    private Vec3[] prevPositions;
    private bool   captured;

    // Recorded `Kind.SetPos` undo (task 1903 §L0-b).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-b,
        /// witness W-b2). THIS COMMAND HAS NO FORWARD POSITION WRITE OF ITS
        /// OWN — its entire forward is the `applySymmetryMirror` call below —
        /// so "recorded nothing" is a state in which the census reads 0, the
        /// forward geometry is right, and `revert()` still answers `true` off
        /// the legacy array. Only reading the log sees it. `version
        /// (unittest)`, so this is not a door in a shipped build; `public` on
        /// the declaration and NOT a `public:` section.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.symmetrize"; }
    override string label() const { return "Symmetrize"; }

    override Param[] params() {
        return [
            Param.enum_ ("axis",     "Axis",              &axis_,
                         [["X","X"],["Y","Y"],["Z","Z"]], "X"),
            Param.enum_ ("side",     "Driver Side",       &side_,
                         [["positive","Positive"],["negative","Negative"]], "positive"),
            Param.bool_ ("topology", "Topological Pairing", &topology_, false),
            Param.float_("offset",   "Plane Offset",      &offset_,   0.0f),
            Param.float_("epsilon",  "Tolerance",         &epsilon_,  1e-4f).min(1e-7f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.vertices.length == 0) return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;
        // §2.4 — all three guards above resolve BEFORE any batch opens; this
        // command has no `throw`, so those `return false`s are the whole set.

        // REDO (CommandHistory.redo): re-run the kernel UNRECORDED and keep
        // the first delta. The kernel rebuilds its own pairing from the
        // restored pre-op mesh and its own params — it reads no pipeline state
        // at all — so the replay lands where the first run landed.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed);
            ed.close();
            return ok;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed);
        undo_.arm(ed.close());
        if (!ok) { undo_.disarm(); return false; }
        return true;
    }

    // -----------------------------------------------------------------------
    // THE RECORDING STRATEGY IS shape (D), AND IT IS THE ONLY ONE AVAILABLE
    // (plan §L0.3; task 1903 §L0-b).
    //
    // This command makes ZERO forward position writes of its own: its entire
    // forward is the `applySymmetryMirror(mesh, …)` call below, in
    // `source/symmetry.d` — a module this stage may not change (its other
    // callers are `source/tools/transform/**`, task 1905/T2's zone) and which
    // writes `mesh.vertices[…]` RAW. Under a RECORDING batch a raw write
    // produces no op-log entry, because `alias mesh this` makes that spelling
    // compile. So the recorder cannot be a write and cannot be an index list
    // either: the writer's own `alsoTouched` output is not one (see the
    // movement gate below, which had already measured that). It is a DIFF
    // against the pre-op image the command already keeps.
    // -----------------------------------------------------------------------
    private bool applyKernel(ref MeshEditBatch ed) {
        // Positional snapshot — taken BEFORE apply so we can diff and revert.
        // It is THREE things at once: the movement gate's reference, the
        // EMPTY-DELTA revert arm's source, and `recordPositionDiff`'s
        // pre-image. The middle one used to be the tracker-off revert's
        // source; task 1903 Stage N deleted the hatch and left the arm.
        prevPositions = mesh.vertices.dup;
        captured = false;

        // Build a self-contained SymmetryPacket.
        SymmetryPacket sp;
        sp.enabled    = true;
        sp.axisIndex  = (axis_[0] == 'X') ? 0 : (axis_[0] == 'Y') ? 1 : 2;
        sp.offset     = offset_;
        sp.epsilonWorld = epsilon_;
        sp.baseSide   = (side_ == "positive") ? +1 : -1;

        // Plane: unit normal along the chosen axis, plane point = normal * offset.
        Vec3 n;
        if      (sp.axisIndex == 0) n = Vec3(1, 0, 0);
        else if (sp.axisIndex == 1) n = Vec3(0, 1, 0);
        else                        n = Vec3(0, 0, 1);
        sp.planeNormal = n;
        sp.planePoint  = n * offset_;

        // Build the pairing into separate locals, then assign into sp — mirrors
        // the pattern in stages/symmetry.d:82-99 to avoid aliasing sp fields
        // as both in-param and out-param in the same call.
        int[]  pairOf;
        bool[] onPlane;
        int[]  vertSign;
        if (topology_)
            rebuildPairingTopological(*mesh, sp, pairOf, onPlane, vertSign);
        else
            rebuildPairing           (*mesh, sp, pairOf, onPlane, vertSign);
        sp.pairOf   = pairOf;
        sp.onPlane  = onPlane;
        sp.vertSign = vertSign;

        // Apply: whole-mesh mask (all-true) + baseSide → driver side preserved,
        // partner side snapped to mirror of driver.  On-plane verts projected.
        // Unpaired verts untouched.
        auto selected    = new bool[](mesh.vertices.length);  selected[]    = true;
        auto alsoTouched = new bool[](mesh.vertices.length);  alsoTouched[] = false;
        applySymmetryMirror(mesh, sp, selected, alsoTouched);

        // THE RECORDER, placed immediately after the write it records. On an
        // unrecorded batch it early-outs before the O(V) compare.
        ed.recordPositionDiff(prevPositions);

        // Movement gate: diff pre-apply snapshot vs live positions.
        // Do NOT use alsoTouched — it under-reports on-plane projection
        // changes and over-reports no-op mirror writes (see plan §Undo shape).
        // That sentence is also why the recorder above is a diff: an
        // under-reporting index list loses a vertex from the delta, and the
        // one it loses comes back at its POST-op position on undo.
        bool moved = false;
        foreach (i; 0 .. prevPositions.length) {
            if (i < mesh.vertices.length && mesh.vertices[i] != prevPositions[i]) {
                moved = true;
                break;
            }
        }
        if (!moved) return false;   // already symmetric — no history entry

        captured = true;
        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // THE EMPTY-DELTA ARM. `RecordedUndo.arm` leaves the holder DISARMED
        // when the batch came back with an empty log, so this is the live
        // answer for a forward that succeeded and moved nothing a bitwise diff
        // could see. Until task 1903 Stage N it was also the tracker-off ORACLE
        // the parity cell measured the recorded revert against (W-b4); that
        // reading died with the hatch, this one did not.
        if (!captured) return false;
        // TASK 1903 §L0-b — THE LEGACY REVERT WRITES THROUGH THE BATCH TOO,
        // for the reason L0-d recorded at the same line in nine other files:
        // §2.5's "leave the loop untouched" is incompatible with §1/§3/W-d1's
        // `countRawPositionWrites == 0` for this file — that count included
        // this loop, and it was this file's ONLY raw position write. Resolved
        // the way §2.5 already resolved the forward: the same write, through
        // the same primitive, on an UNRECORDED batch. Byte-identical —
        // `setVertexPositions` skips only writes whose new value is
        // BIT-identical to the current one (writing identical bits back was
        // what the loop did), and it drops out-of-range indices, which is the
        // same guard as the old `if (i < mesh.vertices.length)`.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        uint[] idx = new uint[](prevPositions.length);
        foreach (i; 0 .. idx.length) idx[i] = cast(uint)i;
        ed.setVertexPositions(idx, prevPositions);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
        return true;
    }
}

// ---------------------------------------------------------------------------
// Module unittest — exercises the apply-mask reasoning (plan Risk 1) without
// an HTTP server.  Runs under `dub test --config=tests`.
// ---------------------------------------------------------------------------

// Two-quad mesh sharing a seam edge on X=0 — the same topology as the
// proven fixture in symmetry.d's unittests.  This is the minimal structure
// that gives rebuildPairingTopological enough connectivity to seed and expand.
//
// Vertex layout:
//   0: seam (0, 0, 0)
//   1: seam (0, 1, 0)
//   2: +X driver  (1 + driftX, 0.5, 0)
//   3: +X second  (1.5, 1.2, 0)
//   4: -X partner of v2 at exact spatial mirror (-1, 0.5, 0) or drifted far
//   5: -X partner of v3 (-1.5, 1.2, 0)
// Faces: [0,2,3,1] (+X quad), [0,1,5,4] (-X quad)
//
// With small drift (driftX ≤ epsilon): spatial pairing finds v4↔v2.
// With large drift (driftX >> epsilon): only topological pairing finds v4↔v2.

version(unittest) {
    import math : Vec3;
    import mesh : Mesh;
    import symmetry : rebuildPairing, rebuildPairingTopological, applySymmetryMirror;
    import toolpipe.packets : SymmetryPacket;

    // Build the two-quad mesh with v2 drifted by driftX.  v4 stays at
    // its base position (-1, 0.5, 0) — the spatial mirror of undrifted v2.
    // When driftX is large, the spatial mirror of the DRIFTED v2 is far from
    // v4, so spatial pairing fails; topological succeeds via connectivity.
    private Mesh makeTwoQuadMesh(float driftX) {
        Mesh m;
        m.addVertex(Vec3( 0.0f,  0.0f, 0.0f));          // 0: seam
        m.addVertex(Vec3( 0.0f,  1.0f, 0.0f));          // 1: seam
        m.addVertex(Vec3( 1.0f + driftX, 0.5f, 0.0f));  // 2: +X driver
        m.addVertex(Vec3( 1.5f,  1.2f, 0.0f));          // 3: +X second
        m.addVertex(Vec3(-1.0f,  0.5f, 0.0f));          // 4: -X partner of v2
        m.addVertex(Vec3(-1.5f,  1.2f, 0.0f));          // 5: -X partner of v3
        m.addFace([0u, 2u, 3u, 1u]);    // +X quad
        m.addFace([0u, 1u, 5u, 4u]);    // -X quad
        m.buildLoops();
        return m;
    }

    private SymmetryPacket makeXPacket(float eps, int baseSide) {
        SymmetryPacket sp;
        sp.enabled      = true;
        sp.axisIndex    = 0;
        sp.offset       = 0.0f;
        sp.epsilonWorld = eps;
        sp.baseSide     = baseSide;
        sp.planeNormal  = Vec3(1, 0, 0);
        sp.planePoint   = Vec3(0, 0, 0);
        return sp;
    }
}

unittest {
    import std.math : abs;
    // Spatial pairing — driver side +1, small drift within epsilon.
    // Mirror of drifted v2=(1.05,0.5,0) = (-1.05,0.5,0).
    // v4 is at (-1.0,0.5,0), distance = 0.05 < eps=0.1 → paired.
    auto m  = makeTwoQuadMesh(0.05f);
    auto sp = makeXPacket(0.1f, +1);

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);
    sp.pairOf = pairOf; sp.onPlane = onPlane; sp.vertSign = vertSign;

    assert(pairOf[2] == 4, "spatial: v2 should pair with v4");

    auto pre = m.vertices.dup;
    auto selected    = new bool[](m.vertices.length);  selected[]    = true;
    auto alsoTouched = new bool[](m.vertices.length);  alsoTouched[] = false;
    applySymmetryMirror(&m, sp, selected, alsoTouched);

    // Driver (v2, +X side) must be unchanged.
    assert(m.vertices[2].x == pre[2].x && m.vertices[2].y == pre[2].y,
        "spatial: driver vert must be unchanged");

    // Partner (v4) must snap to mirror of drifted driver: (-1.05, 0.5, 0).
    assert(abs(m.vertices[4].x - (-1.05f)) < 1e-5f,
        "spatial: partner.x should be -1.05 (mirror of 1.05)");
    assert(abs(m.vertices[4].y - 0.5f) < 1e-5f,
        "spatial: partner.y should match driver.y = 0.5");
}

unittest {
    import std.math : abs;
    // Topological pairing — driver side +1, large drift (spatial would miss).
    // Mirror of drifted v2=(1.3,0.5,0) = (-1.3,0.5,0).
    // v4 is at (-1.0,0.5,0), distance=0.3 > eps=0.05 → spatial misses.
    auto m  = makeTwoQuadMesh(0.3f);
    auto sp = makeXPacket(0.05f, +1);

    // Confirm spatial does NOT pair v2.
    {
        int[] pOf; bool[] oP; int[] vS;
        rebuildPairing(m, sp, pOf, oP, vS);
        assert(pOf[2] == -1, "spatial should leave large-drift v2 unpaired");
    }

    // Topological pairing DOES pair v2↔v4 via connectivity.
    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairingTopological(m, sp, pairOf, onPlane, vertSign);
    sp.pairOf = pairOf; sp.onPlane = onPlane; sp.vertSign = vertSign;

    assert(pairOf[2] == 4 || pairOf[4] == 2,
        "topological: v2 and v4 must be paired");

    auto pre = m.vertices.dup;
    auto selected    = new bool[](m.vertices.length);  selected[]    = true;
    auto alsoTouched = new bool[](m.vertices.length);  alsoTouched[] = false;
    applySymmetryMirror(&m, sp, selected, alsoTouched);

    // Driver (v2) unchanged.
    assert(m.vertices[2].x == pre[2].x,
        "topological: driver vert must be unchanged");

    // Partner (v4) snapped to mirror of drifted v2: (-1.3, 0.5, 0).
    assert(abs(m.vertices[4].x - (-1.3f)) < 1e-5f,
        "topological: partner.x should be -1.3 (mirror of 1.3)");
    assert(abs(m.vertices[4].y - 0.5f) < 1e-5f,
        "topological: partner.y should match driver.y = 0.5");
}


unittest {
    // No-op gate: already-symmetric mesh → no positions change.
    // Using a symmetric two-quad mesh (exact mirrors; drift = 0).
    auto m  = makeTwoQuadMesh(0.0f);   // v2=(1,0.5,0), v4=(-1,0.5,0) — symmetric
    auto sp = makeXPacket(1e-4f, +1);

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);
    sp.pairOf = pairOf; sp.onPlane = onPlane; sp.vertSign = vertSign;

    auto pre = m.vertices.dup;
    auto selected    = new bool[](m.vertices.length);  selected[]    = true;
    auto alsoTouched = new bool[](m.vertices.length);  alsoTouched[] = false;
    applySymmetryMirror(&m, sp, selected, alsoTouched);

    bool moved = false;
    foreach (i; 0 .. pre.length)
        if (m.vertices[i] != pre[i]) { moved = true; break; }
    assert(!moved, "already-symmetric mesh: no positions should change");
}
