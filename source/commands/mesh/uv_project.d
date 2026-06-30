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
/// map), uv.project CREATES the map when absent.  Undo restores the complete
/// pre-create state (snapshot precedes addMeshMap — snapshot.d:97 wholesale
/// meshMaps restore removes the freshly created map).
///
/// Ordering invariant (blocker fix):
///   (a) read-only face walk + empty-check  → must run BEFORE any mutation
///   (b) return false if affected set empty  → mesh untouched, no orphan map
///   (c) MeshSnapshot.capture               → snapshot first
///   (d) meshMap(name) ?? addMeshMap(...)   → create-if-absent AFTER snapshot
///   (e) write UV data, commitChange(Material)

import command;
import mesh     : Mesh, MeshMap, MapDomain, kUvMapName;
import math     : Vec3;
import view     : View;
import editmode : EditMode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params   : Param;
import uv_project : UvProjMode, UvProjAxis, projectUv;

// ---------------------------------------------------------------------------
// UvProject command
// ---------------------------------------------------------------------------

class UvProject : Command {
    private string mode_   = "planar";
    private string axis_   = "z";
    private float  size_   = 1.0f;
    private string center_ = "origin";

    private MeshSnapshot snap;

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

    override bool apply() {
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

        // Per-loop record: owning face index + loop index (needed by Box for
        // faceNormal; flat-loop collectors lose fi).
        struct LoopRef { uint fi; size_t loop; }
        LoopRef[] affected;

        float bxMin = float.infinity, bxMax = -float.infinity;
        float byMin = float.infinity, byMax = -float.infinity;
        float bzMin = float.infinity, bzMax = -float.infinity;

        foreach (uint fi; 0 .. cast(uint) mesh.faces.length) {
            if (anyFaceSelected && !mesh.isFaceSelected(fi)) continue;
            const uint nc = cast(uint) mesh.faces[fi].length;
            foreach (uint c; 0 .. nc) {
                const size_t l = mesh.faceCornerLoop(fi, c);
                if (l == size_t.max) continue; // bounds guard
                affected ~= LoopRef(fi, l);
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
        // (d) Snapshot FIRST — before addMeshMap — so revert() restores the
        //     pre-create state.  snapshot.d:97 does a wholesale meshMaps
        //     replace, so a snapshot taken before addMeshMap causes restore()
        //     to remove the freshly created map (it was not in the snapshot).
        // -----------------------------------------------------------------
        snap = MeshSnapshot.capture(*mesh);

        // -----------------------------------------------------------------
        // (e) Create-if-absent.
        //     meshMap returns null if absent → addMeshMap creates and sizes
        //     the map to loops.length*2 zero-filled.
        //     If the map already exists, validate it before overwriting.
        // -----------------------------------------------------------------
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            map = mesh.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
        if (map is null)
            throw new Exception("uv.project: addMeshMap failed unexpectedly");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.project: existing UV map has wrong dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.project: UV map data out of sync with loop count");

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
            Vec3 pos = mesh.vertices[mesh.loops[lr.loop].vert];
            if (mode == UvProjMode.Box && lr.fi != lastFi) {
                fn     = mesh.faceNormal(lr.fi);
                lastFi = lr.fi;
            }
            float[2] uv = projectUv(pos, mode, axis, ctr, sz, fn);
            map.data[lr.loop * 2]     = uv[0];
            map.data[lr.loop * 2 + 1] = uv[1];
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
