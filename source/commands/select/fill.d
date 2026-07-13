module commands.select.fill;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

// ---------------------------------------------------------------------------
// select.fill.holes — face selection → face selection.
//
// Thin wrapper around `Mesh.fillSelectionHoles` (task 0386, the local
// quad-remesh auto-fill heuristic — see mesh.d's doc comment on that
// function): grows the current FACE selection to swallow small, fully
// enclosed unselected islands ("holes" left by a user who missed a few
// interior faces). Do NOT duplicate the enclosure/size heuristic here —
// both this command and the 0386 remesh call the one shared helper.
//
// Undo: SelectionSnapshot, same mechanism as select.expand / select.more /
// select.connect (Command's default CmdFlags.Model — undoable, Model-undo
// class — is left un-overridden, exactly like that family).
// ---------------------------------------------------------------------------
class SelectFillHoles : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.fill.holes"; }

    override bool apply() {
        snap = SelectionSnapshot.capture(*mesh);
        mesh.syncSelection();
        auto filled = mesh.fillSelectionHoles(mesh.selectedFaces);
        mesh.setFacesSelectedFrom(filled);
        return true;
    }
}

// ---------------------------------------------------------------------------
// select.fill.insideLoop — edge selection → face selection.
//
// The selected EDGES are treated as a barrier. Flood-filling face adjacency
// while never crossing a barrier edge partitions the mesh's faces into
// regions separated by the loop; this command selects the "inside" one and
// switches to Polygons mode. This is NEW and DIFFERENT from
// `select.convert`'s edgeToPoly (which selects faces whose ALL edges are
// selected — empty for a perimeter loop; that rule answers "which faces are
// bounded ONLY by selected edges", not "which faces are enclosed BY the
// loop").
//
// Region partition: build a face→face adjacency graph that only links two
// faces across an edge that is NOT part of the barrier (`Mesh.buildEdgeFaces`
// supplies the per-edge face pair; the free `edgeKey` function — the same
// canonical (min,max) packing `buildEdgeFaces` uses internally — looks an
// edge up in both the barrier set and that map). Flood-filling this graph
// over ALL faces (`Mesh.faceComponentsOf`, the same connected-components
// helper `fillSelectionHoles` uses) yields the regions the barrier carves
// the mesh into.
//
// Choosing "inside": a region "reaches the mesh's true open boundary" when
// one of its faces has an edge bordering exactly one face MESH-WIDE
// (`buildEdgeFaces`'s "-1" slot) — independent of whether that edge happens
// to be part of the barrier.
//   * exactly one region does NOT reach the open boundary -> select it (the
//     common case: a loop on an open mesh separates a bounded interior from
//     the rest, and "the rest" always reaches the mesh's real edge).
//   * 2+ regions don't reach it (a fully CLOSED mesh, where neither side of
//     the loop ever reaches an open boundary because there isn't one, or
//     several disjoint barrier loops each enclosing their own region) ->
//     pick the SMALLEST of them by face count. Same tie-break spirit as
//     `select.fill.holes`'s own "smaller than the rest" rule.
//   * 0 regions qualify (the barrier fails to separate the mesh into more
//     than one piece at all — an open polyline, a spur, a non-closed
//     selection, or no edges selected) -> REJECTED as a no-op: selection and
//     edit mode are left exactly as they were. Chosen over "select
//     everything reachable" because that fallback would silently select
//     almost the entire mesh on the single most likely user mistake (an
//     unclosed loop) — a paint-bucket-style leak. A fill should only ever
//     fire on a genuine enclosure.
//
// Undo: SelectionSnapshot for the geometry selection, same mechanism as the
// rest of the select.* growth family (Command's default CmdFlags.Model is
// left un-overridden). The EditMode switch to Polygons is ALSO undone
// (tracked separately, since SelectionSnapshot does not capture EditMode) —
// routed through the same promoteGeometryType hook select.convert uses, so
// SelType's recent-ordering stays in lockstep on both apply and revert.
// ---------------------------------------------------------------------------
class SelectFillInsideLoop : Command {
    private SelectionSnapshot       snap;
    private EditMode                priorEditMode;
    private bool                    modeSwitched;
    private EditMode*               editModePtr;
    private void delegate(EditMode) promoteType;

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        if (modeSwitched && editModePtr !is null) {
            if (promoteType !is null) promoteType(priorEditMode);
            else                      *editModePtr = priorEditMode;
        }
        return true;
    }

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name() const { return "select.fill.insideLoop"; }

    // Lockstep hook with the app's geometry-type funnel (mirrors
    // select.convert's setPromoteHook). Optional: a headless/unit-test
    // construction without a hook falls back to writing *editModePtr
    // directly.
    SelectFillInsideLoop setPromoteHook(void delegate(EditMode) h) { promoteType = h; return this; }

    override bool apply() {
        snap = SelectionSnapshot.capture(*mesh);
        priorEditMode = editModePtr !is null ? *editModePtr : editMode;
        mesh.syncSelection();

        const size_t nf = mesh.faces.length;
        if (nf == 0) return true;

        // Barrier: canonical (min,max) key of every selected edge.
        bool[ulong] barrier;
        foreach (ei, sel; mesh.selectedEdges) {
            if (!sel) continue;
            auto e = mesh.edges[ei];
            barrier[edgeKey(e[0], e[1])] = true;
        }
        if (barrier.length == 0) return true; // nothing to fill from

        auto edgeFaces = mesh.buildEdgeFaces();

        // Face adjacency crossing only NON-barrier edges.
        auto faceAdj = new int[][](nf);
        foreach (fi; 0 .. nf) {
            auto face = mesh.faces[fi];
            const size_t n = face.length;
            foreach (k; 0 .. n) {
                const ulong key = edgeKey(face[k], face[(k + 1) % n]);
                if ((key in barrier) !is null) continue; // never cross the barrier
                auto p = key in edgeFaces;
                if (p is null) continue; // defensive — shouldn't happen
                const int other = (*p)[0] == cast(int) fi ? (*p)[1] : (*p)[0];
                if (other >= 0) faceAdj[fi] ~= other;
            }
        }

        auto wantAll = new bool[](nf);
        wantAll[] = true;
        auto regions = Mesh.faceComponentsOf(wantAll, faceAdj);
        if (regions.length < 2) return true; // barrier doesn't separate anything -- no-op

        // A region "reaches the true open boundary" iff one of its faces has
        // an edge bordering exactly one face mesh-wide -- regardless of
        // whether that edge is itself part of the barrier.
        bool reachesBoundary(const(uint)[] region) {
            foreach (fi; region) {
                auto face = mesh.faces[fi];
                const size_t n = face.length;
                foreach (k; 0 .. n) {
                    const ulong key = edgeKey(face[k], face[(k + 1) % n]);
                    auto p = key in edgeFaces;
                    if (p !is null && (*p)[1] == -1) return true;
                }
            }
            return false;
        }

        size_t chosen     = size_t.max;
        size_t chosenSize = size_t.max;
        foreach (ri, region; regions) {
            if (reachesBoundary(region)) continue;
            if (chosen == size_t.max || region.length < chosenSize) {
                chosen     = ri;
                chosenSize = region.length;
            }
        }
        if (chosen == size_t.max) return true; // no enclosed candidate -- no-op

        auto faceSel = new bool[](nf);
        foreach (fi; regions[chosen]) faceSel[fi] = true;

        mesh.clearEdgeSelection();
        mesh.setFacesSelectedFrom(faceSel);

        modeSwitched = true;
        if (editModePtr !is null) {
            if (promoteType !is null) promoteType(EditMode.Polygons);
            else                      *editModePtr = EditMode.Polygons;
        }
        return true;
    }
}
