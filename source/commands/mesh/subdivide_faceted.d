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
    // Mode-gated fallback — visibleFaceMask(), not operandFaceMask()
    // (task 0613, S5; see the helper's doc comment in mesh.d). This is the
    // operand-exclusion half of task 0632: a hidden face is never in the
    // operand, so it is carried through whole. The other half — carrying its
    // Hide bit ACROSS the rebuild instead of dropping it — lives in
    // `facetedSubdivide` itself.
    const bool[] mask = hadSelection
        ? mesh.selectedFaces
        : mesh.visibleFaceMask();
    // Corner-provenance (task 0901, `CornerDrop.SubdivideNoLaw`): verified NOT
    // APPLICABLE, same shape as `commands/mesh/subdivide.d`'s ccsds mode —
    // `facetedSubdivide`/`smoothSubdivide` return a fresh `Mesh result` with
    // no PolyVertex map of its own, and this `*mesh = ...` REPLACES the whole
    // value. The old map disappears with the old mesh; nothing here zeroes it.
    // TASK 1903 STAGE L5-P0 — the axis-0 commit seam (plan §5.0: a row whose
    // undo stays a snapshot still owes the batch). Everything from the install
    // to the tail publish runs inside ONE unrecorded batch, so the six-odd
    // `commitChange`es below (`resetSelection`, one per re-selected face, the
    // final `publishChange`) defer and stamp once at `close()` instead of
    // ticking `changeBus.unbatchedGeometryCommits` one at a time.
    //
    // UNRECORDED, deliberately: this family is declined on axis 2 (§6.6) —
    // the kernel builds a FRESH `Mesh` and installs it wholesale, so there is
    // no op-log an inverse could be built from and the undo image stays the
    // caller's `MeshSnapshot`.
    //
    // `*mesh = …` INSIDE the frame is safe because the batch state is
    // MODULE-level and keyed by `Mesh*` (§2.2a): the assignment replaces the
    // pointee's contents, not the pointer, so the frame the handle owns is
    // still found by `close()`. A `batchDepth_` FIELD on `Mesh` would have
    // been zeroed by this very line.
    auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Geometry);
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
    // (new verts AND faces). No version bump: the `*mesh = ...` swap reset the
    // version counters to 0; the bus only needs the class so caches rebuild.
    // TASK 1906 STAGE 2 PRECONDITION — `publishChange`, not `noteChange`.
    // `noteChange` accumulates and NEVER delivers (that is its contract:
    // safe inside loops, safe mid-drag), so a command whose LAST mesh
    // publisher is a note delivers only if some EARLIER call happened to
    // register the mesh with the open delivery batch — incidental, not
    // structural. Stage 2a moved the display family off the frame-drain
    // pull and onto the bus, and a wholesale replace that delivers nothing
    // would leave the mid-batch pull guard (`ensureDisplayCurrent`) with
    // no reason to re-upload before the next VBO reader. `publishChange`
    // accumulates identically and delivers at depth 0 / at the batch
    // close, so the delivery COUNT per command is unchanged (one) while
    // the delivery itself is now guaranteed.
    mesh.publishChange(MeshEditScope.Geometry);
    ed.close();
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

