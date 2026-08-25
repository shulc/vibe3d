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
import editmode : EditMode;
import document : Layer, ItemXform;
import change_bus : noteLayerChange, LayerChange;

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
    void setEdit(LayerXformTarget[] targets) { targets_ = targets; }

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

    override bool revert() {
        foreach (ref t; targets_) t.target.xform = t.before;
        if (targets_.length > 0) noteLayerChange(LayerChange.PropertyChanged);
        return true;
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
        result.targets_ = merged;
        return result;
    }
}

version (unittest) {
    import math : Vec3;
    private ItemXform xf(float px) {
        ItemXform x;
        x.pos = Vec3(px, 0, 0);
        return x;
    }
}

unittest { // mergeRunTail: single target, first-touch before + latest after.
    Mesh mesh;
    View view = new View(0, 0, 1, 1);
    auto layer = new Layer();

    auto c1 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c1.setEdit([ LayerXformTarget(layer, xf(0), xf(1)) ]);
    auto c2 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c2.setEdit([ LayerXformTarget(layer, xf(1), xf(2)) ]);
    auto c3 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c3.setEdit([ LayerXformTarget(layer, xf(2), xf(3)) ]);

    auto merged = cast(LayerXformEdit) c1.mergeRunTail([c2, c3]);
    assert(merged !is null);
    auto ts = merged.targets();
    assert(ts.length == 1);
    assert(ts[0].target is layer);
    assert(ts[0].before.pos.x == 0, "must keep the RUN-START (first-touch) before");
    assert(ts[0].after.pos.x  == 3, "must adopt the LATEST after");
}

unittest { // mergeRunTail: two targets unioned by Layer IDENTITY.
    Mesh mesh;
    View view = new View(0, 0, 1, 1);
    auto layerA = new Layer();
    auto layerB = new Layer();

    // Gesture 1 touches only A; gesture 2 touches only B (a run that changed
    // which item was under the cursor mid-run would look like this).
    auto c1 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c1.setEdit([ LayerXformTarget(layerA, xf(0), xf(1)) ]);
    auto c2 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c2.setEdit([ LayerXformTarget(layerB, xf(10), xf(11)) ]);

    auto merged = cast(LayerXformEdit) c1.mergeRunTail([c2]);
    assert(merged !is null);
    auto ts = merged.targets();
    assert(ts.length == 2, "targets must union by Layer identity, not overwrite");
    bool sawA = false, sawB = false;
    foreach (t; ts) {
        if (t.target is layerA) { sawA = true; assert(t.before.pos.x == 0); assert(t.after.pos.x == 1); }
        if (t.target is layerB) { sawB = true; assert(t.before.pos.x == 10); assert(t.after.pos.x == 11); }
    }
    assert(sawA && sawB);

    // NIT (0614 review) — order must be the deterministic FIRST-TOUCH
    // insertion order (A touched by c1, B touched by c2), not whatever order
    // an associative array's `.values` happens to iterate in (unspecified by
    // the language). Multi-target merges only ship in Phase 6, but the API
    // is exercised here today, so pin it now rather than let a future caller
    // discover the non-determinism first.
    assert(ts[0].target is layerA && ts[1].target is layerB,
        "targets must preserve deterministic first-touch insertion order");
}

unittest { // apply()/revert() write the WHOLE xform, both directions.
    Mesh mesh;
    View view = new View(0, 0, 1, 1);
    auto layer = new Layer();
    layer.xform = xf(5);

    auto cmd = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    cmd.setEdit([ LayerXformTarget(layer, xf(5), xf(9)) ]);

    assert(cmd.apply());
    assert(layer.xform.pos.x == 9);

    assert(cmd.revert());
    assert(layer.xform.pos.x == 5);
}
