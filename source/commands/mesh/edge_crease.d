module commands.mesh.edge_crease;

import command;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import params : Param;

// ---------------------------------------------------------------------------
// Edge-crease (subdivision semi-sharp crease) lifecycle commands — task 1062.
//
// Stores a scalar on the reserved MapKind.creaseWeight edge map
// (source/mesh.d: kCreaseWeightMapName == "crease"). 1.0 == the editor UI's
// 100%; the map value is fed through subpatch_osd.creaseSharpnessFromWeight
// at preview-build time (sharpness = 10 * weight, saturating at 1.0). Two
// commands cover the authoring lifecycle:
//   mesh.edgeCrease.set   {weight} — absolute write to every selected edge
//   mesh.edgeCrease.clear           — writes 0.0 to every selected edge
//
// Both use MeshSnapshot for undo (snapshot.d deep-dups meshMaps, so a
// restore brings the crease map back exactly as it was). Absolute, not
// additive — the fixture's law.storage says the reference's set is
// absolute; an empty edge selection REFUSES (baseRefusal_ + return false)
// rather than silently applying to the whole mesh (a silent whole-mesh
// crease would be the worst possible mis-fire — see edge_weight_plan.md
// §5). Refusing via the house baseRefusal_/return-false mechanism (not a
// thrown Exception) matters here specifically because the button this
// dispatches from (config/buttons.yaml) reaches it through the UI's plain
// runCommand path, which passes throwMsg = null — an uncaught throw there
// unwinds past the args dialog's own popup-close call and leaves the ImGui
// popup stack one deep. The HTTP /api/command path still reports a non-ok
// status: the SCRIPT-origin dispatch adapter raises its OWN Exception off
// refusalReason() (source/http_providers.d, task 1520 — the UI-origin adapter
// raises a notice from the same refusal instead).
// ---------------------------------------------------------------------------

private uint[] selectedEdgeIndices(ref const Mesh mesh) {
    uint[] result;
    foreach (ei; 0 .. mesh.edges.length)
        if (mesh.isEdgeSelected(ei)) result ~= cast(uint) ei;
    return result;
}

class EdgeCreaseSet : Command {
    private float        weight_ = 0.0f;
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeCrease.set"; }
    override string label() const { return "Set Edge Crease"; }

    override Param[] params() {
        return [ Param.float_("weight", "Weight", &weight_, 0.0f) ];
    }

    override bool apply() {
        baseRefusal_ = "";
        auto sel = selectedEdgeIndices(*mesh);
        if (sel.length == 0) {
            baseRefusal_ = "no edges selected";
            return false;
        }
        snap = MeshSnapshot.capture(*mesh);
        foreach (ei; sel) {
            if (!mesh.setCreaseWeight(ei, weight_)) {
                // Earlier edges in `sel` may already have written through
                // setCreaseWeight before this one failed — restore the
                // mesh from the pre-apply snapshot BEFORE discarding it.
                // Discarding first (the old behaviour) left the mesh
                // half-changed with `snap.filled == false`, so revert()
                // below would no-op and the partial write became
                // permanent, with no undo entry to blame it on.
                snap.restore(*mesh);
                snap = MeshSnapshot.init;
                baseRefusal_ = "failed to write edge weight";
                return false;
            }
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}

version (unittest) {
    private View freshView() { return new View(0, 0, 1, 1); }
}

// Empty selection REFUSES (baseRefusal_ + return false) rather than
// silently applying to the whole mesh (§ module doc) — and rather than
// throwing out of the UI dispatch frame, which is what this test pinned
// before the SHOULD-FIX 1 rewrite (task 1062 review). Mutation: drop the
// `sel.length == 0` guard on either command → apply() succeeds against zero
// edges and both assertions below redden (the return value AND the reason).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    View v = freshView();

    auto setCmd = new EdgeCreaseSet(m, v, EditMode.Edges);
    assert(!setCmd.apply(),
        "mesh.edgeCrease.set must refuse (not throw) on an empty edge selection");
    assert(setCmd.refusalReason().length > 0,
        "a refusal without a reason renders as a SILENT no-op "
      ~ "(ui/command_notice.d) — the empty-selection case must say why");

    auto clearCmd = new EdgeCreaseClear(m, v, EditMode.Edges);
    assert(!clearCmd.apply(),
        "mesh.edgeCrease.clear must refuse (not throw) on an empty edge selection");
    assert(clearCmd.refusalReason().length > 0);
}

// Absolute set + undo round-trip: apply() writes to every selected edge
// (not just the first), revert() restores the PRIOR map exactly (including
// "the map did not exist before this call" — a snapshot taken before the
// map was ever created must restore to "no map").
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.buildLoops();
    m.syncSelection();
    // Two of the cube's 12 edges, by cage-vert pair (matches makeCube()'s
    // own vertex numbering — see mesh.d's makeCube doc).
    immutable uint e67 = m.edgeIndex(6, 7);
    immutable uint e23 = m.edgeIndex(2, 3);
    assert(e67 != ~0u && e23 != ~0u);
    m.selectEdge(cast(int) e67);
    m.selectEdge(cast(int) e23);

    View v = freshView();
    auto c = new EdgeCreaseSet(m, v, EditMode.Edges);
    c.weight_ = 0.3f;
    assert(c.apply());
    assert(m.creaseWeightMap() !is null,
        "apply() must create the reserved crease map on first use");
    assert(m.edgeCreaseWeight(e67) == 0.3f, "weight not written to edge 67");
    assert(m.edgeCreaseWeight(e23) == 0.3f, "weight not written to edge 23"
        ~ " — apply() must write EVERY selected edge, not just the first");
    // Unselected edges are untouched (stay at the zero-fill default).
    immutable uint eOther = m.edgeIndex(0, 1);
    assert(m.edgeCreaseWeight(eOther) == 0.0f);

    assert(c.revert());
    assert(m.creaseWeightMap() is null,
        "revert() must restore 'no crease map ever existed' — the snapshot "
      ~ "was captured before EdgeCreaseSet created the map");
}

// mesh.edgeCrease.clear writes 0.0 (a real stored value that behaves as no
// crease) rather than removing the map entirely — the map registration
// itself is undo-visible state, not something clear() should discard.
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.buildLoops();
    m.syncSelection();
    immutable uint e67 = m.edgeIndex(6, 7);
    m.selectEdge(cast(int) e67);

    View v = freshView();
    auto setCmd = new EdgeCreaseSet(m, v, EditMode.Edges);
    setCmd.weight_ = 0.8f;
    assert(setCmd.apply());
    assert(m.edgeCreaseWeight(e67) == 0.8f);

    m.clearEdgeSelection();
    m.selectEdge(cast(int) e67);
    auto clearCmd = new EdgeCreaseClear(m, v, EditMode.Edges);
    assert(clearCmd.apply());
    assert(m.creaseWeightMap() !is null,
        "clear() must NOT remove the reserved map, only zero the value");
    assert(m.edgeCreaseWeight(e67) == 0.0f);
}

// Partial-mutation safety: when a LATER edge in the selection fails to
// write, apply() must restore the mesh from the pre-apply snapshot before
// returning — not just discard the snapshot and leave the EARLIER edges'
// already-landed writes standing with no way back (SHOULD-FIX 2, task 1062
// review). `setCreaseWeight` only fails on an out-of-bounds map index, which
// cannot happen through normal use (the resize hook keeps the map's length
// in lock-step with `edges.length`) — so this test corrupts the map's
// length directly to force a deterministic mid-loop failure on the SECOND
// selected edge. Mutation: delete the `snap.restore(*mesh)` call ahead of
// `snap = MeshSnapshot.init` → e23's write stays at 0.3 after the failed
// apply() instead of reverting to 0.0, and this reddens on the
// `edgeCreaseWeight(e23)` assertion below (verified 2026-08-17).
unittest {
    auto m = new Mesh;
    *m = makeCube();
    m.buildLoops();
    m.syncSelection();
    immutable uint e67 = m.edgeIndex(6, 7);   // ascending edge index 6
    immutable uint e23 = m.edgeIndex(2, 3);   // ascending edge index 1
    assert(e67 != ~0u && e23 != ~0u);
    assert(e23 < e67,
        "fixture assumption: e23 is processed before e67 by "
      ~ "selectedEdgeIndices' ascending scan");
    m.selectEdge(cast(int) e67);
    m.selectEdge(cast(int) e23);

    // Pre-create the crease map, then truncate its data array so the FIRST
    // selected edge (e23) is still in bounds but the SECOND (e67) is not.
    auto map = m.addMeshMapOfKind(MapKind.creaseWeight);
    assert(map !is null);
    map.data.length = e67;   // in range for e23 (< e67), out of range for e67

    View v = freshView();
    auto c = new EdgeCreaseSet(m, v, EditMode.Edges);
    c.weight_ = 0.3f;
    assert(!c.apply(),
        "apply() must refuse when a selected edge's write fails mid-loop");
    assert(c.refusalReason().length > 0);

    // The mesh must be back to a sound PRE-apply state — not left with
    // e23's write standing and the snapshot thrown away. (The map's length
    // comes back at `edges.length`, not the corrupted length used to force
    // the failure: `MeshSnapshot.restore` heals map lengths via
    // `resizeAllMeshMaps` rather than trusting the snapshot's raw length —
    // the invariant that matters is "every map matches `edges.length`",
    // which the corrupted setup above deliberately violated.)
    assert(m.creaseWeightMap().data.length == m.edges.length,
        "a restored map must match edges.length, healed by resizeAllMeshMaps");
    assert(m.edgeCreaseWeight(e23) == 0.0f,
        "e23's write (which succeeded before e67 failed) must be rolled "
      ~ "back by restoring the snapshot, not left standing with the "
      ~ "snapshot discarded and no way to undo it");
}

class EdgeCreaseClear : Command {
    private MeshSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.edgeCrease.clear"; }
    override string label() const { return "Clear Edge Crease"; }

    override Param[] params() { return []; }

    override bool apply() {
        baseRefusal_ = "";
        auto sel = selectedEdgeIndices(*mesh);
        if (sel.length == 0) {
            baseRefusal_ = "no edges selected";
            return false;
        }
        snap = MeshSnapshot.capture(*mesh);
        foreach (ei; sel) {
            // 0.0 is a real stored value that behaves as no crease (fixture
            // law.storage) — this is NOT the same code path as
            // removeMeshMap; the reserved map stays registered.
            if (!mesh.setCreaseWeight(ei, 0.0f)) {
                // See EdgeCreaseSet.apply() above for why restore must
                // happen before the snapshot is discarded.
                snap.restore(*mesh);
                snap = MeshSnapshot.init;
                baseRefusal_ = "failed to clear edge weight";
                return false;
            }
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
