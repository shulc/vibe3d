module commands.mesh.subdivide;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import subpatch_osd : catmullClarkOsd;
import change_bus : MeshEditScope;
import params : Param;
import commands.mesh.subdivide_faceted : runFacetedFamily;

class Subdivide : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate() onTopologyChange;
    private MeshSnapshot snap;
    private string mode_ = "ccsds";

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.subdivide"; }

    /// Three subdivision modes:
    ///   ccsds  — Catmull-Clark via OpenSubdiv (default, back-compat).
    ///   flat   — Faceted/linear split (= mesh.subdivide_faceted).
    ///   smooth — Faceted topology + one Laplacian relax pass (λ=0.5).
    /// Note: this is a deliberate three-method subset; a fourth method exists
    /// in the reference config but is intentionally out of scope for this task.
    override Param[] params() {
        return [
            Param.enum_("mode", "Mode", &mode_,
                [["ccsds",  "Catmull-Clark"],
                 ["flat",   "Faceted"],
                 ["smooth", "Smooth"]],
                "ccsds")
        ];
    }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        // Full mesh snapshot — the kernel replaces the entire mesh (verts,
        // edges, faces, selection, etc.).
        snap = MeshSnapshot.capture(*mesh);
        noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
        if (onTopologyChange !is null) onTopologyChange();

        if (mode_ == "flat" || mode_ == "smooth") {
            // Flat and smooth share the faceted topology; runFacetedFamily
            // handles selection rebuild and change-bus notification.
            runFacetedFamily(mesh, editMode, mode_ == "smooth");
        } else {
            // ccsds (default): Catmull-Clark via OpenSubdiv.
            // Selection-aware subdivision (refine only marked faces) only
            // makes sense when the user could see and curate the face
            // selection — i.e. in Polygons mode. In Vertices / Edges mode
            // we ignore any stale `mesh.selectedFaces` from a prior
            // polygon session and refine the whole cage.
            //
            // Hide (task 0632): the fallback is `visibleFaceMask()`, NOT a
            // null "refine everything" mask — hidden faces are excluded from
            // the OPERAND, so a hidden cage face is carried through whole
            // instead of being refined into four hidden children. Same
            // mode-gated shape as the four face commands listed in
            // `visibleFaceMask`'s doc comment (task 0613, S5): the gate stays
            // the mode, only the whole-mesh meaning narrows to "visible".
            // `operandFaceMask()` would ALSO make Vertices/Edges mode start
            // honouring a stale face selection, which is a behaviour change
            // this task does not want.
            //
            // The subtraction lives HERE and not inside `catmullClarkOsd`
            // deliberately: that kernel also builds the subpatch PREVIEW, and
            // subpatch_osd.d's §S3 stamp comment pins the invariant that the
            // limit surface is bit-identical whether or not anything is
            // hidden. Teaching the kernel to skip hidden faces would move the
            // preview's geometry the moment a face is hidden.
            bool polygonMode = editMode == EditMode.Polygons;
            bool[] mask = (polygonMode && mesh.hasAnySelectedFaces())
                          ? mesh.selectedFaces : mesh.visibleFaceMask();
            // `mask` is a slice into mesh.selectedFaces and dies with the
            // swap, so snapshot the selection before calling.
            auto prevSelectedFaces = polygonMode
                ? mesh.selectedFaces.dup : null;
            uint[] faceOrigin;
            Mesh sub = catmullClarkOsd(*mesh, mask, &faceOrigin);
            // TASK 1903 STAGE L5-P0 — the axis-0 commit seam (plan §5.0). See
            // `runFacetedFamily`'s copy of this note for the three reasons it
            // is UNRECORDED, for why `*mesh = …` inside the frame is safe
            // (§2.2a — module-level batch state keyed by `Mesh*`), and for
            // what the batch buys (`clearSubpatch` + `resetSelection` + one
            // commit per re-selected face + the tail publish, deferred to one
            // stamp instead of N ticks of
            // `changeBus.unbatchedGeometryCommits`).
            //
            // OPENED AFTER the GIGO guard below, not before: that arm restores
            // the snapshot and returns `false`, and a rollback belongs OUTSIDE
            // the frame (§6.5 item 1). Opening first would mean closing the
            // batch on the refusal path too, for a frame that has nothing to
            // stamp.
            // `catmullClarkOsd` returns `Mesh.init` (empty) when OSD can't
            // build a topology — a degenerate marked face, or an
            // all-degenerate/empty subset. Without this guard the
            // unconditional `*mesh = sub` below would WIPE the mesh on a
            // GIGO input; treat it as a clean no-op instead (mirrors
            // `commands/mesh/make_polygon.d`'s reject-is-a-no-op idiom).
            if (sub.vertices.length == 0 || sub.faces.length == 0) {
                snap.restore(*mesh);
                snap = MeshSnapshot.init;
                return false;
            }
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Geometry);
            // Corner-provenance (task 0901, `CornerDrop.SubdivideNoLaw`):
            // verified NOT APPLICABLE. `*mesh = sub` REPLACES the whole `Mesh`
            // value — `sub` never had a PolyVertex map of its own (it comes
            // fresh from `catmullClarkOsd`), so the old map disappears WITH
            // the old mesh rather than being zeroed by a face rewrite. The
            // `mesh.d` "D5 drop set" comment used to call this a drop; that
            // was the inaccuracy task 0682 introduced, corrected in task 0901.
            *mesh = sub;
            // `catmullClarkOsd` propagates the Subpatch bit from each cage
            // face to its child faces (task 0389 audit) — that propagation
            // is meant for SubpatchPreview's transient refine-mesh, not for
            // this command's baked result. An explicit Subdivide bakes real
            // geometry; leaving it marked Subpatch would make the ALREADY
            // -smoothed result subdivide again on the next preview pass.
            // resetSelection() no longer clears subpatch on its own (task
            // 0389), so clear it explicitly here to keep this command's
            // long-standing "bake produces plain polygons" behavior.
            mesh.clearSubpatch();
            mesh.resetSelection();
            foreach (k, parentFi; faceOrigin) {
                if (parentFi < prevSelectedFaces.length
                    && prevSelectedFaces[parentFi])
                    mesh.selectFace(cast(int)k);
            }
            // Change-notification (Stage 1): Catmull-Clark REPLACED the whole
            // mesh (new verts AND faces) — publish Geometry (Points|Polygons).
            // No version bump: the `*mesh = ...` swap reset the fresh struct's
            // version counters to 0; the bus class is what caches rebuild on.
            // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`: this is
            // the command's LAST mesh publisher, and a command's tail must
            // DELIVER. It happened to deliver before, because `resetSelection()`
            // above commits — incidental, and it is exactly the kind of
            // coupling that survives until someone tidies the reset away.
            // `Mesh.publishChange`'s doc comment carries the whole rule.
            mesh.publishChange(MeshEditScope.Geometry);
            ed.close();
        }
        return true;
    }

    protected override void revertImpl() {
        snap.restore(*mesh);
    }
}
