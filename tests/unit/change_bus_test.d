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
    bus.onMeshChanged((size_t, uint f) { seen |= f; ++calls; });

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
    bus.onMeshChanged((size_t, uint) { ++calls; });

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
    bus.onMeshChanged((size_t, uint) { ++meshCalls; });
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
    bus.onMeshChanged((size_t, uint f) { meshSeen = f; meshOrder = order++; });
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
    bus.onMeshChanged((size_t, uint) {
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
    bus.onMeshChanged((size_t, uint f) { meshSeen = f; meshOrder = order++; });
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
    bus.onMeshChanged((size_t, uint) { ++meshCalls; });
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
    bus.onMeshChanged((size_t, uint) { ++meshCalls; });
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
    bus.onMeshChanged((size_t, uint) { meshOrder = order++; });
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
        bus.flush(MeshEditScope.Maps, 0, 0);
        assert(bus.totalMaps == 1, "a Maps flush is counted");
        assert(bus.docRevision() == before + 1,
            "a per-element MAP write is PERSISTED document content (.v3d "
          ~ "meshMaps / edgeMaps, .lwo VMAPs), so it must move docRevision -- "
          ~ "without this a whole morph session leaves the document reading "
          ~ "clean and Quit closes with no save prompt");
    }
    {
        ChangeBus bus;
        const before = bus.docRevision();
        bus.flush(MeshEditScope.MapsDisplay, 0, 0);
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
//   * delete `++g_deliveryDepth` in `Mesh.beginDeliveryBatch`
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

// (e) The frame flush and the edit-boundary delivery are INDEPENDENT counter
//     families, and that is load-bearing rather than tidy: until the last
//     frame-drain consumer leaves, the same mutation is delivered twice (once
//     here, once out of `Mesh.pendingChanges_` at the frame flush). A per-class
//     total bumped on both paths would double `docRevision()` and make a clean
//     document read dirty after one edit.
unittest {
    ChangeBus bus;
    const beforeRev = bus.docRevision();
    bus.deliverMesh(0xDEAD, MeshEditScope.Position | MeshEditScope.Maps,
                    SelDomain.Vertex);
    assert(bus.deliveryCount == 1, "deliverMesh counts its own deliveries");
    assert(bus.lastDeliverySubject == 0xDEAD);
    assert(bus.lastDeliverySelDomains == SelDomain.Vertex);
    assert(bus.flushCount == 0 && bus.lastFlushFlags == 0,
        "a delivery is NOT a flush: the per-frame counters must not move");
    assert(bus.totalPosition == 0 && bus.totalMaps == 0
        && bus.totalSelVertex == 0,
        "no per-class total moves on the delivery path — the frame flush "
      ~ "still drains the same mutation out of pendingChanges_");
    assert(bus.docRevision() == beforeRev,
        "docRevision (the unsaved-changes counter) must not double-count");
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
