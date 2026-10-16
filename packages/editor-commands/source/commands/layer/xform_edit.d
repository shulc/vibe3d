module commands.layer.xform_edit;

// Task 0614 Phase 4 (doc/item_mode_transform_plan.md §Undo) — the item-mode
// gizmo-drag undo command. NOT user-facing (no dispatcher id, no /api/command
// entry point) — built only by XfrmTransformTool's item-commit branch, one
// per gesture, mirroring MeshVertexEdit's role on the vertex path.
//
// `LayerAttr` (commands/layer/commands.d) stays the panel's write point (one
// param per invocation); this command exists because a gizmo drag touches
// several ItemXform channels (pos/rot/scl) in ONE gesture and needs ONE
// undo entry, which LayerAttr's per-(target,attrName) compareOp cannot give
// (see the plan's "Do NOT reuse layer.attr for the drag").

import command : Command, CmdFlags, CompareResult, RunMergeable;
import mesh : Mesh;
import view : View;
import vibe3d.editing.contracts.editmode : EditMode;
import document : Layer, ItemXform;
import vibe3d.mesh.change.change_bus : noteLayerChange, LayerChange;

/// One target's before/after `ItemXform` pair. A plain array (not an
/// associative structure) so the payload stays ordered and trivially
/// serializable; Phase 3 constructs a one-element array (the primary),
/// Phase 6 widens it to every selected item — the shape needs no change.
struct LayerXformTarget {
    Layer     target;
    ItemXform before;
    ItemXform after;
}

/// Undo command for a gizmo-driven item-transform gesture. `apply()` writes
/// every target's `after` xform; `revert()` restores `before`. Both are
/// whole-`ItemXform` writes (matching the reference's absolute, per-slot
/// write model — §SDK-grounded reason 7 in the plan), never a delta.
final class LayerXformEdit : Command, RunMergeable {
    private LayerXformTarget[] targets_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    /// Programmatic setter — mirrors `MeshVertexEdit.setEdit`. Called once by
    /// the tool's item-commit branch right before recording.
    void setEdit(LayerXformTarget[] targets) {
        targets_ = targets;
        noteUndoRecorded();   // task 2500 — the image and its flag, one statement
    }

    /// Read-only accessor so a caller (e.g. a future undo-panel widget, or a
    /// test) can inspect the payload without a downcast into private state.
    const(LayerXformTarget)[] targets() const { return targets_; }

    override string name()  const { return "layer.xform.edit"; }
    override string label() const { return "Transform Item"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }

    protected override bool applyImpl() {
        foreach (ref t; targets_) t.target.xform = t.after;
        if (targets_.length > 0) noteLayerChange(LayerChange.PropertyChanged);
        return true;
    }

    protected override void revertImpl() {
        foreach (ref t; targets_) t.target.xform = t.before;
        if (targets_.length > 0) noteLayerChange(LayerChange.PropertyChanged);
    }

    /// RunMergeable — collapse a whole in-session run into ONE surviving
    /// entry. `this` is the run's EARLIEST recorded gesture (it owns the
    /// run-start `before`); `later` are the rest, oldest -> newest. The merge
    /// law mirrors `MeshVertexEdit.mergeRun` exactly: union targets by
    /// `Layer` IDENTITY, keep the FIRST-TOUCH `before` per target (the
    /// run-start state), adopt the LATEST `after` per target (the run-end
    /// state). Declines (returns null) only if `later` is empty or contains
    /// a foreign command type — neither is reachable through
    /// `CommandHistory.consolidate`'s own gather, which only ever calls this
    /// with commands from the SAME tagged run.
    Command mergeRunTail(Command[] later) {
        if (later.length == 0) return null;

        // NIT (0614 review) — an ordered array + an index map, NOT an
        // associative array keyed by `Layer`. `AA.values`' iteration order is
        // unspecified by the language; at Phase 3's single-target shape this
        // was harmless (a 1-element array has only one order), but Phase 6
        // ships multiple targets and an unspecified merge order becomes a
        // real, visible non-determinism (e.g. a serialised undo payload whose
        // element order isn't reproducible run to run). This keeps the exact
        // same union-by-identity / first-touch-before / latest-after law,
        // just with a deterministic FIRST-TOUCH insertion order.
        LayerXformTarget[] merged;
        size_t[Layer] indexOf;
        foreach (ref t; targets_) {
            indexOf[t.target] = merged.length;
            merged ~= t;
        }

        foreach (cmd; later) {
            auto le = cast(LayerXformEdit) cmd;
            if (le is null) return null;
            foreach (ref t; le.targets_) {
                if (auto idx = t.target in indexOf) {
                    merged[*idx].after = t.after;   // adopt the latest after
                } else {
                    indexOf[t.target] = merged.length;
                    merged ~= t;                     // first touch by a LATER
                                                       // command — its own
                                                       // `before` IS the
                                                       // run-start state for
                                                       // this target
                }
            }
        }

        auto result = new LayerXformEdit(meshPtr(), viewRef(), editModeVal());
        // Through `setEdit`, not a raw field write: it is the door that raises
        // the undo flag (task 2500), and a merged run holds an image exactly
        // like the entries it replaces.
        result.setEdit(merged);
        return result;
    }
}
