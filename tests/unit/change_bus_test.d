// Module unittests for `change_bus`, moved verbatim out of source/change_bus.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.change_bus_test;

public import mesh_edit_delta : MeshEditScope;
import seltype : SelType;
import change_bus;

// TASK 1906 STAGE 3 — WHICH CHANNEL A BLOCK DRIVES CHANGED, AND THE BLOCKS WERE
// RE-READ RATHER THAN PATCHED. `ChangeBus.flush` no longer carries the mesh
// channel at all: since stage 3 it drains only the three DOCUMENT-level
// accumulators (layer kinds, the Item selection domain, the current-type flip),
// and every mesh/geometry-selection change is delivered by `deliverMesh` at the
// edit boundary. So a block that used to pass mesh flags to `flush` was not
// testing "the flush"; it was testing the MESH CHANNEL through the only entry
// point that then existed, and it now drives `deliverMesh`. `flushCount` and
// `lastSelDomains` keep their names and mean the document-level channel;
// `lastFlushFlags` is gone rather than left reading zero.
enum size_t kSubj = 0xB0;   // a stand-in subject address; deliverMesh needs one

// Accumulate-coalesce: multiple noteChange-style ORs combine, and flush sees
// the union once.
unittest {
    // The OR-accumulate happens on the Mesh; here we just verify the bus
    // delivers a pre-combined flag word once with all bits set.
    ChangeBus bus;
    uint seen = 0;
    int  calls = 0;
    bus.onMeshChanged((size_t, uint f) { seen |= f; ++calls; });

    const combined = MeshEditScope.Position | MeshEditScope.Points
                   | MeshEditScope.Polygons;
    bus.deliverMesh(kSubj, combined, 0);

    assert(calls == 1, "one delivery per deliverMesh");
    assert(seen == combined, "all coalesced bits delivered");
    assert(bus.deliveryCount == 1);
    assert(bus.lastDeliveryFlags == combined);
    assert(bus.totalPosition == 1 && bus.totalPoints == 1
        && bus.totalPolygons == 1);
}

// flush delivers once and (since pending state lives on the Mesh, not the bus)
// a subsequent zero-arg flush is a no-op that does not re-deliver.
unittest {
    ChangeBus bus;
    int calls = 0;
    bus.onMeshChanged((size_t, uint) { ++calls; });

    bus.deliverMesh(kSubj, MeshEditScope.Marks, 0);
    assert(calls == 1);
    assert(bus.totalMarks == 1);

    // Second delivery with nothing pending: no delivery.
    bus.deliverMesh(kSubj, 0, 0);
    assert(calls == 1, "an empty delivery must not re-deliver");
    assert(bus.deliveryCount == 1, "no-op delivery does not bump the counter");
}

// Task 1931, stage 0 — the guard `if (selDomains != 0)` immediately before
// `foreach (dg; selSubs) dg(selDomains);` in `deliverMesh` has no cell above
// it. The block just above registers a mesh subscriber only; the block below
// (`flush with both args zero`) drives `deliverMesh(kSubj, 0, 0)`, which never
// reaches this guard at all — it returns at the earlier
// `meshFlags == 0 && selDomains == 0` check. This is the first cell to
// register BOTH subscriber kinds and prove a mesh-only delivery does not also
// ring the selection channel.
unittest {
    ChangeBus bus;
    int meshCalls = 0, selCalls = 0;
    bus.onMeshChanged((size_t, uint) { ++meshCalls; });
    bus.onSelectionChanged((uint) { ++selCalls; });

    bus.deliverMesh(kSubj, MeshEditScope.Marks, 0);

    assert(meshCalls == 1, "the mesh subscriber must still fire");
    assert(selCalls == 0,
        "a mesh-only delivery must not ring the selection channel — this is "
      ~ "the `if (selDomains != 0)` guard at change_bus.d, and nothing above "
      ~ "this block registered both subscriber kinds at once to see it fail");
}

// flush with both args zero is a complete no-op: no counter bump, no call.
unittest {
    ChangeBus bus;
    int meshCalls = 0, selCalls = 0;
    bus.onMeshChanged((size_t, uint) { ++meshCalls; });
    bus.onSelectionChanged((uint) { ++selCalls; });

    bus.flush(0, 0);
    bus.deliverMesh(kSubj, 0, 0);

    assert(meshCalls == 0 && selCalls == 0);
    assert(bus.flushCount == 0 && bus.deliveryCount == 0);
    assert(bus.lastSelDomains == 0);
}

// Selection domains are delivered to selSubs after meshSubs, with per-domain
// counters maintained.
unittest {
    ChangeBus bus;
    uint meshSeen = 0, selSeen = 0;
    int order = 0, meshOrder = -1, selOrder = -1;
    bus.onMeshChanged((size_t, uint f) { meshSeen = f; meshOrder = order++; });
    bus.onSelectionChanged((uint d) { selSeen = d; selOrder = order++; });

    bus.deliverMesh(kSubj, MeshEditScope.Marks,
                    SelDomain.Vertex | SelDomain.Face);

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
    bus.onMeshChanged((size_t, uint) {
        try {
            bus.deliverMesh(kSubj, MeshEditScope.Position, 0); // illegal re-entry
        } catch (AssertError) {
            tripped = true;
        }
    });

    bus.deliverMesh(kSubj, MeshEditScope.Marks, 0);
    assert(tripped, "re-entering delivery from a subscriber must assert");
}

// SelDomain.Item (#4 Stage 2a) delivers on the SELECTION channel like the
// geometry domains and bumps its own running total. An Item-only sel flush
// reaches selSubs and ticks totalSelItem (not the geometry totals).
unittest {
    ChangeBus bus;
    uint selSeen = 0;
    int  selCalls = 0;
    bus.onSelectionChanged((uint d) { selSeen = d; ++selCalls; });

    bus.flush(SelDomain.Item, 0);

    assert(selCalls == 1, "item selection delivers on the selection channel");
    assert(selSeen == SelDomain.Item, "carries the Item domain bit");
    assert(bus.totalSelItem == 1, "totalSelItem ticks");
    assert(bus.totalSelVertex == 0 && bus.totalSelEdge == 0 && bus.totalSelFace == 0,
        "geometry domain totals untouched by an item-only selection");
    assert(bus.lastSelDomains == SelDomain.Item);
}

// TASK 1906 STAGE 3 — the block that used to assert "Item coalesces with the
// geometry domains in a single selection word" asserts the law that REPLACED
// it: the two now arrive on the same channel from DIFFERENT sites, because
// Item has no owning `Mesh` to hang an edit boundary on and the geometry
// domains do. Both still reach `selSubs`, and each still ticks only its own
// total — that is what makes them one channel rather than two.
unittest {
    ChangeBus bus;
    uint[] selSeen;
    bus.onSelectionChanged((uint d) { selSeen ~= d; });

    bus.deliverMesh(kSubj, MeshEditScope.Marks, SelDomain.Vertex);
    bus.flush(SelDomain.Item, 0);

    assert(selSeen == [cast(uint)SelDomain.Vertex, cast(uint)SelDomain.Item],
        "both domains reach the SAME subscriber, in the order they were made");
    assert(bus.totalSelVertex == 1 && bus.totalSelItem == 1,
        "each site ticks only its own total");
    assert(bus.lastSelDomains == SelDomain.Item,
        "`lastSelDomains` is the FLUSH's word, so it carries Item only");
    assert(bus.lastDeliverySelDomains == SelDomain.Vertex,
        "the delivery's word is the geometry half");
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
    bus.flush(0, combined);

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

    bus.flush(0, LayerChange.Reordered);
    assert(calls == 1);
    assert(bus.totalLayerReordered == 1);

    bus.flush(0, 0);
    assert(calls == 1, "zero-arg flush must not re-deliver");
    assert(bus.flushCount == 1, "no-op flush does not bump the counter");
}

// Layer kinds are delivered to layerSubs AFTER meshSubs and selSubs, with the
// per-kind counters maintained. (meshChanged → selectionChanged → layerChanged.)
unittest {
    ChangeBus bus;
    uint meshSeen = 0, selSeen = 0, layerSeen = 0;
    int order = 0, meshOrder = -1, selOrder = -1, layerOrder = -1;
    bus.onMeshChanged((size_t, uint f) { meshSeen = f; meshOrder = order++; });
    bus.onSelectionChanged((uint d) { selSeen = d; selOrder = order++; });
    bus.onLayerChanged((uint k) { layerSeen = k; layerOrder = order++; });

    // TASK 1906 STAGE 3 — two calls, because the mesh channel left the flush.
    // The ORDER claim survives intact and is still worth pinning: a subscriber
    // reacting to a layer event must already have seen this edit's mesh and
    // selection invalidation.
    bus.deliverMesh(kSubj, MeshEditScope.Marks, SelDomain.Vertex);
    bus.flush(0, LayerChange.Renamed | LayerChange.ActiveChanged);

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
    bus.onMeshChanged((size_t, uint) { ++meshCalls; });
    bus.onLayerChanged((uint) { ++layerCalls; });

    bus.flush(0, LayerChange.VisibilityChanged);

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
            bus.flush(0, LayerChange.Added); // illegal re-entry
        } catch (AssertError) {
            tripped = true;
        }
    });

    bus.flush(0, LayerChange.Removed);
    assert(tripped, "re-entering flush from a layer subscriber must assert");
}

// A current-type-only flush (mesh/sel/layer all zero) is NOT swallowed by the
// early-out, delivers the new SelType once, and bumps the counter.
unittest {
    // TASK 1906 STAGE 3 — the current-type SUBSCRIBER PORT was deleted (it had
    // no listener and no consumer of the delegate), so the observable is the
    // COUNTER pair, which `/api/changes` reports and two suite tests read. The
    // claim is unchanged: a type-only flush must not be swallowed by the
    // early-out.
    ChangeBus bus;
    int meshCalls = 0;
    bus.onMeshChanged((size_t, uint) { ++meshCalls; });

    bus.flush(0, 0, true, SelType.Polygon);

    assert(meshCalls == 0, "no mesh delivery when meshFlags==0");
    assert(bus.flushCount == 1,
        "current-type delivery must not be swallowed by the early-out");
    assert(bus.currentTypeChanged == 1, "currentTypeChanged counter ticks");
    assert(bus.lastCurrentType == SelType.Polygon, "records the newly-current type");
}

// `typeChanged == false` carries NO current-type flip even with a non-default
// newType — the counter must not tick (it would otherwise false-positive every
// frame that does a mesh/sel edit).
unittest {
    ChangeBus bus;

    bus.flush(SelDomain.Item, 0);              // 2-arg: typeChanged defaults false
    bus.flush(SelDomain.Item, 0, false, SelType.Edge); // explicit false
    assert(bus.currentTypeChanged == 0, "counter does not tick without a flip");
    assert(bus.flushCount == 2, "…and the flushes themselves still happened, "
      ~ "so the assert above is not vacuous");
}

// Delivery order across the three channels that HAVE subscribers.
//
// TASK 1906 STAGE 3 — this block used to end "→ currentType", and that fourth
// term is gone with the current-type subscriber port. Said plainly rather than
// quietly dropped: the port had no listener, so the only thing that could ever
// observe its position in the order was this test. What remains is the order
// three real subscriber lists are delivered in.
unittest {
    ChangeBus bus;
    int order = 0, meshOrder = -1, selOrder = -1, layerOrder = -1;
    bus.onMeshChanged((size_t, uint) { meshOrder = order++; });
    bus.onSelectionChanged((uint) { selOrder = order++; });
    bus.onLayerChanged((uint) { layerOrder = order++; });

    // Two sites since stage 3 (see the block above), one order.
    bus.deliverMesh(kSubj, MeshEditScope.Marks, SelDomain.Vertex);
    bus.flush(0, LayerChange.ActiveChanged, true, SelType.Edge);

    assert(meshOrder == 0 && selOrder == 1 && layerOrder == 2,
        "delivery order: mesh → sel → layer");
    assert(bus.currentTypeChanged == 1,
        "the flip still counts — the channel lost its port, not its counter");
}

// A current-type flip alone (no mesh/sel) ticks currentTypeChanged but NOT the
// selection or mesh counters — a mode switch is not selection content.
unittest {
    ChangeBus bus;
    bus.flush(0, 0, true, SelType.Edge);
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

// ---------------------------------------------------------------------------
// Task 1073 (review B1) — the MAP channel and the unsaved-changes counter.
//
// The bug: every morph write (the routed drag, mesh.morph.set / .clear /
// .create / .remove / .rename) published ONLY `MeshEditScope.Maps`, and
// `docRevision()` — the counter `io.doc_state` diffs to decide "dirty" —
// summed five classes that did not include it. A whole morph session
// therefore left the document reading CLEAN: no asterisk in the title, and
// Quit closed WITHOUT the save prompt. Work was lost silently.
//
// The second half is the one that makes this a pair of assertions rather than
// one: `mesh.morph.select` also has to publish, because binding a target
// changes what the viewport DRAWS — but it must NOT dirty a clean document,
// because it changes nothing a `.v3d` would carry. That is what the separate
// `MapsDisplay` bit buys, and asserting only the first half would go green on
// the naive fix of routing the target change through `Maps` as well.
//
// Mutations, both run:
//   * drop `totalMaps` from `docRevision()`      -> the first block reddens.
//   * bump `totalMaps` on `MapsDisplay` too (or publish `Maps` from
//     `MorphSelect.publishTargetChange`)         -> the second block reddens.
unittest {
    {
        ChangeBus bus;
        const before = bus.docRevision();
        bus.deliverMesh(kSubj, MeshEditScope.Maps, 0);
        assert(bus.totalMaps == 1, "a Maps delivery is counted");
        assert(bus.docRevision() == before + 1,
            "a per-element MAP write is PERSISTED document content (.v3d "
          ~ "meshMaps / edgeMaps, .lwo VMAPs), so it must move docRevision -- "
          ~ "without this a whole morph session leaves the document reading "
          ~ "clean and Quit closes with no save prompt");
    }
    {
        ChangeBus bus;
        const before = bus.docRevision();
        bus.deliverMesh(kSubj, MeshEditScope.MapsDisplay, 0);
        assert(bus.totalMapsDisplay == 1,
            "the display-only route is still DELIVERED (the GPU must "
          ~ "re-upload) and still observable");
        assert(bus.totalMaps == 0,
            "...but it is not a map WRITE");
        assert(bus.docRevision() == before,
            "binding a morph target to look at it is not an edit -- it must "
          ~ "not dirty a clean, freshly-opened document");
    }
}

// ===========================================================================
// TASK 1906 stage 0 — SYNCHRONOUS DELIVERY AT THE EDIT BOUNDARY.
//
// These blocks drive the GLOBAL `changeBus`, not a local one, because that is
// where `Mesh.deliverPending()` delivers — a synchronous delivery is made by
// the mesh, not by the caller, so there is no seam at which a local bus could
// be substituted. Every assertion is therefore a DELTA on `deliveryCount`, and
// the two blocks that register a listener restore `changeBus.meshSubs` on the
// way out (v1 has no unsubscribe; restoring the slice is the equivalent, and
// it keeps a leaked listener from firing in every later module of the shared
// unittest binary).
//
// Mutations these are the red for (plan §5, stage 0 rows):
//   * `Mesh.deliverPending()` → early `return` before `changeBus.deliverMesh`
//     ⇒ block (a) reddens.
//   * delete `++g_deliveryDepth` in `mesh.beginDeliveryBatchGlobal`
//     ⇒ block (b) reddens on its FIRST assert (8 deliveries, not 0).
//   * a listener that publishes ⇒ blocks (d1)/(d2) redden.
// ===========================================================================

// (a) ONE delivery per commitChange, outside any batch.
unittest {
    import mesh : Mesh, makeCube;

    Mesh m = makeCube();
    m.syncSelection();

    const before = changeBus.deliveryCount;
    m.commitChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before + 1,
        "one commitChange at delivery depth 0 must deliver exactly once");
    assert(changeBus.lastDeliverySubject == cast(size_t)&m,
        "the delivery names its SUBJECT: every consumer in this tree already "
      ~ "keys its cache on the mesh address, so the payload speaks that "
      ~ "language (MeshCacheKey.addr, BvhPick._meshAddr, CandidateGrid.meshAddr)");
    assert((changeBus.lastDeliveryFlags & MeshEditScope.Position) != 0,
        "the delivery carries the class that was committed");

    m.commitChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before + 2,
        "a second commit is a second delivery — delivery is per EDIT, not "
      ~ "per frame");
}

// (b) N commits inside ONE delivery batch = ONE delivery, at the close.
unittest {
    import mesh : Mesh, makeCube;

    Mesh m = makeCube();
    m.syncSelection();

    const before = changeBus.deliveryCount;
    m.beginDeliveryBatch();
    foreach (i; 0 .. 8)
        m.commitChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before,
        "an open delivery batch must deliver NOTHING — this is what stops one "
      ~ "command that moves 8 vertices (or appends 400 faces) from firing one "
      ~ "delivery per element");
    m.endDeliveryBatch();
    assert(changeBus.deliveryCount == before + 1,
        "the batch close delivers exactly once");
    assert((changeBus.lastDeliveryFlags & MeshEditScope.Position) != 0,
        "the coalesced delivery carries the union of the batch's classes");
}

// (c) `noteChange` alone delivers nothing, and its flags ride the NEXT
//     delivering publisher. This is the accumulate-only contract that keeps
//     the ~30 in-loop note sites (and the version-silent mid-drag path) free.
unittest {
    import mesh : Mesh, makeCube;

    Mesh m = makeCube();
    m.syncSelection();
    m.commitChange(MeshEditScope.Marks);   // drain anything the fixture left

    const before = changeBus.deliveryCount;
    m.noteChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before,
        "noteChange accumulates and does NOT deliver");

    m.commitChange(MeshEditScope.Material);
    assert(changeBus.deliveryCount == before + 1,
        "the next delivering publisher delivers once");
    assert((changeBus.lastDeliveryFlags & MeshEditScope.Position) != 0
        && (changeBus.lastDeliveryFlags & MeshEditScope.Material) != 0,
        "...carrying BOTH the noted class and its own — a noted change is "
      ~ "deferred, never dropped");
}

// (c2) `publishChange` delivers WITHOUT bumping a version counter. This is the
//      version-silent delivering publisher the interactive transform path needs:
//      counters own STRUCTURE, the bus's Position class owns POSITION.
unittest {
    import mesh : Mesh, makeCube;

    Mesh m = makeCube();
    m.syncSelection();

    const before   = changeBus.deliveryCount;
    const mutVer   = m.mutationVersion;
    const topoVer  = m.topologyVersion;
    m.publishChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before + 1,
        "publishChange delivers at depth 0");
    assert(m.mutationVersion == mutVer && m.topologyVersion == topoVer,
        "...and bumps NO version counter — a mutationVersion bump here would "
      ~ "cancel an in-session falloff re-grade, which is the whole reason the "
      ~ "drag is version-silent");
}

// (d1) A listener that PUBLISHES trips the always-on contract assert. The
//      companion assert in `Mesh.noteChange` is what fires here — at the
//      offending line, one frame earlier than `deliverMesh`'s own re-entry
//      guard would.
unittest {
    import core.exception : AssertError;
    import mesh : Mesh, makeCube;

    Mesh m = makeCube();
    m.syncSelection();

    auto saved = changeBus.meshSubs;
    scope (exit) changeBus.meshSubs = saved;

    Mesh* mp = &m;
    bool tripped = false;
    // The listener's OWN re-entry stop. It is not part of the contract; it is
    // what makes the mutation drill produce a legible red instead of a crash.
    // With the guards removed, the illegal publish would deliver again, call
    // this listener again, and recurse until the stack ran out — a segfault,
    // from which no assertion message survives. With the stop, the same
    // mutation leaves `tripped` false and this block reddens by its own message.
    int depth = 0;
    // The AssertError is caught INSIDE the listener, exactly as the two
    // flush-re-entrancy blocks above do it, and that placement is load-bearing
    // rather than stylistic: `deliverMesh` is `nothrow`, and the compiler emits
    // no unwind cleanup for an `Error` passing through a nothrow function — so
    // letting the error escape the listener would skip the `scope (exit)` that
    // releases `delivering_` and latch the guard for the rest of this shared
    // unittest binary. In production that path ends the process, so it cannot
    // latch anything; only a test that catches and carries on has to care.
    changeBus.onMeshChanged((size_t, uint) {
        if (depth > 0) return;
        ++depth;
        // Illegal: a listener may write only its own dirty state.
        try { mp.commitChange(MeshEditScope.Position); }
        catch (AssertError) { tripped = true; }
        catch (Exception)   {}
        --depth;
    });

    m.commitChange(MeshEditScope.Marks);
    assert(tripped,
        "a listener that publishes a mesh change must trip the contract "
      ~ "assert — listeners are dirty-bit-only");
    assert(!changeBus.delivering,
        "the guard releases on the way out, so one violation does not wedge "
      ~ "the bus for every later publisher");
}

// (d2) A listener that RE-ENTERS delivery directly trips `deliverMesh`'s own
//      always-on guard. Separate block from (d1): druntime stops a module at
//      its first failed assert, so a shared block would hide whichever half
//      ran second.
unittest {
    import core.exception : AssertError;
    import mesh : Mesh, makeCube;

    Mesh m = makeCube();
    m.syncSelection();

    auto saved = changeBus.meshSubs;
    scope (exit) changeBus.meshSubs = saved;

    bool tripped = false;
    int  depth   = 0;   // the same re-entry stop, for the same reason as (d1)
    changeBus.onMeshChanged((size_t addr, uint f) {
        if (depth > 0) return;
        ++depth;
        // Caught inside the listener — see (d1) for why that placement is
        // required rather than incidental.
        try { changeBus.deliverMesh(addr, f, 0); }   // illegal re-entry
        catch (AssertError) { tripped = true; }
        --depth;
    });

    m.commitChange(MeshEditScope.Marks);
    assert(tripped, "re-entering deliverMesh from a listener must assert");
    assert(!changeBus.delivering, "the guard releases on the way out");
}

// (e) THE PER-CLASS TOTALS RIDE THE DELIVERY, and this block is the INVERSION
//     of what it asserted before stage 3. It used to say "no per-class total
//     moves on the delivery path", and the reason was explicit: the same
//     mutation was delivered TWICE — once here, once out of the per-frame
//     drain — so a total bumped on both paths would double `docRevision()` and
//     make a clean document read dirty after one edit. Stage 3 deleted the
//     drain, which made the delivery the ONLY path; leaving the totals on the
//     flush would have stopped `docRevision()` moving on a mesh edit at all,
//     and with it the title asterisk and the quit-save prompt.
//
//     `flushCount` still must NOT move: it counts the DOCUMENT-level channel,
//     and a mesh edit is not one. That half is unchanged and is what keeps this
//     block from passing under "just bump everything everywhere".
unittest {
    ChangeBus bus;
    const beforeRev = bus.docRevision();
    bus.deliverMesh(0xDEAD, MeshEditScope.Position | MeshEditScope.Maps,
                    SelDomain.Vertex);
    assert(bus.deliveryCount == 1, "deliverMesh counts its own deliveries");
    assert(bus.lastDeliverySubject == 0xDEAD);
    assert(bus.lastDeliverySelDomains == SelDomain.Vertex);
    assert(bus.flushCount == 0,
        "a mesh delivery is NOT a document-level flush");
    assert(bus.totalPosition == 1 && bus.totalMaps == 1
        && bus.totalSelVertex == 1,
        "every per-class total the delivery carried moves exactly once");
    assert(bus.totalSelItem == 0,
        "Item is the flush's domain and cannot arrive on this path");
    assert(bus.docRevision() == beforeRev + 2,
        "docRevision counts the two PERSISTED classes (Position, Maps) and "
      ~ "not the selection domain — a selection is not saved content");
}

// ===========================================================================
// TASK 1906 review B1 / S2 — THE DELIVERY SUBJECT FILTER.
//
// `Mesh` is a plain struct, so without a filter every instance in the process
// publishes to the live document's listeners. Measured before the fix:
// `MeshSnapshot.restore` on the bevel preview's private `cage_` delivered
// `0x3f` once per mouse-motion frame, `makeCube()` delivered 6, and
// `makeGridPlane(316)` delivered 99 856 — all of them into `app.d`'s hub,
// whose `Geometry` arm runs `syncSelection` plus a full pick-cache
// invalidation.
//
// These blocks install a rejecting `mesh.g_isDocumentMesh` and assert the
// delivery does not happen, then take it away and assert it does. Both halves
// are needed and neither is redundant: the FIRST is the fix, and the SECOND
// pins the "uninstalled ⇒ deliver" rule that keeps every other headless block
// in this file — none of which has a `Document` — from passing vacuously.
//
// Mutation (plan §Мутация, row `0-B1`): delete the
// `if (!deliverySubjectAccepted(&this)) return;` line at the top of
// `Mesh.deliverPending` ⇒ block (f) reddens on its first assert, and block (g)
// reddens on the pending-set assert.
// ===========================================================================

// (f) A mesh no `Layer` owns delivers NOTHING when the filter rejects it, and
//     delivers normally when no filter is installed.
unittest {
    import mesh : Mesh, makeCube, g_isDocumentMesh;

    Mesh scratch = makeCube();
    scratch.syncSelection();

    auto savedFilter = g_isDocumentMesh;
    scope (exit) g_isDocumentMesh = savedFilter;

    // Reject EVERYTHING — the app installs `document.ownsMesh`, and for a mesh
    // no layer owns that is what this returns.
    int asked = 0;
    g_isDocumentMesh = (const(Mesh)*) { ++asked; return false; };

    const before = changeBus.deliveryCount;
    scratch.commitChange(MeshEditScope.Position);
    // THE LAW FIRST, THE PRECONDITION SECOND, and that order is load-bearing.
    // Asserting `asked > 0` first would make it the check that reddens when
    // the filter is deleted — a precondition masking the law, which is the
    // failure shape this project pays for most. In this order the mutation
    // reddens the sentence that describes what is broken, and `asked` still
    // catches the other failure (a filter that is present but never consulted,
    // where some UNRELATED reason suppressed the delivery and this block would
    // otherwise be green over a fix that does nothing).
    assert(changeBus.deliveryCount == before,
        "a commit on a mesh no Layer owns must reach NO listener: app.d's hub "
      ~ "would OR it into meshChangedFlags and invalidate the live document's "
      ~ "pick caches from a private scratch mesh");
    assert(asked > 0,
        "the filter was never consulted — the suppression above came from "
      ~ "somewhere else, so this block proves nothing about it");

    // The uninstalled rule, on the SAME mesh, so the two arms differ in
    // nothing but the filter.
    g_isDocumentMesh = null;
    scratch.commitChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before + 1,
        "uninstalled means DELIVER — every headless unit test in this tree "
      ~ "builds a bare Mesh with no Document, so a fail-closed default would "
      ~ "make the whole delivery family pass vacuously");

    // ...and an ACCEPTING filter behaves like the uninstalled one, which is
    // what proves the previous arm measured the filter's ANSWER and not merely
    // its presence.
    g_isDocumentMesh = (const(Mesh)*) => true;
    scratch.commitChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before + 2,
        "an accepting filter delivers");
}

// (g) S2 — a rejected mesh never enters the DEFERRED set either. That set
//     outlives the call that appends to it, so a stack-local `Mesh` in it is a
//     pointer to a dead frame by the time the batch closes (measured: a second
//     delivery reading flags=0x0 and a garbage selDomains). The filter runs
//     ABOVE the depth check in `deliverPending` for exactly this reason.
unittest {
    import mesh : Mesh, makeCube, g_isDocumentMesh, deliveryPendingSetLength;

    Mesh scratch = makeCube();
    scratch.syncSelection();

    auto savedFilter = g_isDocumentMesh;
    scope (exit) g_isDocumentMesh = savedFilter;
    g_isDocumentMesh = (const(Mesh)*) => false;

    const before = changeBus.deliveryCount;
    scratch.beginDeliveryBatch();
    assert(deliveryPendingSetLength() == 0, "fixture: the batch opens empty");
    foreach (i; 0 .. 4)
        scratch.commitChange(MeshEditScope.Position);
    assert(deliveryPendingSetLength() == 0,
        "a rejected mesh must never be appended to the deferred-delivery set "
      ~ "— that array is drained after the frame that appended to it, so a "
      ~ "stack-local Mesh in it is a dangling pointer");
    scratch.endDeliveryBatch();
    assert(changeBus.deliveryCount == before,
        "...and the batch close therefore delivers nothing for it");
    assert(deliveryPendingSetLength() == 0, "the close leaves the set empty");
}

// (h) The ACCEPTED mesh still coalesces through the deferred set — the control
//     for (g). Without it, (g) is green on a `deliverPending` that lost the
//     ability to defer at all.
unittest {
    import mesh : Mesh, makeCube, g_isDocumentMesh, deliveryPendingSetLength;

    Mesh subject = makeCube();
    subject.syncSelection();

    auto savedFilter = g_isDocumentMesh;
    scope (exit) g_isDocumentMesh = savedFilter;
    g_isDocumentMesh = (const(Mesh)* m) => m is &subject;

    const before = changeBus.deliveryCount;
    subject.beginDeliveryBatch();
    foreach (i; 0 .. 4)
        subject.commitChange(MeshEditScope.Position);
    assert(deliveryPendingSetLength() == 1,
        "an accepted mesh IS deferred — exactly once, however many commits");
    subject.endDeliveryBatch();
    assert(changeBus.deliveryCount == before + 1,
        "and the close delivers it once");
}

// (i) A REJECTED subject KEEPS its `undelivered*_` words — and they ride a
//     wholesale `*mesh = <scratch>` assignment into the mesh a `Layer` owns,
//     where the next delivering publisher carries them out.
//
//     This is the rule `Mesh.deliverPending`'s rejection arm states ("Rejection
//     deliberately leaves `undelivered*_` ALONE rather than zeroing it"), and
//     it is the reason ~15 wholesale-assign kernels do not silently lose the
//     classes their scratch mesh accumulated. Over-invalidation is the safe
//     direction; a zero on rejection is the other one.
//
//     IT HAS NO WITNESS OVER HTTP, WHICH IS WHY IT IS PINNED HERE.
//     `tests/test_bus_delivery_subject.d` block (1) asserts the reset's one
//     delivery carries 14 — but 14 is exactly `mesh.resetSelection()`'s own
//     `commitChange(Geometry | Marks)`, and every class `makeCube()` (or any
//     other `/api/reset` primitive) accumulates on its scratch is a SUBSET of
//     it. Zeroing on rejection leaves that assert green. Measured: the reviewer
//     rewrote the rejection arm to zero both words and the HTTP block still
//     PASSED. So the discriminating cell is a class the DOCUMENT-side publisher
//     does not re-commit, and no reset arm has one.
//
//     `Maps` is that class here: the scratch commits it, the document mesh
//     commits only `Position`, so the bit can ONLY have arrived by the carry.
//
//     MUTATION: give `Mesh.deliverPending`'s rejection arm a body —
//     `{ undeliveredChanges_ = 0; undeliveredSelDomains_ = 0; return; }` ⇒ this
//     block reddens on its last assert. (The B1 blocks (f)/(g) stay green: they
//     measure that the rejected mesh does not DELIVER, not what it retains.)
unittest {
    import mesh : Mesh, makeCube, g_isDocumentMesh;

    // `docMesh` stands in for a `Layer`'s `mesh_` field; `scratch` for the
    // stack-local a kernel builds beside it. The filter separates them by
    // ADDRESS, which is exactly what `Document.ownsMesh` does.
    Mesh docMesh;
    Mesh scratch;

    auto savedFilter = g_isDocumentMesh;
    scope (exit) g_isDocumentMesh = savedFilter;
    g_isDocumentMesh = (const(Mesh)* m) => m is &docMesh;

    const beforeScratch = changeBus.deliveryCount;
    scratch = makeCube();                       // 6 rejected Geometry commits
    scratch.syncSelection();
    scratch.commitChange(MeshEditScope.Maps);   // the carried class
    assert(changeBus.deliveryCount == beforeScratch,
        "fixture: the scratch mesh is REJECTED, so nothing above delivered — "
      ~ "if it did, the flags below would have left by the front door and this "
      ~ "block would be measuring the wrong path");

    // The wholesale hand-over: the whole struct is copied, `undelivered*_`
    // included, into the mesh that actually owns the geometry.
    docMesh = scratch;

    const before = changeBus.deliveryCount;
    docMesh.commitChange(MeshEditScope.Position);
    assert(changeBus.deliveryCount == before + 1,
        "the accepted mesh delivers once");
    assert((changeBus.lastDeliveryFlags & MeshEditScope.Position) != 0,
        "...carrying its own class");

    // THE LAW. `Maps` is not committed anywhere on the document side; the only
    // way this bit can be in the delivery is that the rejection kept it.
    assert((changeBus.lastDeliveryFlags & MeshEditScope.Maps) != 0,
        "a rejected delivery must KEEP its undelivered classes: they ride the "
      ~ "wholesale `*mesh = <scratch>` assignment into the layer's mesh and "
      ~ "are carried by the next delivering publisher there. Zeroing on "
      ~ "rejection drops them and every listener under-invalidates");
}

// ===========================================================================
// TASK 1906 STAGE 3 — EVERY SELECTION WRITER ON `Mesh` DELIVERS, and this is
// the half of the stage that `Command.apply`'s anchor cannot reach.
//
// The anchor offers the COMMAND'S OWN mesh at the batch close. Two shapes fall
// outside it, and both were measured on the live app before this landed:
//   * a TOOL. The Topology Pen's undo path calls `mesh.selectVertex` at
//     delivery depth 0 — a gesture is not a `Command.apply` — and was the last
//     frame of drain residue the stage-3 census found.
//   * a command that writes marks on a mesh that is NOT its own.
//     `select.set.apply` walks every foreground layer; the anchor's single
//     offer reaches one of them.
//
// So the writers deliver, and `noteSelectionChange` beside them deliberately
// does not: it is also the funnel `refreshHiddenDerived` uses mid-`commitStamps`,
// where an early delivery would land BEFORE the derive that `commitChange`'s
// documented order puts first.
//
// Mutations, each in isolation (each reddens ONE clause):
//   * drop `deliverPending()` from the six scalar setters  ⇒ (1)
//   * drop it from the three bulk `clear*`                 ⇒ (2)
//   * drop it from `applySelectedFrom_`                    ⇒ (3)
//
// Note what is NOT asserted here: a count on a LOOP. Inside a batch these only
// register; outside one a tool-sized loop delivers per element. THAT IS ONLY
// AFFORDABLE BECAUSE THE MESH-SIZED LOOPS ARE BATCHED AT THE GESTURE, which is
// a claim about the editor and cannot be made from a bare `Mesh` — it is
// pinned over HTTP by `tests/test_bus_delivery_granularity.d` blocks (4)/(5)
// (an RMB lasso selecting hundreds of faces ⇒ ONE delivery; a lasso that moved
// no mark ⇒ zero) and block (6) (a paint stroke ⇒ one delivery per element it
// ADDS, measured 42 for 42 over 120 motion events). Blocks (1)-(3) of that
// file pin a twelve-step GIZMO DRAG and say nothing about a pick ceiling —
// this sentence used to point at them, which was the wrong witness.
// ===========================================================================
unittest {
    import mesh : Mesh, makeCube;

    Mesh m = makeCube();
    m.syncSelection();
    m.resetSelection();

    // (1) the scalar writer — the tool path.
    {
        const before = changeBus.deliveryCount;
        m.selectVertex(0);
        assert(changeBus.deliveryCount == before + 1,
            "a scalar selection write outside any command must deliver — a "
          ~ "tool gesture is not a `Command.apply` and has no batch to close");
        assert((changeBus.lastDeliverySelDomains & SelDomain.Vertex) != 0,
            "…carrying the domain it wrote");
    }

    // (2) the bulk clear.
    {
        const before = changeBus.deliveryCount;
        m.clearVertexSelection();               // drops a LIVE selection
        assert(changeBus.deliveryCount == before + 1,
            "clearing a live selection must deliver — this is the editor's "
          ~ "click-empty-space-to-deselect path, called straight from "
          ~ "`input_router.d` with no command around it");
        const after = changeBus.deliveryCount;
        m.clearVertexSelection();               // already empty: inert
        assert(changeBus.deliveryCount == after,
            "…and clearing an ALREADY-EMPTY selection must NOT: the "
          ~ "compare-before-set guard is what keeps a delivering writer from "
          ~ "publishing on every no-op call");
    }

    // (3) the bulk apply — the `select.set.apply` shape.
    {
        bool[] sel; sel.length = m.vertices.length;
        sel[3] = true;
        const before = changeBus.deliveryCount;
        m.setVerticesSelectedFrom(sel);
        assert(changeBus.deliveryCount == before + 1,
            "a bulk selection apply must deliver — `select.set.apply` writes "
          ~ "marks on every foreground layer's mesh, and the command anchor "
          ~ "offers only its own");
        const after = changeBus.deliveryCount;
        m.setVerticesSelectedFrom(sel);         // identical: inert
        assert(changeBus.deliveryCount == after,
            "…and an identical re-apply must NOT");
    }
}
