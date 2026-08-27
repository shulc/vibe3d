module commands.mesh.uv_project;

/// `uv.project` — generate or overwrite the active "uv" PolyVertex MeshMap
/// from one of four standard projections: planar, box, cylindrical, spherical.
///
/// Scope: all faces (whole mesh), or — when any face is marked selected —
/// only those faces' corners.  Selection is EditMode-agnostic: stale face
/// marks from a prior polygon-mode selection are honoured regardless of the
/// current edit mode.
///
/// Create-if-absent: unlike uv.flip/mirror/rotate (which require an existing
/// map), uv.project CREATES the map when absent.
///
/// UNDO IS A RECORDED `MeshOpEntry.Kind.MapValueDelta` SINCE TASK 1903 STAGE
/// L1-b — and this command is one of the two HYBRIDS, so it records ONE of
/// TWO shapes depending on which branch its create-if-absent took:
///
///   * the map EXISTED  → `MapOp.Values`, recorded post-hoc by
///     `MeshEditBatch.recordMapValueDiff` against a pre-op image. Mode C.
///   * the map was ABSENT → `MapOp.Create`, `WholeArray`, carrying the
///     projected content. NOT `DefaultInit`: `MeshSessionEdit` replays a delta
///     FORWARD for redo (`session_edit.d:140`), so a default-init create would
///     redo into a map with the right name, domain, dim and LENGTH and every
///     value zero. The undo direction is the same either way — the arm's
///     reverse un-registers the map, which is what the wholesale
///     `MeshSnapshot.restore` used to do implicitly.
///
/// It is ONE entry, never two: a Create that carries its content already says
/// everything the pair (create, then fill) would.
///
/// Ordering invariant (blocker fix), unchanged in substance and now expressed
/// as "everything that can refuse happens before the batch opens" — a throw
/// out of an open batch leaves `~MeshEditBatch` to tick `changeBus.batchLeaks`:
///   (a) read-only face walk + empty-check  → BEFORE any mutation
///   (b) return false if affected set empty → mesh untouched, no orphan map
///   (c) validate an EXISTING map, or pre-check the MAX_MESH_MAPS ceiling
///   (d) open the batch; create-if-absent inside it
///   (e) write UV data, record, commitChange(Material)

import command;
import mesh     : Mesh, MeshMap, MapDomain, MeshEditBatch, kUvMapName,
                  MAX_MESH_MAPS;
import math     : Vec3;
import view     : View;
import editmode : EditMode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params   : Param;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEditEmptyOk;
import uv_project : UvProjMode, UvProjAxis, projectUv;

/// One affected corner: its owning face index and its loop index. At module
/// scope rather than inside `applyImpl` so the kernel can take it as a
/// parameter; `Box` needs `fi` for `faceNormal` and a flat loop list loses it.
package struct UvLoopRef { uint fi; size_t loop; }

// ---------------------------------------------------------------------------
// UvProject command
// ---------------------------------------------------------------------------

class UvProject : Command {
    private string mode_   = "planar";
    private string axis_   = "z";
    private float  size_   = 1.0f;
    private string center_ = "origin";

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
        /// green over a deleted recorder; only reading the log is not — and
        /// here the log's SHAPE is the whole point, because this command
        /// records `Create` or `Values` depending on a branch.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.project"; }
    override string label() const { return "Project UVs"; }

    override Param[] params() {
        return [
            Param.enum_("mode",   "Projection", &mode_,
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
        ];
    }

    protected override bool applyImpl() {
        // -----------------------------------------------------------------
        // (a) READ-ONLY face walk: build affected (fi, loop) list and
        //     simultaneously accumulate the vertex-position bbox for the
        //     optional center=bbox mode.  This walk touches only
        //     faces/loops/faceCornerLoop — never the UV map — so it is safe
        //     to run before the map exists.
        // -----------------------------------------------------------------
        bool anyFaceSelected = false;
        foreach (fi; 0 .. mesh.faces.length) {
            if (mesh.isFaceSelected(fi)) { anyFaceSelected = true; break; }
        }

        UvLoopRef[] affected;

        float bxMin = float.infinity, bxMax = -float.infinity;
        float byMin = float.infinity, byMax = -float.infinity;
        float bzMin = float.infinity, bzMax = -float.infinity;

        foreach (uint fi; 0 .. cast(uint) mesh.faces.length) {
            if (anyFaceSelected && !mesh.isFaceSelected(fi)) continue;
            const uint nc = cast(uint) mesh.faces[fi].length;
            foreach (uint c; 0 .. nc) {
                const size_t l = mesh.faceCornerLoop(fi, c);
                if (l == size_t.max) continue; // bounds guard
                affected ~= UvLoopRef(fi, l);
                // Accumulate vertex-position bbox for center=bbox.
                Vec3 pos = mesh.vertices[mesh.loops[l].vert];
                if (pos.x < bxMin) bxMin = pos.x;
                if (pos.x > bxMax) bxMax = pos.x;
                if (pos.y < byMin) byMin = pos.y;
                if (pos.y > byMax) byMax = pos.y;
                if (pos.z < bzMin) bzMin = pos.z;
                if (pos.z > bzMax) bzMax = pos.z;
            }
        }

        // -----------------------------------------------------------------
        // (b) Empty-check BEFORE any mutation.
        //     Zero-face mesh or a face-selected scope with no selected faces
        //     → return false.  No snapshot taken, no map created: the mesh
        //     is left completely clean so the dispatcher discards without
        //     calling revert(), leaving no orphan map.
        // -----------------------------------------------------------------
        if (affected.length == 0) return false;

        // -----------------------------------------------------------------
        // (c) Resolve projection parameters.
        // -----------------------------------------------------------------
        Vec3 ctr = (center_ == "bbox")
            ? Vec3((bxMin + bxMax) * 0.5f,
                   (byMin + byMax) * 0.5f,
                   (bzMin + bzMax) * 0.5f)
            : Vec3(0, 0, 0);

        float sz = (size_ > 0.0f) ? size_ : 1.0f; // guard zero/negative

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
        // (d) EVERY REFUSAL, RESOLVED BEFORE THE BATCH OPENS. An existing map
        //     is validated here; an absent one only needs the per-mesh map
        //     ceiling checked, which is the only other way `addMeshMap`
        //     answers null once the name is known to be free.
        // -----------------------------------------------------------------
        auto pre = mesh.meshMap(kUvMapName);
        if (pre is null) {
            if (mesh.meshMaps.length >= MAX_MESH_MAPS)
                throw new Exception(
                    "uv.project: this mesh already carries the maximum number "
                  ~ "of maps");
        } else {
            if (pre.dim != 2 || pre.domain != MapDomain.PolyVertex)
                throw new Exception("uv.project: existing UV map has wrong dim/domain");
            if (pre.data.length != mesh.loops.length * 2)
                throw new Exception("uv.project: UV map data out of sync with loop count");
        }

        applied_ = runMapEdit(mesh, undo_, snap, MeshEditScope.Material,
                          (ref MeshEditBatch ed) =>
                              kernel(ed, affected, mode, axis, ctr, sz));
        return applied_;
    }

    private bool kernel(ref MeshEditBatch ed, UvLoopRef[] affected,
                        UvProjMode mode, UvProjAxis axis, Vec3 ctr, float sz) {
        // -----------------------------------------------------------------
        // (e) Create-if-absent, INSIDE the batch. `created` is what decides
        //     which of the two entry shapes this command records, so it is a
        //     local rather than a re-derivation later: after the write the
        //     map exists either way and the branch is no longer visible.
        // -----------------------------------------------------------------
        auto map = ed.mesh.meshMap(kUvMapName);
        const bool created = (map is null);
        if (created)
            map = ed.mesh.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
        assert(map !is null, "uv.project: addMeshMap refused after applyImpl "
                           ~ "pre-checked the map cap");

        // The pre-op image, ONLY when there is a diff to take and ONLY on the
        // recording arm. A freshly created map needs none: its whole content
        // rides on the `Create` entry.
        const bool rec = ed.recording();
        float[] preData;
        if (rec && !created) preData = map.data.dup;

        // -----------------------------------------------------------------
        // (f) Write UVs.
        // -----------------------------------------------------------------
        // Cache faceNormal per face: affected is grouped by fi (outer loop),
        // so lastFi tracks the previous entry and we recompute only on face
        // transitions.  For non-Box modes faceNormal is never read by
        // projectUv, so we skip it entirely.
        uint lastFi = uint.max;
        Vec3 fn     = Vec3(0, 0, 1); // dummy; overwritten before first Box use
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

        if (rec) {
            if (created)
                ed.rec.recordMapCreateFilledOwned(kUvMapName, map.dim, map.domain,
                                                  map.kind,
                                                  map.data.dup, map.present.dup);
            else
                ed.recordMapValueDiff(kUvMapName, preData, null,
                                      MeshEditScope.Material);
        }
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        return revertMapEditEmptyOk(mesh, undo_, snap, applied_);
    }
}
