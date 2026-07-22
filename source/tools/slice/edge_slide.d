module tools.slice.edge_slide;

import mesh    : Mesh, GpuMesh;
import view    : View;
import editmode : EditMode;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import tools.common.command_wrapper : CommandWrapperTool;
import commands.mesh.edge_slide : MeshEdgeSlide;

import std.algorithm : clamp;
import std.json : JSONValue;

/// Interactive Edge Slide tool (factory id `edge.slide`).
///
/// Wraps `MeshEdgeSlide` as a `CommandWrapperTool` so drag interactivity,
/// live preview, revert-to-baseline, and one-gesture undo are inherited
/// from the base.
///
/// Drag mapping: horizontal mouse delta from LMB-down maps linearly to `t`
/// (right = positive, left = negative); ±200 px saturates at t = ±1.
/// The sign convention (which side is positive) follows the topological
/// 2-colouring of the selection (see `edgeSlidePositions` in mesh.d).
///
/// Undo: `CommandWrapperTool.commitNow` records one `MeshVertexEdit`
/// (before-baseline / after-preview diff) on deactivation — one gesture,
/// one undo entry.  Operates in Edges mode only.
final class EdgeSlideTool : CommandWrapperTool {
    private MeshEdgeSlide inner_;
    private float         lastT = 0.0f;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        inner_ = new MeshEdgeSlide(mesh, view, editMode);
        inner    = inner_;
        meshPtr  = mesh;
        viewRef  = view;
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name() const { return "edge.slide"; }

    /// Map the cumulative drag offset (pixels from LMB-down) to t ∈ [-1,1].
    /// ±200 px saturates; finer control by dragging slowly.
    protected override void onDragDelta(int dx, int dy) {
        lastT = clamp(cast(float)dx * 0.005f, -1.0f, 1.0f);
        inner_.setT(lastT);
    }

    protected override float handleSize() const {
        import std.math : abs;
        return abs(lastT);
    }

    /// Edge Slide only makes sense in Edges mode.
    override EditMode[] supportedModes() const {
        return [EditMode.Edges];
    }

    /// Read-only test/introspection seam (mirrors poly.bevel / edge.bevel):
    /// exposes the live slide parameter to /api/tool/state + the step-trace
    /// `tool` block so a per-step differential (trace_diff) can route an
    /// interactive edge-slide edit by its identity and read `t`.
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"] = JSONValue("edgeSlide");
        root["t"]    = JSONValue(inner_.slideT());
        return root;
    }
}
