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
/// Undo: `MeshSnapshot` (snapshot.d:68 deep-dups `meshMaps`), verbatim
/// weightmap.d pattern — UV undo is free.

import command;
import mesh           : Mesh, MapDomain, kUvMapName;
import view           : View;
import editmode       : EditMode;
import snapshot       : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params         : Param;
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
    private MeshSnapshot snap;

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

    override bool apply() {
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
        // Empty only when selected-faces mode yields zero corners (e.g. empty
        // mesh).  Return false → no snapshot, no history entry.
        if (loops.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const UvPivot pv    = parsePivot(pivot_);
        float[2]      pivot = computePivot(map, loops, pv);
        auto          a     = (axis_ == "v") ? makeFlipV(pivot) : makeFlipU(pivot);
        applyUvAffine(map, loops, a);
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
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
    private MeshSnapshot snap;

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

    override bool apply() {
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            throw new Exception(
                "uv.mirror: no UV map found ('" ~ kUvMapName ~ "')");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.mirror: UV map has unexpected dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.mirror: UV map data out of sync");

        auto loops = collectAffectedUvLoops(*mesh);
        if (loops.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const UvPivot pv    = parsePivot(pivot_);
        float[2]      pivot = computePivot(map, loops, pv);
        auto          a     = (axis_ == "v") ? makeFlipV(pivot) : makeFlipU(pivot);
        applyUvAffine(map, loops, a);
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
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
    private MeshSnapshot snap;

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

    override bool apply() {
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            throw new Exception(
                "uv.rotate: no UV map found ('" ~ kUvMapName ~ "')");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.rotate: UV map has unexpected dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.rotate: UV map data out of sync");

        auto loops = collectAffectedUvLoops(*mesh);
        if (loops.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const UvPivot pv    = parsePivot(pivot_);
        float[2]      pivot = computePivot(map, loops, pv);
        auto          a     = makeRotate(angle_, pivot);
        applyUvAffine(map, loops, a);
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
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
