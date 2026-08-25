// Task 1620 — an interactive preview drag must not RECREATE the topology it
// already built, and the check is on COUNTERS, not on a screenshot.
//
// THE DEFECT. `edge.extend`, `edge.bevel` and `poly.bevel` rebuilt their live
// preview by tearing the created topology down (`before.restore(*mesh)`) and
// creating it again (`mesh.<kernel>(...)`) on EVERY frame. Both halves publish
// a Geometry-class change, so `Mesh.topologyVersion` advanced twice per frame
// — and `topologyVersion` is the key `SubpatchPreview` reads to decide whether
// its index space still holds. A moved key sends it through `dispatchBuild`,
// which drops `active` AT DISPATCH (deliberately: while a build is in flight
// the CAGE has to be what is drawn and what is picked). Frame in — subpatch;
// frame out — cage. That is the flicker the owner found dragging an extend
// handle on a subdiv mesh.
//
// WHAT EACH CELL ASSERTS, and the three ways a cell like this goes vacuous —
// all three are asserted here rather than written down as advice:
//
//  1. A CAGE WITH NO SUBPATCH FACES NEVER DISPATCHES AT ALL, so every cell
//     below would be green whether or not anything was fixed.
//     `unsubdivided_rig_cannot_fail` proves that directly on the same
//     gesture, and every other cell asserts `preview.active` plus a STRICTLY
//     GROWN build count on its arming frame — the rig's dispatch machinery is
//     shown to be live inside the cell that depends on it.
//  2. A GESTURE THAT DOES NOT REBUILD NEVER DISPATCHES EITHER (`rebuildPreview`
//     returns early on `if (!active)`), so "zero dispatches" arrives for free.
//     Every cell first asserts that the rebuild HAPPENED — the vertex count
//     grew on the arming sample, and the vertex POSITIONS then changed across
//     the drag samples — and only then that no dispatch followed.
//  3. THE DISPATCH COUNT ALONE CANNOT PIN THE KEY. The seam does not trust the
//     key: it hashes the topology the kernel produced and falls back to a full
//     rebuild when it disagrees, so an under-declared key still lands the right
//     geometry AND the right dispatch count — it just pays twice. `keyMisses`
//     is the counter that sees it, so every cell asserts that too. This is the
//     assertion the bevel zero-crossing mutation reddens.
//
// RUN A MUTATION AGAINST ONE CELL AT A TIME: druntime stops a module at its
// first failed assert, so a mutation that should redden two cells only ever
// proves the first.
module tests.unit.tools.edit.preview_topology_churn_test;

import mesh;
import math : Vec3;
import editmode : EditMode;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import params : Param;
import tool : Tool;
import tools.edit.edge_extend : EdgeExtendTool;
import tools.edit.edge_bevel  : EdgeBevelTool;
import tools.edit.poly_bevel  : PolyBevelTool;

import std.conv : to;

// ---------------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------------

// Heap-allocated: every tool holds a `Mesh* delegate()` over this.
private final class Rig {
    Mesh            mesh;
    GpuMesh         gpu;
    EditMode        editMode = EditMode.Edges;
    VertexCache     vc;
    EdgeCache       ec;
    FaceBoundsCache fc;
    SubpatchPreview preview;

    this(Mesh m, EditMode em) {
        mesh     = m;
        editMode = em;
        // The `make*` factories build geometry but leave the per-element mark
        // arrays unsized; `selectEdge`/`selectFace` index straight into them.
        mesh.resizeVertexSelection();
        mesh.resizeEdgeSelection();
        mesh.resizeFaceSelection();
        // `resizeFaceSelection` grows faceMarks only; the pick-order array is
        // normally grown in lock-step by the calling mutator, and `selectFace`
        // writes into it.
        mesh.faceSelectionOrder.length = mesh.faces.length;
        // The tools refresh their display through `refreshDisplay` →
        // `GpuMesh.upload`, which is raw GL. `suppressCageUpload` is the
        // shipped path for "a subpatch preview is on screen and the main loop
        // owns the upload" — exactly this rig's situation — and it turns the
        // upload into the Position-class publish the tools need. No GL.
        gpu.suppressCageUpload = true;
    }

    /// One frame of the editor's main loop, as far as this task is concerned:
    /// the change bus hands this mesh's pending classes to the epoch table and
    /// the subpatch preview is asked to catch up with the cage.
    ///
    /// TASK 1906 STAGE 2d — the `noteMeshChange` line replaces the `true` this
    /// used to pass for `positionsDirty`, and it mirrors app.d MORE closely
    /// than the flag did: app.d's per-layer feed at the frame drain hands
    /// `noteMeshChange` exactly this mesh's own `pendingChanges_`, per layer,
    /// with the subject address. A scratch mesh no `Document` owns gets no
    /// delivery of its own (`Mesh.deliverPending`'s subject filter), so a
    /// headless rig drives the listener body directly.
    void frame(int depth = 2) {
        import mesh_dirty : noteMeshChange;
        noteMeshChange(cast(size_t)&mesh, mesh.pendingChanges_);
        // The drain's half. app.d's feed is read-only because the drain zeroes
        // the word once per frame; a rig that only reads it re-publishes the
        // cage's build-time `Points | Polygons` on every call and invalidates
        // for a reason that is not the edit under test.
        mesh.pendingChanges_ = 0;
        preview.rebuildIfStale(mesh, depth);
    }
}

private enum int DEPTH = 2;

/// A flat grid with every face marked subpatch — the extend rig. Boundary
/// edges have one adjacent face, which is all `extendEdgesByMask` needs.
private Mesh subdividedGrid(int n) {
    Mesh m = makeGridPlane(n);
    m.resizeSubpatch();
    foreach (fi; 0 .. m.faces.length) m.setSubpatch(fi, true);
    return m;
}

/// The same grid with NO subpatch marks — the vacuous-rig control.
private Mesh flatGrid(int n) {
    return makeGridPlane(n);
}

private Mesh subdividedCube() {
    Mesh m = makeCube();
    m.resizeSubpatch();
    foreach (fi; 0 .. m.faces.length) m.setSubpatch(fi, true);
    return m;
}

/// Write a tool parameter the way an interactive control does: poke the
/// backing field the Param points at, then deliver the interactive
/// notification. That is the panel's own two-step, so this drives the real
/// `onParamChanged` → `rebuildPreview` path rather than a test-only shortcut.
private void setFloatParam(Tool t, string name, float v) {
    foreach (ref p; t.params()) {
        if (p.name != name) continue;
        assert(p.kind == Param.Kind.Float, "param `" ~ name ~ "` is not a float");
        *p.fptr = v;
        t.notifyInteractiveParamChanged(name);
        return;
    }
    assert(false, "no float param named `" ~ name ~ "`");
}

private void setIntParam(Tool t, string name, int v) {
    foreach (ref p; t.params()) {
        if (p.name != name) continue;
        assert(p.kind == Param.Kind.Int, "param `" ~ name ~ "` is not an int");
        *p.iptr = v;
        t.notifyInteractiveParamChanged(name);
        return;
    }
    assert(false, "no int param named `" ~ name ~ "`");
}

private bool positionsDiffer(in Vec3[] a, in Vec3[] b) {
    if (a.length != b.length) return true;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i]) return true;
    return false;
}

// ---------------------------------------------------------------------------
// TRAP 1, asserted rather than described: on a cage with no subpatch faces the
// preview never dispatches, so the "zero dispatches" claim below would hold no
// matter what `rebuildPreview` did. This cell drives the SAME extend gesture
// on such a cage and shows the count sitting at zero throughout — including
// across the arming sample, which on a subdivided cage MUST dispatch.
// ---------------------------------------------------------------------------
unittest {
    auto rig = new Rig(flatGrid(3), EditMode.Edges);
    rig.mesh.selectEdge(0);

    rig.frame();
    assert(!rig.preview.active,
        "control setup: an unmarked cage must not produce a preview");

    auto tool = new EdgeExtendTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                   null, &rig.vc, &rig.ec, &rig.fc);
    tool.activate();

    const size_t vertsBefore = rig.mesh.vertices.length;
    setFloatParam(tool, "offsetY", 0.10f);
    rig.frame();
    assert(rig.mesh.vertices.length > vertsBefore,
        "control setup: the extend kernel must have built a ridge");
    // The topology DID change here — and the dispatch count still did not
    // move, because there is nothing to dispatch. That is the whole point:
    // a cell built on this rig cannot fail.
    assert(rig.preview.topologyBuilds == 0,
        "an unmarked cage must never dispatch a subpatch build, so a churn "
      ~ "cell built on one is vacuous — saw "
      ~ rig.preview.topologyBuilds.to!string);
}

// ---------------------------------------------------------------------------
// MAIN CELL — edge.extend. A gesture that changes neither the selection nor
// the segment count must leave `topologyVersion` alone and dispatch nothing.
// ---------------------------------------------------------------------------
unittest {
    auto rig = new Rig(subdividedGrid(3), EditMode.Edges);
    rig.mesh.selectEdge(0);
    rig.mesh.selectEdge(1);

    rig.frame();
    assert(rig.preview.active,
        "rig must actually subdivide, or the dispatch count cannot move");
    const ulong buildsAtArm = rig.preview.topologyBuilds;
    assert(buildsAtArm > 0, "the arming frame must have built a preview");

    auto tool = new EdgeExtendTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                   null, &rig.vc, &rig.ec, &rig.fc);
    tool.activate();

    // Sample 1 — the ridge appears. This one IS a topology change and one
    // dispatch here is correct.
    const size_t vertsBare = rig.mesh.vertices.length;
    setFloatParam(tool, "offsetY", 0.10f);
    rig.frame();
    assert(rig.mesh.vertices.length > vertsBare,
        "the extend kernel must have built a ridge on the first sample");
    const ulong buildsAfterFirst = rig.preview.topologyBuilds;
    assert(buildsAfterFirst > buildsAtArm,
        "the FIRST sample must dispatch — a rig whose dispatch count never "
      ~ "moves cannot detect one that moves too often");

    const ulong topoAfterFirst = rig.mesh.topologyVersion;
    const size_t vertsAfterFirst = rig.mesh.vertices.length;
    auto posAfterFirst = rig.mesh.vertices.dup;

    // Samples 2..16 — position only. Same selection, same segment count.
    foreach (k; 2 .. 17) {
        setFloatParam(tool, "offsetY", 0.10f + 0.02f * k);
        rig.frame();
    }

    // TRAP 2 — the rebuild has to have HAPPENED, or "no dispatch" is free.
    assert(rig.mesh.vertices.length == vertsAfterFirst,
        "a position-only drag must not change the vertex count");
    assert(positionsDiffer(rig.mesh.vertices, posAfterFirst),
        "the drag samples moved no vertex — the preview never rebuilt, so "
      ~ "the dispatch assertions below would pass for free");

    // THE LAW. The dispatch count first, because it IS the flicker; the
    // topology version is the mechanism behind it and is asserted next.
    assert(rig.preview.topologyBuilds == buildsAfterFirst,
        "a position-only extend drag dispatched a subpatch build: expected "
      ~ buildsAfterFirst.to!string ~ " dispatches, saw "
      ~ rig.preview.topologyBuilds.to!string ~ " (topologyVersion "
      ~ topoAfterFirst.to!string ~ " -> "
      ~ rig.mesh.topologyVersion.to!string ~ ")");
    assert(rig.mesh.topologyVersion == topoAfterFirst,
        "topologyVersion moved during a position-only extend drag: "
      ~ topoAfterFirst.to!string ~ " -> "
      ~ rig.mesh.topologyVersion.to!string);
    assert(rig.preview.active,
        "the preview must still be the subdivided surface after the drag "
      ~ "(a dropped `active` is the cage showing through — the flicker)");

    // TRAP 3 — the topology key itself, which the dispatch count cannot pin
    // because the seam's topology hash rescues a wrong one.
    const c = tool.previewRebuildCounts();
    assert(c.keyMisses == 0,
        "the extend topology key mis-declared a position-only sample: "
      ~ c.keyMisses.to!string ~ " key miss(es)");
    assert(c.placements >= 15,
        "expected every drag sample after the first on the position-only "
      ~ "path, saw " ~ c.placements.to!string);
    assert(c.fullRebuilds == 1,
        "expected exactly one restore-and-rebuild (the arming sample), saw "
      ~ c.fullRebuilds.to!string);
}

// ---------------------------------------------------------------------------
// CONTROL — without it the cell above means nothing. Changing the SEGMENT
// COUNT mid-gesture is a real topology change: the version must move and a
// build must happen, EXACTLY ONCE PER CHANGE and not once per frame.
// ---------------------------------------------------------------------------
unittest {
    auto rig = new Rig(subdividedGrid(3), EditMode.Edges);
    rig.mesh.selectEdge(0);
    rig.mesh.selectEdge(1);
    rig.frame();
    assert(rig.preview.active, "rig must actually subdivide");

    auto tool = new EdgeExtendTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                   null, &rig.vc, &rig.ec, &rig.fc);
    tool.activate();
    setFloatParam(tool, "offsetY", 0.10f);
    rig.frame();

    const ulong buildsBefore = rig.preview.topologyBuilds;
    const ulong topoBefore   = rig.mesh.topologyVersion;
    const size_t vertsBefore = rig.mesh.vertices.length;

    // One segment change, then four position-only samples on top of it.
    setIntParam(tool, "segments", 3);
    rig.frame();

    assert(rig.mesh.vertices.length > vertsBefore,
        "segments 1 -> 3 must add ring vertices");
    assert(rig.mesh.topologyVersion > topoBefore,
        "a segment-count change is a real topology change and must move the "
      ~ "version");
    assert(rig.preview.topologyBuilds == buildsBefore + 1,
        "a segment-count change must dispatch EXACTLY ONE build: expected "
      ~ (buildsBefore + 1).to!string ~ ", saw "
      ~ rig.preview.topologyBuilds.to!string);

    const ulong buildsAfterChange = rig.preview.topologyBuilds;
    const ulong topoAfterChange   = rig.mesh.topologyVersion;
    foreach (k; 0 .. 4) {
        setFloatParam(tool, "offsetY", 0.30f + 0.02f * k);
        rig.frame();
    }
    assert(rig.mesh.topologyVersion == topoAfterChange,
        "the samples AFTER the segment change must be position-only again");
    assert(rig.preview.topologyBuilds == buildsAfterChange,
        "a segment change must cost ONE build, not one per following frame: "
      ~ "expected " ~ buildsAfterChange.to!string ~ ", saw "
      ~ rig.preview.topologyBuilds.to!string);

    const c = tool.previewRebuildCounts();
    assert(c.fullRebuilds == 2,
        "expected two restore-and-rebuilds (arming + the segment change), saw "
      ~ c.fullRebuilds.to!string);
    assert(c.keyMisses == 0,
        "the extend topology key mis-declared a sample: "
      ~ c.keyMisses.to!string ~ " key miss(es)");
}

// ---------------------------------------------------------------------------
// MAIN CELL — edge.bevel. Same law, second shape: the width drag moves
// vertices only, as long as it stays clear of zero.
// ---------------------------------------------------------------------------
unittest {
    auto rig = new Rig(subdividedCube(), EditMode.Edges);
    rig.mesh.selectEdge(0);
    rig.frame();
    assert(rig.preview.active, "rig must actually subdivide");
    const ulong buildsAtArm = rig.preview.topologyBuilds;
    assert(buildsAtArm > 0, "the arming frame must have built a preview");

    auto tool = new EdgeBevelTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                  null, &rig.vc, &rig.ec, &rig.fc);
    tool.activate();

    const size_t vertsBare = rig.mesh.vertices.length;
    setFloatParam(tool, "width", 0.05f);
    rig.frame();
    assert(rig.mesh.vertices.length > vertsBare,
        "the bevel kernel must have built geometry on the first sample");
    const ulong buildsAfterFirst = rig.preview.topologyBuilds;
    assert(buildsAfterFirst > buildsAtArm,
        "the FIRST sample must dispatch — otherwise this rig cannot detect "
      ~ "a dispatch that should not have happened");

    const ulong topoAfterFirst   = rig.mesh.topologyVersion;
    const size_t vertsAfterFirst = rig.mesh.vertices.length;
    auto posAfterFirst = rig.mesh.vertices.dup;

    foreach (k; 2 .. 17) {
        setFloatParam(tool, "width", 0.05f + 0.01f * k);
        rig.frame();
    }

    assert(rig.mesh.vertices.length == vertsAfterFirst,
        "a width drag clear of zero must not change the vertex count");
    assert(positionsDiffer(rig.mesh.vertices, posAfterFirst),
        "the width samples moved no vertex — the preview never rebuilt, so "
      ~ "the dispatch assertions below would pass for free");

    assert(rig.preview.topologyBuilds == buildsAfterFirst,
        "a position-only bevel width drag dispatched a subpatch build: "
      ~ "expected " ~ buildsAfterFirst.to!string ~ " dispatches, saw "
      ~ rig.preview.topologyBuilds.to!string ~ " (topologyVersion "
      ~ topoAfterFirst.to!string ~ " -> "
      ~ rig.mesh.topologyVersion.to!string ~ ")");
    assert(rig.mesh.topologyVersion == topoAfterFirst,
        "topologyVersion moved during a position-only bevel width drag: "
      ~ topoAfterFirst.to!string ~ " -> "
      ~ rig.mesh.topologyVersion.to!string);
    assert(rig.preview.active,
        "the preview must still be the subdivided surface after the drag");

    const c = tool.previewRebuildCounts();
    assert(c.keyMisses == 0,
        "the edge-bevel topology key mis-declared a width sample: "
      ~ c.keyMisses.to!string ~ " key miss(es)");
    assert(c.fullRebuilds == 1,
        "expected exactly one restore-and-rebuild (the arming sample), saw "
      ~ c.fullRebuilds.to!string);
}

// ---------------------------------------------------------------------------
// CONTROL — edge.bevel round level. `roundLevel` is the bevel's segment
// count, so changing it mid-gesture must cost exactly one build.
// ---------------------------------------------------------------------------
unittest {
    auto rig = new Rig(subdividedCube(), EditMode.Edges);
    rig.mesh.selectEdge(0);
    rig.frame();
    assert(rig.preview.active, "rig must actually subdivide");

    auto tool = new EdgeBevelTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                  null, &rig.vc, &rig.ec, &rig.fc);
    tool.activate();
    setFloatParam(tool, "width", 0.10f);
    rig.frame();

    const ulong buildsBefore = rig.preview.topologyBuilds;
    const ulong topoBefore   = rig.mesh.topologyVersion;
    const size_t vertsBefore = rig.mesh.vertices.length;

    setIntParam(tool, "roundLevel", 2);
    rig.frame();

    assert(rig.mesh.vertices.length > vertsBefore,
        "roundLevel 0 -> 2 must add rounding vertices");
    assert(rig.mesh.topologyVersion > topoBefore,
        "a round-level change is a real topology change");
    assert(rig.preview.topologyBuilds == buildsBefore + 1,
        "a round-level change must dispatch EXACTLY ONE build: expected "
      ~ (buildsBefore + 1).to!string ~ ", saw "
      ~ rig.preview.topologyBuilds.to!string);

    const ulong buildsAfter = rig.preview.topologyBuilds;
    foreach (k; 0 .. 4) {
        setFloatParam(tool, "width", 0.12f + 0.01f * k);
        rig.frame();
    }
    assert(rig.preview.topologyBuilds == buildsAfter,
        "a round-level change must cost ONE build, not one per following "
      ~ "frame: expected " ~ buildsAfter.to!string ~ ", saw "
      ~ rig.preview.topologyBuilds.to!string);

    const c = tool.previewRebuildCounts();
    assert(c.keyMisses == 0,
        "the edge-bevel topology key mis-declared a sample: "
      ~ c.keyMisses.to!string ~ " key miss(es)");
}

// ---------------------------------------------------------------------------
// THE ZERO CROSSING — the trap extend does not have. `edge_bevel`'s kernel
// call sits behind `if (width_ == 0.0f)`, so crossing zero makes the bevel
// geometry disappear and reappear: two REAL topology changes that a key over
// (mask, roundLevel) alone would sit still through. Exactly two builds, at
// the two crossings and nowhere else.
//
// This is the cell the mutation reddens: drop `width_ == 0.0f` from the key
// in `edge_bevel.d`'s `rebuildPreview` and run this block alone.
// ---------------------------------------------------------------------------
unittest {
    auto rig = new Rig(subdividedCube(), EditMode.Edges);
    rig.mesh.selectEdge(0);
    rig.frame();
    assert(rig.preview.active, "rig must actually subdivide");

    auto tool = new EdgeBevelTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                  null, &rig.vc, &rig.ec, &rig.fc);
    tool.activate();

    // Arm above zero.
    const size_t vertsBare = rig.mesh.vertices.length;
    setFloatParam(tool, "width", 0.15f);
    rig.frame();
    assert(rig.mesh.vertices.length > vertsBare,
        "the bevel must have built geometry before the crossing");
    const ulong buildsArmed = rig.preview.topologyBuilds;

    // Down to zero (crossing 1), across the bottom, and back up (crossing 2).
    // The two samples AT zero and the two above it are position-only.
    const float[] widths = [0.10f, 0.05f, 0.0f, 0.0f, 0.05f, 0.10f];
    foreach (w; widths) {
        setFloatParam(tool, "width", w);
        rig.frame();
    }

    assert(rig.mesh.vertices.length > vertsBare,
        "the bevel geometry must be back after the second crossing");
    assert(rig.preview.topologyBuilds == buildsArmed + 2,
        "a width drag through zero and back must dispatch EXACTLY TWO builds "
      ~ "— one per crossing: expected " ~ (buildsArmed + 2).to!string
      ~ ", saw " ~ rig.preview.topologyBuilds.to!string);

    const c = tool.previewRebuildCounts();
    assert(c.fullRebuilds == 3,
        "expected three restore-and-rebuilds (arming + two crossings), saw "
      ~ c.fullRebuilds.to!string);
    assert(c.keyMisses == 0,
        "the zero crossing is not in the edge-bevel topology key: "
      ~ c.keyMisses.to!string ~ " key miss(es) — the seam's topology hash "
      ~ "caught what the key failed to declare, which is why the dispatch "
      ~ "count alone cannot pin this");
}

// ---------------------------------------------------------------------------
// poly.bevel — the seam carried to a second kernel with a two-parameter
// degenerate branch (`inset == 0 && shift == 0`). Same three cells folded
// into one block: a position-only drag, and a crossing.
// ---------------------------------------------------------------------------
unittest {
    auto rig = new Rig(subdividedCube(), EditMode.Polygons);
    rig.mesh.selectFace(0);
    rig.frame();
    assert(rig.preview.active, "rig must actually subdivide");
    const ulong buildsAtArm = rig.preview.topologyBuilds;
    assert(buildsAtArm > 0, "the arming frame must have built a preview");

    auto tool = new PolyBevelTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                  null, &rig.vc, &rig.ec, &rig.fc);
    tool.activate();

    const size_t vertsBare = rig.mesh.vertices.length;
    setFloatParam(tool, "inset", 0.05f);
    rig.frame();
    assert(rig.mesh.vertices.length > vertsBare,
        "the poly-bevel kernel must have built geometry on the first sample");
    const ulong buildsAfterFirst = rig.preview.topologyBuilds;
    assert(buildsAfterFirst > buildsAtArm,
        "the FIRST sample must dispatch");

    const ulong topoAfterFirst = rig.mesh.topologyVersion;
    auto posAfterFirst = rig.mesh.vertices.dup;

    foreach (k; 2 .. 12) {
        setFloatParam(tool, "inset", 0.05f + 0.01f * k);
        rig.frame();
    }

    assert(positionsDiffer(rig.mesh.vertices, posAfterFirst),
        "the inset samples moved no vertex — the preview never rebuilt");
    assert(rig.preview.topologyBuilds == buildsAfterFirst,
        "a position-only poly-bevel drag dispatched a subpatch build: "
      ~ "expected " ~ buildsAfterFirst.to!string ~ " dispatches, saw "
      ~ rig.preview.topologyBuilds.to!string ~ " (topologyVersion "
      ~ topoAfterFirst.to!string ~ " -> "
      ~ rig.mesh.topologyVersion.to!string ~ ")");
    assert(rig.mesh.topologyVersion == topoAfterFirst,
        "topologyVersion moved during a position-only poly-bevel drag: "
      ~ topoAfterFirst.to!string ~ " -> "
      ~ rig.mesh.topologyVersion.to!string);

    // The crossing, on the same armed tool: inset back to zero (with shift
    // already zero, that is the degenerate branch) and out again.
    const ulong buildsBeforeCross = rig.preview.topologyBuilds;
    setFloatParam(tool, "inset", 0.0f);
    rig.frame();
    setFloatParam(tool, "inset", 0.0f);
    rig.frame();
    setFloatParam(tool, "inset", 0.05f);
    rig.frame();
    assert(rig.preview.topologyBuilds == buildsBeforeCross + 2,
        "an inset drag through zero and back must dispatch EXACTLY TWO "
      ~ "builds: expected " ~ (buildsBeforeCross + 2).to!string ~ ", saw "
      ~ rig.preview.topologyBuilds.to!string);

    const c = tool.previewRebuildCounts();
    assert(c.keyMisses == 0,
        "the poly-bevel topology key mis-declared a sample: "
      ~ c.keyMisses.to!string ~ " key miss(es)");
}
