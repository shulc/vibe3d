module commands.mesh.morph;

import command;
import mesh;
import math : Vec3;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope, MeshOpEntry, undoTrackerEnabled;
import mesh_morph : morphApply;
import morph_target;
import params : Param;
import commands.mesh.position_undo : RecordedUndo, PositionUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEdit, mapSlotOf;
import std.array : uninitializedArray;

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
// UNDO IS A RECORDED DELTA SINCE TASK 1903 STAGE L1-a, and this file is the
// kind's FIRST production caller. Five of the six mutating commands record
// `MeshOpEntry.Kind.MapValueDelta`; `mesh.morph.apply` records `Kind.SetPos`,
// because it writes POSITIONS and leaves the map alone. `MeshSnapshot` stays
// as the escape hatch's arm (`VIBE3D_UNDO_TRACKER=0`) and dies with the hatch.
//
// WHY THIS FILE WENT FIRST OF THE FOUR L1 GROUPS. Five things are true here and
// of no other group in the family, and each one is a failure the other three
// cannot exhibit:
//
//   1. It is the only family whose PRESENCE channel changes. `mesh.morph.clear`
//      drops entries — `present` goes to 0 — and `mesh.morph.set` raises one.
//      An empty `present` MEANS "all present" (`MeshMap.present`), so a revert
//      that puts `data` back and leaves `present` alone yields a legal, wrong
//      map with every length still matching.
//   2. It is the only place two `MapKind`s are SHAPE-IDENTICAL. `morphRelative`
//      and `morphAbsolute` are both Point / dim 3 / no reserved name, and they
//      differ in `absentIsZero` — so a kind-blind restore into the other one
//      moves vertices. That is why `mapKind` is a bind term and not decoration.
//   3. It is the only group that drives all FOUR `MapOp` arms in production:
//      Create (create), Remove (remove), Rename (rename) and Values (set,
//      clear).
//   4. It is the only group with a POSITION write (`mesh.morph.apply`), so it
//      is the group that pins that a map command and a position command in one
//      file do not share a payload kind.
//   5. It is the only group with a NON-MESH undo tail: the routing target in
//      `morph_target`, which no plane dump can see and which every revert here
//      still has to fix up by hand, exactly as it did under the snapshot.
//
// The per-gesture routed drag is a different mechanism entirely and lives in
// `commands/mesh/morph_edit.d`; it is deliberately UNRECORDED (plan §9).
//
// SHAPE OF EVERY MIGRATED COMMAND BELOW, so the five bodies read the same:
// `applyImpl` resolves every guard FIRST — a `throw` or a `return false` out
// of an open batch would leave `~MeshEditBatch` to pop the frame and tick
// `changeBus.batchLeaks`, which the suite asserts is 0 — and then hands one
// kernel to `runMapEdit`, which owns the three arms (redo / recorded /
// hatch). Each kernel does its own recording behind `ed.recording()`, so the
// redo and hatch arms allocate NOTHING extra (§K.5 rule 2: L0-d made four
// commands twice as slow by paying bookkeeping on an unrecorded path).
//
// REFUSAL POLICY, and it is decided by ONE question: can the args dialog
// reach this command? (task 1073, review B3.)
//
// `config/buttons.yaml` dispatches `mesh.morph.create` and `mesh.morph.apply`
// from buttons, so both open `ArgsDialog` — and `ArgsDialog.draw` calls
// `runCmd` from INSIDE the `if (Button("OK"))` block with `EndPopup()` after
// it, while neither `App.runCommand` nor `applyOrRefire` catches. A throw out
// of `apply()` therefore unwinds past `EndPopup()` and leaves the ImGui popup
// stack one deep. Both of those commands default `name` to `""`, so OK on a
// freshly-opened dialog was exactly the throwing path: the DEFAULT state of a
// dialog the user is meant to type into.
//
// So the two DIALOG-REACHABLE commands refuse the house way — `baseRefusal_`
// + `return false`, which `ui/command_notice.d` renders as a notice — for
// every rejection they can be handed, argument errors included.
//
// THE JUSTIFICATION FOR THE OTHER FOUR IS FALSE, AND SAYING SO IS THE POINT
// (task 1520, opponent blocker B3). It used to read: "the script-only commands
// (`remove` / `rename` / `set` / `clear`) keep throwing — their only caller is
// `/api/command`". That is not true. `replayUndoEntry` re-dispatches an
// ARBITRARY line from the undo history, and its callers are the History
// panel's Re-run button and its context menu — both INSIDE the draw. So these
// four ARE reachable from a draw, and their throw is caught only because
// `replayUndoEntry` keeps a `try/catch` (which task 1520 therefore did NOT
// delete; it now routes the message into the notice instead of swallowing it).
//
// Turning these four into house refusals is a separate change with its own
// HTTP-contract consequences (their `/api/command` callers currently read a
// non-ok status off the throw) and is left to the backlog. What is fixed here
// is the record: the premise is stated as false rather than repeated.
// Same situation, same wording, in `edge_crease.d`.
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

// THE THREE ARMS — redo / recorded / hatch — AND THE MESH HALF OF THE REVERT
// LIVE IN `commands/mesh/map_edit_undo.d` SINCE STAGE L1-b. They were private
// to this file while it was the family's only migrated group; seven more files
// migrated in L1-b, and a private copy each would be eight implementations of
// one mechanism. The bodies are unchanged and that module's header carries the
// reasoning, including what deliberately did NOT move: the empty-edit answer
// (each `revert()` keeps its own arm, per `position_undo.d`'s measured rule)
// and the non-mesh tail (three of the five commands below re-point the
// `morph_target` binding; no UV or weight command has one).

class MorphCreate : Command {
    private string       name_;
    private string       kind_ = "relative";
    private MeshSnapshot snap;      // the hatch's arm only
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 2230). The
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

    override string name()  const { return "mesh.morph.create"; }
    override string label() const { return "Create Morph Map"; }

    override Param[] params() {
        return [
            Param.string_("name", "Name", &name_, ""),
            Param.string_("kind", "Kind", &kind_, "relative"),
        ];
    }

    // DIALOG-REACHABLE (config/buttons.yaml "New Morph Map…"), so every
    // rejection is a refusal and none is a throw — see the module header.
    protected override bool applyImpl() {
        baseRefusal_ = "";
        if (name_.length == 0) {
            baseRefusal_ = "a morph map needs a name";
            return false;
        }
        MapKind kind;
        if (!parseMorphKind(kind_, kind)) {
            baseRefusal_ =
                "kind must be 'relative' or 'absolute', got '" ~ kind_ ~ "'";
            return false;
        }
        // The one rejection that cannot be resolved before the batch opens —
        // `addMeshMapOfKind` refuses a duplicate name AND the MAX_MESH_MAPS
        // ceiling, and re-implementing either test here would be a second,
        // unnamed guard in front of the named one. The kernel therefore
        // returns false and `runMapEdit` closes the batch; nothing was written.
        if (!runMapEdit(mesh, undo_, snap, MeshEditScope.Maps,
                        (ref MeshEditBatch ed) => createKernel(ed, kind)))
            return false;
        return true;
    }

    private bool createKernel(ref MeshEditBatch ed, MapKind kind) {
        auto m = ed.mesh.addMeshMapOfKind(kind, name_);
        if (m is null) {
            baseRefusal_ =
                "map '" ~ name_ ~ "' already exists, or the per-mesh map cap "
              ~ "was reached";
            return false;
        }
        // The ABSOLUTE kind is created DENSE: an entry for every vertex,
        // holding that vertex's own base position. That is measured, and it is
        // the half of the two-kind split that a "one kind with a flag" design
        // cannot express — for this kind an absent entry does not mean "no
        // displacement", it means "stay at the base", so a sparse creation
        // would be indistinguishable from every vertex being unmoved.
        if (kind == MapKind.morphAbsolute) {
            foreach (i; 0 .. ed.mesh.vertices.length)
                m.setEntry(i, ed.mesh.vertices[i]);
        }
        // ...and the RELATIVE kind is created EMPTY, which is what
        // addMeshMapOfKind already left it as. Stated so the asymmetry reads
        // as deliberate rather than as a missing branch.

        // TWO CREATE SPELLINGS, AND THE CHOICE IS THE DENSE/EMPTY SPLIT ABOVE
        // read a second time. `Create`'s forward is FAITHFUL — `MeshSessionEdit`
        // replays a delta FORWARD for redo — so an absolute map, which was
        // created FILLED, must carry its content or a redo would bring it back
        // with every vertex "at the base". A relative map is created empty, so
        // `DefaultInit` reproduces it exactly and carries no array at all.
        // Recording is behind `recording()`: the redo and hatch arms must not
        // pay for the two `.dup`s.
        if (ed.recording()) {
            if (kind == MapKind.morphAbsolute)
                ed.rec.recordMapCreateFilledOwned(name_, m.dim, m.domain, m.kind,
                                                  m.data.dup, m.present.dup);
            else
                ed.rec.recordMapCreate(name_, m.dim, m.domain, m.kind);
        }
        // Creating a map STEALS the routing target: the next edit lands in the
        // new map, measured (`new_map_steals_the_selection`).
        setMorphTarget(name_, kind);
        ed.commitChange(MeshEditScope.Maps);
        return true;
    }

    override bool revert() {
        if (!revertMapEdit(mesh, undo_, snap)) return false;
        // The NON-MESH tail, and no plane dump can see it: the target named a
        // map that no longer exists after the restore. Unchanged by the
        // migration, and it runs AFTER the mesh half in both paths.
        forgetMorphTargetIfNamed(name_);
        return true;
    }
}

class MorphRemove : Command {
    private string       name_;
    private MeshSnapshot snap;      // the hatch's arm only
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see MorphCreate.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.remove"; }
    override string label() const { return "Remove Morph Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    protected override bool applyImpl() {
        if (name_.length == 0)
            throw new Exception("mesh.morph.remove: name must not be empty");
        if (morphMapOrNull(mesh, name_) is null)
            throw new Exception(
                "mesh.morph.remove: morph map '" ~ name_ ~ "' not found");
        return runMapEdit(mesh, undo_, snap, MeshEditScope.Maps, &removeKernel);
    }

    private bool removeKernel(ref MeshEditBatch ed) {
        // THE WHOLE PRE-IMAGE, READ BEFORE THE SPLICE, and behind
        // `recording()` so the redo and hatch arms copy nothing. The reverse
        // has to RE-REGISTER this map, so its payload is the map itself: name,
        // shape, both channels — and the registry SLOT, because
        // `removeMeshMap` splices and the re-registration appends (see
        // `MeshOpEntry.mapSlot`; measured on the parity stand, where MA sits
        // between `crease` and `MR`).
        ubyte     dim;
        MapDomain dom;
        MapKind   kind;
        float[]   data;
        ubyte[]   pres;
        uint      slot = uint.max;
        const bool rec = ed.recording();
        if (rec) {
            auto live = ed.mesh.meshMap(name_);
            // Cannot be null: `applyImpl` already resolved it and nothing has
            // run since. Asserted rather than assumed, because a silent null
            // here would record a shapeless entry that the replay refuses.
            assert(live !is null,
                "mesh.morph.remove: the map resolved in applyImpl vanished "
              ~ "before the kernel ran");
            dim  = live.dim;
            dom  = live.domain;
            kind = live.kind;
            data = live.data.dup;      // one block memcpy, never a gather
            pres = live.present.dup;
            slot = mapSlotOf(&ed.mesh(), name_);
        }
        if (!ed.mesh.removeMeshMap(name_)) return false;
        if (rec)
            ed.rec.recordMapRemoveOwned(name_, dim, dom, kind, slot, data, pres);
        forgetMorphTargetIfNamed(name_);
        ed.commitChange(MeshEditScope.Maps);
        return true;
    }

    override bool revert() {
        // NO non-mesh tail, deliberately and unchanged: the forward DROPS the
        // routing target when it named this map and the undo has never put it
        // back. Recorded here so the asymmetry with `create` and `rename`
        // reads as pre-existing behaviour rather than as something this
        // migration lost.
        return revertMapEdit(mesh, undo_, snap);
    }
}

class MorphRename : Command {
    private string       from_;
    private string       to_;
    private MeshSnapshot snap;      // the hatch's arm only
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see MorphCreate.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

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

    protected override bool applyImpl() {
        if (from_.length == 0 || to_.length == 0)
            throw new Exception("mesh.morph.rename: from/to must not be empty");
        auto m = morphMapOrNull(mesh, from_);
        if (m is null)
            throw new Exception(
                "mesh.morph.rename: morph map '" ~ from_ ~ "' not found");
        if (mesh.meshMap(to_) !is null)
            throw new Exception(
                "mesh.morph.rename: target name '" ~ to_ ~ "' already exists");
        return runMapEdit(mesh, undo_, snap, MeshEditScope.Maps, &renameKernel);
    }

    private bool renameKernel(ref MeshEditBatch ed) {
        auto m = morphMapOrNull(&ed.mesh(), from_);
        assert(m !is null, "mesh.morph.rename: the map resolved in applyImpl "
                         ~ "vanished before the kernel ran");
        const bool wasTarget = (morphTargetName() == from_);
        const MapKind   kind = m.kind;
        const ubyte     dim  = m.dim;
        const MapDomain dom  = m.domain;
        m.name = to_;
        // TWO STRINGS — the whole reason `MapOp.Rename` exists. Spelled as
        // Remove+Create the payload would be the entire map (task 2210
        // measured "two strings" against 3.05 MB), which for four classes in
        // this family is the difference between mode A and mode B.
        if (ed.recording()) ed.rec.recordMapRename(from_, to_, dim, dom, kind);
        // Retarget rather than drop: the map the user is editing did not go
        // away, it changed name.
        if (wasTarget) setMorphTarget(to_, kind);
        ed.commitChange(MeshEditScope.Maps);
        return true;
    }

    override bool revert() {
        if (!revertMapEdit(mesh, undo_, snap)) return false;
        // The NON-MESH tail, and it reads the mesh AFTER the restore — so the
        // order of these two statements is load-bearing on both paths.
        if (morphTargetName() == to_) setMorphTarget(from_, mesh.mapKind(from_));
        return true;
    }
}

/// Bind the routing target. An empty name clears it, which is the "edit the
/// base again" state. NOT undoable through a snapshot — it mutates no mesh
/// data — so `revert` restores the previous binding directly.
///
/// UI-ONLY, AND THEREFORE NOT MIGRATED (task 1903 Stage L1-a). It is the one
/// class in this file that records neither a `MapValueDelta` nor a `SetPos`,
/// and the reason is not "not yet": it writes NOTHING on the mesh. `applyImpl`
/// moves a name and a kind in `morph_target`, which is app state, and its
/// only `Mesh` call is the `commitChange(MapsDisplay)` below that tells the
/// viewport to redraw. There is no before-image to record and no plane to
/// restore, so opening an edit batch here would produce an empty delta whose
/// `revert` answers false — the regression-0099 shape — in exchange for
/// nothing. Its `CmdFlags.UiState` says the same thing in the history's
/// vocabulary. Counted in the L1 roster as one of the two non-mutating map
/// classes (the other is `WeightmapSelect`).
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

    /// UI-undo class, NOT Model (task 1073, review SF5). This command mutates
    /// no mesh datum at all — it moves a name in `morph_target`, app state —
    /// so `Model` was wrong twice over. The visible cost was the second one:
    /// `app.d`'s post-dispatch tool-drop fires for every `Model` command
    /// outside the `tool.` / `scene.` / `file.` / `layer.attr` families, so
    /// picking a morph target while a transform tool was armed dropped the
    /// tool and took the gizmo with it — in the one workflow where the two
    /// are used together. `UiState` still lands an undo entry (so the
    /// binding is undoable, which `revert()` below implements), just in the
    /// UI-undo class where selection and edit-mode changes live.
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, "") ];
    }

    protected override bool applyImpl() {
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
    ///
    /// `MapsDisplay`, NOT `Maps` (task 1073, review B1). The two carry the
    /// same display obligation — both sit in `DisplayRefreshMask`, and
    /// `commitChange` bumps `mutationVersion` so the GPU re-uploads either
    /// way — and differ on exactly one thing: `Maps` is summed into
    /// `ChangeBus.docRevision()` because a map WRITE is persisted content,
    /// and this is not a write. Publishing `Maps` here would put an asterisk
    /// on the title bar and a save prompt in front of Quit for a user who
    /// only picked a morph to look at.
    private void publishTargetChange() {
        mesh.commitChange(MeshEditScope.MapsDisplay);
    }
}

/// Write ONE entry, absolutely (not additively), and set its presence.
class MorphSet : Command {
    private string       name_;
    private int          vert_ = -1;
    private float        x_ = 0.0f, y_ = 0.0f, z_ = 0.0f;
    private MeshSnapshot snap;      // the hatch's arm only
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see MorphCreate.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

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

    protected override bool applyImpl() {
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
        if (!runMapEdit(mesh, undo_, snap, MeshEditScope.Maps, &setKernel))
            // UNREACHABLE, and named as such: `setMorphValue` refuses on a
            // missing map, a non-morph kind or an out-of-range vertex, and all
            // three are pre-checked above. The pre-2230 code restored its
            // snapshot before throwing here; nothing has been written when
            // this arm is taken, so the restore was a no-op carrying a pair of
            // version bumps, and dropping it changes nothing a reader can see.
            // The throw itself is kept verbatim — it is an HTTP contract.
            throw new Exception("mesh.morph.set: write refused");
        return true;
    }

    private bool setKernel(ref MeshEditBatch ed) {
        auto mm = ed.mesh.meshMap(name_);
        assert(mm !is null, "mesh.morph.set: the map resolved in applyImpl "
                          ~ "vanished before the kernel ran");
        const size_t vi = cast(size_t) vert_;
        const bool rec = ed.recording();

        // (γ) THE INDEX SET IS ALREADY KNOWN — record it directly, never diff
        // (§K.5 rule 4). One element, so `Listed` is 4 + 12 + 1 bytes against
        // the whole map; nothing here is pre-sized because nothing here is a
        // loop.
        float[3] before = 0;
        ubyte    presBefore = 0;
        if (rec) {
            before[]   = mm.data[vi * 3 .. vi * 3 + 3];
            presBefore = vi < mm.present.length ? mm.present[vi] : 0;
        }
        if (!ed.mesh.setMorphValue(name_, vi, Vec3(x_, y_, z_))) return false;
        if (rec) {
            // The AFTER image is READ BACK FROM THE LIVE MAP rather than
            // reconstructed from the parameters. `setMorphValue` raises the
            // presence bit only `if (vi < present.length)`, so a map whose
            // channel is short would make a reconstructed `1` a lie — and the
            // presence half is the plane this family loses most easily.
            float[3] after = 0;
            after[] = mm.data[vi * 3 .. vi * 3 + 3];
            const ubyte presAfter = vi < mm.present.length ? mm.present[vi] : 0;
            ed.rec.recordMapValuesOwned(name_, mm.dim, mm.domain, mm.kind,
                MeshOpEntry.MapAddressing.Listed, [cast(uint) vi],
                before.dup, after.dup, [presBefore], [presAfter]);
        }
        return true;
    }

    override bool revert() {
        return revertMapEdit(mesh, undo_, snap);
    }
}

/// Drop the entries of the SELECTED vertices only — measured
/// (`clear_is_selection_scoped`): a clear with 4 of 8 vertices selected leaves
/// the other 4 entries alone. This is a presence operation, NOT a "write
/// zero": for the absolute kind those are different positions, and for either
/// kind they are different states on the wire.
class MorphClear : Command {
    private string       name_;
    private MeshSnapshot snap;      // the hatch's arm only
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see MorphCreate.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph.clear"; }
    override string label() const { return "Clear Morph Entries"; }

    override Param[] params() {
        return [ Param.string_("name", "Map", &name_, "") ];
    }

    protected override bool applyImpl() {
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
        return runMapEdit(mesh, undo_, snap, MeshEditScope.Maps, &clearKernel);
    }

    private bool clearKernel(ref MeshEditBatch ed) {
        auto sel = mesh.selectedVertexIndicesVertices();
        auto mm  = ed.mesh.meshMap(name_);
        assert(mm !is null, "mesh.morph.clear: the map resolved in applyImpl "
                          ~ "vanished before the kernel ran");
        const bool rec = ed.recording();

        // (γ) again, and this is THE cell for the presence channel: a clear is
        // a PRESENCE operation, not a "write zero". `clearMorphValue` zeroes
        // the three components AND drops the bit, and for `morphAbsolute` the
        // two are different vertex positions.
        //
        // PRE-SIZED, NOT APPEND-GROWN (§K.5 rule 3, task 2160): the ceiling is
        // exact — one entry per selected vertex — and `~=` is a runtime call
        // per element, which is what made four L0 commands twice as slow.
        uint[]  idx;
        float[] before, after;
        ubyte[] pb, pa;
        if (rec) {
            idx    = uninitializedArray!(uint[])(sel.length);
            before = uninitializedArray!(float[])(sel.length * 3);
            pb     = uninitializedArray!(ubyte[])(sel.length);
            foreach (k, vi; sel) {
                const size_t v = cast(size_t) vi;
                idx[k] = cast(uint) v;
                before[k * 3 .. k * 3 + 3] = mm.data[v * 3 .. v * 3 + 3];
                pb[k] = v < mm.present.length ? mm.present[v] : 0;
            }
        }

        // The house whole-mesh fallback lives in
        // `selectedVertexIndicesVertices`: no selection means every VISIBLE
        // vertex. Unlike `mesh.edgeCrease.set` this is NOT refused on an empty
        // selection — clearing a whole map is a coherent, reversible request.
        foreach (vi; sel) ed.mesh.clearMorphValue(name_, cast(size_t) vi);

        if (rec) {
            // The AFTER image is read from the LIVE map, not assumed to be
            // zeros-and-absent: `clearMorphValue` refuses an out-of-range
            // vertex, and an entry whose after-image disagrees with the mesh
            // is an undo that writes the wrong thing on redo.
            after = uninitializedArray!(float[])(sel.length * 3);
            pa    = uninitializedArray!(ubyte[])(sel.length);
            foreach (k, vi; sel) {
                const size_t v = cast(size_t) vi;
                after[k * 3 .. k * 3 + 3] = mm.data[v * 3 .. v * 3 + 3];
                pa[k] = v < mm.present.length ? mm.present[v] : 0;
            }
            ed.rec.recordMapValuesOwned(name_, mm.dim, mm.domain, mm.kind,
                MeshOpEntry.MapAddressing.Listed, idx, before, after, pb, pa);
        }
        // NO `commitChange` HERE, deliberately: `clearMorphValue` publishes
        // `Maps` itself, per element, and the batch DEFERS those into one
        // stamp at `close()`. Adding one would publish on an empty selection,
        // where the pre-2230 command published nothing at all.
        return true;
    }

    override bool revert() {
        return revertMapEdit(mesh, undo_, snap);
    }
}

/// Bake the map into the base at `amount` strength. Destructive on the base;
/// the MAP is left exactly as it was (measured: `freeze_deform_keeps_the_map`,
/// and the "map value untouched" half of every apply case).
class MorphApplyCmd : Command {
    private string       name_;
    private float        amount_ = 1.0f;
    private MeshSnapshot snap;      // the hatch's arm only
    // `PositionUndo`, NOT the map holder the five siblings use — and it is the
    // same TYPE under a different alias (`commands/mesh/position_undo.d`). The
    // spelling is the point: this command's payload is `Kind.SetPos`, not
    // `Kind.MapValueDelta`, because it writes `mesh.vertices` and leaves the
    // map exactly as it was.
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see MorphCreate.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

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

    // DIALOG-REACHABLE (config/buttons.yaml "Apply Morph…"), so every
    // rejection is a refusal and none is a throw — see the module header.
    protected override bool applyImpl() {
        baseRefusal_ = "";
        if (name_.length == 0) {
            baseRefusal_ = "name a morph map to apply";
            return false;
        }
        auto m = morphMapOrNull(mesh, name_);
        if (m is null) {
            baseRefusal_ = "no morph map named '" ~ name_ ~ "'";
            return false;
        }
        const MapKind kind = m.kind;

        // REDO: re-run the kernel UNRECORDED and keep the first delta.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            applyKernel(ed, kind);
            ed.close();
            return true;
        }
        if (undoTrackerEnabled()) {
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
            applyKernel(ed, kind);
            undo_.arm(ed.close());
            return true;
        }
        snap = MeshSnapshot.capture(*mesh);
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        applyKernel(ed, kind);
        ed.close();
        return true;
    }

    /// THE ONLY POSITION WRITE IN THE FAMILY, and the reason it goes through
    /// `ed.setVertexPositions` rather than `mesh.vertices[i] = …`: a raw
    /// coordinate write records NOTHING under an open batch, so a delta undo
    /// would restore the map planes (there are none here) and leave the
    /// coordinates at their post-op values.
    ///
    /// Byte-identical to the loop it replaces: `setVertexPositions` skips only
    /// writes whose new value is BIT-identical to the current one, and writing
    /// identical bits back is what the loop did there. Bit identity, not `==`
    /// — `meshPlanesJson` prints `%.9g`, so a `-0.0` the kernel produced is
    /// visible in the parity dump and must still be written.
    private void applyKernel(ref MeshEditBatch ed, MapKind kind) {
        auto m = ed.mesh.meshMap(name_);
        assert(m !is null, "mesh.morph.apply: the map resolved in applyImpl "
                         ~ "vanished before the kernel ran");
        // PRE-SIZED, NOT APPEND-GROWN (§K.5 rule 3): at most one entry per
        // vertex, and the unwritten tail is sliced off at the call.
        auto idxs   = uninitializedArray!(uint[])(ed.mesh.vertices.length);
        auto newPos = uninitializedArray!(Vec3[])(ed.mesh.vertices.length);
        size_t n = 0;
        // Only PRESENT entries move a vertex. For the relative kind an absent
        // entry would be a no-op anyway; for the absolute kind it is the
        // difference between "stay at the base" and "teleport to the origin",
        // so the presence test is load-bearing, not an optimisation.
        foreach (i; 0 .. ed.mesh.vertices.length) {
            if (!m.isPresent(i)) continue;
            idxs[n]   = cast(uint) i;
            newPos[n] = morphApply(ed.mesh.vertices[i],
                                   m.entryOr(i, Vec3(0, 0, 0)),
                                   kind, amount_);
            ++n;
        }
        ed.setVertexPositions(idxs[0 .. n], newPos[0 .. n]);
        // Positions moved, so this is a Geometry-class change, not a Maps one:
        // the MAP is deliberately untouched.
        ed.commitChange(MeshEditScope.Position);
    }

    override bool revert() {
        return revertMapEdit(mesh, undo_, snap);
    }
}

version (unittest) {
    private View morphFreshView() { return new View(0, 0, 1, 1); }
}

// The two DIALOG-REACHABLE commands must REFUSE, not throw, on the state a
// freshly-opened args dialog hands them — which for both is the DEFAULT one:
// `name` is `""` until the user types. `ArgsDialog.draw` runs the command
// inside the `if (Button("OK"))` block and calls `EndPopup()` after it, and
// nothing between here and there catches, so a throw unwinds past the
// popup-close and leaves the ImGui popup stack one deep (task 1073 review B3;
// the same finding, and the same fix, as task 1062's SHOULD-FIX 1 on
// `mesh.edgeCrease.set`).
//
// Every rejection each of the two can be handed is covered, not just the
// empty name — a typo'd `kind` and a name that does not resolve are equally
// reachable by typing into the dialog and pressing OK.
//
// Mutation: turn any one of the four `baseRefusal_ = …; return false;` pairs
// below back into `throw new Exception(...)` -> that block's `apply()` call
// throws out of the unittest and it reddens (verified). Note the refusal
// REASON is asserted alongside the return value: a refusal without a reason
// renders as a completely silent no-op (ui/command_notice.d), which for a
// dialog the user just pressed OK in is its own bug.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    View v = morphFreshView();
    // `morph_target` is process-global app state and MorphCreate steals it on
    // success — leave it as this block found it.
    scope (exit) clearMorphTarget();

    // mesh.morph.create, straight out of the dialog: no name typed yet.
    auto create = new MorphCreate(m, v, EditMode.Vertices);
    assert(!create.apply(),
        "mesh.morph.create must refuse (not throw) on the empty name a "
      ~ "freshly-opened args dialog hands it");
    assert(create.refusalReason().length > 0,
        "a refusal without a reason renders as a SILENT no-op after the user "
      ~ "pressed OK");

    // ...and on a `kind` the user mistyped.
    auto badKind = new MorphCreate(m, v, EditMode.Vertices);
    badKind.name_ = "m1";
    badKind.kind_ = "realtive";
    assert(!badKind.apply(), "mesh.morph.create must refuse an unknown kind");
    assert(badKind.refusalReason().length > 0);
    assert(m.meshMap("m1") is null, "a refused create must not leave a map");

    // ...and on a name that is already taken.
    auto first = new MorphCreate(m, v, EditMode.Vertices);
    first.name_ = "m1";
    assert(first.apply(), "the happy path still applies");
    auto dup = new MorphCreate(m, v, EditMode.Vertices);
    dup.name_ = "m1";
    assert(!dup.apply(), "mesh.morph.create must refuse a duplicate name");
    assert(dup.refusalReason().length > 0);

    // mesh.morph.apply, straight out of the dialog: no name typed yet.
    auto applyCmd = new MorphApplyCmd(m, v, EditMode.Vertices);
    assert(!applyCmd.apply(),
        "mesh.morph.apply must refuse (not throw) on the empty name a "
      ~ "freshly-opened args dialog hands it");
    assert(applyCmd.refusalReason().length > 0);

    // ...and on a name that does not resolve to a morph map.
    auto missing = new MorphApplyCmd(m, v, EditMode.Vertices);
    missing.name_ = "nope";
    assert(!missing.apply(), "mesh.morph.apply must refuse an unknown map");
    assert(missing.refusalReason().length > 0);
}

// mesh.morph.select is UI state, not model state (task 1073 review SF5).
// `app.d`'s post-dispatch tool-drop fires on `CmdFlags.Model`, so this flag is
// the whole reason binding a target no longer disarms an armed transform tool
// — the one workflow where a morph target and a transform tool are used
// together. It also keeps the command out of `docRevision`'s Model class by
// construction.
//
// Mutation: delete the `cmdFlags()` override (the base class returns Model)
// -> the first assertion reddens.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    View v = morphFreshView();
    auto sel = new MorphSelect(m, v, EditMode.Vertices);
    assert((sel.cmdFlags() & CmdFlags.Model) == 0,
        "mesh.morph.select mutates no mesh datum, and app.d drops the armed "
      ~ "tool for every Model command outside the tool./scene./file. families");
    assert((sel.cmdFlags() & CmdFlags.UiState) != 0,
        "...but the binding is still undoable, in the UI-undo class");
}
