module commands.mesh.vertex_edit;

import display_sync : refreshDisplayActive;
import std.conv : to;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import params : Param;
import change_bus : MeshEditScope;
import view;
import editmode;
import math : Vec3;

/// Records a vertex-position edit that has ALREADY happened (the
/// "record" flavor — apply already ran via the tool's fast in-place
/// mutation path). Stores absolute pre/post positions so apply()/revert()
/// are exact (no FP drift across re-apply cycles).
///
/// Used by MoveTool / RotateTool / ScaleTool to land each drag (or each
/// Tool Properties slider release) on the undo stack as one entry.
class MeshVertexEdit : Command, Operator {
    mixin OperatorActrCommon;

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

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
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

    /// Coalescing predicate (Phase 2 op-merge). A new MeshVertexEdit is a
    /// CONTINUATION of the previous one — and therefore mergeable into a single
    /// undo entry — iff the previous command is ALSO a MeshVertexEdit acting on
    /// the SAME index set in the SAME order AND carrying the SAME edit label
    /// (so e.g. a run of "Move" nudges on the same verts collapses, but a Move
    /// followed by a Scale, or a Move on a different vertex set, stays a
    /// separate step). Anything else → Different (append normally).
    override CompareResult compareOp(const Command prev) const {
        auto p = cast(const(MeshVertexEdit))prev;
        if (p is null) return CompareResult.Different;
        // Target-mesh equality (layers seam, switch-hook step 2a): never
        // coalesce two delta edits recorded on different layers' meshes. With
        // one mesh this is identity in Stage 0a; load-bearing once layers exist.
        if (p.mesh !is this.mesh) return CompareResult.Different;
        if (p.editLabel != this.editLabel) return CompareResult.Different;
        if (p.indices.length != this.indices.length)
            return CompareResult.Different;
        foreach (i, vid; this.indices)
            if (p.indices[i] != vid) return CompareResult.Different;
        return CompareResult.Compatible;
    }

    /// In-place merge of a newer, COMPATIBLE edit into this (the existing top
    /// undo entry). KEEPS this entry's `before[]` (the state before the FIRST
    /// edit of the run) and ADOPTS the newer edit's `after[]` (the latest
    /// post-state). Net effect: the single coalesced entry's revert() restores
    /// the original pre-first-edit geometry, and its apply()/redo lands the
    /// most recent positions. The mesh already holds `newer`'s post-state (the
    /// dispatcher applied it before calling this), so no mesh mutation happens
    /// here. `indices`/label are identical by compareOp()'s contract, so only
    /// `after[]` needs adopting.
    void mergeFrom(MeshVertexEdit newer) {
        assert(newer.indices.length == this.indices.length,
            "mergeFrom: index-set length mismatch (compareOp contract broken)");
        this.after = newer.after.dup;
    }

    /// Type-erased merge hook (base Command.mergeFrom) used by
    /// CommandHistory.recordCoalescing(). Downcasts `newer` to MeshVertexEdit
    /// and defers to the typed mergeFrom above. Returns false if `newer` is not
    /// a MeshVertexEdit (compareOp() guarantees it is when this is reached).
    override bool mergeFrom(Command newer) {
        auto n = cast(MeshVertexEdit)newer;
        if (n is null) return false;
        mergeFrom(n);
        return true;
    }

    /// Optional callbacks that fire after the vert mutation in apply() /
    /// revert() — used by tools to restore their Tool Properties state
    /// (propDeg, scaleAccum, dragDelta) and origVertices/activationVertices
    /// baselines to the value they had at the corresponding edit boundary.
    void setHooks(void delegate() onApply, void delegate() onRevert) {
        this.onApplyHook  = onApply;
        this.onRevertHook = onRevert;
    }

    /// Read access to the apply/revert hooks. onApplyHook/onRevertHook are
    /// MODULE-private fields, and D `private` is module-scoped, so a consumer
    /// in another module (the run-consolidation primitive in command_history)
    /// cannot read them off a gathered command object. This pair accessor is
    /// the public surface it splices the first/last gesture's hooks from.
    struct Hooks { void delegate() apply; void delegate() revert; }
    Hooks getHooks() const {
        return Hooks(cast(void delegate())onApplyHook,
                     cast(void delegate())onRevertHook);
    }

    /// Read access to the edit payload — needed by the run-consolidation
    /// primitive (a different module) to union-merge several gathered edits.
    /// Returned as const slices; callers must .dup if they keep them.
    const(uint)[] editIndices() const { return indices; }
    const(Vec3)[] editBefore()  const { return before; }
    const(Vec3)[] editAfter()   const { return after; }

    /// Union-merge a CONTIGUOUS run of edits into ONE new MeshVertexEdit.
    /// `entries` is in stack order (oldest → newest). The merged edit's:
    ///   - indices = sorted union of every entry's indices
    ///   - before[vid] = the EARLIEST gathered entry's before for vid
    ///     (first-touch-wins → the run-start state of that vert)
    ///   - after[vid]  = the LATEST gathered entry's after for vid
    ///   - label = the first (oldest) entry's label (runs are single-bank by
    ///     construction, so all labels agree; the first is canonical)
    ///   - hooks = first.onRevertHook (restore to run-start) +
    ///     last.onApplyHook  (run-end)
    /// Context (mesh/view/editMode) is cloned from the first entry so the
    /// merged edit's apply()/revert() route through the same mesh; the GPU
    /// upload target comes from `refreshDisplayActive`'s app-installed
    /// resolver (task 0413), not a per-entry captured pointer.
    ///
    /// Lives HERE (not in command_history) because it reads each entry's
    /// private indices/before/after, module-scoped to vertex_edit. Pure: it
    /// does NOT mutate any mesh — it only builds a fresh command object.
    static MeshVertexEdit mergeRun(MeshVertexEdit[] entries) {
        assert(entries.length > 0, "mergeRun requires at least one entry");
        auto first = entries[0];
        auto last  = entries[$ - 1];

        // Build the union map. Walk oldest → newest: afterLatest always
        // adopts the newest after; beforeEarliest takes the first-touch before.
        Vec3[uint]   beforeEarliest;
        Vec3[uint]   afterLatest;
        foreach (e; entries) {
            auto idx = e.indices;
            foreach (i, vid; idx) {
                afterLatest[vid] = e.after[i];
                if (vid !in beforeEarliest)
                    beforeEarliest[vid] = e.before[i];
            }
        }

        // Sorted union of indices for a deterministic payload.
        import std.algorithm : sort;
        uint[] outIdx = beforeEarliest.keys;
        outIdx.sort();

        Vec3[] outBefore;
        Vec3[] outAfter;
        outBefore.reserve(outIdx.length);
        outAfter.reserve(outIdx.length);
        foreach (vid; outIdx) {
            outBefore ~= beforeEarliest[vid];
            outAfter  ~= afterLatest[vid];
        }

        // Clone context from the first entry.
        auto merged = new MeshVertexEdit(
            first.meshPtr, first.viewRef, first.editModeVal);
        merged.setEdit(outIdx, outBefore, outAfter,
                       first.editLabel.length ? first.editLabel : "Edit");
        // Hooks: revert to run-start (first), redo to run-end (last).
        auto fh = first.getHooks();
        auto lh = last.getHooks();
        merged.setHooks(lh.apply, fh.revert);
        return merged;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
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
        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        if (onApplyHook !is null) onApplyHook();
        return true;
    }

    override bool revert() {
        foreach (i, vid; indices) {
            if (vid < mesh.vertices.length)
                mesh.vertices[vid] = before[i];
        }
        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        if (onRevertHook !is null) onRevertHook();
        return true;
    }
}
