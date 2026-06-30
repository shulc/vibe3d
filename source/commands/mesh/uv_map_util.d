module commands.mesh.uv_map_util;

import command;
import mesh            : Mesh, MapDomain, MeshMap, kUvMapName;
import view            : View;
import editmode        : EditMode;
import snapshot        : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params          : Param;

// ---------------------------------------------------------------------------
// UV map lifecycle commands.
//
// A UV map is a named MapDomain.PolyVertex dim=2 MeshMap — two floats (u,v)
// per face-corner (loop).  Four commands cover the authoring lifecycle:
//   uv.delete  {name="uv"}         — remove a named UV map
//   uv.rename  {from="uv", to}     — rename a UV map in place
//   uv.copy    {from="uv", to}     — duplicate a UV map under a new name
//   uv.clear   {name="uv"}         — zero a UV map's values
//
// All four use MeshSnapshot for undo (snapshot.d:68 deep-dups meshMaps so
// delete/rename/copy/clear are all reverted by a plain snapshot restore).
//
// Domain guard: `requireUvMap` rejects any map that is not PolyVertex dim=2
// with a data array sized to loops.length*2, so weight maps (Point dim=1)
// and colour maps (PolyVertex dim=3) are caught before any mutation.
// ---------------------------------------------------------------------------

// Shared validation helper.  Returns a non-null, size-consistent UV map
// pointer, or throws a descriptive Exception (→ HTTP status:error).
private MeshMap* requireUvMap(Mesh* mesh, string name) {
    auto m = mesh.meshMap(name);
    if (m is null)
        throw new Exception(
            "UV map '" ~ name ~ "' not found");
    if (m.domain != MapDomain.PolyVertex || m.dim != 2)
        throw new Exception(
            "map '" ~ name ~ "' is not a UV map (domain/dim mismatch)");
    if (m.data.length != mesh.loops.length * 2)
        throw new Exception(
            "UV map '" ~ name ~ "' data out of sync with mesh topology");
    return m;
}

// ---------------------------------------------------------------------------
// uv.delete — remove a named UV map.
// ---------------------------------------------------------------------------

class UvDelete : Command {
    private string       name_ = kUvMapName;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.delete"; }
    override string label() const { return "Delete UV Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, kUvMapName) ];
    }

    override bool apply() {
        requireUvMap(mesh, name_);   // throws if absent or not a UV map
        snap = MeshSnapshot.capture(*mesh);
        if (!mesh.removeMeshMap(name_)) {
            snap = MeshSnapshot.init;
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

// ---------------------------------------------------------------------------
// uv.rename — rename a UV map in place.
// ---------------------------------------------------------------------------

class UvRename : Command {
    private string       from_ = kUvMapName;
    private string       to_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.rename"; }
    override string label() const { return "Rename UV Map"; }

    override Param[] params() {
        return [
            Param.string_("from", "From", &from_, kUvMapName),
            Param.string_("to",   "To",   &to_,   ""),
        ];
    }

    override bool apply() {
        if (from_.length == 0 || to_.length == 0)
            throw new Exception(
                "uv.rename: from/to must not be empty");
        if (from_ == to_)
            throw new Exception(
                "uv.rename: from and to must not be identical");
        requireUvMap(mesh, from_);   // throws if absent or not a UV map
        if (mesh.meshMap(to_) !is null)
            throw new Exception(
                "uv.rename: target name '" ~ to_ ~ "' already exists");
        snap = MeshSnapshot.capture(*mesh);
        // Re-fetch after snapshot: capture() doesn't realloc meshMaps so
        // the pointer is valid, but a fresh lookup is defensive best practice.
        auto m = mesh.meshMap(from_);
        m.name = to_;
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
// uv.copy — duplicate a UV map under a new name.
//
// POINTER-SAFETY: addMeshMap does `meshMaps ~= m` which can reallocate the
// meshMaps array, invalidating any MeshMap* held before the call.  Capture
// src.dim and src.data.dup into LOCAL variables before calling addMeshMap;
// never dereference src after the append.
// ---------------------------------------------------------------------------

class UvCopy : Command {
    private string       from_ = kUvMapName;
    private string       to_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.copy"; }
    override string label() const { return "Copy UV Map"; }

    override Param[] params() {
        return [
            Param.string_("from", "From", &from_, kUvMapName),
            Param.string_("to",   "To",   &to_,   ""),
        ];
    }

    override bool apply() {
        if (from_.length == 0 || to_.length == 0)
            throw new Exception(
                "uv.copy: from/to must not be empty");
        if (from_ == to_)
            throw new Exception(
                "uv.copy: from and to must not be identical");
        auto src = requireUvMap(mesh, from_);   // throws if absent or not UV
        if (mesh.meshMap(to_) !is null)
            throw new Exception(
                "uv.copy: target name '" ~ to_ ~ "' already exists");
        // Snapshot src metadata to locals BEFORE addMeshMap (which can
        // reallocate meshMaps, invalidating src).
        const ubyte   srcDim  = src.dim;
        const float[] srcData = src.data.dup;
        snap = MeshSnapshot.capture(*mesh);
        auto dst = mesh.addMeshMap(to_, srcDim, MapDomain.PolyVertex);
        if (dst is null) {
            snap = MeshSnapshot.init;
            throw new Exception(
                "uv.copy: failed to create map '" ~ to_ ~ "'");
        }
        dst.data[] = srcData[];
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
// uv.clear — zero a UV map's values (reset to the default value 0.0).
// The map itself is kept; only its data array is zeroed.
// ---------------------------------------------------------------------------

class UvClear : Command {
    private string       name_ = kUvMapName;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.clear"; }
    override string label() const { return "Clear UV Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, kUvMapName) ];
    }

    override bool apply() {
        auto m = requireUvMap(mesh, name_);   // throws if absent or not UV
        snap = MeshSnapshot.capture(*mesh);
        m.data[] = 0.0f;
        mesh.commitChange(MeshEditScope.Material);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
