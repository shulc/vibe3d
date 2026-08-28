module commands.mesh.uv_transform;

/// Commands `uv.flip`, `uv.mirror`, `uv.rotate` — batch affine transforms
/// on the active UV map (`kUvMapName`, MapDomain.PolyVertex, dim==2).
///
/// Scope: the whole UV map, or — when faces are selected — only the selected
/// faces' corners.  Selection is **EditMode-agnostic**: stale face marks from
/// a prior face-mode selection are honoured regardless of the current edit
/// mode.  If the user is in vertex/edge mode but has face marks set (e.g.
/// from a previous polygon-mode selection), those faces' corners will be the
/// affected set.  Document this footgun in command help so the behaviour is
/// discoverable.
///
/// Error contracts:
///   - Missing UV map (`kUvMapName` not found, or dim≠2/domain≠PolyVertex):
///     throws with a descriptive message → HTTP dispatcher returns status:error.
///   - Empty affected corner set (only possible when selected-faces mode yields
///     zero corners, e.g. on an empty mesh): returns `false` → dispatcher
///     returns status:error with NO history entry recorded.
///
/// UNDO IS A RECORDED `MeshOpEntry.Kind.MapValueDelta` SINCE TASK 1903 STAGE
/// L1-b, through the POST-HOC door `MeshEditBatch.recordMapValueDiff`:
/// `applyUvAffine` takes the map pointer and writes it, so the command holds a
/// pre-op image and the DIFF against the live map is the record. Kernel
/// signatures are unchanged. Task 1903 Stage N deleted the escape hatch, so
/// the recorded delta is now the ONLY undo image this file has.
///
/// MODE C, and the ratio is stated rather than assumed: these three rewrite
/// every affected corner, so the payload is two whole images of the map —
/// ~6.10 MB against the 20.81 MB whole-mesh capture at 99 856 faces, a ratio
/// of 3.4x that is SCALE-INVARIANT (task 2210). The owner accepted it because
/// the absolute saving is 71 % of the dense side, not because the ratio is
/// large; do not read the small ratio as "barely worth it".
///
/// THE PRE-OP `dup` IS BEHIND `ed.recording()`. It is the whole payload, and
/// paying it on the redo and hatch arms is exactly what made four L0-d
/// commands twice as slow (task 2160, plan §K.5 rule 2).

import command;
import mesh           : Mesh, MapDomain, MeshEditBatch, kUvMapName;
import view           : View;
import editmode       : EditMode;
import mesh_edit_delta : MeshEditScope;
import params         : Param;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit;
import uv_transform;

// ---------------------------------------------------------------------------
// uv.flip — flip (negate) UV coords on one axis about a fixed pivot.
//
// Default axis: "u".  Default pivot: "unit" (0.5, 0.5), so axis=u gives
// u' = 1 − u.  The pivot can be overridden to "origin" (0,0) or "centroid"
// (bbox centre of the affected corners).
//
// Note: "uv.flip" and "uv.mirror" are intentionally distinct commands —
// flip's default pivot is the canonical unit-square centre, mirror's default
// is the centroid of the affected corner set (an in-place mirror).
// ---------------------------------------------------------------------------

class UvFlip : Command {
    private string       axis_  = "u";
    private string       pivot_ = "unit";
    private RecordedUndo undo_;
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

    override string name()  const { return "uv.flip"; }
    override string label() const { return "Flip UVs"; }

    override Param[] params() {
        return [
            Param.enum_("axis",  "Axis",  &axis_,
                        [["u","U"],["v","V"]], "u"),
            Param.enum_("pivot", "Pivot", &pivot_,
                        [["unit","Unit"],["origin","Origin"],
                         ["centroid","Centroid"]], "unit"),
        ];
    }

    protected override bool applyImpl() {
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            throw new Exception(
                "uv.flip: no UV map found ('" ~ kUvMapName ~ "'); "
                ~ "load a mesh with UV data first");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.flip: UV map has unexpected dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.flip: UV map data out of sync");

        auto loops = collectAffectedUvLoops(*mesh);
        // Empty only when selected-faces mode yields zero corners (e.g. an
        // empty mesh). Return false BEFORE the batch opens — no undo image, no
        // history entry, and nothing to roll back.
        if (loops.length == 0) return false;

        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Material,
                          (ref MeshEditBatch ed) => kernel(ed, loops));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, size_t[] loops) {
        auto map = ed.mesh.meshMap(kUvMapName);
        assert(map !is null, "uv.flip: the map resolved in applyImpl "
                           ~ "vanished before the kernel ran");
        // ONE block `dup` of the payload, and ONLY on the recording arm.
        float[] pre;
        const bool rec = ed.recording();
        if (rec) pre = map.data.dup;

        const UvPivot pv    = parsePivot(pivot_);
        float[2]      pivot = computePivot(map, loops, pv);
        auto          a     = (axis_ == "v") ? makeFlipV(pivot) : makeFlipU(pivot);
        applyUvAffine(map, loops, a);

        // THE POST-HOC DOOR. `applyUvAffine` has already written; asking the
        // setters to re-announce those values would record nothing useful and
        // re-publish per element, so the diff against `pre` IS the record. It
        // publishes `Material` — the class this command has always published —
        // so the recorded arm's stamp equals the redo and hatch arms'.
        if (rec) ed.recordMapValueDiff(kUvMapName, pre, null,
                                       MeshEditScope.Material);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
    }
}

// ---------------------------------------------------------------------------
// uv.mirror — same geometry as uv.flip but default pivot is the centroid of
// the affected corners (bbox centre of the affected UV coordinates).  This
// gives a true in-place mirror of the UV island rather than a reflection about
// the unit-square centre.
// ---------------------------------------------------------------------------

class UvMirror : Command {
    private string       axis_  = "u";
    private string       pivot_ = "centroid";
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see UvFlip.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.mirror"; }
    override string label() const { return "Mirror UVs"; }

    override Param[] params() {
        return [
            Param.enum_("axis",  "Axis",  &axis_,
                        [["u","U"],["v","V"]], "u"),
            Param.enum_("pivot", "Pivot", &pivot_,
                        [["unit","Unit"],["origin","Origin"],
                         ["centroid","Centroid"]], "centroid"),
        ];
    }

    protected override bool applyImpl() {
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            throw new Exception(
                "uv.mirror: no UV map found ('" ~ kUvMapName ~ "')");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.mirror: UV map has unexpected dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.mirror: UV map data out of sync");

        auto loops = collectAffectedUvLoops(*mesh);
        // Empty only when selected-faces mode yields zero corners (e.g. an
        // empty mesh). Return false BEFORE the batch opens — no undo image, no
        // history entry, and nothing to roll back.
        if (loops.length == 0) return false;

        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Material,
                          (ref MeshEditBatch ed) => kernel(ed, loops));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, size_t[] loops) {
        auto map = ed.mesh.meshMap(kUvMapName);
        assert(map !is null, "uv.mirror: the map resolved in applyImpl "
                           ~ "vanished before the kernel ran");
        // ONE block `dup` of the payload, and ONLY on the recording arm.
        float[] pre;
        const bool rec = ed.recording();
        if (rec) pre = map.data.dup;

        const UvPivot pv    = parsePivot(pivot_);
        float[2]      pivot = computePivot(map, loops, pv);
        auto          a     = (axis_ == "v") ? makeFlipV(pivot) : makeFlipU(pivot);
        applyUvAffine(map, loops, a);

        // THE POST-HOC DOOR. `applyUvAffine` has already written; asking the
        // setters to re-announce those values would record nothing useful and
        // re-publish per element, so the diff against `pre` IS the record. It
        // publishes `Material` — the class this command has always published —
        // so the recorded arm's stamp equals the redo and hatch arms'.
        if (rec) ed.recordMapValueDiff(kUvMapName, pre, null,
                                       MeshEditScope.Material);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
    }
}

// ---------------------------------------------------------------------------
// uv.rotate — rotate UV coords CCW by `angle` degrees about a pivot.
//
// Default: 90° CCW about the centroid of the affected corners.  A positive
// angle is CCW; a negative angle is CW.
// ---------------------------------------------------------------------------

class UvRotate : Command {
    private float        angle_ = 90.0f;
    private string       pivot_ = "centroid";
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see UvFlip.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.rotate"; }
    override string label() const { return "Rotate UVs"; }

    override Param[] params() {
        return [
            Param.float_("angle", "Angle (deg)", &angle_, 90.0f).angle(),
            Param.enum_("pivot", "Pivot", &pivot_,
                        [["unit","Unit"],["origin","Origin"],
                         ["centroid","Centroid"]], "centroid"),
        ];
    }

    protected override bool applyImpl() {
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            throw new Exception(
                "uv.rotate: no UV map found ('" ~ kUvMapName ~ "')");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.rotate: UV map has unexpected dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.rotate: UV map data out of sync");

        auto loops = collectAffectedUvLoops(*mesh);
        // Empty only when selected-faces mode yields zero corners (e.g. an
        // empty mesh). Return false BEFORE the batch opens — no undo image, no
        // history entry, and nothing to roll back.
        if (loops.length == 0) return false;

        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Material,
                          (ref MeshEditBatch ed) => kernel(ed, loops));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, size_t[] loops) {
        auto map = ed.mesh.meshMap(kUvMapName);
        assert(map !is null, "uv.rotate: the map resolved in applyImpl "
                           ~ "vanished before the kernel ran");
        // ONE block `dup` of the payload, and ONLY on the recording arm.
        float[] pre;
        const bool rec = ed.recording();
        if (rec) pre = map.data.dup;

        const UvPivot pv    = parsePivot(pivot_);
        float[2]      pivot = computePivot(map, loops, pv);
        auto          a     = makeRotate(angle_, pivot);
        applyUvAffine(map, loops, a);

        // THE POST-HOC DOOR. `applyUvAffine` has already written; asking the
        // setters to re-announce those values would record nothing useful and
        // re-publish per element, so the diff against `pre` IS the record. It
        // publishes `Material` — the class this command has always published —
        // so the recorded arm's stamp equals the redo and hatch arms'.
        if (rec) ed.recordMapValueDiff(kUvMapName, pre, null,
                                       MeshEditScope.Material);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
    }
}

// ---------------------------------------------------------------------------
// Shared pivot-name parser (private to this module).
// ---------------------------------------------------------------------------

private UvPivot parsePivot(string s) {
    switch (s) {
        case "origin":   return UvPivot.Origin;
        case "centroid": return UvPivot.Centroid;
        default:         return UvPivot.Unit;
    }
}
