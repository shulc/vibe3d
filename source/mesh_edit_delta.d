module mesh_edit_delta;

// ---------------------------------------------------------------------------
// Mesh-edit change tracker — per-mutation operation-log undo (Phase 1 core).
//
// This module is the foundation for operation-inverse topology undo: instead
// of snapshotting the WHOLE mesh per command (the MeshSnapshot model), a
// topology op records an ORDERED log of element-level mutations AS THEY RUN
// (verts added/removed, faces added/removed/reshaped, the index permutation
// each compaction applied, plus sparse selection/subpatch/material deltas).
// Undo inverts exactly that log in LIFO order; both capture and replay are
// O(delta), never O(mesh).
//
// PHASE 1 ships PROVEN INFRA with NO op wired. The mesh-mutation hooks below
// (installed in source/mesh.d) are inert unless a batch is explicitly open:
// their first action is `if (editRecorder_ is null) return;`, so existing
// behavior and interactive-drag perf are completely unchanged. A batch is
// opened only by the unit tests this phase, via Mesh.beginEditBatch.
//
// MIT-clean naming: this is vibe3d-native infrastructure. No proprietary /
// SDK symbol names appear here — provenance lives in doc/ + agent memory.
// ---------------------------------------------------------------------------

import std.array : insertInPlace;

import mesh;            // Mesh, Marks, edgeKey (mutual import — see note below)
import math : Vec3;

// NOTE on the mesh <-> mesh_edit_delta mutual import: D handles mutual module
// imports fine; there is no module-ctor cycle here (these are plain structs +
// free logic, no static this()). mesh.d holds a `MeshEditTracker*` and calls
// the recorder's `record*` methods from its mutation primitives; this module's
// apply()/revert() take `ref Mesh`. Neither references the other at static-init.

// ---------------------------------------------------------------------------
// Change-scope bitfield — declared at beginEditBatch to describe the kinds of
// mutation a batch covers. Advisory in Ph1 (the log is self-describing); kept
// so commands can surface change scope later.
// ---------------------------------------------------------------------------
enum MeshEditScope : uint {
    None     = 0,
    Position = 1 << 0,  // vertex coords moved (no count change)
    Points   = 1 << 1,  // verts added / removed
    Polygons = 1 << 2,  // faces added / removed / reshaped
    Marks    = 1 << 3,  // selection + subpatch bits, order arrays, counters
    Material = 1 << 4,  // faceMaterial[] / surfaces[]
    Geometry = Points | Polygons,
}

// ---------------------------------------------------------------------------
// One recorded mutation. The op-log is an ordered array of these; revert plays
// it LIFO, each entry inverting itself. Only the fields relevant to a given
// `kind` are populated (the rest stay empty) — a tagged record, not a true
// union, kept simple for Ph1.
// ---------------------------------------------------------------------------
struct MeshOpEntry {
    enum Kind : ubyte {
        AddVerts,       // vIdx = [V0..V1); pos = appended positions
        RemoveVerts,    // vIdx = removed indices (pre-removal space); pos = positions
        SetPos,         // vIdx = moved indices; posBefore / posAfter (reserved Ph1)
        AddFaces,       // fIdx = [F0..F1); faceLists = appended vertex-lists
        RemoveFaces,    // fIdx = removed indices; faceLists; faceMat; facePrt; faceSub
        ReshapeFaces,   // fIdx; faceListsBefore / faceListsAfter
        Reindex,        // perm = old->new vertex remap (~0u = dropped)
        SelectionDelta, // markIdx + markBefore / markAfter (Select bit, by element)
        SubpatchDelta,  // markIdx + markBefore / markAfter (Subpatch bit, by face)
        MaterialDelta,  // markIdx + markBefore / markAfter (faceMaterial[], by face)
        EdgeSelByEnds,  // edge selection keyed by VERTEX-INDEX endpoint pairs,
                        //   re-applied through edgeIndexMap AFTER finalize rebuilds
                        //   edges (edge indices are unstable across rebuildEdges,
                        //   so this is endpoint-keyed — doc §1.3). The vertex
                        //   indices are in the space that finalize restores, so
                        //   forward uses `edgeEndsAfter`, reverse `edgeEndsBefore`.
        MeshMapDelta,   // reserved — deferred (Q4)
    }
    Kind kind;

    // Domain on which a SelectionDelta operates (Select bit lives on every
    // element type; the delta names which array to patch).
    enum SelDomain : ubyte { Vertex, Edge, Face }
    SelDomain selDomain;

    uint[]    vIdx, fIdx;
    Vec3[]    pos, posBefore, posAfter;
    uint[][]  faceLists, faceListsBefore, faceListsAfter;
    uint[]    faceMat;                 // RemoveFaces: per-face material
    uint[]    facePrt;                 // RemoveFaces: per-face part id
    uint[]    faceSub;                 // RemoveFaces: per-face subpatch bit (0/1)
    uint[]    perm;                    // Reindex: old->new remap

    // Sparse marks/subpatch/material deltas. For SelectionDelta the element
    // index is into the array named by `selDomain`; before/after hold the
    // whole mark word (so the order-counter restore is the snapshot-style
    // whole-array restore below, not folded here). For Subpatch/Material the
    // value is the bit / material id.
    uint[]    markIdx, markBefore, markAfter;

    // EdgeSelByEnds: edge selection keyed by vertex-index endpoint pairs (flat
    // [a0,b0, a1,b1, …]). Applied post-finalize via edgeIndexMap. before = the
    // selection restored on revert; after = the selection restored on apply/redo.
    uint[]    edgeEndsBefore, edgeEndsAfter;
}

// ---------------------------------------------------------------------------
// MeshEditDelta — the net, invertible record of one finished edit batch.
// apply() = forward replay; revert() = LIFO inverse replay.
// ---------------------------------------------------------------------------
struct MeshEditDelta {
    MeshEditScope scope_;
    MeshOpEntry[] log;       // execution order; revert plays backward

    bool isEmpty() const { return log.length == 0; }

    // Approximate stored byte size — for the Ph3 "is the delta smaller than a
    // snapshot?" gate. Counts the heap-backed arrays' element bytes.
    size_t byteSize() const {
        size_t n = 0;
        foreach (ref e; log) {
            n += e.vIdx.length * uint.sizeof;
            n += e.fIdx.length * uint.sizeof;
            n += e.pos.length * Vec3.sizeof;
            n += e.posBefore.length * Vec3.sizeof;
            n += e.posAfter.length * Vec3.sizeof;
            foreach (ref l; e.faceLists)        n += l.length * uint.sizeof;
            foreach (ref l; e.faceListsBefore)  n += l.length * uint.sizeof;
            foreach (ref l; e.faceListsAfter)   n += l.length * uint.sizeof;
            n += e.faceMat.length * uint.sizeof;
            n += e.faceSub.length * uint.sizeof;
            n += e.perm.length * uint.sizeof;
            n += e.markIdx.length * uint.sizeof;
            n += e.markBefore.length * uint.sizeof;
            n += e.markAfter.length * uint.sizeof;
            n += e.edgeEndsBefore.length * uint.sizeof;
            n += e.edgeEndsAfter.length * uint.sizeof;
            n += MeshOpEntry.sizeof;
        }
        return n;
    }

    // Forward replay — redo. Plays the log in execution order; each entry
    // re-applies its forward effect, then finalize() re-derives edges/loops.
    bool apply(ref Mesh m) const {
        foreach (i, ref e; log) {
            // Compaction pair (RemoveVerts immediately followed by Reindex): the
            // Reindex's perm carries the FULL old->new map INCLUDING the dropped
            // (~0u) slots, so applyReindexForward both drops AND repacks. The
            // preceding RemoveVerts forward must therefore be a NO-OP — otherwise
            // it would drop the verts first, shifting indices out from under the
            // perm (which is keyed in the pre-drop index space) → corruption.
            // (RemoveVerts' positions are only needed on REVERSE, to re-insert.)
            if (e.kind == MeshOpEntry.Kind.RemoveVerts
                && i + 1 < log.length
                && log[i + 1].kind == MeshOpEntry.Kind.Reindex)
                continue;
            applyForward(m, e);
        }
        // Edge selection is endpoint-keyed and must be re-applied AFTER finalize
        // rebuilds the edge array + edgeIndexMap (edge indices are unstable
        // across rebuildEdges). On apply/redo we want the post-op selection.
        const(uint)[] edgeSel = null;
        bool haveEdgeSel = false;
        foreach (ref e; log)
            if (e.kind == MeshOpEntry.Kind.EdgeSelByEnds) {
                edgeSel = e.edgeEndsAfter;
                haveEdgeSel = true;
            }
        finalize(m, scope_, edgeSel, haveEdgeSel);
        return true;
    }

    // Reverse replay — undo. Plays the log LIFO; each entry inverts itself,
    // then finalize() re-derives edges/loops. See doc §2.3 for the extrude
    // reverse-composition trace this generalizes.
    bool revert(ref Mesh m) const {
        foreach_reverse (ref e; log)
            applyReverse(m, e);
        // On revert we want the pre-op (before) edge selection, re-applied after
        // finalize rebuilds edges (doc §1.3 / §2.3 step 1's endpoint-keyed part).
        const(uint)[] edgeSel = null;
        bool haveEdgeSel = false;
        foreach (ref e; log)
            if (e.kind == MeshOpEntry.Kind.EdgeSelByEnds) {
                edgeSel = e.edgeEndsBefore;
                haveEdgeSel = true;
            }
        finalize(m, scope_, edgeSel, haveEdgeSel);
        return true;
    }
}

// ---------------------------------------------------------------------------
// MeshEditTracker — the recorder. Installed on a Mesh while a batch is open
// (via Mesh.beginEditBatch); the hooked mutation primitives append entries to
// its log. finish() moves the log into a MeshEditDelta.
// ---------------------------------------------------------------------------
struct MeshEditTracker {
    private MeshOpEntry[] log_;
    private MeshEditScope declared_ = MeshEditScope.None;

    void declare(MeshEditScope s) { declared_ = s; }

    // --- Class P: per-primitive append hooks ------------------------------
    // addVertex appends one vertex; consecutive AddVerts coalesce into one
    // [V0..V1) range so a kernel that appends N verts logs ONE entry.
    void recordAddVert(uint idx, Vec3 p) {
        if (log_.length > 0) {
            auto last = &log_[$ - 1];
            if (last.kind == MeshOpEntry.Kind.AddVerts
                && last.vIdx.length == 1
                && last.vIdx[0] + last.pos.length - 1 == idx - 1) {
                // contiguous append onto the open AddVerts range
                last.pos ~= p;
                return;
            }
        }
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.AddVerts;
        e.vIdx = [idx];
        e.pos  = [p];
        log_ ~= e;
    }

    void recordAddVerts(uint v0, uint v1, in Vec3[] pos) {
        if (v1 <= v0) return;
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.AddVerts;
        e.vIdx = [v0];
        e.pos  = pos.dup;
        log_ ~= e;
    }

    void recordRemoveVerts(in uint[] idx, in Vec3[] pos) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.RemoveVerts;
        e.vIdx = idx.dup;
        e.pos  = pos.dup;
        log_ ~= e;
    }

    void recordSetPos(in uint[] idx, in Vec3[] before, in Vec3[] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.SetPos;
        e.vIdx      = idx.dup;
        e.posBefore = before.dup;
        e.posAfter  = after.dup;
        log_ ~= e;
    }

    // addFace / addFaceFast append one face; consecutive AddFaces coalesce.
    void recordAddFace(uint idx, in uint[] list) {
        if (log_.length > 0) {
            auto last = &log_[$ - 1];
            if (last.kind == MeshOpEntry.Kind.AddFaces
                && last.fIdx.length == 1
                && last.fIdx[0] + last.faceLists.length - 1 == idx - 1) {
                last.faceLists ~= list.dup;
                return;
            }
        }
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.AddFaces;
        e.fIdx      = [idx];
        e.faceLists = [list.dup];
        log_ ~= e;
    }

    void recordAddFaces(uint f0, uint f1, in uint[][] lists) {
        if (f1 <= f0) return;
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.AddFaces;
        e.fIdx      = [f0];
        e.faceLists = dupLists(lists);
        log_ ~= e;
    }

    // --- Class B: coarse bulk-op deltas -----------------------------------
    void recordRemoveFaces(in uint[] idx, in uint[][] lists, in uint[] mat, in uint[] prt, in uint[] sub) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.RemoveFaces;
        e.fIdx      = idx.dup;
        e.faceLists = dupLists(lists);
        e.faceMat   = mat.dup;
        e.facePrt   = prt.dup;
        e.faceSub   = sub.dup;
        log_ ~= e;
    }

    void recordReshapeFaces(in uint[] idx, in uint[][] before, in uint[][] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind            = MeshOpEntry.Kind.ReshapeFaces;
        e.fIdx            = idx.dup;
        e.faceListsBefore = dupLists(before);
        e.faceListsAfter  = dupLists(after);
        log_ ~= e;
    }

    // --- Class R: reindex permutation -------------------------------------
    void recordReindex(in uint[] perm) {
        if (perm.length == 0) return;
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.Reindex;
        e.perm = perm.dup;
        log_ ~= e;
    }

    // --- HP3: sparse selection / subpatch / material deltas ---------------
    void recordSelectionDelta(MeshOpEntry.SelDomain dom, in uint[] idx,
                              in uint[] before, in uint[] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind       = MeshOpEntry.Kind.SelectionDelta;
        e.selDomain  = dom;
        e.markIdx    = idx.dup;
        e.markBefore = before.dup;
        e.markAfter  = after.dup;
        log_ ~= e;
    }

    void recordSubpatchDelta(in uint[] idx, in uint[] before, in uint[] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind       = MeshOpEntry.Kind.SubpatchDelta;
        e.markIdx    = idx.dup;
        e.markBefore = before.dup;
        e.markAfter  = after.dup;
        log_ ~= e;
    }

    void recordMaterialDelta(in uint[] idx, in uint[] before, in uint[] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind       = MeshOpEntry.Kind.MaterialDelta;
        e.markIdx    = idx.dup;
        e.markBefore = before.dup;
        e.markAfter  = after.dup;
        log_ ~= e;
    }

    // Edge selection delta keyed by VERTEX-INDEX endpoint pairs (flat arrays
    // [a,b, a,b, …]). Edge indices are unstable across rebuildEdges, so the
    // selection is carried by endpoint and re-resolved through edgeIndexMap in
    // finalize. `before` = the edges to reselect on revert (the pre-op edge
    // selection, in the vertex-index space the revert restores); `after` = the
    // edges to reselect on apply/redo (the post-op selection, in the post-op
    // vertex-index space). An empty list on a side is a valid "clear" target.
    void recordEdgeSelByEnds(in uint[] before, in uint[] after) {
        MeshOpEntry e;
        e.kind           = MeshOpEntry.Kind.EdgeSelByEnds;
        e.edgeEndsBefore = before.dup;
        e.edgeEndsAfter  = after.dup;
        log_ ~= e;
    }

    bool isEmpty() const { return log_.length == 0; }

    // Move the accumulated log into a finished, invertible MeshEditDelta.
    MeshEditDelta finish() {
        MeshEditDelta d;
        d.scope_ = declared_;
        d.log    = log_;
        log_     = null;
        return d;
    }
}

// ===========================================================================
// Forward / reverse entry application. These are free functions (not Mesh
// methods) so the inverse machinery lives entirely in this module and can be
// stubbed by the unit test's negative control.
// ===========================================================================

private void applyForward(ref Mesh m, ref const MeshOpEntry e) {
    final switch (e.kind) {
        case MeshOpEntry.Kind.AddVerts:
            foreach (p; e.pos) m.vertices ~= p;
            break;
        case MeshOpEntry.Kind.RemoveVerts:
            // Forward: drop the listed verts (descending so indices stay valid).
            removeVertsForward(m, e.vIdx);
            break;
        case MeshOpEntry.Kind.SetPos:
            foreach (i, vi; e.vIdx)
                if (vi < m.vertices.length) m.vertices[vi] = e.posAfter[i];
            break;
        case MeshOpEntry.Kind.AddFaces:
            foreach (l; e.faceLists) m.faces ~= l.dup;
            break;
        case MeshOpEntry.Kind.RemoveFaces:
            removeFacesForward(m, e.fIdx);
            break;
        case MeshOpEntry.Kind.ReshapeFaces:
            foreach (i, fi; e.fIdx)
                if (fi < m.faces.length) m.faces[fi] = e.faceListsAfter[i].dup;
            break;
        case MeshOpEntry.Kind.Reindex:
            applyReindexForward(m, e.perm);
            break;
        case MeshOpEntry.Kind.SelectionDelta:
            patchSelection(m, e.selDomain, e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.SubpatchDelta:
            patchSubpatch(m, e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.MaterialDelta:
            patchMaterial(m, e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.EdgeSelByEnds:
            break; // handled in finalize (post-rebuildEdges, endpoint-keyed)
        case MeshOpEntry.Kind.MeshMapDelta:
            break; // deferred (Q4)
    }
}

private void applyReverse(ref Mesh m, ref const MeshOpEntry e) {
    final switch (e.kind) {
        case MeshOpEntry.Kind.AddVerts:
            // Inverse of append = truncate the tail [V0..V0+N).
            assert(e.vIdx.length == 1);
            const v0 = e.vIdx[0];
            if (v0 <= m.vertices.length)
                m.vertices.length = v0;
            break;
        case MeshOpEntry.Kind.RemoveVerts:
            // Inverse of drop = re-insert at the recorded (pre-removal) indices.
            removeVertsReverse(m, e.vIdx, e.pos);
            break;
        case MeshOpEntry.Kind.SetPos:
            foreach (i, vi; e.vIdx)
                if (vi < m.vertices.length) m.vertices[vi] = e.posBefore[i];
            break;
        case MeshOpEntry.Kind.AddFaces:
            assert(e.fIdx.length == 1);
            const f0 = e.fIdx[0];
            if (f0 <= m.faces.length)
                m.faces.length = f0;
            break;
        case MeshOpEntry.Kind.RemoveFaces:
            removeFacesReverse(m, e.fIdx, e.faceLists, e.faceMat, e.facePrt, e.faceSub);
            break;
        case MeshOpEntry.Kind.ReshapeFaces:
            // NEGATIVE CONTROL (test only): stub ReshapeFaces^-1 to a no-op
            // under -version=UndoNegControlReshape so the reshape round-trip
            // test (c) proves the in-place-reshape inverse is load-bearing.
            version (UndoNegControlReshape) {} else {
                foreach (i, fi; e.fIdx)
                    if (fi < m.faces.length) m.faces[fi] = e.faceListsBefore[i].dup;
            }
            break;
        case MeshOpEntry.Kind.Reindex:
            applyReindexReverse(m, e.perm);
            break;
        case MeshOpEntry.Kind.SelectionDelta:
            patchSelection(m, e.selDomain, e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.SubpatchDelta:
            patchSubpatch(m, e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.MaterialDelta:
            patchMaterial(m, e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.EdgeSelByEnds:
            break; // handled in finalize (post-rebuildEdges, endpoint-keyed)
        case MeshOpEntry.Kind.MeshMapDelta:
            break; // deferred (Q4)
    }
}

// ---------------------------------------------------------------------------
// Reindex — the crux (doc §2). `perm[old] = new` for kept verts, ~0u for
// dropped. The pair (RemoveVerts, Reindex) is recorded in that order by
// compactUnreferenced (drop-before-permute); LIFO reverse therefore runs
// Reindex^-1 first (restore the pre-compaction index space), then
// RemoveVerts^-1 (re-insert the dropped verts into the re-opened gaps).
// ---------------------------------------------------------------------------

// Forward: apply the compaction the kernel already did to the CURRENT mesh
// (rewrite face vids old->new, drop ~0u verts, repack vertices to new order).
// Used by redo (apply): on redo the verts are present at their pre-compaction
// positions (RemoveVerts^-1 + Reindex^-1 having been undone), so re-applying
// the recorded permutation reproduces the post-compaction state.
private void applyReindexForward(ref Mesh m, in uint[] perm) {
    if (perm.length == 0) return;
    // New vertex array sized to the count of kept slots.
    size_t kept = 0;
    foreach (p; perm) if (p != ~0u) ++kept;
    Vec3[] nv;
    nv.length = kept;
    foreach (old, p; perm) {
        if (p == ~0u) continue;
        if (old < m.vertices.length) nv[p] = m.vertices[old];
    }
    m.vertices = nv;
    // Rewrite face vertex ids old->new.
    foreach (ref f; m.faces)
        foreach (ref vid; f)
            if (vid < perm.length && perm[vid] != ~0u) vid = perm[vid];
}

// Reverse: restore the PRE-compaction index space. Grow `vertices` back to
// perm.length, placing the current (post-compaction) vert `new` back at its
// old index; dropped slots stay as gaps (Vec3.init) to be filled by the
// following RemoveVerts^-1. Face vids are rewritten new->old via the inverse
// permutation.
private void applyReindexReverse(ref Mesh m, in uint[] perm) {
    // NEGATIVE CONTROL (test only): stub Reindex^-1 to a no-op. Compiled in
    // ONLY under -version=UndoNegControlReindex so the compaction round-trip
    // test (b) can prove the permutation handling is load-bearing (the appended
    // verts/faces then truncate in the wrong index space → corrupted mesh).
    version (UndoNegControlReindex) return;
    if (perm.length == 0) return;
    Vec3[] nv;
    nv.length = perm.length;            // pre-compaction length (gaps included)
    foreach (old, p; perm) {
        if (p == ~0u) continue;         // dropped slot — gap, filled by RemoveVerts^-1
        if (p < m.vertices.length) nv[old] = m.vertices[p];
    }
    m.vertices = nv;
    // Inverse map: new -> old. Build it once, then rewrite face vids.
    uint[] inv;
    inv.length = m.vertices.length; // == perm.length now; safe upper bound for `new` ids
    // Initialise to identity-ish; only kept `new` slots matter.
    foreach (old, p; perm)
        if (p != ~0u && p < inv.length) inv[p] = cast(uint)old;
    foreach (ref f; m.faces)
        foreach (ref vid; f) {
            // A face vid here is a post-compaction `new` id; map back to old.
            // It must reference a kept vert, so inv[vid] is defined.
            if (vid < inv.length) vid = inv[vid];
        }
}

// ---------------------------------------------------------------------------
// RemoveVerts forward/reverse (used by RemoveVerts entries that are NOT the
// compaction pair — e.g. a future direct vert-removal op). The compaction
// path records RemoveVerts purely to carry the dropped positions; on reverse
// they are re-inserted into the gaps Reindex^-1 re-opened.
// ---------------------------------------------------------------------------

// Forward drop: remove the listed (sorted-ascending) indices from `vertices`.
private void removeVertsForward(ref Mesh m, in uint[] idx) {
    if (idx.length == 0) return;
    bool[] drop;
    drop.length = m.vertices.length;
    foreach (i; idx) if (i < drop.length) drop[i] = true;
    Vec3[] nv;
    nv.reserve(m.vertices.length);
    foreach (i, v; m.vertices) if (!drop[i]) nv ~= v;
    m.vertices = nv;
}

// Reverse: restore the dropped verts at their recorded (pre-removal) indices.
//
// Two cases compose here:
//  * After a preceding Reindex^-1 (the compaction pair, the common case),
//    `vertices` is ALREADY at pre-compaction length with the dropped slots
//    sitting as gaps — so we ASSIGN the recorded position into the existing
//    gap (NOT insert, which would double-grow the array).
//  * For a standalone RemoveVerts with no preceding Reindex (a future direct
//    removal op), the slot does not exist yet, so we INSERT.
// `idx` is ascending; low-to-high keeps later indices valid in the insert case.
private void removeVertsReverse(ref Mesh m, in uint[] idx, in Vec3[] pos) {
    foreach (i, vi; idx) {
        if (vi < m.vertices.length)
            m.vertices[vi] = pos[i];          // fill the gap re-opened by Reindex^-1
        else if (vi == m.vertices.length)
            m.vertices ~= pos[i];             // contiguous append at the tail
        else
            m.vertices.insertInPlace(vi, pos[i]); // standalone removal (no Reindex)
    }
}

// ---------------------------------------------------------------------------
// RemoveFaces forward/reverse.
// ---------------------------------------------------------------------------
private void removeFacesForward(ref Mesh m, in uint[] idx) {
    if (idx.length == 0) return;
    bool[] drop;
    drop.length = m.faces.length;
    foreach (i; idx) if (i < drop.length) drop[i] = true;
    uint[][] nf;
    nf.reserve(m.faces.length);
    foreach (i, ref f; m.faces) if (!drop[i]) nf ~= f.dup;
    m.faces = nf;
}

private void removeFacesReverse(ref Mesh m, in uint[] idx, in uint[][] lists,
                                in uint[] mat, in uint[] prt, in uint[] sub) {
    // NEGATIVE CONTROL (test only): stub RemoveFaces^-1 to a no-op under
    // -version=UndoNegControlRemoveFaces so the delete/remove round-trip proves
    // the face re-insertion inverse is load-bearing (without it the deleted
    // faces never come back on undo → face count diverges from the pre-op mesh).
    version (UndoNegControlRemoveFaces) return;
    // Insert ascending so later indices stay valid.
    foreach (i, fi; idx) {
        if (fi <= m.faces.length)
            m.faces.insertInPlace(fi, lists[i].dup);
    }
    // Restore parallel per-face arrays (material / part / subpatch) where carried.
    // The face selection/order arrays are restored by the SelectionDelta /
    // whole-array path, not here.
    if (mat.length == idx.length) {
        foreach (i, fi; idx) {
            if (fi < m.faceMaterial.length) {
                m.faceMaterial.insertInPlace(fi, mat[i]);
            }
        }
    }
    if (prt.length == idx.length) {
        foreach (i, fi; idx) {
            if (fi <= m.facePart.length)
                m.facePart.insertInPlace(fi, prt[i]);
        }
    } else {
        // prt not carried (old delta): insert 0u to keep length aligned.
        foreach (i, fi; idx) {
            if (fi <= m.facePart.length)
                m.facePart.insertInPlace(fi, 0u);
        }
    }
    if (sub.length == idx.length) {
        foreach (i, fi; idx)
            if (fi < m.faces.length)
                m.setFaceSubpatch(fi, sub[i] != 0);
    }
}

// ---------------------------------------------------------------------------
// Sparse mark patches. SelectionDelta carries the whole Select mark word per
// touched element; Subpatch/Material carry the bit / id.
// ---------------------------------------------------------------------------
private void patchSelection(ref Mesh m, MeshOpEntry.SelDomain dom,
                            in uint[] idx, in uint[] vals) {
    final switch (dom) {
        case MeshOpEntry.SelDomain.Vertex:
            foreach (i, e; idx) if (e < m.vertexMarks.length) setSelectBit(m.vertexMarks[e], vals[i]);
            break;
        case MeshOpEntry.SelDomain.Edge:
            foreach (i, e; idx) if (e < m.edgeMarks.length) setSelectBit(m.edgeMarks[e], vals[i]);
            break;
        case MeshOpEntry.SelDomain.Face:
            foreach (i, e; idx) if (e < m.faceMarks.length) setSelectBit(m.faceMarks[e], vals[i]);
            break;
    }
}

private void setSelectBit(ref uint word, uint on) {
    if (on) word |=  Mesh.Marks.Select;
    else    word &= ~Mesh.Marks.Select;
}

private void patchSubpatch(ref Mesh m, in uint[] idx, in uint[] vals) {
    foreach (i, e; idx)
        if (e < m.faceMarks.length)
            m.setFaceSubpatch(e, vals[i] != 0);
}

private void patchMaterial(ref Mesh m, in uint[] idx, in uint[] vals) {
    foreach (i, e; idx)
        if (e < m.faceMaterial.length)
            m.faceMaterial[e] = vals[i];
}

// ---------------------------------------------------------------------------
// finalize — the byte-identical tail of MeshSnapshot.restore (snapshot.d:97).
// Re-derive edges + loops + map lengths, bump both version counters ONCE.
// ---------------------------------------------------------------------------
private void finalize(ref Mesh m, MeshEditScope scope_,
                      in uint[] edgeSelEnds = null, bool haveEdgeSel = false) {
    // buildLoops() reads `edges` (it does NOT re-derive it), so rebuild the
    // deduplicated edge array from the restored faces FIRST — the same triplet
    // the topology mutators run, and the same canonical edge order the kernels
    // produce (so a revert is byte-identical to the pre-op edges). buildLoops
    // then rebuilds loops + edgeIndexMap from those edges.
    m.rebuildEdges();
    m.buildLoops();
    // Keep the per-element marks / order arrays length-correct with the
    // restored geometry (the same resize primitives the topology mutators run).
    // These GROW/SHRINK without clearing; the SelectionDelta entries restored
    // the actual bits, so this only fixes lengths after a count change.
    m.vertexMarks.length          = m.vertices.length;
    m.vertexSelectionOrder.length = m.vertices.length;
    m.edgeMarks.length            = m.edges.length;
    m.edgeSelectionOrder.length   = m.edges.length;
    m.faceMarks.length            = m.faces.length;
    m.faceSelectionOrder.length   = m.faces.length;
    m.faceMaterial.length         = m.faces.length;
    m.facePart.length             = m.faces.length;
    m.resizeAllMeshMaps();
    // Endpoint-keyed edge selection (doc §1.3). Applied here — AFTER rebuildEdges
    // re-derived `edges` + edgeIndexMap — because edge indices are unstable
    // across the rebuild. The vertex-index endpoints are in the space the replay
    // just restored, so edgeIndexMap resolves them to the live edge indices.
    if (haveEdgeSel) {
        // Clear the (length-resized, possibly stale) edge selection first so the
        // result is exactly the recorded set, not a superset.
        m.clearEdgeSelection();
        applyEdgeSelByEnds(m, edgeSelEnds);
    }
    // Change-notification (Stage 1): publish the delta's own change scope so
    // every tracked op AND its undo/redo emits its correct classes for free.
    // commitChange(scope_) bumps mutationVersion (always) and topologyVersion
    // (when scope_ carries a Geometry class). finalize ALWAYS rebuilds edges +
    // loops, so it ALWAYS bumped topologyVersion before — preserve that
    // unconditionally for the (currently impossible) non-Geometry tracked delta,
    // keeping the counters byte-identical to the old two raw bumps.
    m.commitChange(scope_);
    if (!(scope_ & MeshEditScope.Geometry)) ++m.topologyVersion;
}

// Re-select the edges named by the flat vertex-index endpoint pairs
// [a0,b0, a1,b1, …] through the freshly-rebuilt edgeIndexMap. An endpoint pair
// with no matching edge (geometry diverged) is silently skipped.
private void applyEdgeSelByEnds(ref Mesh m, in uint[] ends) {
    import mesh : edgeKey;
    for (size_t i = 0; i + 1 < ends.length; i += 2) {
        const a = ends[i], b = ends[i + 1];
        if (auto p = edgeKey(a, b) in m.edgeIndexMap)
            m.selectEdge(cast(int)*p);
    }
}

// ---------------------------------------------------------------------------
// Endpoint-keyed edge-selection capture/restore helpers, used by the delta-
// backed destructive commands (delete / remove) to round-trip the pre-op EDGE
// selection across a kernel that re-derives edges (doc §1.3). Edge indices are
// unstable across rebuildEdges, so the selection is carried by vertex-index
// endpoint pair and re-resolved through edgeIndexMap after the geometry is
// restored. Vertex/face selection stays index-keyed (those index spaces ARE
// restored exactly by the delta), so only edges need this.
// ---------------------------------------------------------------------------

// Flat [a0,b0, a1,b1, …] vertex-index endpoint pairs of the currently-selected
// edges. Empty when no edges are selected.
uint[] captureSelectedEdgeEnds(in Mesh m) {
    uint[] ends;
    auto sel = m.selectedEdges;            // bool[] indexed by edge
    foreach (ei; 0 .. m.edges.length) {
        if (ei < sel.length && sel[ei]) {
            ends ~= m.edges[ei][0];
            ends ~= m.edges[ei][1];
        }
    }
    return ends;
}

// Re-select the edges named by the flat endpoint pairs through the live
// edgeIndexMap. The caller is expected to have cleared the edge selection
// first (so the result is exactly the recorded set).
void restoreSelectedEdgeEnds(ref Mesh m, in uint[] ends) {
    for (size_t i = 0; i + 1 < ends.length; i += 2) {
        const a = ends[i], b = ends[i + 1];
        if (auto p = edgeKey(a, b) in m.edgeIndexMap)
            m.selectEdge(cast(int)*p);
    }
}

// ---------------------------------------------------------------------------
// Small helper.
// ---------------------------------------------------------------------------
private uint[][] dupLists(in uint[][] src) {
    uint[][] r;
    r.length = src.length;
    foreach (i, ref l; src) r[i] = l.dup;
    return r;
}
