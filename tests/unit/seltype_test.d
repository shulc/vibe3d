// Module unittests for `seltype`, moved verbatim out of source/seltype.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.seltype_test;

import editmode : EditMode;
import seltype;

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

// The candidate-set query (task 0655). THE ONE READING that matters is the
// simultaneous pair: at a single instant, the item-inclusive set and the
// component-only set must give DIFFERENT answers. A single call proves nothing
// — an implementation that ignores `candidates` entirely and returns `order[0]`
// passes any item-inclusive assertion on its own, and one that ignores the
// ordering and returns `candidates[0]` passes any component-only assertion on
// its own. Only the pair refutes both.
unittest {
    SelTypeOrder o;
    touchSelType(o, SelType.Polygon);   // most-recent geometry := Polygon
    touchSelType(o, SelType.Item);      // …then Item goes to the front
    assert(o.order == [SelType.Item, SelType.Polygon, SelType.Vertex, SelType.Edge]);

    // The pair, at one instant.
    assert(viewportPickType(o) == SelType.Item,
        "the item-inclusive candidate set must answer Item");
    assert(geometryPickType(o) == SelType.Polygon,
        "the component-only set must answer the most-recent GEOMETRY type");

    // Walking the CANDIDATE array instead of the ordering is the plausible
    // wrong implementation: it would answer Vertex here (the first entry of
    // `viewportPickTypes` that is present in the ordering) instead of Item.
    assert(viewportPickType(o) != SelType.Vertex);

    // `editMode`'s derivation is literally this query with the component-only
    // set — so the two cannot drift into two rules.
    assert(mostRecentGeometryType(o) == geometryPickType(o));

    // Back to a geometry type: both sets now agree, which is the ordinary case
    // and the reason a single-set assertion is worth nothing.
    touchSelType(o, SelType.Edge);
    assert(viewportPickType(o) == SelType.Edge);
    assert(geometryPickType(o) == SelType.Edge);
}

// `resolve` honours an arbitrary caller set, not just the two named ones — a
// single-element set answers that element whatever the ordering says, because
// the walk stops at the first ordering entry the set contains.
unittest {
    SelTypeOrder o;                      // [Vertex, Edge, Polygon, Item]
    assert(o.resolve([SelType.Polygon]) == SelType.Polygon);
    assert(o.resolve([SelType.Item, SelType.Edge]) == SelType.Edge,
        "Edge is ahead of Item in this ordering, so Edge wins");
    touchSelType(o, SelType.Item);       // [Item, Vertex, Edge, Polygon]
    assert(o.resolve([SelType.Item, SelType.Edge]) == SelType.Item,
        "the same candidate set answers differently once Item is promoted — "
        ~ "the ordering is what decides, not the set's own order");
    // Empty set: no defined answer, falls back to the front rather than
    // inventing a type or reading out of bounds.
    assert(o.resolve([]) == o.current);
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
