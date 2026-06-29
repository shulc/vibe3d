module commands.mesh.weightmap;

import command;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import params : Param;

// ---------------------------------------------------------------------------
// Weight-map lifecycle commands.
//
// A weight map is a named MapDomain.Point dim=1 MeshMap — one float per
// vertex. Four commands cover the authoring lifecycle:
//   mesh.weightmap.create  {name}              — add a zero-filled map
//   mesh.weightmap.remove  {name}              — remove a named map
//   mesh.weightmap.rename  {from, to}          — rename in place
//   mesh.weightmap.set     {name, vert, weight}— set one vertex's weight
//
// All four use MeshSnapshot for undo (snapshot.d deep-dups meshMaps so
// create/remove/rename/set are all reverted by a plain snapshot restore).
// ---------------------------------------------------------------------------

class WeightmapCreate : Command {
    private string       name_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weightmap.create"; }
    override string label() const { return "Create Weight Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    override bool apply() {
        if (name_.length == 0)
            throw new Exception("mesh.weightmap.create: name must not be empty");
        snap = MeshSnapshot.capture(*mesh);
        auto m = mesh.addWeightMap(name_);
        if (m is null) {
            snap = MeshSnapshot.init;
            throw new Exception(
                "mesh.weightmap.create: map '" ~ name_ ~ "' already exists");
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

class WeightmapRemove : Command {
    private string       name_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weightmap.remove"; }
    override string label() const { return "Remove Weight Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    override bool apply() {
        if (name_.length == 0)
            throw new Exception("mesh.weightmap.remove: name must not be empty");
        if (mesh.meshMap(name_) is null)
            throw new Exception(
                "mesh.weightmap.remove: map '" ~ name_ ~ "' not found");
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

class WeightmapRename : Command {
    private string       from_;
    private string       to_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weightmap.rename"; }
    override string label() const { return "Rename Weight Map"; }

    override Param[] params() {
        return [
            Param.string_("from", "From", &from_, ""),
            Param.string_("to",   "To",   &to_,   ""),
        ];
    }

    override bool apply() {
        if (from_.length == 0 || to_.length == 0)
            throw new Exception("mesh.weightmap.rename: from/to must not be empty");
        auto m = mesh.meshMap(from_);
        if (m is null)
            throw new Exception(
                "mesh.weightmap.rename: map '" ~ from_ ~ "' not found");
        if (mesh.meshMap(to_) !is null)
            throw new Exception(
                "mesh.weightmap.rename: target name '" ~ to_ ~ "' already exists");
        snap = MeshSnapshot.capture(*mesh);
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

class WeightmapSet : Command {
    private string       name_;
    private int          vert_   = -1;
    private float        weight_ = 0.0f;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weightmap.set"; }
    override string label() const { return "Set Weight Map Value"; }

    override Param[] params() {
        return [
            Param.string_("name",   "Map",    &name_,   ""),
            Param.int_   ("vert",   "Vertex", &vert_,   -1),
            Param.float_ ("weight", "Weight", &weight_, 0.0f),
        ];
    }

    override bool apply() {
        if (name_.length == 0)
            throw new Exception("mesh.weightmap.set: name must not be empty");
        if (vert_ < 0)
            throw new Exception("mesh.weightmap.set: vert must be >= 0");
        if (mesh.meshMap(name_) is null)
            throw new Exception(
                "mesh.weightmap.set: map '" ~ name_ ~ "' not found");
        snap = MeshSnapshot.capture(*mesh);
        if (!mesh.setVertexWeight(name_, cast(size_t) vert_, weight_)) {
            snap = MeshSnapshot.init;
            throw new Exception(
                "mesh.weightmap.set: out-of-range vertex index or type mismatch");
        }
        // commitChange is done inside setVertexWeight → setMeshMapValue
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
