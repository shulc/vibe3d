module seltype;

import editmode : EditMode;

// source/seltype.d — imports nothing; pure data. No GL, no render, no UI.
//
// Selection-types Stage 1: the "current selection type" authority.
//
// `SelType` generalizes the geometry-only `EditMode` (Vertices/Edges/Polygons)
// to a small ordered set of selection TYPES that additionally carries `Item`
// (layer) selection, with a most-recent-FIRST ordering. The front of the order
// (`selTypeOrder[0]`) is the CURRENT type; `touchSelType(t)` promotes `t` to the
// front (keeping the rest in relative order) — the analog of a typed
// recent-ordering service's per-type "touch".
//
// `EditMode` survives as the geometry-type VIEW and stays the picking/draw
// authority: when the current type is a geometry type, `editMode` mirrors it;
// when the current type is `Item`, `editMode` retains the most-recent geometry
// type (`mostRecentGeometryType`) so geometry picking/drawing always has a
// defined mode. Stage 1 never makes `Item` current — it lands in the enum +
// ordering as forward-compatible shape, exercised only by the unittests.
//
// `editMode` is a MATERIALIZED VIEW of `selTypeOrder.mostRecentGeometry`:
// it is written by exactly ONE writer path — `setEditModeFromOrder()` in
// `app.d` (called from the geometry-type funnel `switchGeometryType` /
// `promoteGeometryType`). No command or handler writes `editMode` independently
// of the order. A debug-only invariant on the `/api/selection` read boundary
// asserts `editMode == geometryEditMode(selTypeOrder.mostRecentGeometry)`.
//
// MIT-clean naming: vibe3d-native infrastructure. No proprietary / SDK symbol
// names appear here — the neutral identifiers (`SelType`, `selTypeOrder`,
// `currentSelType`, `touchSelType`, `mostRecentGeometryType`) are the public
// vocabulary; provenance lives in doc/ + agent memory.

/// The selection types. `Vertex/Edge/Polygon` are the geometry types (1:1 with
/// `EditMode.Vertices/Edges/Polygons`); `Item` is layer selection.
enum SelType : ubyte { Vertex, Edge, Polygon, Item }

/// The uniform select-operation mode shared by item (and, later, geometry)
/// selection commands. NEUTRAL vocabulary mirroring the reference's
/// `{set,add,remove,toggle}` select-mode enum (Stage 2a folds it into
/// `layer.select`'s `mode` arg, replacing the prior `additive` bool /
/// standalone deselect):
///   * `Set`    — exclusive: deselect every other item, select the target,
///                it becomes primary.
///   * `Add`    — select the target (if not already), it becomes primary.
///   * `Remove` — deselect the target; if it was primary, primary moves to the
///                most-recent remaining selected item. Removing the LAST
///                selected item is a no-op (≥1 selected invariant).
///   * `Toggle` — `selected ? Remove : Add` (ctrl-click semantics).
enum SelMode : ubyte { Set, Add, Remove, Toggle }

/// Parse the lowercase wire token (`set`/`add`/`remove`/`toggle`) into a
/// `SelMode`. The string spelling is the `layer.select mode:` argument
/// vocabulary; an unknown token throws (the command param's enum validation
/// rejects it before this is reached, so this is a defensive fallback).
SelMode selModeFromToken(string s) pure @safe {
    switch (s) {
        case "set":    return SelMode.Set;
        case "add":    return SelMode.Add;
        case "remove": return SelMode.Remove;
        case "toggle": return SelMode.Toggle;
        default: throw new Exception("unknown select mode '" ~ s ~ "'");
    }
}

/// True iff `t` is a geometry selection type (Vertex/Edge/Polygon), i.e. one
/// with an `EditMode` counterpart. `Item` is the only non-geometry type.
bool isGeometryType(SelType t) pure nothrow @safe @nogc {
    return t != SelType.Item;
}

/// A most-recent-FIRST ordered list over the four selection types. A
/// fixed-capacity 4-element array (every `SelType` appears exactly once), so
/// there is no allocation and no growth. `order[0]` is the current type.
///
/// The default ordering puts the three geometry types first (Vertex current),
/// then `Item` — matching the editor booting in vertex mode with no item
/// selection ever having been current.
struct SelTypeOrder {
    SelType[4] order = [SelType.Vertex, SelType.Edge,
                        SelType.Polygon, SelType.Item];

    /// The current (most-recent) selection type.
    SelType current() const pure nothrow @safe @nogc { return order[0]; }

    /// Promote `t` to the front (most-recent), shifting everything that was
    /// ahead of it back by one. The relative order of the others is preserved.
    /// Returns true iff this CHANGED the front (i.e. `t` was not already
    /// current) — callers use that to gate the front-flip side effects
    /// (tool-drop, the `currentTypeChanged` bus note).
    bool touch(SelType t) pure nothrow @safe @nogc {
        if (order[0] == t) return false;          // already current — no flip
        // Find t's current position, then rotate [0 .. pos] right by one so t
        // lands at the front and the displaced entries shift back one slot.
        size_t pos = 0;
        foreach (i, e; order) if (e == t) { pos = i; break; }
        foreach_reverse (i; 1 .. pos + 1) order[i] = order[i - 1];
        order[0] = t;
        return true;
    }

    /// The most-recent of the GEOMETRY types (Vertex/Edge/Polygon), scanning the
    /// order front-to-back. Used to derive `editMode` while `Item` is current
    /// (so geometry picking keeps a defined mode under item selection). Always
    /// well-defined — the three geometry types are always present in the order.
    SelType mostRecentGeometry() const pure nothrow @safe @nogc {
        foreach (t; order) if (isGeometryType(t)) return t;
        return SelType.Vertex; // unreachable (all three are always present)
    }
}

// Free-function facade over a SelTypeOrder reference, matching the plan's
// vocabulary (`currentSelType`, `touchSelType`, `mostRecentGeometryType`). These
// keep call sites reading as verbs against the app's one ordering instance.

/// The current (most-recent) selection type held by `o`.
SelType currentSelType(ref const SelTypeOrder o) pure nothrow @safe @nogc {
    return o.current;
}

/// Promote `t` to the front of `o`. Returns true iff the front type CHANGED.
bool touchSelType(ref SelTypeOrder o, SelType t) pure nothrow @safe @nogc {
    return o.touch(t);
}

/// The most-recent geometry type in `o` (used to derive `editMode`).
SelType mostRecentGeometryType(ref const SelTypeOrder o) pure nothrow @safe @nogc {
    return o.mostRecentGeometry;
}

/// The SelType corresponding to a geometry `EditMode` (the 1:1 mapping used to
/// keep editMode ↔ SelType in lockstep). `Item` has no EditMode counterpart.
SelType geometrySelType(EditMode m) pure nothrow @safe @nogc {
    final switch (m) {
        case EditMode.Vertices: return SelType.Vertex;
        case EditMode.Edges:    return SelType.Edge;
        case EditMode.Polygons: return SelType.Polygon;
    }
}

/// The EditMode corresponding to a geometry SelType (the inverse of
/// `geometrySelType`, restricted to Vertex/Edge/Polygon). Used by the single
/// `setEditModeFromOrder()` writer in `app.d` to recompute the materialized
/// `editMode` from `selTypeOrder.mostRecentGeometry`. Calling with `Item`
/// is a logic error (Item has no EditMode counterpart); assert(false) guards it.
EditMode geometryEditMode(SelType t) pure nothrow @safe @nogc {
    final switch (t) {
        case SelType.Vertex:  return EditMode.Vertices;
        case SelType.Edge:    return EditMode.Edges;
        case SelType.Polygon: return EditMode.Polygons;
        case SelType.Item:    assert(false); // Item has no EditMode counterpart
    }
}

/// Lowercase SINGULAR token for a SelType — the HTTP wire vocabulary
/// (vertex/edge/polygon/item), matching the existing geometry-payload spelling.
string selTypeToken(SelType t) pure nothrow @safe @nogc {
    final switch (t) {
        case SelType.Vertex:  return "vertex";
        case SelType.Edge:    return "edge";
        case SelType.Polygon: return "polygon";
        case SelType.Item:    return "item";
    }
}

// ---------------------------------------------------------------------------
// In-module unit tests — pure data contracts only (front-promotion, geometry
// recall when Item is current). No app.d wiring, no GL/UI.
// ---------------------------------------------------------------------------

// Default ordering: Vertex is current; the geometry types lead, Item trails.
unittest {
    SelTypeOrder o;
    assert(o.current == SelType.Vertex, "boots in Vertex (current type)");
    assert(currentSelType(o) == SelType.Vertex);
    assert(o.order == [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item]);
    assert(mostRecentGeometryType(o) == SelType.Vertex);
}

// touch promotes to front, preserving the relative order of the rest, and
// reports whether the front flipped.
unittest {
    SelTypeOrder o;
    // Promote Polygon: it jumps to front; Vertex/Edge shift back one; Item stays.
    assert(touchSelType(o, SelType.Polygon), "Polygon was not current → flip");
    assert(o.current == SelType.Polygon);
    assert(o.order == [SelType.Polygon, SelType.Vertex, SelType.Edge, SelType.Item],
        "promote shifts the displaced entries back by one, preserving order");

    // Re-touching the current type is a no-op and reports no flip.
    assert(!touchSelType(o, SelType.Polygon), "already current → no flip");
    assert(o.order == [SelType.Polygon, SelType.Vertex, SelType.Edge, SelType.Item]);

    // Promote Edge from the middle.
    assert(touchSelType(o, SelType.Edge));
    assert(o.current == SelType.Edge);
    assert(o.order == [SelType.Edge, SelType.Polygon, SelType.Vertex, SelType.Item]);
}

// Geometry-type recall under a (hypothetical) current Item: the most-recent
// geometry type persists, so editMode stays defined while Item is current.
unittest {
    SelTypeOrder o;
    // Make Polygon the most-recent geometry type, then go to Item.
    touchSelType(o, SelType.Polygon);
    assert(touchSelType(o, SelType.Item), "Item was not current → flip");
    assert(o.current == SelType.Item, "Item is now overall-current");
    // The most-recent GEOMETRY type is still Polygon (skips Item at the front).
    assert(mostRecentGeometryType(o) == SelType.Polygon,
        "geometry mode persists under Item");

    // Touch Item again: no flip, geometry recall unchanged.
    assert(!touchSelType(o, SelType.Item));
    assert(mostRecentGeometryType(o) == SelType.Polygon);

    // Dropping back to a geometry type makes it current again.
    assert(touchSelType(o, SelType.Vertex));
    assert(o.current == SelType.Vertex);
    assert(mostRecentGeometryType(o) == SelType.Vertex);
}

// isGeometryType classifies the four types.
unittest {
    assert(isGeometryType(SelType.Vertex));
    assert(isGeometryType(SelType.Edge));
    assert(isGeometryType(SelType.Polygon));
    assert(!isGeometryType(SelType.Item));
}

// SelMode token parse round-trips the four select operations; unknown throws.
unittest {
    import std.exception : assertThrown;
    assert(selModeFromToken("set")    == SelMode.Set);
    assert(selModeFromToken("add")    == SelMode.Add);
    assert(selModeFromToken("remove") == SelMode.Remove);
    assert(selModeFromToken("toggle") == SelMode.Toggle);
    assertThrown(selModeFromToken("bogus"));
}

// geometrySelType is the 1:1 EditMode↔SelType mapping + token spellings.
unittest {
    assert(geometrySelType(EditMode.Vertices) == SelType.Vertex);
    assert(geometrySelType(EditMode.Edges)    == SelType.Edge);
    assert(geometrySelType(EditMode.Polygons) == SelType.Polygon);
    assert(selTypeToken(SelType.Vertex)  == "vertex");
    assert(selTypeToken(SelType.Edge)    == "edge");
    assert(selTypeToken(SelType.Polygon) == "polygon");
    assert(selTypeToken(SelType.Item)    == "item");
}

// geometryEditMode is the inverse of geometrySelType over the geometry types.
unittest {
    assert(geometryEditMode(SelType.Vertex)  == EditMode.Vertices);
    assert(geometryEditMode(SelType.Edge)    == EditMode.Edges);
    assert(geometryEditMode(SelType.Polygon) == EditMode.Polygons);
    // Round-trip: geometryEditMode(geometrySelType(m)) == m for all geometry modes.
    assert(geometryEditMode(geometrySelType(EditMode.Vertices)) == EditMode.Vertices);
    assert(geometryEditMode(geometrySelType(EditMode.Edges))    == EditMode.Edges);
    assert(geometryEditMode(geometrySelType(EditMode.Polygons)) == EditMode.Polygons);
}
