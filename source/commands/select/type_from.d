module commands.select.type_from;

import command;
import mesh;
import view;
import editmode;
import params : Param, wireArgs;

/// select.typeFrom <vertex|edge|polygon|item>
/// Switches the current SELECTION TYPE without changing any selection.
/// Not undoable — mode-only, no mesh mutation.
///
/// Selection-types Stage 1: when an `applyHook` is supplied (the app wires it
/// to its geometry-type switch funnel), `apply()` routes the switch through it
/// so the SelType recent-ordering, the lockstep editMode write, the tool-drop
/// on a front-flip, and the `currentTypeChanged` bus note all happen in ONE
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

// ---------------------------------------------------------------------------
// In-module unit tests — the wire vocabulary's four tokens and the ONE
// structural claim that separates `item` from the other three: the item arm
// must not write `*editModePtr`.
//
// A wrong-but-plausible implementation ("just map item onto a fourth EditMode",
// or "fall through to the editMode fallback when no hook is wired") is exactly
// what the second unittest below reads a different number through: it would
// leave `em` at something other than the Polygons it was seeded with.
// ---------------------------------------------------------------------------

version (unittest) {
    import std.typecons : tuple;

    // Build a command against a throwaway mesh/view, seeded with `t`.
    // Same construction shape the other command unittests use
    // (commands/layer/xform_edit.d), with the Mesh on the heap so the
    // `Mesh*` the command keeps outlives this frame.
    private SelectTypeFromCommand mkTypeFrom(string t, EditMode* emPtr,
                                             void delegate(EditMode) applyHook,
                                             void delegate() itemHook) {
        auto m = new Mesh;                 // heap, so the Mesh* outlives this frame
        View v = new View(0, 0, 1, 1);
        auto c = new SelectTypeFromCommand(m, v, *emPtr, emPtr, t, applyHook);
        c.setItemHook(itemHook);
        return c;
    }
}

// The three geometry tokens route through applyHook with the mapped EditMode.
// `geomCalls` is counted rather than inferred from `seen`: `EditMode.init` IS
// `Vertices`, so a "did the hook fire" check written as `seen == Vertices`
// would pass on a hook that never fired at all.
unittest {
    EditMode em = EditMode.Polygons;
    EditMode seen;
    int      geomCalls = 0;
    int      itemCalls = 0;
    void onGeom(EditMode m) { seen = m; geomCalls++; }
    void onItem()           { itemCalls++; }

    foreach (pair; [tuple("vertex",  EditMode.Vertices),
                    tuple("edge",    EditMode.Edges),
                    tuple("polygon", EditMode.Polygons)]) {
        geomCalls = 0;
        auto c = mkTypeFrom(pair[0], &em, &onGeom, &onItem);
        assert(c.apply());
        assert(geomCalls == 1, "token '" ~ pair[0] ~ "' must fire the geometry funnel once");
        assert(seen == pair[1], "token '" ~ pair[0] ~ "' must map to its EditMode");
    }
    assert(itemCalls == 0, "a geometry token must not reach the item door");
}

// `item` fires the item door and leaves the EditMode pointer ALONE. The
// discriminating value: `em` stays Polygons. An implementation that mapped
// `item` onto a fourth EditMode, or that fell through to the `*editModePtr`
// fallback, would write something else here.
unittest {
    EditMode em = EditMode.Polygons;
    int      geomCalls = 0;
    int      itemCalls = 0;
    void onGeom(EditMode m) { geomCalls++; }
    void onItem()           { itemCalls++; }

    auto c = mkTypeFrom("item", &em, &onGeom, &onItem);
    assert(c.apply());
    assert(itemCalls == 1, "item must fire the item door exactly once");
    assert(em == EditMode.Polygons,
        "the item arm must NOT write *editModePtr — EditMode is the geometry "
        ~ "view and stays at the most-recent geometry type under Item");
    assert(geomCalls == 0, "item must not reach the geometry applyHook");
}

// An unknown token still throws, and the message now names all FOUR.
unittest {
    import std.exception : assertThrown, collectExceptionMsg;
    import std.algorithm : canFind;
    EditMode em = EditMode.Vertices;
    auto c = mkTypeFrom("ptag", &em, null, null);
    auto msg = collectExceptionMsg(c.apply());
    assert(msg.canFind("item"), "the reject message must enumerate item: " ~ msg);
}

// `item` with NO hook wired throws rather than silently degrading into an
// editMode write. Pins the "there is nothing to fall back to" contract.
unittest {
    import std.exception : collectExceptionMsg;
    import std.algorithm : canFind;
    EditMode em = EditMode.Edges;
    auto c = mkTypeFrom("item", &em, null, null);
    auto msg = collectExceptionMsg(c.apply());
    assert(msg.length > 0, "item without a hook must throw, not no-op");
    assert(em == EditMode.Edges, "and must not have written *editModePtr");
}
