module tests.unit.commands.select.type_from_source_public_test;

import commands.select.type_from;

import command;
import mesh;
import view;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.params.params : Param, wireArgs;

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
