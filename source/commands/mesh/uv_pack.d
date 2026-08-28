module commands.mesh.uv_pack;

/// `uv.fit` — translate+scale all affected UV corners so their combined
/// bounding box exactly fills [0,1]² (both bbox edges touch 0 and 1).
/// Optional `keepAspect=uniform` uses uniform scale and centres the result.
///
/// `uv.pack` — detect UV islands (connected components via shared-vertex +
/// matching UV coords), lay them out non-overlapping inside [0,1]² with a
/// greedy shelf packer, then apply one affine per island.
///
/// Both commands:
///   - Require an existing "uv" PolyVertex dim-2 MeshMap (unlike uv.project
///     which creates-if-absent).  Missing map → throw → HTTP status:error.
///   - Empty affected corner set → return false → no snapshot, no history.
///   - Undo: a recorded `MeshOpEntry.Kind.MapValueDelta` since task 1903
///     Stage L1-b, through `MeshEditBatch.recordMapValueDiff` — the kernels
///     (`applyUvAffine`) take the map pointer and write it, so the command
///     holds a pre-op image and the DIFF is the record. Task 1903 Stage N
///     deleted the escape hatch, so the delta is the only undo image left.
///     Mode C: two whole images of the map, ~6.10 MB
///     against a 20.81 MB whole-mesh capture, ratio 3.4x and scale-invariant
///     (task 2210).
///   - commitChange(MeshEditScope.Material) — UV is a material-domain edit.
///
/// EditMode-agnostic footgun: stale face marks from a prior polygon-mode
/// selection are honoured regardless of the current edit mode.  A face-scoped
/// UV edit can fire even when the user is in vertex or edge mode.

import command;
import mesh            : Mesh, MeshMap, MapDomain, MeshEditBatch, kUvMapName;
import view            : View;
import editmode        : EditMode;
import mesh_edit_delta : MeshEditScope;
import params          : Param;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEditEmptyOk;
import uv_transform    : applyUvAffine, collectAffectedUvLoops;
import uv_island       : UvBBox, loopsBBox, computeUvIslands,
                         computeFitAffine, computeShelfPack;

// ---------------------------------------------------------------------------
// Shared validation (inline helper — mirrors uv.flip validation verbatim).
// ---------------------------------------------------------------------------

private MeshMap* validateUvMap(Mesh* mesh, string cmdName) {
    auto map = mesh.meshMap(kUvMapName);
    if (map is null)
        throw new Exception(
            cmdName ~ ": no UV map found ('" ~ kUvMapName ~ "'); "
            ~ "run uv.project first to create a UV map");
    if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
        throw new Exception(cmdName ~ ": UV map has unexpected dim/domain");
    if (map.data.length != mesh.loops.length * 2)
        throw new Exception(cmdName ~ ": UV map data out of sync with loop count");
    return map;
}

// ---------------------------------------------------------------------------
// uv.fit
// ---------------------------------------------------------------------------

class UvFit : Command {
    private string       keepAspect_ = "fill";
    private RecordedUndo undo_;
    /// The forward SUCCEEDED. NOT derivable from `undo_`/`snap`, and the three
    /// shipped cells that caught the attempt say why: these commands' `revert()`
    /// must answer FALSE when the forward refused or never ran
    /// (`test_uv_transform.d` "revert without apply must return false",
    /// `test_uv_pack.d`, `test_uv_project.d`) and TRUE when the forward
    /// SUCCEEDED while moving nothing a bitwise diff could see (regression
    /// 0099: `CommandHistory.undo` discards an entry whose revert answers false
    /// AND its whole trailing suffix). Both states are "no delta and no
    /// snapshot", so only a bit set by the forward can separate them.
    private bool applied_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 2250). A
        /// command that recorded NOTHING falls back to its snapshot and
        /// restores every plane correctly, so every result-shaped assertion is
        /// green over a deleted recorder; only reading the log is not.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.fit"; }
    override string label() const { return "Fit UVs"; }

    override Param[] params() {
        return [
            Param.enum_("keepAspect", "Mode", &keepAspect_,
                        [["fill","Fill [0,1]²"],["uniform","Uniform (keep aspect)"]],
                        "fill"),
        ];
    }

    protected override bool applyImpl() {
        validateUvMap(mesh, name());
        auto loops = collectAffectedUvLoops(*mesh);
        // Refused BEFORE the batch opens: no undo image, no history entry, and
        // nothing written that would need rolling back.
        if (loops.length == 0) return false;

        applied_ = runMapEdit(mesh, undo_, MeshEditScope.Material,
                          (ref MeshEditBatch ed) => kernel(ed, loops));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, size_t[] loops) {
        auto map = ed.mesh.meshMap(kUvMapName);
        assert(map !is null, "uv.fit: the map resolved in applyImpl vanished "
                           ~ "before the kernel ran");
        // ONE block `dup`, and ONLY on the recording arm — it is the whole
        // payload, and paying it on the redo and hatch arms is what made four
        // L0-d commands twice as slow (task 2160, plan §K.5 rule 2).
        float[] pre;
        const bool rec = ed.recording();
        if (rec) pre = map.data.dup;

        auto box  = loopsBBox(map, loops);
        auto a    = computeFitAffine(box, keepAspect_ == "uniform");
        applyUvAffine(map, loops, a);

        if (rec) ed.recordMapValueDiff(kUvMapName, pre, null,
                                       MeshEditScope.Material);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        return revertMapEditEmptyOk(mesh, undo_, applied_);
    }
}

// ---------------------------------------------------------------------------
// uv.pack
// ---------------------------------------------------------------------------

class UvPack : Command {
    private float        gutter_ = 0.0f;
    private RecordedUndo undo_;
    /// The forward SUCCEEDED. NOT derivable from `undo_`/`snap`, and the three
    /// shipped cells that caught the attempt say why: these commands' `revert()`
    /// must answer FALSE when the forward refused or never ran
    /// (`test_uv_transform.d` "revert without apply must return false",
    /// `test_uv_pack.d`, `test_uv_project.d`) and TRUE when the forward
    /// SUCCEEDED while moving nothing a bitwise diff could see (regression
    /// 0099: `CommandHistory.undo` discards an entry whose revert answers false
    /// AND its whole trailing suffix). Both states are "no delta and no
    /// snapshot", so only a bit set by the forward can separate them.
    private bool applied_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see UvFit.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.pack"; }
    override string label() const { return "Pack UV Islands"; }

    override Param[] params() {
        return [
            Param.float_("gutter", "Gutter", &gutter_, 0.0f).min(0.0f),
        ];
    }

    protected override bool applyImpl() {
        validateUvMap(mesh, name());
        auto loops = collectAffectedUvLoops(*mesh);
        if (loops.length == 0) return false;

        applied_ = runMapEdit(mesh, undo_, MeshEditScope.Material,
                          (ref MeshEditBatch ed) => kernel(ed, loops));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, size_t[] loops) {
        auto map = ed.mesh.meshMap(kUvMapName);
        assert(map !is null, "uv.pack: the map resolved in applyImpl vanished "
                           ~ "before the kernel ran");

        // Detect islands.
        size_t count;
        auto islandOf = computeUvIslands(ed.mesh, map, loops, count);

        // Build per-island loop lists and bboxes.
        auto islandLoops = new size_t[][](count);
        foreach (l; loops) {
            const size_t id = islandOf[l];
            if (id != size_t.max)
                islandLoops[id] ~= l;
        }

        auto boxes = new UvBBox[](count);
        foreach (id; 0 .. count)
            boxes[id] = loopsBBox(map, islandLoops[id]);

        // Compute per-island pack affines.
        auto affines = computeShelfPack(boxes, gutter_);

        // The pre-op image goes LAST, immediately before the write, and only
        // on the recording arm: everything above is read-only planning and a
        // `dup` taken earlier would be held across it for nothing.
        float[] pre;
        const bool rec = ed.recording();
        if (rec) pre = map.data.dup;

        foreach (id; 0 .. count)
            applyUvAffine(map, islandLoops[id], affines[id]);

        // ONE entry for ALL the islands. The recorder diffs the finished map,
        // so the per-island structure of the forward is irrelevant to the
        // undo — which is also why an island count of zero is not a special
        // case: nothing moved, `recordMapValueDiff` records nothing, and the
        // delta stays empty.
        if (rec) ed.recordMapValueDiff(kUvMapName, pre, null,
                                       MeshEditScope.Material);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        return revertMapEditEmptyOk(mesh, undo_, applied_);
    }
}
