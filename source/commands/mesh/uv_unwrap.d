module commands.mesh.uv_unwrap;

/// `uv.unwrap` — cotangent-weighted harmonic UV layout.
///
/// Seeds the "uv" PolyVertex map via `projectUv` (default mode=planar), then
/// runs `uvUnwrap` (cotan GS relax) to reduce angular distortion.
///
/// Seam modes:
///   boundary — cut at mesh boundary only (seams = mesh holes / open edges).
///   selected  — additionally cut at currently selected edges.
///
/// UNDO IS A RECORDED `MeshOpEntry.Kind.MapValueDelta` SINCE TASK 1903 STAGE
/// L1-b. Like `uv.project` this is a HYBRID and records one of two shapes: a
/// `MapOp.Create` in the `WholeArray` spelling when it created the map, and a
/// post-hoc `MapOp.Values` diff when it did not. `MeshSnapshot` is the escape
/// hatch's arm only.
///
/// THE ONE PLACE IN THE WHOLE L1 FAMILY WHERE A REFUSAL FOLLOWS A WRITE, and
/// it is why this file does not read like `uv.relax`. `uvUnwrap` is called
/// AFTER the seed has been written, and it can still answer false (no pinned
/// class, nothing relaxable). Before the migration that was undone by
/// `snap.restore` — a whole-mesh restore for a map-sized mistake. There is no
/// snapshot on the delta path, so the kernel keeps its OWN rollback image and
/// undoes exactly what it wrote: the map's `data` if it existed, the whole
/// registration if it did not.
///
/// THAT IMAGE IS NOT "BOOKKEEPING ON AN UNRECORDED PATH". It is the command's
/// own rollback, needed by every arm, and it is strictly CHEAPER than what it
/// replaces (one `float[].dup` of the map against a deep copy of the entire
/// mesh). Plan §K.5 rule 2 forbids paying for RECORDING on a path that does
/// not record; the recording-only cost here is the `preData` the diff needs,
/// and that one is behind `ed.recording()`.
///
/// Ordering invariant (same as uv.project):
///   (a) read-only walk + empty-check  → before any mutation
///   (b) validate an existing map, or pre-check MAX_MESH_MAPS → before the batch
///   (c) open the batch; create-if-absent inside it
///   (d) write seed via projectUv
///   (e) build seamLoop[] + cornerPinned[]
///   (f) call uvUnwrap; iter=0 → commit seed only; iter>0 + false → roll the
///       seed back and return false
///   (g) record, commitChange(Material)
///
/// Error contracts (mirrors uv.project / uv.relax family):
///   - zero affected loops         → false (no map created, mesh clean)
///   - wrong dim / domain on map   → throws → status:error
///   - uvUnwrap returns false       → seed rolled back, returns false
///   - iter=0                      → seed only; committed, returns true

import command;
import mesh            : Mesh, MeshMap, MapDomain, MeshEditBatch, kUvMapName,
                         MAX_MESH_MAPS;
import math            : Vec3;
import view            : View;
import editmode        : EditMode;
import snapshot        : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params          : Param;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEditEmptyOk;
import commands.mesh.uv_project    : UvLoopRef;
import uv_project      : UvProjMode, UvProjAxis, projectUv;
import uv_unwrap       : uvUnwrap;

class UvUnwrap : Command {
    private string mode_   = "planar";  // default planar, NOT box (see plan)
    private string axis_   = "z";
    private float  size_   = 1.0f;
    private string center_ = "origin";
    private int    iter_   = 30;
    private string seams_  = "selected";

    private MeshSnapshot snap;      // the hatch's arm only
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

    override string name()  const { return "uv.unwrap"; }
    override string label() const { return "Unwrap UVs"; }

    override Param[] params() {
        return [
            Param.enum_("mode", "Projection", &mode_,
                        [["planar","Planar"],
                         ["box","Box"],
                         ["cylindrical","Cylindrical"],
                         ["spherical","Spherical"]],
                        "planar"),
            Param.enum_("axis",   "Axis",   &axis_,
                        [["x","X"],["y","Y"],["z","Z"]], "z"),
            Param.float_("size",  "Size",   &size_,  1.0f),
            Param.enum_("center", "Center", &center_,
                        [["origin","Origin"],["bbox","BBox"]], "origin"),
            // `.max(256).enforceBounds()` matches uvUnwrap's internal
            // `MAX_UV_UNWRAP_ITER` cap — the Param bound alone is a UI-only
            // hint and does not clamp a raw HTTP write.
            Param.int_  ("iter",  "Iterations", &iter_, 30).min(0).max(256).enforceBounds(),
            Param.enum_("seams", "Seams", &seams_,
                        [["boundary","Boundary"],["selected","Selected"]],
                        "selected"),
        ];
    }

    protected override bool applyImpl() {
        // -----------------------------------------------------------------
        // (a) Read-only walk: collect affected loops + bbox.
        // -----------------------------------------------------------------
        bool anyFaceSelected = false;
        foreach (fi; 0 .. mesh.faces.length)
            if (mesh.isFaceSelected(fi)) { anyFaceSelected = true; break; }

        UvLoopRef[] affected;

        float bxMin = float.infinity, bxMax = -float.infinity;
        float byMin = float.infinity, byMax = -float.infinity;
        float bzMin = float.infinity, bzMax = -float.infinity;

        foreach (uint fi; 0 .. cast(uint) mesh.faces.length) {
            if (anyFaceSelected && !mesh.isFaceSelected(fi)) continue;
            const uint nc = cast(uint) mesh.faces[fi].length;
            foreach (uint c; 0 .. nc) {
                const size_t l = mesh.faceCornerLoop(fi, c);
                if (l == size_t.max) continue;
                affected ~= UvLoopRef(fi, l);
                Vec3 pos = mesh.vertices[mesh.loops[l].vert];
                if (pos.x < bxMin) bxMin = pos.x;
                if (pos.x > bxMax) bxMax = pos.x;
                if (pos.y < byMin) byMin = pos.y;
                if (pos.y > byMax) byMax = pos.y;
                if (pos.z < bzMin) bzMin = pos.z;
                if (pos.z > bzMax) bzMax = pos.z;
            }
        }

        if (affected.length == 0) return false;

        // -----------------------------------------------------------------
        // (b) Resolve projection parameters.
        // -----------------------------------------------------------------
        Vec3 ctr = (center_ == "bbox")
            ? Vec3((bxMin + bxMax) * 0.5f,
                   (byMin + byMax) * 0.5f,
                   (bzMin + bzMax) * 0.5f)
            : Vec3(0, 0, 0);

        const float sz = (size_ > 0.0f) ? size_ : 1.0f;

        UvProjMode mode;
        switch (mode_) {
            case "box":         mode = UvProjMode.Box;         break;
            case "cylindrical": mode = UvProjMode.Cylindrical; break;
            case "spherical":   mode = UvProjMode.Spherical;   break;
            default:            mode = UvProjMode.Planar;       break;
        }

        UvProjAxis axis;
        switch (axis_) {
            case "x": axis = UvProjAxis.X; break;
            case "y": axis = UvProjAxis.Y; break;
            default:  axis = UvProjAxis.Z; break;
        }

        // -----------------------------------------------------------------
        // (b) EVERY REFUSAL THAT CAN BE RESOLVED WITHOUT WRITING, resolved
        //     BEFORE the batch opens — a throw out of an open batch leaves
        //     `~MeshEditBatch` to pop the frame and tick
        //     `changeBus.batchLeaks`, which the suite asserts is 0.
        // -----------------------------------------------------------------
        auto pre = mesh.meshMap(kUvMapName);
        if (pre is null) {
            if (mesh.meshMaps.length >= MAX_MESH_MAPS)
                throw new Exception(
                    "uv.unwrap: this mesh already carries the maximum number "
                  ~ "of maps");
        } else {
            if (pre.dim != 2 || pre.domain != MapDomain.PolyVertex)
                throw new Exception("uv.unwrap: existing UV map has wrong dim/domain");
            if (pre.data.length != mesh.loops.length * 2)
                throw new Exception("uv.unwrap: UV map data out of sync with loop count");
        }

        applied_ = runMapEdit(mesh, undo_, snap, MeshEditScope.Material,
                          (ref MeshEditBatch ed) =>
                              kernel(ed, affected, mode, axis, ctr, sz));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, UvLoopRef[] affected,
                        UvProjMode mode, UvProjAxis axis, Vec3 ctr, float sz) {
        // -----------------------------------------------------------------
        // (c) Create-if-absent.
        // -----------------------------------------------------------------
        auto map = ed.mesh.meshMap(kUvMapName);
        const bool created = (map is null);
        if (created)
            map = ed.mesh.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
        assert(map !is null, "uv.unwrap: addMeshMap refused after applyImpl "
                           ~ "pre-checked the map cap");

        // THE ROLLBACK IMAGE, taken on EVERY arm because (i) below can refuse
        // after the seed has been written. See the module header: this is not
        // recording bookkeeping, it is the command's own undo of a write it is
        // about to make, and it is cheaper than the whole-mesh snapshot it
        // replaces. `preData` is null when the map is new — the rollback there
        // is `removeMeshMap`, not a restore.
        float[] preData;
        if (!created) preData = map.data.dup;

        // -----------------------------------------------------------------
        // (d) Write seed UVs via projectUv (same pattern as uv.project).
        // -----------------------------------------------------------------
        uint lastFi = uint.max;
        Vec3 fn     = Vec3(0, 0, 1);
        foreach (ref lr; affected) {
            Vec3 pos = ed.mesh.vertices[ed.mesh.loops[lr.loop].vert];
            if (mode == UvProjMode.Box && lr.fi != lastFi) {
                fn     = ed.mesh.faceNormal(lr.fi);
                lastFi = lr.fi;
            }
            float[2] uv = projectUv(pos, mode, axis, ctr, sz, fn);
            map.data[lr.loop * 2]     = uv[0];
            map.data[lr.loop * 2 + 1] = uv[1];
        }

        // -----------------------------------------------------------------
        // (f) Seed-only shortcut: iter=0 commits the seed and returns true.
        // -----------------------------------------------------------------
        if (iter_ <= 0) {
            recordUnwrap(ed, map, created, preData);
            ed.commitChange(MeshEditScope.Material);
            return true;
        }

        // -----------------------------------------------------------------
        // (g) Build seamLoop[]: cuts at selected edges when seams=selected.
        //     Mesh boundary (twin==uint.max) is always a chart boundary and
        //     is handled inside uvUnwrap's weld loop directly.
        // -----------------------------------------------------------------
        bool[] seamLoop = null;
        if (seams_ == "selected" && ed.mesh.loopEdge.length == ed.mesh.loops.length) {
            seamLoop = new bool[](ed.mesh.loops.length);
            foreach (L; 0 .. ed.mesh.loops.length) {
                if (ed.mesh.loops[L].twin == uint.max) continue; // boundary handled by kernel
                const size_t ei = ed.mesh.loopEdge[L];
                if (ei < ed.mesh.edges.length)
                    seamLoop[L] = ed.mesh.isEdgeSelected(ei);
            }
        }

        // -----------------------------------------------------------------
        // (h) Build cornerPinned for selected-face scope.
        // -----------------------------------------------------------------
        const bool[] cp = buildCornerPinned(ed.mesh);

        // Re-fetch map pointer after potential meshMaps reallocation.
        map = ed.mesh.meshMap(kUvMapName);

        // -----------------------------------------------------------------
        // (i) Run cotangent-weighted harmonic relax.
        //     If it returns false (all-pinned, no-pin guard, etc.), undo the
        //     SEED WRITE and report no-op. Rolling back exactly what was
        //     written — the map's values, or the whole registration — is what
        //     the wholesale `MeshSnapshot.restore` did here before the
        //     migration; nothing else on the mesh has been touched.
        // -----------------------------------------------------------------
        if (!uvUnwrap(ed.mesh, map, iter_, seamLoop, cp)) {
            if (created) ed.mesh.removeMeshMap(kUvMapName);
            else         map.data[] = preData[];
            return false;
        }

        recordUnwrap(ed, map, created, preData);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    /// The ONE recording site, shared by the seed-only arm and the relaxed
    /// one so the two cannot drift into recording different shapes.
    private static void recordUnwrap(ref MeshEditBatch ed, MeshMap* map,
                                     bool created, const float[] preData) {
        if (!ed.recording()) return;
        if (created)
            // `WholeArray`, not `DefaultInit`: `MeshSessionEdit` replays a
            // delta FORWARD for redo (`session_edit.d:140`), and a
            // default-init create would redo into a correctly-shaped map of
            // zeros.
            ed.rec.recordMapCreateFilledOwned(kUvMapName, map.dim, map.domain,
                                              map.kind,
                                              map.data.dup, map.present.dup);
        else
            ed.recordMapValueDiff(kUvMapName, preData, null,
                                  MeshEditScope.Material);
    }

    override bool revert() {
        return revertMapEditEmptyOk(mesh, undo_, snap, applied_);
    }
}

// Build the cornerPinned mask for selected-face scope.
// Returns null when no face is selected (whole-map mode).
// When faces are selected: pinned[L] = true for loops of unselected faces.
private bool[] buildCornerPinned(const ref Mesh m) {
    bool anySelected = false;
    foreach (fi; 0 .. m.faces.length)
        if (m.isFaceSelected(fi)) { anySelected = true; break; }
    if (!anySelected) return null;

    bool[] p = new bool[](m.loops.length);
    p[] = true;
    foreach (uint fi; 0 .. cast(uint) m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        foreach (uint c; 0 .. cast(uint) m.faces[fi].length) {
            const size_t loop = m.faceCornerLoop(fi, c);
            if (loop != size_t.max && loop < p.length)
                p[loop] = false;
        }
    }
    return p;
}
