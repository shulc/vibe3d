module commands.mesh.uv_relax;

/// Command `uv.relax` — N Jacobi uniform-Laplacian passes over the per-corner
/// UV map.  Interior UV vertices move toward the mean of their UV neighbours;
/// boundary / seam UV vertices are pinned.
///
/// Error contracts (identical to uv.flip / uv.rotate):
///   - Missing UV map      → throws → HTTP status:error.
///   - UV map dim ≠ 2 or domain ≠ PolyVertex → throws → HTTP status:error.
///   - UV data out of sync (data.length ≠ loops.length*2) → throws.
///   - All UV vertices pinned, or iter < 1, or strn == 0 → returns false
///     → HTTP status:error, NO history entry (no-op convention).
///
/// Undo: a recorded `MeshOpEntry.Kind.MapValueDelta` since task 1903 Stage
/// L1-b, through the post-hoc door `MeshEditBatch.recordMapValueDiff` —
/// `uvRelax` takes a `const ref Mesh` plus the map pointer and writes through
/// it, so the command holds a pre-op image and the DIFF is the record. The
/// kernel signature is UNCHANGED. Task 1903 Stage N deleted the escape hatch,
/// so the recorded delta is now the only undo image this file has.
///
/// THE REFUSAL ARM IS SAFE TO TAKE FROM INSIDE THE BATCH, and that is a
/// property of the kernel rather than an assumption: every `return false` in
/// `uvRelax` — `iterations < 1`, `strength == 0`, no loops, nothing relaxable
/// — precedes its first write, so a refusal leaves the map untouched and
/// there is nothing to roll back. `uv.unwrap`'s kernel does NOT have that
/// property (it writes its seed first) and its command says so at its own
/// site.

import command;
import mesh            : Mesh, MapDomain, MeshEditBatch, kUvMapName;
import view            : View;
import editmode        : EditMode;
import mesh_edit_delta : MeshEditScope;
import params          : Param;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEditEmptyOk;
import uv_relax        : uvRelax;

class UvRelax : Command {
    private int          iter_ = 5;
    private float        strn_ = 0.5f;
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

    override string name()  const { return "uv.relax"; }
    override string label() const { return "Relax UVs"; }

    override Param[] params() {
        return [
            // `.max(256).enforceBounds()` matches uvRelax's internal
            // `MAX_UV_RELAX_ITER` cap — the Param bound alone is a UI-only
            // hint and does not clamp a raw HTTP write.
            Param.int_  ("iter", "Iterations", &iter_, 5).min(0).max(256).enforceBounds(),
            Param.float_("strn", "Strength",   &strn_, 0.5f).min(0.0f).max(1.0f),
        ];
    }

    protected override bool applyImpl() {
        // Validate map — same three guards as uv.flip (uv_transform.d:68-76).
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            throw new Exception(
                "uv.relax: no UV map found ('" ~ kUvMapName ~ "'); "
                ~ "load a mesh with UV data first");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.relax: UV map has unexpected dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.relax: UV map data out of sync");

        // Selection scope: pin corners of unselected faces when any face is
        // selected; null = whole-map mode (no selection restriction).
        const bool[] cp = buildCornerPinned(*mesh);

        applied_ = runMapEdit(mesh, undo_, MeshEditScope.Material,
                          (ref MeshEditBatch ed) => kernel(ed, cp));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, const bool[] cp) {
        auto map = ed.mesh.meshMap(kUvMapName);
        assert(map !is null, "uv.relax: the map resolved in applyImpl "
                           ~ "vanished before the kernel ran");
        // ONE block `dup` of the payload, and ONLY on the recording arm
        // (plan §K.5 rules 2 and 3).
        float[] pre;
        const bool rec = ed.recording();
        if (rec) pre = map.data.dup;

        // A refusal here is a TRUE no-op — see the module header — so simply
        // returning false is correct: `runMapEdit` closes the batch, disarms
        // the delta, and `applyImpl` answers false, which lands no history
        // entry. Nothing was written and nothing is rolled back.
        if (!uvRelax(ed.mesh, map, iter_, strn_, cp)) return false;

        if (rec) ed.recordMapValueDiff(kUvMapName, pre, null,
                                       MeshEditScope.Material);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        return revertMapEditEmptyOk(mesh, undo_, applied_);
    }
}

// Build the cornerPinned mask for selected-face scope restriction.
// Returns null (no restriction) when no face is currently selected.
// When faces are selected: pinned[L] = true for loops of UNSELECTED faces,
// false for loops of selected faces.  The kernel then treats the UV classes
// of unselected corners as pinned even if they are topologically interior.
private bool[] buildCornerPinned(const ref Mesh m) {
    bool anySelected = false;
    foreach (fi; 0 .. m.faces.length)
        if (m.isFaceSelected(fi)) { anySelected = true; break; }
    if (!anySelected) return null;

    bool[] p = new bool[](m.loops.length);
    p[] = true;   // start: all corners pinned
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        foreach (uint c; 0 .. cast(uint) m.faces[fi].length) {
            const size_t loop = m.faceCornerLoop(fi, c);
            if (loop != size_t.max && loop < p.length)
                p[loop] = false;   // un-pin: this is a selected-face corner
        }
    }
    return p;
}
