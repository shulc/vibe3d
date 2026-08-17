module commands.mesh.morph;

import command;
import mesh;
import math : Vec3;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import mesh_morph : morphApply;
import morph_target;
import params : Param;

// ---------------------------------------------------------------------------
// Morph-map lifecycle + authoring commands — task 1069.
//
// A morph map is a named MapDomain.Point dim-3 MeshMap of one of TWO kinds:
//
//   relative — stores a DELTA from the base position; created EMPTY.
//              An absent entry means zero displacement.
//   absolute — stores an absolute POSITION; created DENSE (a snapshot of
//              every base position). An absent entry means "stay at the
//              base", which is a DIFFERENT thing from a stored zero.
//
// They are two kinds and not one kind with a flag precisely because those
// two rows differ: the creation default AND the meaning of absence.
//
//   mesh.morph.create {name, kind}          — add; STEALS the routing target
//   mesh.morph.remove {name}                — remove; drops the target if named
//   mesh.morph.rename {from, to}            — rename in place; retargets
//   mesh.morph.select {name}                — bind the routing target ("" = none)
//   mesh.morph.set    {name, vert, x, y, z} — write one entry (absolute write)
//   mesh.morph.clear  {name}                — drop entries for the SELECTED verts
//   mesh.morph.apply  {name, amount}        — bake into the base; map untouched
//
// Undo is `MeshSnapshot` throughout: every one of these is a ONE-SHOT command,
// not a per-frame drag, and snapshot.d deep-dups `meshMaps` (presence channel
// included), so a plain restore reverts create / remove / rename / set / clear
// / apply alike. The per-gesture routed drag is a different mechanism entirely
// and lives in `commands/mesh/morph_edit.d`.
//
// Refusals use `baseRefusal_` + `return false`, not `throw`, for anything
// selection-driven — the same rule `edge_crease.d` documents: the UI's plain
// `runCommand` path passes `throwMsg = null`, and an uncaught throw there
// unwinds past the args dialog's popup-close and leaves the ImGui popup stack
// one deep. Lifecycle argument errors (empty name, unknown map) keep throwing,
// matching `weightmap.d`, because those come from a caller mistake rather
// than from the document's state.
// ---------------------------------------------------------------------------

/// Parse the `kind` parameter. Only the two morph kinds are namable here —
/// this command cannot create a uv / weight / crease map.
private bool parseMorphKind(string s, out MapKind kind) {
    switch (s) {
        case "relative": kind = MapKind.morphRelative; return true;
        case "absolute": kind = MapKind.morphAbsolute; return true;
        default:         kind = MapKind.unclassified;  return false;
    }
}

/// The string form of a morph kind — the one used by the `kind` parameter,
/// by the `.v3d` block and by the UI. Shared so the three cannot drift.
string morphKindName(MapKind k) {
    switch (k) {
        case MapKind.morphRelative: return "relative";
        case MapKind.morphAbsolute: return "absolute";
        default:                    return "";
    }
}

/// The map named `name` if it exists AND is a morph map, else null.
private MeshMap* morphMapOrNull(Mesh* m, string name) {
    auto mm = m.meshMap(name);
    if (mm is null || !isMorphKind(mm.kind)) return null;
    return mm;
}

class MorphCreate : Command {
    private string       name_;
    private string       kind_ = "relative";
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.create"; }
    override string label() const { return "Create Morph Map"; }

    override Param[] params() {
        return [
            Param.string_("name", "Name", &name_, ""),
            Param.string_("kind", "Kind", &kind_, "relative"),
        ];
    }

    override bool apply() {
        if (name_.length == 0)
            throw new Exception("mesh.morph.create: name must not be empty");
        MapKind kind;
        if (!parseMorphKind(kind_, kind))
            throw new Exception(
                "mesh.morph.create: kind must be 'relative' or 'absolute', got '"
              ~ kind_ ~ "'");
        snap = MeshSnapshot.capture(*mesh);
        auto m = mesh.addMeshMapOfKind(kind, name_);
        if (m is null) {
            snap = MeshSnapshot.init;
            throw new Exception(
                "mesh.morph.create: map '" ~ name_ ~ "' already exists, or the "
              ~ "per-mesh map cap was reached");
        }
        // The ABSOLUTE kind is created DENSE: an entry for every vertex,
        // holding that vertex's own base position. That is measured, and it is
        // the half of the two-kind split that a "one kind with a flag" design
        // cannot express — for this kind an absent entry does not mean "no
        // displacement", it means "stay at the base", so a sparse creation
        // would be indistinguishable from every vertex being unmoved.
        if (kind == MapKind.morphAbsolute) {
            foreach (i; 0 .. mesh.vertices.length)
                m.setEntry(i, mesh.vertices[i]);
        }
        // ...and the RELATIVE kind is created EMPTY, which is what
        // addMeshMapOfKind already left it as. Stated so the asymmetry reads
        // as deliberate rather than as a missing branch.

        // Creating a map STEALS the routing target: the next edit lands in the
        // new map, measured (`new_map_steals_the_selection`).
        setMorphTarget(name_, kind);
        mesh.commitChange(MeshEditScope.Maps);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        // The target named a map that no longer exists after the restore.
        forgetMorphTargetIfNamed(name_);
        return true;
    }
}

class MorphRemove : Command {
    private string       name_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.remove"; }
    override string label() const { return "Remove Morph Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    override bool apply() {
        if (name_.length == 0)
            throw new Exception("mesh.morph.remove: name must not be empty");
        if (morphMapOrNull(mesh, name_) is null)
            throw new Exception(
                "mesh.morph.remove: morph map '" ~ name_ ~ "' not found");
        snap = MeshSnapshot.capture(*mesh);
        if (!mesh.removeMeshMap(name_)) {
            snap = MeshSnapshot.init;
            return false;
        }
        forgetMorphTargetIfNamed(name_);
        mesh.commitChange(MeshEditScope.Maps);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

class MorphRename : Command {
    private string       from_;
    private string       to_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.rename"; }
    override string label() const { return "Rename Morph Map"; }

    override Param[] params() {
        return [
            Param.string_("from", "From", &from_, ""),
            Param.string_("to",   "To",   &to_,   ""),
        ];
    }

    override bool apply() {
        if (from_.length == 0 || to_.length == 0)
            throw new Exception("mesh.morph.rename: from/to must not be empty");
        auto m = morphMapOrNull(mesh, from_);
        if (m is null)
            throw new Exception(
                "mesh.morph.rename: morph map '" ~ from_ ~ "' not found");
        if (mesh.meshMap(to_) !is null)
            throw new Exception(
                "mesh.morph.rename: target name '" ~ to_ ~ "' already exists");
        snap = MeshSnapshot.capture(*mesh);
        const bool wasTarget = (morphTargetName() == from_);
        const MapKind kind = m.kind;
        m.name = to_;
        // Retarget rather than drop: the map the user is editing did not go
        // away, it changed name.
        if (wasTarget) setMorphTarget(to_, kind);
        mesh.commitChange(MeshEditScope.Maps);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        if (morphTargetName() == to_) setMorphTarget(from_, mesh.mapKind(from_));
        return true;
    }
}

/// Bind the routing target. An empty name clears it, which is the "edit the
/// base again" state. NOT undoable through a snapshot — it mutates no mesh
/// data — so `revert` restores the previous binding directly.
class MorphSelect : Command {
    private string  name_;
    private string  prevName_;
    private MapKind prevKind_ = MapKind.unclassified;
    private bool    applied_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.select"; }
    override string label() const { return "Select Morph Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    override bool apply() {
        baseRefusal_ = "";
        prevName_ = morphTargetName();
        prevKind_ = morphTargetKind();
        if (name_.length == 0) {
            clearMorphTarget();
            applied_ = true;
            publishTargetChange();
            return true;
        }
        auto m = morphMapOrNull(mesh, name_);
        if (m is null) {
            baseRefusal_ = "no morph map named '" ~ name_ ~ "'";
            return false;
        }
        setMorphTarget(name_, m.kind);
        applied_ = true;
        publishTargetChange();
        return true;
    }

    override bool revert() {
        if (!applied_) return false;
        setMorphTarget(prevName_, prevKind_);
        publishTargetChange();
        return true;
    }

    /// Binding or UNBINDING the target changes what the viewport DRAWS —
    /// the preview is base+delta while a target is bound and base while it is
    /// not — even though no mesh datum changed. Nothing else publishes that:
    /// the target lives in app state, not on the mesh, so without this the
    /// GPU keeps whatever surface it last uploaded and the screen silently
    /// disagrees with the document. (Found by measurement: with this missing,
    /// clearing the target left the morphed surface on screen AND left face
    /// picking resolving against it.)
    private void publishTargetChange() {
        mesh.commitChange(MeshEditScope.Maps);
    }
}

/// Write ONE entry, absolutely (not additively), and set its presence.
class MorphSet : Command {
    private string       name_;
    private int          vert_ = -1;
    private float        x_ = 0.0f, y_ = 0.0f, z_ = 0.0f;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.set"; }
    override string label() const { return "Set Morph Value"; }

    override Param[] params() {
        return [
            Param.string_("name", "Map",    &name_, ""),
            Param.int_   ("vert", "Vertex", &vert_, -1),
            Param.float_ ("x",    "X",      &x_,    0.0f),
            Param.float_ ("y",    "Y",      &y_,    0.0f),
            Param.float_ ("z",    "Z",      &z_,    0.0f),
        ];
    }

    override bool apply() {
        if (name_.length == 0)
            throw new Exception("mesh.morph.set: name must not be empty");
        if (morphMapOrNull(mesh, name_) is null)
            throw new Exception(
                "mesh.morph.set: morph map '" ~ name_ ~ "' not found");
        // `vert` indexes a DENSE array, so it is range-checked here as well as
        // inside setMorphValue — the caller can be a script.
        if (vert_ < 0 || cast(size_t) vert_ >= mesh.vertices.length)
            throw new Exception(
                "mesh.morph.set: vert out of range");
        snap = MeshSnapshot.capture(*mesh);
        if (!mesh.setMorphValue(name_, cast(size_t) vert_, Vec3(x_, y_, z_))) {
            snap.restore(*mesh);
            snap = MeshSnapshot.init;
            throw new Exception("mesh.morph.set: write refused");
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

/// Drop the entries of the SELECTED vertices only — measured
/// (`clear_is_selection_scoped`): a clear with 4 of 8 vertices selected leaves
/// the other 4 entries alone. This is a presence operation, NOT a "write
/// zero": for the absolute kind those are different positions, and for either
/// kind they are different states on the wire.
class MorphClear : Command {
    private string       name_;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.clear"; }
    override string label() const { return "Clear Morph Entries"; }

    override Param[] params() {
        return [ Param.string_("name", "Map", &name_, "") ];
    }

    override bool apply() {
        baseRefusal_ = "";
        if (name_.length == 0)
            throw new Exception("mesh.morph.clear: name must not be empty");
        if (morphMapOrNull(mesh, name_) is null)
            throw new Exception(
                "mesh.morph.clear: morph map '" ~ name_ ~ "' not found");
        // The house whole-mesh fallback: no selection means every visible
        // vertex. Unlike `mesh.edgeCrease.set` this is NOT refused on an empty
        // selection — clearing a whole map is a coherent, reversible request,
        // and `selectedVertexIndicesVertices` is the same operand set every
        // other vertex-domain command uses.
        auto sel = mesh.selectedVertexIndicesVertices();
        snap = MeshSnapshot.capture(*mesh);
        foreach (vi; sel) mesh.clearMorphValue(name_, cast(size_t) vi);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

/// Bake the map into the base at `amount` strength. Destructive on the base;
/// the MAP is left exactly as it was (measured: `freeze_deform_keeps_the_map`,
/// and the "map value untouched" half of every apply case).
class MorphApplyCmd : Command {
    private string       name_;
    private float        amount_ = 1.0f;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.apply"; }
    override string label() const { return "Apply Morph"; }

    override Param[] params() {
        return [
            Param.string_("name",   "Map",      &name_,   ""),
            // NO .min() / .max(), and none may ever be added. The law is
            // measured UNCLAMPED at -0.5 and at 100 (`apply_negative`,
            // `apply_x100`) and independently at 2.0 / -1.0 through the
            // deformer mechanism. `amount` scales no allocation and bounds no
            // loop — it multiplies a fixed per-vertex vector — so it is not a
            // DoS knob and needs no cap either. A later `enforceBounds` sweep
            // that "helpfully" clamps this to [0,1] would silently break four
            // fixture cases; this comment is the reason it must not.
            Param.float_ ("amount", "Amount",   &amount_, 1.0f),
        ];
    }

    override bool apply() {
        if (name_.length == 0)
            throw new Exception("mesh.morph.apply: name must not be empty");
        auto m = morphMapOrNull(mesh, name_);
        if (m is null)
            throw new Exception(
                "mesh.morph.apply: morph map '" ~ name_ ~ "' not found");
        const MapKind kind = m.kind;
        snap = MeshSnapshot.capture(*mesh);
        // Only PRESENT entries move a vertex. For the relative kind an absent
        // entry would be a no-op anyway; for the absolute kind it is the
        // difference between "stay at the base" and "teleport to the origin",
        // so the presence test is load-bearing, not an optimisation.
        foreach (i; 0 .. mesh.vertices.length) {
            if (!m.isPresent(i)) continue;
            mesh.vertices[i] = morphApply(mesh.vertices[i],
                                          m.entryOr(i, Vec3(0, 0, 0)),
                                          kind, amount_);
        }
        // Positions moved, so this is a Geometry-class change, not a Maps one:
        // the MAP is deliberately untouched.
        mesh.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
