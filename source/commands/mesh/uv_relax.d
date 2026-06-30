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
/// Undo: MeshSnapshot deep-dups meshMaps, so UV undo is free.

import command;
import mesh            : Mesh, MapDomain, kUvMapName;
import view            : View;
import editmode        : EditMode;
import snapshot        : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params          : Param;
import uv_relax        : uvRelax;

class UvRelax : Command {
    private int          iter_ = 5;
    private float        strn_ = 0.5f;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.relax"; }
    override string label() const { return "Relax UVs"; }

    override Param[] params() {
        return [
            Param.int_  ("iter", "Iterations", &iter_, 5).min(0),
            Param.float_("strn", "Strength",   &strn_, 0.5f).min(0.0f).max(1.0f),
        ];
    }

    override bool apply() {
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

        // Snapshot before mutation (deep-dups meshMaps → UV undo is free).
        snap = MeshSnapshot.capture(*mesh);

        // Re-fetch map pointer (defensive after capture, which may reallocate
        // meshMaps to separate original from snapshot storage).
        map = mesh.meshMap(kUvMapName);

        if (!uvRelax(*mesh, map, iter_, strn_, cp)) {
            snap = MeshSnapshot.init;   // discard unused snapshot
            return false;
        }

        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
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
