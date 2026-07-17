module commands.mesh.subdivide_faceted;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import change_bus : MeshEditScope;

/// Shared kernel dispatcher for the faceted family (flat and smooth modes).
/// Runs `facetedSubdivide` (smooth=false) or `smoothSubdivide` (smooth=true),
/// then rebuilds the post-op face selection using the same emit-cursor walk
/// and publishes the Geometry change-bus notification.
/// Snapshot capture is the caller's responsibility; the display refresh is
/// bus-driven (the main loop's flush site consumes the Geometry flag
/// published below — task 0427).
package void runFacetedFamily(Mesh* mesh, EditMode editMode, bool smooth)
{
    // Selection-aware split only makes sense in Polygons mode where the user
    // can see and curate the face selection.  Vertices / Edges mode ignores
    // any stale face selection and falls through to the all-true mask.
    bool polygonMode  = editMode == EditMode.Polygons;
    bool hadSelection = polygonMode && mesh.hasAnySelectedFaces();
    auto prevSelectedFaces = polygonMode
        ? mesh.selectedFaces.dup : null;
    auto prevFaceVertCounts = new size_t[](mesh.faces.length);
    foreach (fi; 0 .. mesh.faces.length)
        prevFaceVertCounts[fi] = mesh.faces[fi].length;
    const bool[] mask = hadSelection
        ? mesh.selectedFaces
        : allTrueMask(mesh.faces.length);
    *mesh = smooth ? smoothSubdivide(*mesh, mask) : facetedSubdivide(*mesh, mask);
    mesh.resetSelection();
    // Rebuild the output selection: each selected cage face produced
    // len(fi) sub-quads (one per corner); unselected faces produced 1 face
    // (possibly widened). Walk the cursor to re-select the children.
    size_t cursor = 0;
    foreach (fi; 0 .. prevSelectedFaces.length) {
        bool wasSelected = prevSelectedFaces[fi];
        bool splitsHere  = fi < mask.length && mask[fi];
        size_t emitted   = splitsHere ? prevFaceVertCounts[fi] : 1;
        foreach (j; 0 .. emitted) {
            if (wasSelected && cursor < mesh.faces.length)
                mesh.selectFace(cast(int)cursor);
            ++cursor;
        }
    }
    // Change-notification (Stage 1): faceted kernel REPLACED the whole mesh
    // (new verts AND faces). noteChange (not commitChange): the `*mesh = ...`
    // swap reset the version counters to 0; the bus only needs the class so
    // caches rebuild.
    mesh.noteChange(MeshEditScope.Geometry);
}

class SubdivideFaceted : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate() onTopologyChange;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.subdivide_faceted"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        snap = MeshSnapshot.capture(*mesh);
        if (onTopologyChange !is null) onTopologyChange();
        runFacetedFamily(mesh, editMode, /*smooth=*/false);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

private bool[] allTrueMask(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}
