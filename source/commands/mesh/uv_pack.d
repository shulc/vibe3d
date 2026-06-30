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
///   - Undo via MeshSnapshot (snapshot.d deep-dups meshMaps).
///   - commitChange(MeshEditScope.Material) — UV is a material-domain edit.
///
/// EditMode-agnostic footgun: stale face marks from a prior polygon-mode
/// selection are honoured regardless of the current edit mode.  A face-scoped
/// UV edit can fire even when the user is in vertex or edge mode.

import command;
import mesh            : Mesh, MeshMap, MapDomain, kUvMapName;
import view            : View;
import editmode        : EditMode;
import snapshot        : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params          : Param;
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
    private MeshSnapshot snap_;

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

    override bool apply() {
        auto map   = validateUvMap(mesh, name());
        auto loops = collectAffectedUvLoops(*mesh);
        if (loops.length == 0) return false;

        snap_ = MeshSnapshot.capture(*mesh);

        auto box  = loopsBBox(map, loops);
        auto a    = computeFitAffine(box, keepAspect_ == "uniform");
        applyUvAffine(map, loops, a);
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap_.filled) return false;
        snap_.restore(*mesh);
        return true;
    }
}

// ---------------------------------------------------------------------------
// uv.pack
// ---------------------------------------------------------------------------

class UvPack : Command {
    private float        gutter_ = 0.0f;
    private MeshSnapshot snap_;

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

    override bool apply() {
        auto map   = validateUvMap(mesh, name());
        auto loops = collectAffectedUvLoops(*mesh);
        if (loops.length == 0) return false;

        // Detect islands.
        size_t count;
        auto islandOf = computeUvIslands(*mesh, map, loops, count);

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

        // Apply: snapshot before mutation.
        snap_ = MeshSnapshot.capture(*mesh);

        foreach (id; 0 .. count)
            applyUvAffine(map, islandLoops[id], affines[id]);

        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap_.filled) return false;
        snap_.restore(*mesh);
        return true;
    }
}
