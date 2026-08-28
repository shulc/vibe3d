module commands.mesh.uv_map_util;

import command;
import mesh            : Mesh, MapDomain, MapKind, MeshMap, MeshEditBatch,
                         kindInfo, kUvMapName, MAX_MESH_MAPS;
import view            : View;
import editmode        : EditMode;
import mesh_edit_delta : MeshEditScope, MeshOpEntry;
import params          : Param;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, mapSlotOf;

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
// UNDO IS A RECORDED `MeshOpEntry.Kind.MapValueDelta` SINCE TASK 1903 STAGE
// L1-b. Each of the four records one entry; the escape hatch's `MeshSnapshot`
// arm died with the hatch at task 1903 Stage N. The two arms are
// `commands/mesh/map_edit_undo.runMapEdit`, shared with `morph.d`, `weightmap.d`
// and the five UV value files.
//
// THE TWO TRAPS THAT ARE THIS FILE'S OWN — both named by the plan, both real:
//
//   1. `uv.copy` CREATES its target and FILLS it, so its undo owes a map
//      REMOVAL and its redo owes the CONTENT. `resizeAllMeshMaps` will not
//      un-add a map for you, and a `DefaultInit` create would replay as an
//      empty channel that has the right name, domain, dim and LENGTH — the
//      one shape where "the map is there" and "the map is right" come apart.
//      So it records `recordMapCreateFilledOwned`, which is the same choice
//      `morph.d` makes for its ABSOLUTE kind and for the same reason
//      (`session_edit.d:140` replays a delta FORWARD for redo).
//   2. `uv.clear`'s forward result is ALL ZEROS, which makes a zero-filling
//      revert indistinguishable from a correct one ON THE FORWARD IMAGE.
//      That is Stage F1's measured failure in its purest form — a revert that
//      restored a map's LENGTH, zeroed all 48 of its values and answered
//      `true`. Every witness for this file therefore measures an ARMED
//      REVERT, never a forward.
//
// …and one this file shares with `weightmap.d`: `uv.delete` removes a map that
// is not last in the registry, so its reverse must carry the SLOT
// (`mapSlotOf`). Measured on the frozen oracle: without it the undo restores
// the map's content at the end of `meshMaps` and the `meshMaps` plane differs
// in ORDER from what `MeshSnapshot.restore` produced.
//
// REFUSALS BEFORE THE BATCH. A `throw` out of an open batch leaves
// `~MeshEditBatch` to pop the frame and tick `changeBus.batchLeaks`, which the
// suite asserts is 0, so `uv.copy`'s "failed to create map" is now two
// pre-checks with their own messages instead of one discovery mid-mutation.
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
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 2250). A
        /// command that recorded NOTHING falls back to its snapshot and
        /// restores every plane correctly, so every result-shaped assertion is
        /// green over a deleted recorder; only reading the log itself is not.
        /// `public` on the declaration and NOT a `public:` section — a section
        /// marker would silently change the protection of every member below.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.delete"; }
    override string label() const { return "Delete UV Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, kUvMapName) ];
    }

    protected override bool applyImpl() {
        requireUvMap(mesh, name_);   // throws if absent or not a UV map
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &deleteKernel);
    }

    private bool deleteKernel(ref MeshEditBatch ed) {
        // THE WHOLE PRE-IMAGE, READ BEFORE THE SPLICE, behind `recording()` so
        // the redo and hatch arms copy nothing. Mode B — one whole map — and
        // the registry SLOT, because `removeMeshMap` splices while the
        // reverse's re-registration appends.
        ubyte     dim;
        MapDomain dom;
        MapKind   kind;
        float[]   data;
        ubyte[]   pres;
        uint      slot = uint.max;
        const bool rec = ed.recording();
        if (rec) {
            auto live = ed.mesh.meshMap(name_);
            assert(live !is null, "uv.delete: the map resolved in applyImpl "
                                ~ "vanished before the kernel ran");
            dim  = live.dim;
            dom  = live.domain;
            kind = live.kind;
            data = live.data.dup;      // one block memcpy, never a gather
            pres = live.present.dup;   // EMPTY for a uv kind, carried anyway
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

// ---------------------------------------------------------------------------
// uv.rename — rename a UV map in place.
// ---------------------------------------------------------------------------

class UvRename : Command {
    private string       from_ = kUvMapName;
    private string       to_;
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see UvDelete.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

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

    protected override bool applyImpl() {
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
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &renameKernel);
    }

    private bool renameKernel(ref MeshEditBatch ed) {
        auto m = ed.mesh.meshMap(from_);
        assert(m !is null, "uv.rename: the map resolved in applyImpl vanished "
                         ~ "before the kernel ran");
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
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see UvDelete.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

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

    protected override bool applyImpl() {
        if (from_.length == 0 || to_.length == 0)
            throw new Exception(
                "uv.copy: from/to must not be empty");
        if (from_ == to_)
            throw new Exception(
                "uv.copy: from and to must not be identical");
        requireUvMap(mesh, from_);   // throws if absent or not UV
        if (mesh.meshMap(to_) !is null)
            throw new Exception(
                "uv.copy: target name '" ~ to_ ~ "' already exists");
        // The OTHER way `addMeshMap` answers null, hoisted in front of the
        // batch: the per-mesh map ceiling. It used to be reported by the same
        // "failed to create map" throw, from inside the mutation.
        if (mesh.meshMaps.length >= MAX_MESH_MAPS)
            throw new Exception(
                "uv.copy: this mesh already carries the maximum number of maps");
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &copyKernel);
    }

    private bool copyKernel(ref MeshEditBatch ed) {
        // POINTER-SAFETY, unchanged: `addMeshMap` does `meshMaps ~= m`, which
        // can reallocate, so `src`'s fields are copied to LOCALS first and
        // `src` is never dereferenced after the append.
        auto src = ed.mesh.meshMap(from_);
        assert(src !is null, "uv.copy: the source resolved in applyImpl "
                           ~ "vanished before the kernel ran");
        const ubyte   srcDim  = src.dim;
        const float[] srcData = src.data.dup;

        auto dst = ed.mesh.addMeshMap(to_, srcDim, MapDomain.PolyVertex);
        assert(dst !is null, "uv.copy: addMeshMap refused after applyImpl "
                           ~ "pre-checked both of its refusal terms");
        dst.data[] = srcData[];

        // FILLED, NOT `DefaultInit` — this is the trap the plan named for this
        // file. The undo needs only a name, but `MeshSessionEdit` replays a
        // delta FORWARD for redo (`session_edit.d:140`), and a default-init
        // replay would produce a map with the right name, domain, dim and
        // LENGTH whose every value is zero. Nothing would throw and nothing
        // would look wrong.
        if (ed.recording())
            ed.rec.recordMapCreateFilledOwned(to_, dst.dim, dst.domain, dst.kind,
                                              dst.data.dup, dst.present.dup);
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

// ---------------------------------------------------------------------------
// uv.clear — zero a UV map's values (reset to the default value 0.0).
// The map itself is kept; only its data array is zeroed.
// ---------------------------------------------------------------------------

class UvClear : Command {
    private string       name_ = kUvMapName;
    private RecordedUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo — see UvDelete.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "uv.clear"; }
    override string label() const { return "Clear UV Map"; }

    override Param[] params() {
        return [ Param.string_("name", "Name", &name_, kUvMapName) ];
    }

    protected override bool applyImpl() {
        requireUvMap(mesh, name_);   // throws if absent or not UV
        return runMapEdit(this, mesh, undo_, MeshEditScope.Material, &clearKernel);
    }

    private bool clearKernel(ref MeshEditBatch ed) {
        auto m = ed.mesh.meshMap(name_);
        assert(m !is null, "uv.clear: the map resolved in applyImpl vanished "
                         ~ "before the kernel ran");
        const bool rec    = ed.recording();
        const bool tracks = kindInfo(m.kind).tracksPresence;

        // `WholeArray`, and it is NOT sparsified — plan §K.5 rule 5. Every
        // element of a non-empty UV map is a candidate, so the sparse form is
        // strictly larger here (an index per corner on top of the values). The
        // before-image is ONE block `dup`, never a per-element gather: `.dup`
        // is a memcpy, `~=` is a runtime call per element (2.39-3.27 ms
        // against 0.12-1.08 ms per 100 489, measured at task 2160).
        float[] before;
        ubyte[] presBefore;
        if (rec) {
            before = m.data.dup;
            if (tracks) presBefore = m.present.dup;
        }
        m.data[] = 0.0f;
        if (rec) {
            // The AFTER image is read back from the LIVE map, not assumed to
            // be zeros — and this is exactly where the family's headline
            // failure hides: the forward result of a clear IS all zeros, so a
            // revert that zero-fills is indistinguishable from a correct one
            // on the forward image. Stage F1 measured that failure answering
            // `true`.
            ed.rec.recordMapValuesOwned(name_, m.dim, m.domain, m.kind,
                MeshOpEntry.MapAddressing.WholeArray, null,
                before, m.data.dup,
                tracks ? presBefore : null,
                tracks ? m.present.dup : null);
        }
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
