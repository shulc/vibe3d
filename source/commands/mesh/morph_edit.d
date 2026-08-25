module commands.mesh.morph_edit;

// The undo record for a ROUTED transform gesture (task 1069).
//
// ─── WHY THIS EXISTS AT ALL ────────────────────────────────────────────────
//
// A routed drag reaches undo through NOTHING today. `TransformTool.buildEditCmd`
// diffs `mesh.vertices[vid]` against the positions `beginEdit` captured and
// returns `null` when nothing changed — and under routing nothing in
// `mesh.vertices` changes, by design. So without this command a user can morph
// a face for a minute and find the undo stack empty.
//
// ─── WHY IT IS NOT A `MeshVertexEdit` (and must never become one) ──────────
//
// It would be tempting to subclass `MeshVertexEdit` and override the two
// mutators. That is a data-corrupting trap. `CommandHistory.consolidate` has
// two arms and tries them IN ORDER: arm 1 downcasts every entry of a run to
// `MeshVertexEdit` and, on success, collapses the run with
// `MeshVertexEdit.mergeRun` — which constructs a PLAIN `MeshVertexEdit` from
// the gathered payloads. A `MeshMorphEdit` subclass would pass that downcast,
// get merged into a plain vertex edit, and its stored DELTAS would be written
// straight into `mesh.vertices` on the next undo.
//
// So this is a plain `Command` implementing `RunMergeable`: arm 1 declines
// (`allVertexEdits = false`), arm 2 catches it, and the run collapses through
// `mergeRunTail` below with the same first-touch-before / latest-after law.
//
// ─── PAYLOAD ──────────────────────────────────────────────────────────────
//
// Per touched vertex, the map's stored value AND its PRESENCE before and
// after. Presence is part of the payload because an undo has to be able to
// return an entry to ABSENT — writing a zero instead would leave a present
// zero, which is a different state on the wire and, for the absolute kind, a
// different POSITION.

import command   : Command, CmdFlags, CompareResult, RunMergeable;
import mesh      : Mesh, MapKind, isMorphKind;
import view      : View;
import editmode  : EditMode;
import math      : Vec3;
import mesh_edit_delta : MeshEditScope;

/// One vertex's before/after map state.
struct MorphEntryEdit {
    uint vert;
    Vec3 before;
    bool beforePresent;
    Vec3 after;
    bool afterPresent;
}

final class MeshMorphEdit : Command, RunMergeable {
    private string           mapName_;
    private MorphEntryEdit[] entries_;
    private string           editLabel_ = "Morph";

    // The same tool-state hooks `MeshVertexEdit` carries, for the same reason:
    // the rotate / scale sub-tools push their Tool-Properties accumulators
    // alongside the mutation so the slider readout matches the mesh after an
    // undo. Routing does not change that need.
    private void delegate() onApplyHook_;
    private void delegate() onRevertHook_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.morph_edit"; }
    override string label() const {
        import std.conv : to;
        return editLabel_ ~ " " ~ entries_.length.to!string ~ " morph entries";
    }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }

    void setEdit(string mapName, MorphEntryEdit[] entries, string label = "Morph") {
        mapName_   = mapName;
        entries_   = entries;
        editLabel_ = label.length ? label : "Morph";
    }

    void setHooks(void delegate() onApply, void delegate() onRevert) {
        onApplyHook_  = onApply;
        onRevertHook_ = onRevert;
    }

    string mapName() const { return mapName_; }
    const(MorphEntryEdit)[] entries() const { return entries_; }
    bool isEmpty() const { return entries_.length == 0; }

    /// True when any entry actually changed — value OR presence. A gesture
    /// that moved nothing must not land on the undo stack, and PRESENCE alone
    /// is a real change: writing a zero delta where there was no entry is what
    /// `zero_move_creates_entries` measures.
    bool changed() const {
        foreach (ref e; entries_) {
            if (e.beforePresent != e.afterPresent) return true;
            if (e.before.x != e.after.x || e.before.y != e.after.y
             || e.before.z != e.after.z) return true;
        }
        return false;
    }

    private void write(bool useAfter) {
        auto map = mesh.morphMapForWrite(mapName_);
        if (map is null) return;
        foreach (ref e; entries_) {
            const bool present = useAfter ? e.afterPresent : e.beforePresent;
            const Vec3 v       = useAfter ? e.after         : e.before;
            if (present) {
                map.setEntry(e.vert, v);
            } else {
                // Restore to ABSENT, not to zero. For the absolute kind those
                // are different POSITIONS ("stay at the base" vs "go to the
                // origin"), and for either kind they are different states on
                // the wire.
                mesh.clearMorphValue(mapName_, e.vert);
            }
        }
        mesh.commitChange(MeshEditScope.Maps);
    }

    protected override bool applyImpl() {
        write(/*useAfter=*/true);
        if (onApplyHook_ !is null) onApplyHook_();
        return true;
    }

    override bool revert() {
        write(/*useAfter=*/false);
        if (onRevertHook_ !is null) onRevertHook_();
        return true;
    }

    /// Coalescing predicate. A continuation iff the previous command is also a
    /// `MeshMorphEdit`, on the SAME mesh, the SAME MAP and the same vertex set
    /// in the same order, with the same label.
    ///
    /// The MAP NAME test is load-bearing and easy to omit: without it, two
    /// gestures into two DIFFERENT morphs that happened to touch the same
    /// vertices would coalesce into one undo entry, and undoing it would write
    /// one map's values while leaving the other's edit stranded.
    override CompareResult compareOp(const Command prev) const {
        auto p = cast(const(MeshMorphEdit)) prev;
        if (p is null) return CompareResult.Different;
        if (p.mesh !is this.mesh) return CompareResult.Different;
        if (p.mapName_ != this.mapName_) return CompareResult.Different;
        if (p.editLabel_ != this.editLabel_) return CompareResult.Different;
        if (p.entries_.length != this.entries_.length) return CompareResult.Different;
        foreach (i, ref e; this.entries_)
            if (p.entries_[i].vert != e.vert) return CompareResult.Different;
        return CompareResult.Compatible;
    }

    /// In-place merge of a newer COMPATIBLE edit: keep this entry's `before`
    /// (the run-start state) and adopt the newer one's `after`.
    override bool mergeFrom(Command newer) {
        auto n = cast(MeshMorphEdit) newer;
        if (n is null) return false;
        if (n.entries_.length != this.entries_.length) return false;
        foreach (i, ref e; this.entries_) {
            e.after        = n.entries_[i].after;
            e.afterPresent = n.entries_[i].afterPresent;
        }
        return true;
    }

    /// `RunMergeable` — collapse a whole tagged run into ONE surviving entry.
    /// `this` is the run's EARLIEST gesture (it owns the run-start `before`);
    /// `later` are the rest, oldest -> newest. Union by vertex id, FIRST-TOUCH
    /// before, LATEST after — the same law `MeshVertexEdit.mergeRun` and
    /// `LayerXformEdit.mergeRunTail` use.
    ///
    /// Declines (null) on an empty tail, a foreign command type, or a
    /// DIFFERENT map name — the last one matters: consolidate gathers by run
    /// tag, and a run that switched target mid-way must not be folded into one
    /// entry that can only restore one of the two maps.
    Command mergeRunTail(Command[] later) {
        if (later.length == 0) return null;

        MorphEntryEdit[] merged;
        size_t[uint] indexOf;
        foreach (ref e; entries_) {
            indexOf[e.vert] = merged.length;
            merged ~= e;
        }
        foreach (cmd; later) {
            auto me = cast(MeshMorphEdit) cmd;
            if (me is null) return null;
            if (me.mapName_ != this.mapName_) return null;
            foreach (ref e; me.entries_) {
                if (auto idx = e.vert in indexOf) {
                    merged[*idx].after        = e.after;
                    merged[*idx].afterPresent = e.afterPresent;
                } else {
                    // First touch by a LATER gesture — its OWN `before` is the
                    // run-start state for this vertex.
                    indexOf[e.vert] = merged.length;
                    merged ~= e;
                }
            }
        }

        auto result = new MeshMorphEdit(meshPtr(), viewRef(), editModeVal());
        result.setEdit(mapName_, merged, editLabel_);
        auto last = cast(MeshMorphEdit) later[$ - 1];
        result.setHooks(last !is null ? last.onApplyHook_ : onApplyHook_,
                        onRevertHook_);
        return result;
    }
}
