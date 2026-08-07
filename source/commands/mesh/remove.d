module commands.mesh.remove_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot, SelectionSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshEditScope,
                        captureSelectedEdgeEnds, restoreSelectedEdgeEnds,
                        undoTrackerEnabled;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh).
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Tier 1.1: "Remove" (`vert.remove` / `edge.remove false` /
/// `poly.remove`, dispatched by edit mode). Remove and Delete are
/// DISTINCT topological operations, not aliases:
///   - Vertices: both dissolve (identical result).
///   - Edges:    both dissolve the edge / merge the incident faces.
///   - Polygons: Delete removes the faces AND their now-orphaned points;
///     Remove removes ONLY the faces and leaves the orphaned points
///     floating in place (keepOrphans — task 0465). This mirrors the
///     reference editor, where poly-Delete drops points but poly-Remove
///     keeps them.
/// The two commands stay separate so the menu structure, shortcut layout,
/// and (for polygons) the keep-points semantic can distinguish them.
///
/// Revert: a full MeshSnapshot of the pre-op cage by default; when the
/// VIBE3D_UNDO_TRACKER env toggle is on the kernel run is wrapped in a
/// Mesh edit batch and the resulting operation-log MeshEditDelta drives
/// undo (O(Δ) — doc/undo_change_tracker_plan.md Phase 3). Redo re-runs the
/// kernel batchless from the restored pre-op selection.
class MeshRemove : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;

    // Phase 3 delta path — see MeshDelete for the rationale. Vertex/face
    // selection is index-keyed (SelectionSnapshot); edge selection is endpoint-
    // keyed (re-derived edge order is not index-stable across rebuildEdges); the
    // Subpatch + Hide (task 0613) planes are index-keyed (re-overlaid on revert —
    // the delta only carries the subpatch bit for DROPPED faces, see MeshDelete +
    // the Phase 4 burn-in finding in test_marks_authority).
    private MeshEditDelta      delta_;
    private SelectionSnapshot  preSel_;
    private uint[]             preEdgeEnds_;
    private uint[]             preMarksWord_;
    private bool               useDelta_;

    // Stable label: captured once in runKernel() — see MeshDelete.appliedMode_.
    private EditMode appliedMode_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
        this.appliedMode_ = editMode;   // stable default before apply() runs
    }

    override string name()  const { return "mesh.remove"; }

    // Change-scope metadata (Phase 4 §b) — see MeshDelete.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    override bool isOperationInverse() const { return useDelta_; }

    override string label() const {
        final switch (appliedMode_) {
            case EditMode.Vertices: return "Remove Vertices";
            case EditMode.Edges:    return "Remove Edges";
            case EditMode.Polygons: return "Remove Polygons";
        }
    }

    // The kernel mutation, shared by the first run and the redo re-run.
    // Delete and Remove differ ONLY for edges (both dissolve there); for
    // vertices and polygons they are identical. Selection is read live.
    //
    // effectiveDeleteMode is used instead of the raw editMode so that a
    // selection that lives in a DIFFERENT element type from the active mode is
    // honoured. Without the redirect, nothingSelected(current) fires true and
    // the whole-mesh all-true mask wipes the mesh even though a selection
    // exists elsewhere (task 0110).
    private size_t runKernel() {
        const mode = mesh.effectiveDeleteMode(editMode);
        appliedMode_ = mode;   // freeze for label() — stable after apply()
        const all  = mesh.nothingSelected(mode);
        final switch (mode) {
            case EditMode.Vertices:
                // keepOrphans (measured, task delete-remove-dissolve): matches
                // vertex Delete — removes EXACTLY the selected verts and keeps
                // collateral orphans as loose points (reference-editor parity).
                return mesh.dissolveVerticesByMask(
                    all ? allTrue(mesh.vertices.length) : mesh.selectedVertices,
                    /*keepOrphans=*/true);
            case EditMode.Edges:
                auto n = mesh.removeEdgesByMask(
                    all ? allTrue(mesh.edges.length) : mesh.selectedEdges);
                // Scope the 2-valent cleanup to the removed edges' endpoints
                // (task 0474): a pre-existing 2-valent vertex the remove did not
                // touch — a 90° corner, a straight-through midpoint elsewhere —
                // must survive (reference-editor parity). keepOrphans keeps
                // collateral orphans the merge/cleanup leaves behind (task
                // delete-remove-dissolve).
                if (n > 0) mesh.dissolveDegree2Verts(mesh.edgeDeleteRegion(),
                                                     /*keepOrphans=*/true);
                return n;
            case EditMode.Polygons:
                // Remove ≠ Delete for polygons: Remove drops ONLY the faces
                // and leaves orphaned vertices floating (keepOrphans=true),
                // whereas Delete (mesh.delete) also compacts orphans. This
                // matches the reference editor's poly-Remove vs Delete
                // distinction (task 0465).
                return mesh.deleteFacesByMask(
                    all ? allTrue(mesh.faces.length) : mesh.selectedFaces,
                    /*keepOrphans=*/true);
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Redo: re-run the kernel BATCHLESS (no double record).
        if (useDelta_) {
            const affected = runKernel();
            if (affected == 0) return false;
            return true;
        }

        if (undoTrackerEnabled()) {
            preSel_       = SelectionSnapshot.capture(*mesh);
            preEdgeEnds_  = captureSelectedEdgeEnds(*mesh);
            preMarksWord_ = mesh.faceMarks.dup;
            auto rec = MeshEditTracker();
            mesh.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
            const affected = runKernel();
            delta_ = mesh.endEditBatch();
            if (affected == 0 || delta_.isEmpty) {
                delta_        = MeshEditDelta.init;
                preSel_       = SelectionSnapshot.init;
                preEdgeEnds_  = null;
                preMarksWord_ = null;
                return false;
            }
            useDelta_ = true;
            return true;
        }

        snap = MeshSnapshot.capture(*mesh);
        const affected = runKernel();
        if (affected == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    override bool revert() {
        if (useDelta_) {
            delta_.revert(*mesh);
            // See MeshDelete.revert (code review BLOCKER, task 0613): this
            // full-word overwrite MUST run BEFORE preSel_.restore() below —
            // setFaceMarksFrom assigns the whole word, so running it after
            // the selection restore would zero the Select bit restore just
            // set. `~Marks.Select` keeps this write from resurrecting a
            // stale Select bit of its own ahead of the restore.
            if (preMarksWord_.length) {
                assert(preMarksWord_.length == mesh.faces.length,
                    "MeshRemove.revert: preMarksWord_ length != restored face "
                    ~ "count — the delta revert did not land on the exact "
                    ~ "pre-op face index space this capture assumes");
                mesh.setFaceMarksFrom(preMarksWord_, ~Mesh.Marks.Select);
            }
            // preSel_ restores vertex/face selection by index (setFacesSelectedFrom
            // touches ONLY the Select bit, so it is safe to run after the
            // full-word overwrite above); override the (index-unstable) edge
            // selection with the endpoint capture.
            preSel_.restore(*mesh);
            mesh.clearEdgeSelection();
            restoreSelectedEdgeEnds(*mesh, preEdgeEnds_);
            return true;
        }
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Task 0502 — the SHIPPED COMMANDS, not just the kernel under them.
//
// `mesh.remove` and `mesh.delete` in Edges mode both run
// `removeEdgesByMask` + `dissolveDegree2Verts`, and both tails used to
// re-derive edges[] and vertices[] from faces[] MESH-WIDE. So one edge
// dissolve wiped every bare wire edge and every loose point in the document,
// arbitrarily far from the selection — vibe3d builds both as ordinary
// intermediate retopo state, so this destroyed in-progress work silently.
//
// The kernel unittests in mesh.d pin the primitives. This block pins the
// COMMANDS, through `Command.apply()` — the real dispatch entry — because the
// commands are what the bug was reported against and because the mode
// redirect, the empty-selection fallback and the two-kernel sequence all sit
// between the user and the primitive.
// ---------------------------------------------------------------------------
version (unittest) {
    import commands.mesh.delete_ : MeshDelete;
    import math : Vec3;

    private enum Vec3 kRemoveTestPoint = Vec3(10, 10, 10);
    private enum Vec3 kRemoveTestWireA = Vec3(20, 0, 0);
    private enum Vec3 kRemoveTestWireB = Vec3(21, 0, 0);

    private int removeTestVertAt(in Mesh m, Vec3 p) {
        foreach (i, ref v; m.vertices)
            if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
        return -1;
    }

    private bool removeTestHasWire(in Mesh m, Vec3 a, Vec3 b) {
        immutable int ia = removeTestVertAt(m, a), ib = removeTestVertAt(m, b);
        if (ia < 0 || ib < 0) return false;
        foreach (ref e; m.edges)
            if ((e[0] == ia && e[1] == ib) || (e[0] == ib && e[1] == ia)) return true;
        return false;
    }

    /// A 3x3 grid of quads plus, FAR from it, one loose point and one bare
    /// wire edge. Distance is the point: nothing here is adjacent to the
    /// edited edge, so surviving cannot be an accident of locality.
    private Mesh makeRemoveTestGrid() {
        import mesh : makeGridPlane;
        Mesh m = makeGridPlane(2);
        m.addVertex(kRemoveTestPoint);
        immutable uint w0 = m.addVertex(kRemoveTestWireA);
        immutable uint w1 = m.addVertex(kRemoveTestWireB);
        m.addEdge(w0, w1);
        m.buildLoops();
        m.syncSelection();
        assert(removeTestVertAt(m, kRemoveTestPoint) >= 0, "fixture: the loose point");
        assert(removeTestHasWire(m, kRemoveTestWireA, kRemoveTestWireB),
            "fixture: the bare wire edge");
        return m;
    }
}

unittest { // edge.remove / edge.delete leave unrelated loose geometry alone
    import view : View;

    foreach (isDelete; [false, true]) {
        Mesh m = makeRemoveTestGrid();
        View view = new View(0, 0, 100, 100);

        // An INTERIOR grid edge — the only kind that dissolves at all.
        immutable uint ei = m.edgeIndex(1, 4);
        assert(ei != uint.max, "setup: the interior grid edge");
        m.selectEdge(cast(int)ei);

        Command cmd = isDelete
            ? cast(Command)new MeshDelete(&m, view, EditMode.Edges)
            : cast(Command)new MeshRemove(&m, view, EditMode.Edges);
        assert(cmd.apply(), "setup: the command must report work done");
        assert(m.faces.length == 3, "setup: the two quads either side merged");

        immutable string who = isDelete ? "mesh.delete" : "mesh.remove";
        assert(removeTestVertAt(m, kRemoveTestPoint) >= 0,
            who ~ " FAILS ON THE OLD BEHAVIOUR: the kernel tail's mesh-wide "
          ~ "compactUnreferenced took a loose point 10 units from the edit");
        assert(removeTestHasWire(m, kRemoveTestWireA, kRemoveTestWireB),
            who ~ " FAILS ON THE OLD BEHAVIOUR: the kernel tail's mesh-wide "
          ~ "rebuildEdges re-derived edges[] from faces[] and wiped a bare wire "
          ~ "edge 20 units from the edit");
    }
}
