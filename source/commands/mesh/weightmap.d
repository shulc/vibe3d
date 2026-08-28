module commands.mesh.weightmap;

import command;
import mesh;
import view;
import editmode;
import mesh_edit_delta : MeshEditScope, MeshOpEntry;
import params : Param;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, mapSlotOf;

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
// UNDO IS A RECORDED `MeshOpEntry.Kind.MapValueDelta` SINCE TASK 1903 STAGE
// L1-b. All four mutating commands record one entry; the escape hatch's
// `MeshSnapshot` arm died with the hatch at task 1903 Stage N, so the delta is
// the only undo image left. The two arms (redo / recorded) are
// `commands/mesh/map_edit_undo.runMapEdit`, shared with `morph.d` and the five
// UV groups; the empty-edit answer stays in each `revert()` per
// `position_undo.d`'s measured rule.
//
// WHAT THIS GROUP IS THE ONLY ONE TO SHOW, and it is why it is not a copy of
// `morph.d`:
//
//   1. `mesh.weightmap.set`'s forward writes exactly ONE float — mode A's
//      extreme, a 434-byte payload against a 20.81 MB whole-mesh snapshot
//      (task 2210). Nothing else in the family is that sparse.
//   2. It is the only group whose `commitChange` is DELEGATED into a `Mesh`
//      setter: `setVertexWeight` -> `setMeshMapValue` publishes `Material`
//      itself, per element. The batch DEFERS that into one stamp at `close()`,
//      so this command must NOT add a `commitChange` of its own — a naive
//      migration that adds one publishes on a path where the pre-migration
//      command published nothing.
//   3. Its maps are NOT presence-tracked (`kindInfo(vertexWeight)`), so the
//      entries carry EMPTY presence channels — and `patchMapValuesWrite`
//      refuses an entry that carries them anyway. The recorders below still
//      read the channel through `kindInfo`, never from the array, because a
//      raw `addMeshMap` can register any kind under a dim-1 Point shape.
//   4. The stand's `W` map is `unclassified` (`fixtures.d` registers it
//      through the raw door) while `mesh.weightmap.create` makes a classified
//      `vertexWeight` one — so this group drives BOTH halves of
//      `mapRegister`'s door split in one file.
//
// THE REFUSALS MOVED IN FRONT OF THE BATCH, and that is a real change rather
// than a tidy-up: a `throw` out of an open batch leaves `~MeshEditBatch` to
// pop the frame and tick `changeBus.batchLeaks`, which the suite asserts is 0.
// Every message below is verbatim, and the two conditions that used to be
// discovered INSIDE the mutation (a duplicate name, and the MAX_MESH_MAPS
// ceiling) are now pre-checked. The ceiling gained its own message: it used to
// report "already exists", which was simply wrong.
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
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 2250). The
        /// op-log SHAPE is not derivable from the outside: a command that
        /// recorded NOTHING falls back to its snapshot and restores the right
        /// planes anyway, so every result-shaped assertion is green over a
        /// deleted recorder. Only reading the log itself is not. `public` on
        /// the declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weightmap.create"; }
    override string label() const { return "Create Weight Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    protected override bool applyImpl() {
        if (name_.length == 0)
            throw new Exception("mesh.weightmap.create: name must not be empty");
        // BOTH of `addMeshMap`'s null answers, resolved BEFORE the batch opens
        // and each with its own message. The duplicate-name text is verbatim;
        // the ceiling used to be reported as "already exists", which was
        // false, and could only be reached from inside the mutation.
        if (mesh.meshMap(name_) !is null)
            throw new Exception(
                "mesh.weightmap.create: map '" ~ name_ ~ "' already exists");
        if (mesh.meshMaps.length >= MAX_MESH_MAPS)
            throw new Exception(
                "mesh.weightmap.create: this mesh already carries the maximum "
              ~ "number of maps");
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &createKernel);
    }

    private bool createKernel(ref MeshEditBatch ed) {
        auto m = ed.mesh.addWeightMap(name_);
        assert(m !is null,
            "mesh.weightmap.create: addWeightMap refused after applyImpl "
          ~ "pre-checked both of its refusal terms");
        // `DefaultInit`, AND IT IS FAITHFUL IN BOTH DIRECTIONS HERE — which is
        // the half of the create split `morph.d` could not use for its
        // absolute kind. `addWeightMap` goes through `addMeshMapOfKind`, whose
        // product is a zero-filled `data` and (for a kind that does not track
        // presence) an EMPTY `present`; `mapRegister` reproduces exactly that
        // from the kind alone, so a FORWARD replay through
        // `MeshSessionEdit`'s `delta_.apply` gets the same map and the entry
        // carries no array at all. A `WholeArray` spelling here would pay the
        // payload for content that is definitionally zeros.
        if (ed.recording())
            ed.rec.recordMapCreate(name_, m.dim, m.domain, m.kind);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
    }
}

class WeightmapRemove : Command {
    private string       name_;
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see WeightmapCreate.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weightmap.remove"; }
    override string label() const { return "Remove Weight Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    protected override bool applyImpl() {
        if (name_.length == 0)
            throw new Exception("mesh.weightmap.remove: name must not be empty");
        if (mesh.meshMap(name_) is null)
            throw new Exception(
                "mesh.weightmap.remove: map '" ~ name_ ~ "' not found");
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &removeKernel);
    }

    private bool removeKernel(ref MeshEditBatch ed) {
        // THE WHOLE PRE-IMAGE, READ BEFORE THE SPLICE, and behind
        // `recording()` so the redo and hatch arms copy nothing. The reverse
        // has to RE-REGISTER this map, so its payload is the map itself —
        // name, shape, both channels — plus the registry SLOT. Mode B: ~393 KB
        // on the 100 k stand against the 20.81 MB whole-mesh capture.
        ubyte     dim;
        MapDomain dom;
        MapKind   kind;
        float[]   data;
        ubyte[]   pres;
        uint      slot = uint.max;
        const bool rec = ed.recording();
        if (rec) {
            auto live = ed.mesh.meshMap(name_);
            // Cannot be null: `applyImpl` resolved it and nothing has run
            // since. Asserted rather than assumed — a silent null here would
            // record a shapeless entry the replay can only refuse.
            assert(live !is null,
                "mesh.weightmap.remove: the map resolved in applyImpl "
              ~ "vanished before the kernel ran");
            dim  = live.dim;
            dom  = live.domain;
            kind = live.kind;
            data = live.data.dup;      // one block memcpy, never a gather
            pres = live.present.dup;   // EMPTY for every non-tracking kind
            slot = mapSlotOf(&ed.mesh(), name_);
        }
        if (!ed.mesh.removeMeshMap(name_)) return false;
        if (rec)
            ed.rec.recordMapRemoveOwned(name_, dim, dom, kind, slot, data, pres);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
    }
}

class WeightmapRename : Command {
    private string       from_;
    private string       to_;
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see WeightmapCreate.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

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

    protected override bool applyImpl() {
        if (from_.length == 0 || to_.length == 0)
            throw new Exception("mesh.weightmap.rename: from/to must not be empty");
        auto m = mesh.meshMap(from_);
        if (m is null)
            throw new Exception(
                "mesh.weightmap.rename: map '" ~ from_ ~ "' not found");
        if (mesh.meshMap(to_) !is null)
            throw new Exception(
                "mesh.weightmap.rename: target name '" ~ to_ ~ "' already exists");
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &renameKernel);
    }

    private bool renameKernel(ref MeshEditBatch ed) {
        auto m = ed.mesh.meshMap(from_);
        assert(m !is null, "mesh.weightmap.rename: the map resolved in "
                         ~ "applyImpl vanished before the kernel ran");
        const MapKind   kind = m.kind;
        const ubyte     dim  = m.dim;
        const MapDomain dom  = m.domain;
        m.name = to_;
        // TWO STRINGS — the whole reason `MapOp.Rename` exists. Spelled as
        // Remove+Create the payload would be the entire map (task 2210
        // measured "two strings" against 3.05 MB).
        if (ed.recording()) ed.rec.recordMapRename(from_, to_, dim, dom, kind);
        ed.commitChange(MeshEditScope.Material);
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
    }
}

class WeightmapSet : Command {
    private string       name_;
    private int          vert_   = -1;
    private float        weight_ = 0.0f;
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see WeightmapCreate.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

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

    protected override bool applyImpl() {
        if (name_.length == 0)
            throw new Exception("mesh.weightmap.set: name must not be empty");
        if (vert_ < 0)
            throw new Exception("mesh.weightmap.set: vert must be >= 0");
        auto pre = mesh.meshMap(name_);
        if (pre is null)
            throw new Exception(
                "mesh.weightmap.set: map '" ~ name_ ~ "' not found");
        // BOTH of `setMeshMapValue`'s refusal terms, hoisted in front of the
        // batch and reported with the SAME message the shipped command uses.
        // `setVertexWeight` passes a one-component value, so a map of any
        // other dim is the "type mismatch" half and a short `data` array the
        // "out-of-range" half.
        if (pre.dim != 1
         || cast(size_t) vert_ * pre.dim + pre.dim > pre.data.length)
            throw new Exception(
                "mesh.weightmap.set: out-of-range vertex index or type mismatch");
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &setKernel);
    }

    private bool setKernel(ref MeshEditBatch ed) {
        auto mm = ed.mesh.meshMap(name_);
        assert(mm !is null, "mesh.weightmap.set: the map resolved in applyImpl "
                          ~ "vanished before the kernel ran");
        const size_t vi   = cast(size_t) vert_;
        const bool   rec  = ed.recording();
        // The presence channel is read off the KIND, never off the array: an
        // empty `present` MEANS "all present", so inferring "no channel" from
        // `present.length == 0` would drop a real one. Weight maps do not
        // track presence — but `addMeshMap` takes an explicit kind, so the
        // recorder must not assume the shape of the map it was handed.
        const bool tracks = kindInfo(mm.kind).tracksPresence;

        // (γ) THE INDEX SET IS ALREADY KNOWN — record it directly, never diff
        // (plan §K.5 rule 4). ONE element: 4 bytes of index, 4 of value each
        // way, against a 20.81 MB whole-mesh capture. Nothing here is pre-sized
        // because nothing here is a loop.
        float before = 0;
        ubyte presBefore = 0;
        if (rec) {
            before = mm.data[vi];
            if (tracks) presBefore = vi < mm.present.length ? mm.present[vi] : 0;
        }
        if (!ed.mesh.setVertexWeight(name_, vi, weight_)) return false;
        if (rec) {
            // The AFTER image is READ BACK FROM THE LIVE MAP rather than
            // reconstructed from `weight_`: the write goes through a setter
            // this command does not own, and an entry whose after-image
            // disagrees with the mesh is an undo that writes the wrong thing
            // on redo.
            const float after = mm.data[vi];
            const ubyte presAfter =
                tracks ? (vi < mm.present.length ? mm.present[vi] : 0) : 0;
            ed.rec.recordMapValuesOwned(name_, mm.dim, mm.domain, mm.kind,
                MeshOpEntry.MapAddressing.Listed, [cast(uint) vi],
                [before], [after],
                tracks ? [presBefore] : null, tracks ? [presAfter] : null);
        }
        // NO `commitChange` HERE, deliberately, and this is the trap unique to
        // this group: `setVertexWeight` -> `setMeshMapValue` publishes
        // `Material` itself and the batch folds that into one stamp at
        // `close()`. Adding one would publish a second class-bearing call on
        // the path where the pre-migration command published exactly one.
        return true;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
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

    protected override bool applyImpl() {
        import weightmap_view : setCurrentWeightMap;
        setCurrentWeightMap(name_);
        return true;
    }
}
