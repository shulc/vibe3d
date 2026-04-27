module commands.mesh.bevel;

import command;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import bevel : applyEdgeBevelTopology, updateEdgeBevelPositions,
               BevelOp, BevelWidthMode, MiterPattern, computeLimitOffset;

/// Non-interactive edge bevel — applies the topology change on the currently
/// selected edges and slides each new BoundVert outward by `width` (and
/// optionally `widthR` for asymmetric bevels) using the chosen `mode`.
/// After success the selection is replaced with the bevel-quad edges.
///
/// Parameters (set via setWidth/setWidthR/setMode before apply()):
///   width   — user width on the L side of every beveled edge (>= 0).
///   widthR  — user width on the R side; defaults to `width` (symmetric).
///   mode    — Offset (default), Width, Depth, or Percent.
class MeshBevel : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private float            width   = 0.0f;
    private float            widthR  = float.nan;   // NaN → fall back to `width`
    private BevelWidthMode   mode    = BevelWidthMode.Offset;
    private int              seg     = 1;
    private float            superR  = 2.0f;
    private bool             limit   = true;        // clamp overlap (Blender default)
    private MiterPattern     miterInner = MiterPattern.Sharp;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name() const { return "mesh.bevel"; }

    void setWidth(float w)   { width  = (w < 0.0f) ? 0.0f : w; }
    void setWidthR(float w)  { widthR = (w < 0.0f) ? 0.0f : w; }
    void setSeg(int s)       { seg    = (s < 1) ? 1 : (s > 64 ? 64 : s); }
    void setSuperR(float r)  { superR = (r < 0.1f) ? 0.1f : r; }
    void setLimit(bool b)    { limit = b; }
    void setMiterInner(MiterPattern m) { miterInner = m; }
    void setMiterInner(string s) {
        switch (s) {
            case "sharp": miterInner = MiterPattern.Sharp; break;
            case "arc":   miterInner = MiterPattern.Arc;   break;
            default: throw new Exception("unknown miter_inner '" ~ s ~ "'");
        }
    }
    void setMode(BevelWidthMode m) { mode = m; }
    void setMode(string s) {
        switch (s) {
            case "width":   mode = BevelWidthMode.Width;   break;
            case "depth":   mode = BevelWidthMode.Depth;   break;
            case "percent": mode = BevelWidthMode.Percent; break;
            case "offset":  mode = BevelWidthMode.Offset;  break;
            default: throw new Exception("unknown bevel mode '" ~ s ~ "'");
        }
    }

    override bool apply() {
        import std.math : isNaN;
        if (editMode != EditMode.Edges)            return false;
        if (!mesh.hasAnySelectedEdges())           return false;

        // limit_offset: silently clamp user-facing width(s) so no BoundVert
        // can land past the far end of an adjacent non-bev edge (which would
        // invert geometry). This matches Blender's "Clamp Overlap" default.
        // Disable via setLimit(false) / "limit": false in JSON for tests
        // that need to exercise the unclamped mode-conversion math.
        float w  = width;
        float wR = isNaN(widthR) ? w : widthR;
        if (limit) {
            float lim = computeLimitOffset(mesh, mesh.selectedEdges, mode);
            if (w  > lim) w  = lim;
            if (wR > lim) wR = lim;
        }
        // Slide directions are computed at the (w, wR) widths directly,
        // so the BoundVerts land at their final positions during apply.
        BevelOp op = applyEdgeBevelTopology(mesh, mesh.selectedEdges, mode,
                                             w, wR, seg, superR, miterInner);
        updateEdgeBevelPositions(mesh, op, 1.0f);
        // Remove orphan vertices left by the topology operation (e.g. the
        // BEV-BEV BoundVert at reflex selCount=2 with arc miter, where the
        // patch geometry routes around the original vertex).
        mesh.compactUnreferenced();
        mesh.buildLoops();

        mesh.clearEdgeSelection();
        foreach (eidx; op.bevelQuadEdges)
            if (eidx >= 0 && eidx < cast(int)mesh.edges.length)
                mesh.selectEdge(eidx);

        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        return true;
    }
}
