module commands.mesh.bevel;

import command;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import bevel : BevelOp, BevelParams, BevelWidthMode, MiterPattern,
               computeLimitOffset, runEdgeBevel, EdgeBevelResult;
import snapshot : MeshSnapshot;

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
    private MeshSnapshot     snap;

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
        if (editMode != EditMode.Edges) return false;
        if (!mesh.hasAnySelectedEdges()) return false;

        // Translate this command's NaN-sentinel widthR into BevelParams.
        // NaN means "not set" → symmetric (asymmetric=false, widthR unused).
        BevelParams p;
        p.width      = width;
        p.widthR     = isNaN(widthR) ? width : widthR;
        p.asymmetric = !isNaN(widthR);
        p.mode       = mode;
        p.seg        = seg;
        p.superR     = superR;
        p.miterInner = miterInner;
        p.limit      = limit;

        // Full mesh snapshot for revert (weld + compact renumber vertices in
        // ways revertEdgeBevelTopology(BevelOp) wasn't designed to handle).
        snap = MeshSnapshot.capture(*mesh);

        auto r = runEdgeBevel(mesh, mesh.selectedEdges, p);
        if (!r.success) {
            snap = MeshSnapshot.init;
            return false;
        }

        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        return true;
    }
}
