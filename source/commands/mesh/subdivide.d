module commands.mesh.subdivide;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import subpatch_osd : catmullClarkOsd;
import change_bus : MeshEditScope;
import params : Param;
import commands.mesh.subdivide_faceted : runFacetedFamily;

class Subdivide : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*        gpu;
    private VertexCache*    vc;
    private EdgeCache*      ec;
    private FaceBoundsCache* fc;
    private void delegate() onTopologyChange;
    private MeshSnapshot snap;
    private string mode_ = "ccsds";

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
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
            bool polygonMode = editMode == EditMode.Polygons;
            bool[] mask = (polygonMode && mesh.hasAnySelectedFaces())
                          ? mesh.selectedFaces : null;
            // `mask` is a slice into mesh.selectedFaces and dies with the
            // swap, so snapshot the selection before calling.
            auto prevSelectedFaces = polygonMode
                ? mesh.selectedFaces.dup : null;
            uint[] faceOrigin;
            Mesh sub = catmullClarkOsd(*mesh, mask, &faceOrigin);
            // `catmullClarkOsd` returns `Mesh.init` (empty) when OSD can't
            // build a topology — a degenerate marked face, or an
            // all-degenerate/empty subset. Without this guard the
            // unconditional `*mesh = sub` below would WIPE the mesh on a
            // GIGO input; treat it as a clean no-op instead (mirrors
            // `commands/mesh/make_polygon.d`'s reject-is-a-no-op idiom).
            if (sub.vertices.length == 0 || sub.faces.length == 0) {
                snap.restore(*mesh);
                snap = MeshSnapshot.init;
                refreshCaches();
                return false;
            }
            *mesh = sub;
            mesh.resetSelection();
            foreach (k, parentFi; faceOrigin) {
                if (parentFi < prevSelectedFaces.length
                    && prevSelectedFaces[parentFi])
                    mesh.selectFace(cast(int)k);
            }
            // Change-notification (Stage 1): Catmull-Clark REPLACED the whole
            // mesh (new verts AND faces) — publish Geometry (Points|Polygons).
            // noteChange (not commitChange): the `*mesh = ...` swap reset the
            // fresh struct's version counters to 0; the bus only needs the
            // class so caches rebuild.
            mesh.noteChange(MeshEditScope.Geometry);
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
