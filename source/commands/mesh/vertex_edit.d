module commands.mesh.vertex_edit;

import std.conv : to;

import command;
import mesh;
import params : Param;
import view;
import editmode;
import viewcache;
import math : Vec3;

/// Records a vertex-position edit that has ALREADY happened (the MODO
/// "Record" flavor — apply already ran via the tool's fast in-place
/// mutation path). Stores absolute pre/post positions so apply()/revert()
/// are exact (no FP drift across re-apply cycles).
///
/// Used by MoveTool / RotateTool / ScaleTool to land each drag (or each
/// Tool Properties slider release) on the undo stack as one entry.
class MeshVertexEdit : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private uint[] indices;
    private Vec3[] before;
    private Vec3[] after;
    private string editLabel;     // "Move", "Rotate", etc.

    // Optional hooks for tool-specific state restoration. RotateTool /
    // ScaleTool / MoveTool use these to push/pop their Tool Properties
    // accumulators (propDeg, scaleAccum, dragDelta) and origVertices /
    // activationVertices baselines alongside the vert mutation so that
    // after undo the slider readout matches the visible mesh state.
    private void delegate() onApplyHook;
    private void delegate() onRevertHook;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.vertex_edit"; }
    override string label() const {
        return (editLabel.length ? editLabel : "Edit") ~ " "
             ~ indices.length.to!string ~ " verts";
    }

    /// Schema used by the generic HTTP injector (injectParamsInto).
    /// editLabel is intentionally excluded — tools set it via setEdit()
    /// directly; it is not part of the JSON wire format.
    override Param[] params() {
        return [
            Param.intArray_ ("indices", "Indices", &indices),
            Param.vec3Array_("before",  "Before",  &before),
            Param.vec3Array_("after",   "After",   &after),
        ];
    }

    /// Set the edit payload. before/after must be the same length as indices
    /// — corresponding entry i means mesh.vertices[indices[i]] went from
    /// before[i] to after[i].
    void setEdit(uint[] indices_, Vec3[] before_, Vec3[] after_,
                 string label_ = "Edit") {
        assert(before_.length == indices_.length,
            "before/indices length mismatch");
        assert(after_.length == indices_.length,
            "after/indices length mismatch");
        this.indices    = indices_;
        this.before     = before_;
        this.after      = after_;
        this.editLabel  = label_;
    }

    bool isEmpty() const { return indices.length == 0; }

    /// Optional callbacks that fire after the vert mutation in apply() /
    /// revert() — used by tools to restore their Tool Properties state
    /// (propDeg, scaleAccum, dragDelta) and origVertices/activationVertices
    /// baselines to the value they had at the corresponding edit boundary.
    void setHooks(void delegate() onApply, void delegate() onRevert) {
        this.onApplyHook  = onApply;
        this.onRevertHook = onRevert;
    }

    override bool apply() {
        if (before.length != indices.length || after.length != indices.length)
            throw new Exception(
                "mesh.vertex_edit: indices/before/after length mismatch "
                ~ "(indices=" ~ indices.length.to!string
                ~ " before=" ~ before.length.to!string
                ~ " after=" ~ after.length.to!string ~ ")");
        foreach (i, vid; indices) {
            if (vid < mesh.vertices.length)
                mesh.vertices[vid] = after[i];
        }
        ++mesh.mutationVersion;
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        if (onApplyHook !is null) onApplyHook();
        return true;
    }

    override bool revert() {
        foreach (i, vid; indices) {
            if (vid < mesh.vertices.length)
                mesh.vertices[vid] = before[i];
        }
        ++mesh.mutationVersion;
        gpu.upload(*mesh);
        vc.invalidate();
        ec.invalidate();
        fc.invalidate();
        if (onRevertHook !is null) onRevertHook();
        return true;
    }
}
