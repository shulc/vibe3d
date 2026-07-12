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
/// Ordering invariant (same as uv.project):
///   (a) read-only walk + empty-check  → before any mutation
///   (b) MeshSnapshot.capture          → snapshot first
///   (c) create-if-absent addMeshMap   → after snapshot
///   (d) write seed via projectUv
///   (e) build seamLoop[] + cornerPinned[]
///   (f) call uvUnwrap; iter=0 → commit seed only; iter>0 + false → restore
///   (g) commitChange(Material)
///
/// Error contracts (mirrors uv.project / uv.relax family):
///   - zero affected loops         → false (no map created, mesh clean)
///   - wrong dim / domain on map   → throws → status:error
///   - uvUnwrap returns false       → snapshot restored, returns false
///   - iter=0                      → seed only; committed, returns true

import command;
import mesh            : Mesh, MeshMap, MapDomain, kUvMapName;
import math            : Vec3;
import view            : View;
import editmode        : EditMode;
import snapshot        : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params          : Param;
import uv_project      : UvProjMode, UvProjAxis, projectUv;
import uv_unwrap       : uvUnwrap;

class UvUnwrap : Command {
    private string mode_   = "planar";  // default planar, NOT box (see plan)
    private string axis_   = "z";
    private float  size_   = 1.0f;
    private string center_ = "origin";
    private int    iter_   = 30;
    private string seams_  = "selected";

    private MeshSnapshot snap;

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

    override bool apply() {
        // -----------------------------------------------------------------
        // (a) Read-only walk: collect affected loops + bbox.
        // -----------------------------------------------------------------
        bool anyFaceSelected = false;
        foreach (fi; 0 .. mesh.faces.length)
            if (mesh.isFaceSelected(fi)) { anyFaceSelected = true; break; }

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
                if (l == size_t.max) continue;
                affected ~= LoopRef(fi, l);
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
        // (c) Snapshot FIRST — before addMeshMap — so revert() restores the
        //     pre-create state (snapshot.d wholesale meshMaps replace).
        // -----------------------------------------------------------------
        snap = MeshSnapshot.capture(*mesh);

        // -----------------------------------------------------------------
        // (d) Create-if-absent + validate.
        // -----------------------------------------------------------------
        auto map = mesh.meshMap(kUvMapName);
        if (map is null)
            map = mesh.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
        if (map is null)
            throw new Exception("uv.unwrap: addMeshMap failed unexpectedly");
        if (map.dim != 2 || map.domain != MapDomain.PolyVertex)
            throw new Exception("uv.unwrap: existing UV map has wrong dim/domain");
        if (map.data.length != mesh.loops.length * 2)
            throw new Exception("uv.unwrap: UV map data out of sync with loop count");

        // -----------------------------------------------------------------
        // (e) Write seed UVs via projectUv (same pattern as uv.project).
        // -----------------------------------------------------------------
        uint lastFi = uint.max;
        Vec3 fn     = Vec3(0, 0, 1);
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

        // -----------------------------------------------------------------
        // (f) Seed-only shortcut: iter=0 commits the seed and returns true.
        // -----------------------------------------------------------------
        if (iter_ <= 0) {
            mesh.commitChange(MeshEditScope.Material);
            return true;
        }

        // -----------------------------------------------------------------
        // (g) Build seamLoop[]: cuts at selected edges when seams=selected.
        //     Mesh boundary (twin==uint.max) is always a chart boundary and
        //     is handled inside uvUnwrap's weld loop directly.
        // -----------------------------------------------------------------
        bool[] seamLoop = null;
        if (seams_ == "selected" && mesh.loopEdge.length == mesh.loops.length) {
            seamLoop = new bool[](mesh.loops.length);
            foreach (L; 0 .. mesh.loops.length) {
                if (mesh.loops[L].twin == uint.max) continue; // boundary handled by kernel
                const size_t ei = mesh.loopEdge[L];
                if (ei < mesh.edges.length)
                    seamLoop[L] = mesh.isEdgeSelected(ei);
            }
        }

        // -----------------------------------------------------------------
        // (h) Build cornerPinned for selected-face scope.
        // -----------------------------------------------------------------
        const bool[] cp = buildCornerPinned(*mesh);

        // Re-fetch map pointer after potential meshMaps reallocation.
        map = mesh.meshMap(kUvMapName);

        // -----------------------------------------------------------------
        // (i) Run cotangent-weighted harmonic relax.
        //     If it returns false (all-pinned, no-pin guard, etc.), undo the
        //     seed write via the snapshot and report no-op.
        // -----------------------------------------------------------------
        if (!uvUnwrap(*mesh, map, iter_, seamLoop, cp)) {
            snap.restore(*mesh);       // undo seed write
            snap = MeshSnapshot.init;  // discard (no undo entry)
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
