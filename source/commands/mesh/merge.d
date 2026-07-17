module commands.mesh.merge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;

/// Merge selected adjacent faces into one polygon per connected group by
/// dissolving EVERY interior edge shared by two selected faces, regardless
/// of coplanarity (selection is the only criterion).
///
/// Differs from `mesh.detriangulate` in three ways:
///   - No coplanarity criterion: non-coplanar adjacent faces are merged.
///   - No whole-mesh fallback: an empty selection is a no-op (returns false).
///   - Selection is cleared only after a successful merge, never on a no-op.
///
/// Requires Polygons edit mode with at least one selected face. Non-adjacent
/// or empty selections return false without mutating the mesh or clearing
/// the selection (no undo entry recorded).
///
/// v1 limitations (inherited from `removeEdgesByMask`): collinear 2-valent
/// boundary vertices on the merged n-gon are NOT removed (e.g. two coplanar
/// quads sharing one edge merge to a 6-corner n-gon, not a 4-corner rect).
/// Concave / non-coplanar / non-simply-connected (holed) selections produce
/// a single boundary walk that may be non-planar or self-intersecting.
///
/// Undo via MeshSnapshot.
class MeshMergeFaces : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate()  onTopologyChange;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.mergeFaces"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;

        // Step 1: require a live pipe subject.
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // Step 2: gate — must be in Polygons mode with at least one selected face.
        // Return false before any snapshot or side-effect.
        if (editMode != EditMode.Polygons) return false;
        if (!mesh.hasAnySelectedFaces())   return false;

        // Step 3: snapshot for undo.
        snap = MeshSnapshot.capture(*mesh);

        // Step 4: run the kernel.
        size_t dissolved = mesh.mergeFacesByMask(mesh.selectedFaces);

        // Step 5: if nothing was dissolved (non-adjacent / disjoint selection),
        // restore the snapshot and bail — no side-effects, no undo entry.
        if (dissolved == 0) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            return false;
        }

        // Step 6: topology changed — drop active tool.
        if (onTopologyChange !is null) onTopologyChange();

        // Step 7: clear selection (origin map unavailable after union-find merge).
        mesh.resetSelection();

        // Steps 8-9: notify bus + refresh GPU/caches.
        mesh.noteChange(MeshEditScope.Geometry);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
