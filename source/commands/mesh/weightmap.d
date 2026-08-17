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
//
// A fifth (task 1090) authors NO mesh state at all:
//   mesh.weightmap.select  {name}              — which map the viewport shows
//
// It is deliberately the odd sibling. The four above declare no `cmdFlags()`
// and therefore default to `Model` (command.d) — they mutate the mesh and are
// undoable. `select` writes a session-scope NAME (weightmap_view.d) and
// touches neither the mesh nor the document, so it takes `CmdFlags.UI` and
// lands no undo entry, exactly like `viewport.displayStyle` does for the other
// half of the same feature (commands/viewport/command_base.d).
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

/// `mesh.weightmap.select {name}` — which weight map the viewport's weight
/// display style shows. `""` deselects (the surface goes neutral).
///
/// NOT VALIDATED against the mesh, on purpose. The selection is a NAME and
/// resolution is lazy (`weightmap_view.resolveWeightMap`), so:
///   * "select, then create" works — refusing an absent name would forbid it;
///   * a name that stops resolving (the map is removed, renamed out from under
///     the selection, or the primary layer changes to a mesh without it)
///     renders the NEUTRAL, which is exactly what "no map selected" renders
///     and exactly what was measured. Nothing has to notice; nothing has to
///     re-point.
/// Making this command validate would invent a lifetime rule nobody has
/// measured and would still not cover the three ways a name goes stale AFTER
/// it was accepted.
class WeightmapSelect : Command {
    private string name_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weightmap.select"; }
    override string label() const { return "Select Weight Map"; }

    /// UI class: no mesh state, no document state, no undo entry.
    /// `Command.isUndoable` derives from `Model | UiState | ToolLifecycle`, so
    /// `UI` alone records nothing — the precedent is `ViewportCommand`, which
    /// is what `viewport.displayStyle` itself uses.
    override CmdFlags cmdFlags() const { return CmdFlags.UI; }

    override Param[] params() {
        return [ Param.string_("name", "Map", &name_, "") ];
    }

    override bool apply() {
        import weightmap_view : setCurrentWeightMap;
        setCurrentWeightMap(name_);
        return true;
    }
}
