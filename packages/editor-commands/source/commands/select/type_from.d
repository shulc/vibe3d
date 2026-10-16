module commands.select.type_from;

import command;
import mesh;
import view;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.params.params : Param, wireArgs;

/// select.typeFrom <vertex|edge|polygon|item>
/// Switches the current SELECTION TYPE without changing any selection.
/// Not undoable — mode-only, no mesh mutation.
///
/// Selection-types Stage 1: when an `applyHook` is supplied (the app wires it
/// to its geometry-type switch funnel), `apply()` routes the switch through it
/// so the SelType recent-ordering, the lockstep editMode write, the tool-drop
/// (flip or not), and the `currentTypeChanged` bus note all happen in ONE
/// place — keyboard keys 1/2/3 and this command share that single funnel.
/// Without a hook (e.g. a standalone/headless construction) it falls back to
/// writing `*editModePtr` directly, preserving the original behavior.
///
/// ---------------------------------------------------------------------------
/// `item` is a fourth SelType, NOT a fourth EditMode (task 0642)
/// ---------------------------------------------------------------------------
/// `EditMode` has exactly THREE values and is the picking/draw authority. Under
/// `SelType.Item` it deliberately RETAINS the most-recent geometry type
/// (`source/seltype.d`, and the invariant asserted on the `/api/selection` read
/// boundary) so geometry picking always has a defined mode. So the `item` arm
/// below cannot go through `applyHook`/`editModePtr` at all: there is no
/// `EditMode` to hand it and nothing to write. It routes through its own
/// `itemHook` — the app's deliberate item-type door — and leaves `editModePtr`
/// alone by construction.
///
/// The hook is set-injected (`setItemHook`) rather than passed to the ctor so
/// the existing two ctor signatures and their four call sites stay untouched;
/// same shape as `SelectFillInsideLoop.setPromoteHook`.
class SelectTypeFromCommand : Command {
    private EditMode*               editModePtr;
    private string                  targetType;
    private void delegate(EditMode) applyHook;
    private void delegate()         itemHook;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr,
         void delegate(EditMode) applyHook = null) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
        this.applyHook   = applyHook;
    }

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr,
         string targetType, void delegate(EditMode) applyHook = null) {
        this(mesh, view, editMode, editModePtr, applyHook);
        this.targetType = targetType;
    }

    override string name()  const { return "select.typeFrom"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// The declared argument, and therefore positional slot 0 (task 4062).
    /// An ABSENT argument leaves whatever the constructor put here — the
    /// registered `select.vertex` / `select.edge` / `select.polygon` /
    /// `select.item` ids each bake their own type, and `injectParamsInto`
    /// never writes a key the payload did not carry.
    override Param[] params() {
        return wireArgs(
            Param.string_("type", "Type", &targetType, "")
        );
    }

    void setTargetType(string t) { targetType = t; }

    /// Install the item-type door (app.d's `switchItemType`). Returns `this`
    /// so registration can chain it onto the constructor expression.
    typeof(this) setItemHook(void delegate() dg) { itemHook = dg; return this; }

    protected override bool applyImpl() {
        // The item arm short-circuits ABOVE the EditMode mapping — see the
        // class doc comment. It never touches `editModePtr`.
        if (targetType == "item") {
            if (itemHook is null)
                throw new Exception(
                    "select.typeFrom item: no item-type hook wired. `item` is a "
                    ~ "SelType with no EditMode counterpart, so it cannot be "
                    ~ "applied through the editMode fallback — construct this "
                    ~ "command through the app's registration (which calls "
                    ~ "setItemHook) or supply the hook explicitly");
            itemHook();
            return true;
        }
        EditMode mode;
        switch (targetType) {
            case "vertex":  mode = EditMode.Vertices; break;
            case "edge":    mode = EditMode.Edges;    break;
            case "polygon": mode = EditMode.Polygons; break;
            default:
                throw new Exception(
                    "select.typeFrom: unknown type '" ~ targetType ~
                    "' — expected vertex, edge, polygon, or item; "
                    ~ "to select an indexed element, use "
                    ~ "`select.element vertex|edge|polygon set <idx>`, "
                    ~ "and for an item `layer.select {index, mode}` "
                    ~ "(select.element does NOT take item)");
        }
        if (applyHook !is null) applyHook(mode);
        else                    *editModePtr = mode;
        return true;
    }
}

