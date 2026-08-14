// Module unittests for `change_bus`, moved verbatim out of source/change_bus.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.change_bus_test;

public import mesh_edit_delta : MeshEditScope;
import seltype : SelType;
import change_bus;

// Accumulate-coalesce: multiple noteChange-style ORs combine, and flush sees
// the union once.
unittest {
    // The OR-accumulate happens on the Mesh; here we just verify the bus
    // delivers a pre-combined flag word once with all bits set.
    ChangeBus bus;
    uint seen = 0;
    int  calls = 0;
    bus.onMeshChanged((uint f) { seen |= f; ++calls; });

    const combined = MeshEditScope.Position | MeshEditScope.Points
                   | MeshEditScope.Polygons;
    bus.flush(combined, 0, 0);

    assert(calls == 1, "one delivery per flush");
    assert(seen == combined, "all coalesced bits delivered");
    assert(bus.flushCount == 1);
    assert(bus.lastFlushFlags == combined);
    assert(bus.totalPosition == 1 && bus.totalPoints == 1
        && bus.totalPolygons == 1);
}

// flush delivers once and (since pending state lives on the Mesh, not the bus)
// a subsequent zero-arg flush is a no-op that does not re-deliver.
unittest {
    ChangeBus bus;
    int calls = 0;
    bus.onMeshChanged((uint) { ++calls; });

    bus.flush(MeshEditScope.Marks, 0, 0);
    assert(calls == 1);
    assert(bus.totalMarks == 1);

    // Second flush with nothing pending: no delivery.
    bus.flush(0, 0, 0);
    assert(calls == 1, "zero-arg flush must not re-deliver");
    assert(bus.flushCount == 1, "no-op flush does not bump the counter");
}

// flush with both args zero is a complete no-op: no counter bump, no call.
unittest {
    ChangeBus bus;
    int meshCalls = 0, selCalls = 0;
    bus.onMeshChanged((uint) { ++meshCalls; });
    bus.onSelectionChanged((uint) { ++selCalls; });

    bus.flush(0, 0, 0);

    assert(meshCalls == 0 && selCalls == 0);
    assert(bus.flushCount == 0);
    assert(bus.lastFlushFlags == 0 && bus.lastSelDomains == 0);
}

// Selection domains are delivered to selSubs after meshSubs, with per-domain
// counters maintained.
unittest {
    ChangeBus bus;
    uint meshSeen = 0, selSeen = 0;
    int order = 0, meshOrder = -1, selOrder = -1;
    bus.onMeshChanged((uint f) { meshSeen = f; meshOrder = order++; });
    bus.onSelectionChanged((uint d) { selSeen = d; selOrder = order++; });

    bus.flush(MeshEditScope.Marks, SelDomain.Vertex | SelDomain.Face, 0);

    assert(meshSeen == MeshEditScope.Marks);
    assert(selSeen == (SelDomain.Vertex | SelDomain.Face));
    assert(meshOrder == 0 && selOrder == 1, "meshChanged fires before selChanged");
    assert(bus.totalSelVertex == 1 && bus.totalSelFace == 1);
    assert(bus.totalSelEdge == 0);
}

// Reentrancy: a subscriber that re-enters flush trips the guard assert.
unittest {
    import core.exception : AssertError;

    ChangeBus bus;
    bool tripped = false;
    bus.onMeshChanged((uint) {
        try {
            bus.flush(MeshEditScope.Position, 0, 0); // illegal re-entry
        } catch (AssertError) {
            tripped = true;
        }
    });

    bus.flush(MeshEditScope.Marks, 0, 0);
    assert(tripped, "re-entering flush from a subscriber must assert");
}

// SelDomain.Item (#4 Stage 2a) delivers on the SELECTION channel like the
// geometry domains and bumps its own running total. An Item-only sel flush
// reaches selSubs and ticks totalSelItem (not the geometry totals).
unittest {
    ChangeBus bus;
    uint selSeen = 0;
    int  selCalls = 0;
    bus.onSelectionChanged((uint d) { selSeen = d; ++selCalls; });

    bus.flush(0, SelDomain.Item, 0);

    assert(selCalls == 1, "item selection delivers on the selection channel");
    assert(selSeen == SelDomain.Item, "carries the Item domain bit");
    assert(bus.totalSelItem == 1, "totalSelItem ticks");
    assert(bus.totalSelVertex == 0 && bus.totalSelEdge == 0 && bus.totalSelFace == 0,
        "geometry domain totals untouched by an item-only selection");
    assert(bus.lastSelDomains == SelDomain.Item);
}

// Item coalesces with geometry domains in a single selection word.
unittest {
    ChangeBus bus;
    uint selSeen = 0;
    bus.onSelectionChanged((uint d) { selSeen = d; });
    bus.flush(0, SelDomain.Vertex | SelDomain.Item, 0);
    assert(selSeen == (SelDomain.Vertex | SelDomain.Item));
    assert(bus.totalSelVertex == 1 && bus.totalSelItem == 1);
}

// noteItemSelectionChange OR-accumulates into the module-level pending word and
// is pure accumulate (no delivery). Drains read-and-zero like the flush site.
unittest {
    pendingItemSelDomain = 0;
    noteItemSelectionChange();                  // default SelDomain.Item
    noteItemSelectionChange(SelDomain.Item);    // coalesces
    assert(pendingItemSelDomain == SelDomain.Item, "noteItemSelectionChange coalesces");

    uint drained = pendingItemSelDomain;
    pendingItemSelDomain = 0;
    assert(drained == SelDomain.Item);
    assert(pendingItemSelDomain == 0, "drain zeroes the pending word");
}

// Accumulate-coalesce: several layer kinds OR'd into one flush deliver once with
// every bit set, bumping each per-kind counter exactly once.
unittest {
    ChangeBus bus;
    uint seen = 0;
    int  calls = 0;
    bus.onLayerChanged((uint k) { seen |= k; ++calls; });

    const combined = LayerChange.Added | LayerChange.ActiveChanged;
    bus.flush(0, 0, combined);

    assert(calls == 1, "one delivery per flush");
    assert(seen == combined, "all coalesced layer bits delivered");
    assert(bus.flushCount == 1);
    assert(bus.lastLayerKinds == combined);
    assert(bus.totalLayerAdded == 1 && bus.totalLayerActive == 1);
    assert(bus.totalLayerRemoved == 0 && bus.totalLayerReordered == 0);
}

// A layer-only flush delivers once; a subsequent zero flush is a no-op.
unittest {
    ChangeBus bus;
    int calls = 0;
    bus.onLayerChanged((uint) { ++calls; });

    bus.flush(0, 0, LayerChange.Reordered);
    assert(calls == 1);
    assert(bus.totalLayerReordered == 1);

    bus.flush(0, 0, 0);
    assert(calls == 1, "zero-arg flush must not re-deliver");
    assert(bus.flushCount == 1, "no-op flush does not bump the counter");
}

// Layer kinds are delivered to layerSubs AFTER meshSubs and selSubs, with the
// per-kind counters maintained. (meshChanged → selectionChanged → layerChanged.)
unittest {
    ChangeBus bus;
    uint meshSeen = 0, selSeen = 0, layerSeen = 0;
    int order = 0, meshOrder = -1, selOrder = -1, layerOrder = -1;
    bus.onMeshChanged((uint f) { meshSeen = f; meshOrder = order++; });
    bus.onSelectionChanged((uint d) { selSeen = d; selOrder = order++; });
    bus.onLayerChanged((uint k) { layerSeen = k; layerOrder = order++; });

    bus.flush(MeshEditScope.Marks, SelDomain.Vertex,
              LayerChange.Renamed | LayerChange.ActiveChanged);

    assert(meshSeen == MeshEditScope.Marks);
    assert(selSeen == SelDomain.Vertex);
    assert(layerSeen == (LayerChange.Renamed | LayerChange.ActiveChanged));
    assert(meshOrder == 0 && selOrder == 1 && layerOrder == 2,
        "layerChanged fires after meshChanged + selectionChanged");
    assert(bus.totalLayerRenamed == 1 && bus.totalLayerActive == 1);
}

// A layer-only delivery (mesh + sel both zero) is NOT swallowed by the early-out
// — the three-word zero check must consider layerKinds.
unittest {
    ChangeBus bus;
    int meshCalls = 0, layerCalls = 0;
    bus.onMeshChanged((uint) { ++meshCalls; });
    bus.onLayerChanged((uint) { ++layerCalls; });

    bus.flush(0, 0, LayerChange.VisibilityChanged);

    assert(meshCalls == 0, "no mesh delivery when meshFlags==0");
    assert(layerCalls == 1, "layer delivery must not be swallowed by the early-out");
    assert(bus.flushCount == 1);
    assert(bus.totalLayerVisible == 1);
}

// Reentrancy: a layer subscriber that re-enters flush trips the same guard.
unittest {
    import core.exception : AssertError;

    ChangeBus bus;
    bool tripped = false;
    bus.onLayerChanged((uint) {
        try {
            bus.flush(0, 0, LayerChange.Added); // illegal re-entry
        } catch (AssertError) {
            tripped = true;
        }
    });

    bus.flush(0, 0, LayerChange.Removed);
    assert(tripped, "re-entering flush from a layer subscriber must assert");
}

// A current-type-only flush (mesh/sel/layer all zero) is NOT swallowed by the
// early-out, delivers the new SelType once, and bumps the counter.
unittest {
    ChangeBus bus;
    int  meshCalls = 0, typeCalls = 0;
    SelType seen = SelType.Vertex;
    bus.onMeshChanged((uint) { ++meshCalls; });
    bus.onCurrentTypeChanged((SelType t) { seen = t; ++typeCalls; });

    bus.flush(0, 0, 0, true, SelType.Polygon);

    assert(meshCalls == 0, "no mesh delivery when meshFlags==0");
    assert(typeCalls == 1, "current-type delivery must not be swallowed by the early-out");
    assert(seen == SelType.Polygon, "delivers the newly-current type");
    assert(bus.flushCount == 1);
    assert(bus.currentTypeChanged == 1, "currentTypeChanged counter ticks");
    assert(bus.lastCurrentType == SelType.Polygon);
}

// `typeChanged == false` carries NO current-type flip even with a non-default
// newType — the counter must not tick (it would otherwise false-positive every
// frame that does a mesh/sel edit).
unittest {
    ChangeBus bus;
    int typeCalls = 0;
    bus.onCurrentTypeChanged((SelType) { ++typeCalls; });

    bus.flush(MeshEditScope.Marks, 0, 0);              // 3-arg: typeChanged defaults false
    bus.flush(MeshEditScope.Marks, 0, 0, false, SelType.Edge); // explicit false
    assert(typeCalls == 0, "no current-type delivery when typeChanged is false");
    assert(bus.currentTypeChanged == 0, "counter does not tick without a flip");
}

// Current-type is delivered LAST, after mesh/sel/layer.
unittest {
    ChangeBus bus;
    int order = 0, meshOrder = -1, selOrder = -1, layerOrder = -1, typeOrder = -1;
    bus.onMeshChanged((uint) { meshOrder = order++; });
    bus.onSelectionChanged((uint) { selOrder = order++; });
    bus.onLayerChanged((uint) { layerOrder = order++; });
    bus.onCurrentTypeChanged((SelType) { typeOrder = order++; });

    bus.flush(MeshEditScope.Marks, SelDomain.Vertex,
              LayerChange.ActiveChanged, true, SelType.Edge);

    assert(meshOrder == 0 && selOrder == 1 && layerOrder == 2 && typeOrder == 3,
        "delivery order: mesh → sel → layer → currentType");
}

// A current-type flip alone (no mesh/sel) ticks currentTypeChanged but NOT the
// selection or mesh counters — a mode switch is not selection content.
unittest {
    ChangeBus bus;
    bus.flush(0, 0, 0, true, SelType.Edge);
    assert(bus.currentTypeChanged == 1);
    assert(bus.totalSelVertex == 0 && bus.totalSelEdge == 0 && bus.totalSelFace == 0,
        "a type flip publishes NO selection domain");
    assert(bus.totalPosition == 0 && bus.totalMarks == 0,
        "a type flip publishes NO mesh change");
}

// noteCurrentType records the LAST flip into the module-level pending state and
// is pure accumulate (no delivery). Drains read-and-zero like the flush site.
unittest {
    pendingCurrentTypeSet = false;
    pendingCurrentType    = SelType.Vertex;
    noteCurrentType(SelType.Edge);
    noteCurrentType(SelType.Polygon);             // coalesce to the LAST flip
    assert(pendingCurrentTypeSet, "a flip is pending");
    assert(pendingCurrentType == SelType.Polygon, "coalesces to the last type");

    // Drain semantics mirror the app.d flush site.
    bool drainedSet = pendingCurrentTypeSet;
    SelType drainedType = pendingCurrentType;
    pendingCurrentTypeSet = false;
    assert(drainedSet && drainedType == SelType.Polygon);
    assert(!pendingCurrentTypeSet, "drain clears the pending flag");
}

// noteLayerChange OR-accumulates into the module-level pending word and is pure
// accumulate (no delivery). Drains read-and-zero like the app.d flush site does.
unittest {
    pendingLayerChanges = 0;
    noteLayerChange(LayerChange.Added);
    noteLayerChange(LayerChange.ActiveChanged);
    assert(pendingLayerChanges
        == (LayerChange.Added | LayerChange.ActiveChanged),
        "noteLayerChange coalesces kinds");

    // Drain semantics mirror the app.d flush site.
    uint drained = pendingLayerChanges;
    pendingLayerChanges = 0;
    assert(drained == (LayerChange.Added | LayerChange.ActiveChanged));
    assert(pendingLayerChanges == 0, "drain zeroes the pending word");
}
