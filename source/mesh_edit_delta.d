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
import mesh_selsets : selSetRekeyEdges, selSetGatherVertexMaskForward,
    selSetGatherVertexMaskReverse, selSetDropFilterVertexMask;
import mesh_planes : kNoSource, FaceSource, rewriteFaces;   // task 1902 Stage H —
    // FaceReindex forward replay is the primitive itself (plan §7.2: "one
    // implementation, so replay and live edit cannot drift"). No cycle:
    // mesh_planes.d does not import mesh_edit_delta.d.

// NOTE on the mesh <-> mesh_edit_delta mutual import: D handles mutual module
// imports fine; there is no module-ctor cycle here (these are plain structs +
// free logic, no static this()). mesh.d holds a `MeshEditTracker*` and calls
// the recorder's `record*` methods from its mutation primitives; this module's
// apply()/revert() take `ref Mesh`. Neither references the other at static-init.

// ---------------------------------------------------------------------------
// VIBE3D_UNDO_TRACKER toggle (doc/undo_change_tracker_plan.md, Phase 4 §D). When
// truthy (the DEFAULT) an interactive topology-tool commit records a
// MeshEditDelta (operation-log undo) instead of a before/after MeshSnapshot
// pair. `VIBE3D_UNDO_TRACKER=off` (and the other falsey values) is the ESCAPE
// HATCH that forces the snapshot path — byte-identical to pre-Phase-2 behavior.
// Read ONCE and cached — it is the rollback safety net + the parity-test lever.
// Single definition shared by every migrated command (edge-extrude, edge-extend,
// delete, remove) plus the `undo.tracker.on/off` test-automation commands.
// ---------------------------------------------------------------------------
private bool g_undoTrackerChecked = false;
private bool g_undoTrackerOn      = true;
bool undoTrackerEnabled() {
    if (!g_undoTrackerChecked) {
        import std.process : environment;
        import std.uni : toLower;
        g_undoTrackerChecked = true;
        auto v = environment.get("VIBE3D_UNDO_TRACKER", "");
        auto lv = v.toLower;
        // Default ON: unset ⇒ tracker. Only an explicit falsey value forces the
        // snapshot escape hatch. (Anything unrecognised stays ON.)
        g_undoTrackerOn = !(lv == "0" || lv == "off" || lv == "false" || lv == "no");
    }
    return g_undoTrackerOn;
}

// Test-automation override (the parity-gate lever): flip the cached toggle so a
// single running instance can run the SAME topology op + undo under both the
// snapshot path and the delta path. Marks the env as already-checked so the env
// read doesn't clobber the override on the next commit. Wired to the
// `undo.tracker.on/off` commands in app.d (test-automation only — not surfaced
// in the UI).
void setUndoTrackerEnabled(bool on) {
    g_undoTrackerChecked = true;
    g_undoTrackerOn      = on;
}

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
    // The per-element Hide bit (task 0613). A Marks-class change in every
    // other respect — but `Marks` is dominated by SELECTION, which fires on
    // every click and must never rebuild a GPU buffer, so a Hide cannot be
    // signalled through it alone: hidden geometry leaves the vertex / edge /
    // face buffers at UPLOAD time, so a hide is one of the few marks edits
    // that DOES require the buffers to be rebuilt.
    //
    // Its own class, for the same reason `Material` has one: a per-face
    // display attribute whose change needs a re-upload without a topology
    // edit. Publishers OR it alongside `Marks` (never instead of), so
    // consumers that key on Marks — the subpatch-preview gate, the marks
    // caches — are unaffected, and only the ones that opt in (see
    // display_sync.DisplayRefreshMask) act on it.
    Visibility = 1 << 5,
    // A per-element MAP value changed (task 1069). Its own class for the same
    // reason `Visibility` has one: a morph write moves no vertex and adds no
    // face, but the viewport draws base+delta (Phase 0, measured), so the GPU
    // buffers must be rebuilt. `Material` cannot stand in — it is the
    // per-face surface class and its consumers are a different set. Publishers
    // use it INSTEAD of Material for morph writes; the pre-existing
    // `setMeshMapValue` keeps publishing Material so no existing consumer
    // changes behaviour.
    Maps = 1 << 6,
    // The DISPLAY-ONLY twin of `Maps` (task 1073 / review B1). What the
    // viewport DRAWS changed because the morph ROUTING TARGET was bound or
    // unbound — but no saveable datum moved: the binding lives in app state
    // (`morph_target`), not in the document, and a `.v3d` written before and
    // after is byte-identical.
    //
    // It is a separate bit and not a flag on `Maps` because the ONE consumer
    // that must tell them apart cannot see anything else: `ChangeBus.flush`
    // is handed a bare `uint` of scope bits, and `docRevision()` — the
    // unsaved-changes counter behind the window-title asterisk and the
    // quit-time save prompt — is a sum over those counters. Publishing `Maps`
    // for a target change would mark a freshly-opened, unedited document
    // dirty the moment the user picked a morph to look at; publishing nothing
    // would leave the last-uploaded surface on screen (measured — see
    // `MorphSelect.publishTargetChange`). This bit is the third answer: it
    // rides `DisplayRefreshMask` exactly like `Maps`, and is counted by
    // NOTHING in `docRevision`.
    MapsDisplay = 1 << 7,
    Geometry = Points | Polygons,
}

// ---------------------------------------------------------------------------
// One recorded mutation. The op-log is an ordered array of these; revert plays
// it LIFO, each entry inverting itself. Only the fields relevant to a given
// `kind` are populated (the rest stay empty) — a tagged record, not a true
// union, kept simple for Ph1.
//
// THE INDEX SPACE OF AN ENTRY (task 0703). Every index an entry carries —
// `vIdx`, `fIdx`, `markIdx` — is in the space of the mesh **as it stands
// immediately BEFORE that entry runs forward**, i.e. after all PRECEDING
// entries have been applied and before this one has. Nothing is in the
// post-entry space. Consequences worth stating, because both were violated:
//
//   * `RemoveFaces.fIdx` is the PRE-drop index of each removed face, ascending.
//     That is the only space `removeFacesReverse` can invert: it re-inserts
//     ascending with `insertInPlace(fIdx)`, and inserting at the pre-drop index
//     is exactly what re-opens the slot each face vacated. A post-drop
//     ("the slot it would have occupied had it survived") index reads the same
//     for a SINGLE dropped face and diverges for two or more — two faces
//     dropped from the head both read 0, `insertInPlace(0)` runs twice, and
//     they come back reversed.
//   * a `ReshapeFaces` recorded AFTER a `RemoveFaces` in the same kernel is
//     still in the pre-op space, because `RemoveFaces⁻¹` has, by the time the
//     LIFO revert reaches the reshape, put every dropped face back and so
//     restored that very space.
//
// `AddFaces.fIdx` is the [F0,F1) tail range in the post-append space by
// construction (a tail append has no pre-image), which is the same rule read
// forward: F0 is the length of `faces` before the append.
// ---------------------------------------------------------------------------
struct MeshOpEntry {
    enum Kind : ubyte {
        AddVerts,       // vIdx = [V0..V1); pos = appended positions
        RemoveVerts,    // vIdx = removed indices (pre-removal space); pos = positions
        SetPos,         // vIdx = moved indices; posBefore / posAfter (reserved Ph1)
        AddFaces,       // fIdx = [F0..F1); faceLists = appended vertex-lists
        RemoveFaces,    // fIdx = removed indices (PRE-drop space, ascending —
                        //   see "THE INDEX SPACE OF AN ENTRY" above);
                        //   faceLists; faceMat; facePrt; faceSub
        ReshapeFaces,   // fIdx; faceListsBefore / faceListsAfter
        Reindex,        // perm = old->new vertex remap (~0u = dropped)
        FaceReindex,    // task 1902 Stage H — the face analogue of Reindex,
                        //   and mesh_planes.rewriteFaces's own op-log
                        //   publisher (doc/reindex_primitive_plan.md §7).
                        //   Forward: faceOldOfNew (newToOld correspondence,
                        //   mesh_planes.kNoSource = no ancestor) + newFaceLists
                        //   (the post-rewrite windings — NOT derivable from
                        //   faceOldOfNew alone: a duplicate/create face's
                        //   winding can use vertices its ancestor never had,
                        //   e.g. an array/mirror copy — a correction to §7.2's
                        //   field table, recorded in the task card) replay
                        //   through rewriteFaces itself. Reverse: the drop
                        //   set — fIdx (dropped OLD indices, ascending) /
                        //   faceLists / faceMat / facePrt / faceSub /
                        //   faceSetMsk / faceOrd, the SAME fields RemoveFaces
                        //   carries — for the old faces named by NO new face;
                        //   a SURVIVING old face (named by >=1 new face) is
                        //   restored from the CURRENT (post-reindex, i.e.
                        //   pre-reversal) mesh at its FIRST naming new index
                        //   instead, since that data is still live at
                        //   reverse-time and needs no separate capture.
                        //   oldFaceCount is NOT derivable as max(faceOldOfNew)+1
                        //   — the highest old index may itself be the one
                        //   dropped. DISARMED by default: no production
                        //   recorder sets MeshEditTracker.wantsFaceReindex, so
                        //   this kind is produced only by its own unittest.
        SelectionDelta, // markIdx + markBefore / markAfter (Select bit, by element)
        SubpatchDelta,  // markIdx + markBefore / markAfter (Subpatch bit, by face)
        HideDelta,      // markIdx + markBefore / markAfter (Hide bit, by face — task 0613)
        MaterialDelta,  // markIdx + markBefore / markAfter (faceMaterial[], by face)
        EdgeSelByEnds,  // edge selection keyed by VERTEX-INDEX endpoint pairs,
                        //   re-applied through edgeIndexMap AFTER finalize rebuilds
                        //   edges (edge indices are unstable across rebuildEdges,
                        //   so this is endpoint-keyed — doc §1.3). The vertex
                        //   indices are in the space that finalize restores, so
                        //   forward uses `edgeEndsAfter`, reverse `edgeEndsBefore`.
        MeshMapDelta,   // per-corner (PolyVertex) map values of the faces the
                        //   NEXT entry in forward order destroys — mapDims /
                        //   mapArity / mapVals below. Applies nothing itself
                        //   (see applyForward/applyReverse): the corner plane
                        //   cannot be written mid-replay, because `loops` is
                        //   only rebuilt in finalize. It is READ by
                        //   `CornerCarry`, which is the thing that places it.
    }
    Kind kind;

    // Domain on which a SelectionDelta operates (Select bit lives on every
    // element type; the delta names which array to patch).
    enum SelDomain : ubyte { Vertex, Edge, Face }
    SelDomain selDomain;

    uint[]    vIdx;
    // Task 0831 — `fIdx` is a `FaceIdx[]`, not a `uint[]`, so the space the
    // paragraph above states is now stated by the type as well: there is no
    // implicit `uint` → `FaceIdx`, and the scratch-array `.length` both 0703
    // kernels recorded is a compile error rather than a number that happens to
    // agree whenever exactly one face is dropped. See `FaceIdx` in mesh.d for
    // what the tag does and does not vouch for.
    FaceIdx[] fIdx;
    Vec3[]    pos, posBefore, posAfter;
    uint[][]  faceLists, faceListsBefore, faceListsAfter;
    uint[]    faceMat;                 // RemoveFaces / FaceReindex: per-face material
    uint[]    facePrt;                 // RemoveFaces / FaceReindex: per-face part id
    uint[]    faceSub;                 // RemoveFaces / FaceReindex: per-face subpatch bit (0/1)
    ulong[]   faceSetMsk;              // RemoveFaces / FaceReindex: per-face selection-set
                                        //   membership (task 1060, review SHOULD-FIX 4 —
                                        //   carried the same way facePrt is, not the
                                        //   earlier 0-insert)
    int[]     faceOrd;                 // RemoveFaces / FaceReindex: per-face faceSelectionOrder
                                        //   (task 1902 Stage H — RemoveFaces did not carry
                                        //   this before; a pre-existing gap the new kind
                                        //   must not inherit, plan §7.3)
    uint[]    perm;                    // Reindex: old->new remap

    // --- FaceReindex-only payload (task 1902 Stage H) ----------------------
    uint[]    faceOldOfNew;            // forward newToOld correspondence, one entry
                                        //   per NEW face; mesh_planes.kNoSource = no
                                        //   ancestor. fIdx/faceLists/faceMat/facePrt/
                                        //   faceSub/faceSetMsk/faceOrd above hold the
                                        //   DROP SET (old faces named by no new face).
    uint      oldFaceCount;            // pre-rewrite face count — NOT derivable as
                                        //   max(faceOldOfNew)+1, see the Kind doc above.
    uint[][]  newFaceLists;            // the post-rewrite windings passed to
                                        //   rewriteFaces at record time (see the Kind
                                        //   doc above for why this is needed).
    FaceIdx[] faceSurvivorIdx;         // review finding B2: ascending OLD indices of
                                        //   SURVIVING faces (named by >=1 new face) whose
                                        //   winding CHANGED across the rewrite — e.g.
                                        //   Mesh.removeVertsByMask drops a corner from a
                                        //   kept face's list while its old index still
                                        //   survives. A survivor whose winding did NOT
                                        //   change is cheaper to restore straight off the
                                        //   live (post-reindex) mesh at reverse time (see
                                        //   applyFaceReindexReverse), so this pair only
                                        //   ever holds the subset that actually differs —
                                        //   a WINDING payload, not a kFacePlanes plane
                                        //   (same exemption faceLists/newFaceLists get,
                                        //   tests/unit/mesh_planes_census_test.d).
    uint[][]  faceSurvivorLists;       // their PRE-rewrite windings, parallel to
                                        //   faceSurvivorIdx; captured by mesh_planes.
                                        //   rewriteFaces BEFORE it overwrites m.faces.

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

    // --- MeshMapDelta payload (task 0689) ---------------------------------
    // The per-corner (PolyVertex) map values of the faces the IMMEDIATELY
    // FOLLOWING entry destroys, captured by `Mesh.recordPolyVertexPayload` at
    // the last moment they are still readable.
    //
    //   mapDims  — `dim` of each PolyVertex map, in registration order. The
    //              replay refuses the payload unless the mesh still presents
    //              the same map set (count + dims), so a map added or removed
    //              between record and replay degrades to a zero-fill rather
    //              than shuffling one map's floats into another.
    //   mapArity — corner count of each face, POSITIONALLY parallel to the
    //              following entry's `fIdx` (a payload carries no face indices
    //              of its own — see recordPolyVertexPayload for why).
    //   mapVals  — face-major, then corner, then map: `Σ mapDims` floats per
    //              corner, `Σ mapArity` corners in total.
    ubyte[]   mapDims;
    uint[]    mapArity;
    float[]   mapVals;
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
            n += e.fIdx.length * FaceIdx.sizeof;
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
            n += e.mapDims.length * ubyte.sizeof;
            n += e.mapArity.length * uint.sizeof;
            n += e.mapVals.length * float.sizeof;
            n += MeshOpEntry.sizeof;
        }
        return n;
    }

    // Forward replay — redo. Plays the log in execution order; each entry
    // re-applies its forward effect, then finalize() re-derives edges/loops.
    bool apply(ref Mesh m) const {
        // Per-corner (PolyVertex) map carry — task 0689. Snapshotting the
        // provenance BEFORE the first entry is the whole point: from here on
        // `faces` moves and the live corner indices move with it.
        CornerCarry carry;
        carry.begin(m, log);
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
            carry.step(i, e, /*forward=*/true);
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
        finalize(m, scope_, edgeSel, haveEdgeSel, renumbersCorners(log), &carry);
        return true;
    }

    // Reverse replay — undo. Plays the log LIFO; each entry inverts itself,
    // then finalize() re-derives edges/loops. See doc §2.3 for the extrude
    // reverse-composition trace this generalizes.
    bool revert(ref Mesh m) const {
        CornerCarry carry;
        carry.begin(m, log);
        foreach_reverse (i, ref e; log) {
            carry.step(i, e, /*forward=*/false);
            applyReverse(m, e);
        }
        // On revert we want the pre-op (before) edge selection, re-applied after
        // finalize rebuilds edges (doc §1.3 / §2.3 step 1's endpoint-keyed part).
        const(uint)[] edgeSel = null;
        bool haveEdgeSel = false;
        foreach (ref e; log)
            if (e.kind == MeshOpEntry.Kind.EdgeSelByEnds) {
                edgeSel = e.edgeEndsBefore;
                haveEdgeSel = true;
            }
        finalize(m, scope_, edgeSel, haveEdgeSel, renumbersCorners(log), &carry);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Per-corner (PolyVertex) map handling for a replay — task 0689.
//
// THE LAW (both directions):
//
//   A replay carries the per-corner plane through the face mutations it
//   replays. Every corner whose face survives the replay keeps its own value;
//   every corner of a face the replay RE-CREATES takes the value the delta
//   recorded when that face was destroyed; every other new corner is zero.
//
// Zero for a genuinely new corner is deliberate and is the ONLY invented
// value allowed here: a merged polygon or an extrusion wall has no corner in
// the other state to inherit from, and making one up would be worse than an
// honest blank.
//
// WHY IT IS A SEPARATE PASS AND NOT PER-ENTRY. Corner `c` of face `fi` lives
// at loop index `faceLoop[fi] + c`, and `faceLoop`/`loops` are rebuilt only by
// `buildLoops`, which the replay runs ONCE at the end (`finalize`). So there
// is no moment mid-replay at which a per-corner value can be written to its
// final home — every entry that touches `faces` invalidates the addressing of
// every corner after it. `CornerCarry` therefore does what every kernel in
// mesh.d does: it tracks PROVENANCE while the faces move, and relocates the
// values ONCE, just before the tail `buildLoops` (which then sees a
// length-correct map and no-ops in `resizePolyVertexMaps`). `MeshMapDelta`
// entries are inert in applyForward/applyReverse for exactly this reason:
// they are read here, not applied there.
//
// It also reuses the vocabulary rather than inventing one: provenance is
// resolved into an `oldLoopOfNewLoop` array and handed to the shared
// `Mesh.remapPolyVertexMaps` funnel, with a second pass for the recorded
// values — the same two-pass shape as `Mesh.carryPolyVertexMaps` (task 0682).
//
// SAFETY. The carry declines — leaving `renumbersCorners`' stated drop in
// charge, i.e. exactly the pre-0689 behaviour — when it cannot be sure of
// itself: no PolyVertex map at all (the common case, and the whole thing is
// skipped), maps not in step with `faces` at entry, or a provenance array that
// ends up a different length from `faces` (which would mean the bookkeeping
// below stopped mirroring the real face mutations — the failure mode that
// makes this class of fix dangerous, so it is checked rather than assumed).
// ---------------------------------------------------------------------------
private struct CornerCarry {
    // Where ONE current face's corner values come from. Four cases, resolved
    // in this order per corner `j`:
    //   payload >= 0     — log[payload].mapVals, corner recBase + j (a face
    //                      the replay re-created: its values are in the delta,
    //                      not in the mesh).
    //   explicit !is null— the PRE-replay live corner explicit[j] (~0u = none).
    //                      Only built for an arity-CHANGING reshape, where the
    //                      slot-for-slot run breaks and corners have to be
    //                      matched by the vertex they stand on.
    //   liveBase != ~0u  — the PRE-replay live corner liveBase + j. The common
    //                      case: a face that came through untouched, or one
    //                      whose reshape kept its arity (its slots are stable
    //                      even when a corner is repointed at another vertex —
    //                      per-corner values are addressed by (face, corner)).
    //   otherwise        — no source ⇒ zero (a brand-new face).
    static struct Src {
        uint   liveBase = ~0u;
        uint   arity    = 0;
        uint[] explicit = null;
        int    payload  = -1;
        uint   recBase  = 0;
    }

    bool  active = false;
    Src[] src;
    const(MeshOpEntry)[] log;

    // Snapshot the provenance of the mesh AS IT IS NOW: every face's corners
    // come from its own corners. Declines when there is nothing to carry or
    // when the maps do not describe the current `faces`.
    void begin(ref Mesh m, const(MeshOpEntry)[] logIn) {
        log    = logIn;
        active = false;
        if (!m.hasPolyVertexMap()) return;
        if (!m.polyVertexMapsInStepWithFaces()) return;
        src.length = m.faces.length;
        uint run = 0;
        foreach (fi; 0 .. m.faces.length) {
            const uint a = cast(uint)m.faces[fi].length;
            src[fi] = Src(run, a, null, -1, 0);
            run += a;
        }
        active = true;
    }

    // The payload paired with the entry at `i`: the MeshMapDelta immediately
    // before it in FORWARD order, carrying one arity per face of `fIdx`. The
    // arity-count match is the guard against a payload drifting onto the wrong
    // entry — adjacency alone would silently mis-pair if a recorder ever
    // interleaved something between the two.
    private int payloadFor(size_t i, in FaceIdx[] fIdx) const {
        if (i == 0) return -1;
        const p = &log[i - 1];
        if (p.kind != MeshOpEntry.Kind.MeshMapDelta) return -1;
        if (p.mapArity.length != fIdx.length) return -1;
        return cast(int)(i - 1);
    }

    // Corner base of the `k`-th face inside a payload's `mapVals` (face-major).
    private static uint recBaseOf(in MeshOpEntry p, size_t k) {
        uint b = 0;
        foreach (i; 0 .. k) b += p.mapArity[i];
        return b;
    }

    // Resolve the PRE-replay live corner that currently backs slot `k` of this
    // face, or ~0u when it has none.
    private static uint liveCornerOf(in Src s, size_t k) {
        if (s.explicit !is null)
            return (k < s.explicit.length) ? s.explicit[k] : ~0u;
        if (s.liveBase == ~0u || k >= s.arity) return ~0u;
        return cast(uint)(s.liveBase + k);
    }

    // A face's corner list is replaced: `from` (what it is now) → `to`.
    // Equal arity keeps the slot-for-slot run — the documented convention that
    // per-corner values are addressed by (face, corner), which is what lets an
    // extrude repoint a neighbour's corner at its new inset vertex without
    // losing that corner's UV. A CHANGED arity breaks the run, so each new
    // corner is matched to the old corner standing on the SAME VERTEX (the
    // law mechanism (b) uses in mesh.d); anything unmatched gets no source.
    private static void reshapeSrc(ref Src s, const(uint)[] from, const(uint)[] to) {
        if (to.length == from.length) { s.arity = cast(uint)to.length; return; }
        uint[] ex;
        ex.length = to.length;
        ex[] = ~0u;
        if (s.payload < 0) {
            foreach (j, v; to) {
                foreach (k, u; from)
                    if (u == v) { ex[j] = liveCornerOf(s, k); break; }
            }
        }
        s.explicit = ex;
        s.liveBase = ~0u;
        s.payload  = -1;
        s.recBase  = 0;
        s.arity    = cast(uint)to.length;
    }

    // Mirror of removeFacesForward's drop-filter, on the provenance array.
    private void dropAt(in FaceIdx[] idx) {
        bool[] drop;
        drop.length = src.length;
        foreach (i; idx) if (i < drop.length) drop[i] = true;
        Src[] ns;
        ns.reserve(src.length);
        foreach (i, ref s; src) if (!drop[i]) ns ~= s;
        src = ns;
    }

    // Track ONE entry's effect on the face array, in the direction it is being
    // replayed. Every branch mirrors the corresponding branch of
    // applyForward / applyReverse EXACTLY — that correspondence is the whole
    // correctness argument, and `commit`'s length check is its backstop.
    void step(size_t i, ref const MeshOpEntry e, bool forward) {
        if (!active) return;
        switch (e.kind) {
            case MeshOpEntry.Kind.AddFaces:
                if (forward) {
                    foreach (l; e.faceLists)
                        src ~= Src(~0u, cast(uint)l.length, null, -1, 0);
                } else {
                    if (e.fIdx.length != 1) break;
                    const f0 = e.fIdx[0];
                    if (f0 <= src.length) src.length = f0;
                }
                break;
            case MeshOpEntry.Kind.RemoveFaces:
                if (forward) {
                    dropAt(e.fIdx);
                } else {
                    const int p = payloadFor(i, e.fIdx);
                    foreach (k, fi; e.fIdx) {
                        Src s;
                        s.arity = (k < e.faceLists.length)
                                ? cast(uint)e.faceLists[k].length : 0;
                        if (p >= 0) {
                            s.payload = p;
                            s.recBase = recBaseOf(log[p], k);
                            s.arity   = log[p].mapArity[k];
                        }
                        if (fi <= src.length) src.insertInPlace(fi, s);
                    }
                }
                break;
            case MeshOpEntry.Kind.ReshapeFaces:
                const int p = forward ? -1 : payloadFor(i, e.fIdx);
                foreach (k, fi; e.fIdx) {
                    if (fi >= src.length) continue;
                    if (k >= e.faceListsBefore.length || k >= e.faceListsAfter.length)
                        continue;
                    const(uint)[] before = e.faceListsBefore[k];
                    const(uint)[] after  = e.faceListsAfter[k];
                    if (p >= 0) {
                        // Reverse with a payload: the delta holds this face's
                        // pre-op corner values verbatim — strictly better than
                        // any match against the post-op list, and the only way
                        // to bring back a corner the forward op deleted.
                        src[fi] = Src(~0u, log[p].mapArity[k], null, p, recBaseOf(log[p], k));
                    } else if (forward) {
                        reshapeSrc(src[fi], before, after);
                    } else {
                        reshapeSrc(src[fi], after, before);
                    }
                }
                break;
            default:
                break;   // vertex-space, marks, edge-selection, payloads: no
                         // corner moves. A Reindex rewrites the vertex id
                         // INSIDE a corner without moving the corner.
        }
    }

    // Relocate the per-corner plane onto the replayed faces. MUST run before
    // the tail rebuildEdges()/buildLoops(), while the maps are still in the
    // pre-replay corner space. Deactivates itself (leaving the caller's drop in
    // charge) if the provenance array stopped matching `faces`.
    void commit(ref Mesh m) {
        if (!active) return;
        if (src.length != m.faces.length) { active = false; return; }

        // One resolved restore: which new corner run, from which payload.
        static struct Restore { size_t newLoop; int payload; uint recBase; uint n; }

        size_t total = 0;
        foreach (fi; 0 .. m.faces.length) total += m.faces[fi].length;

        uint[] oldLoopOfNewLoop;
        oldLoopOfNewLoop.length = total;
        Restore[] restores;
        size_t w = 0;
        foreach (fi; 0 .. m.faces.length) {
            const size_t a = m.faces[fi].length;
            const Src s = src[fi];
            if (s.payload >= 0) {
                oldLoopOfNewLoop[w .. w + a] = ~0u;
                restores ~= Restore(w, s.payload, s.recBase,
                                    cast(uint)((a < s.arity) ? a : s.arity));
            } else {
                foreach (j; 0 .. a) oldLoopOfNewLoop[w + j] = liveCornerOf(s, j);
            }
            w += a;
        }

        m.remapPolyVertexMaps(oldLoopOfNewLoop);

        foreach (ref r; restores) {
            const p = &log[r.payload];
            size_t stride = 0;
            foreach (d; p.mapDims) stride += d;
            if (stride == 0) continue;
            // The map set must still be the one the payload was captured
            // against — same count, same dims, same order. Otherwise the flat
            // block would be sliced into the wrong channels.
            size_t k = 0;
            bool ok = true;
            foreach (ref mm; m.meshMaps) {
                if (mm.domain != MapDomain.PolyVertex) continue;
                if (k >= p.mapDims.length || p.mapDims[k] != mm.dim) { ok = false; break; }
                ++k;
            }
            if (!ok || k != p.mapDims.length) continue;
            foreach (j; 0 .. r.n) {
                const size_t rc = cast(size_t)(r.recBase + j) * stride;
                if (rc + stride > p.mapVals.length) break;
                size_t off = 0;
                foreach (ref mm; m.meshMaps) {
                    if (mm.domain != MapDomain.PolyVertex) continue;
                    const size_t dst = (r.newLoop + j) * mm.dim;
                    if (dst + mm.dim <= mm.data.length)
                        mm.data[dst .. dst + mm.dim] = p.mapVals[rc + off .. rc + off + mm.dim];
                    off += mm.dim;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Does this log RENUMBER corners? The fallback question, asked only when the
// carry above declined: a replay that re-slots corners and cannot relocate
// their values must STATE the drop rather than leave it to a coincidence of
// lengths. `resizePolyVertexMaps` (inside `buildLoops`) zeroes the map when the
// corner TOTAL changed and KEEPS it when it did not — and a replay CAN renumber
// corners while keeping their total (drop a face, append one of the same arity
// — `removeEdgesByMask`'s RemoveFaces+AddFaces pair is that shape), leaving
// every value in place while the faces beneath it move: face 1 wears face 0's
// UV. Measured, not argued (tests/test_uv_undo_delta.d).
//
// What counts as a renumbering:
//
//   * AddFaces / RemoveFaces — a face inserted or dropped re-slots every
//     corner after it (and, on a tail append, adds corners with no source).
//   * ReshapeFaces that CHANGES a face's arity — every corner after that face
//     shifts by the difference.
//
// and what deliberately does NOT:
//
//   * ReshapeFaces at EQUAL arity — the face keeps its slots and its corner
//     count; only the VERTEX each corner points at changes (edge/face extrude
//     repointing a neighbour at its new inset vertex). Per-corner values are
//     addressed by (face, corner), so they stay valid, and dropping them here
//     would lose UV the kernel itself preserved.
//   * AddVerts / RemoveVerts / Reindex / SetPos — vertex-space edits. A
//     Reindex rewrites the vertex id INSIDE each corner without moving any
//     corner, so the per-corner plane is untouched.
//   * the mark / material / edge-selection deltas and the map payloads — no
//     geometry at all.
//
// Residual, unchanged by task 0689: an equal-arity reshape that PERMUTES one
// face's corner order (a winding reversal) keeps the slots but changes what
// sits under them, and neither this predicate nor the slot-for-slot run in
// `CornerCarry.reshapeSrc` notices. Nothing wired to the tracker records that
// today (`mesh.flip` is snapshot-only — see commands/mesh/flip.d).
// ---------------------------------------------------------------------------
private bool renumbersCorners(in MeshOpEntry[] log) {
    foreach (ref e; log) {
        switch (e.kind) {
            case MeshOpEntry.Kind.AddFaces:
            case MeshOpEntry.Kind.RemoveFaces:
                return true;
            case MeshOpEntry.Kind.FaceReindex:
                // Review finding S5, correcting this comment's earlier claim
                // (measured, not inspected — both halves below were verified
                // live by mutation, task 1902 Stage H review, 2026-08-25).
                // This `case` is NOT what keeps a FaceReindex corner-safe:
                // deleting this one line (letting FaceReindex fall through to
                // `default: break;`, i.e. answer `false`) leaves the full
                // `--config=tests` lane green. What IS load-bearing is the
                // pair of unconditional
                // `m.dropCornerProvenance(CornerDrop.DeltaReplayDeclined)`
                // calls inside `applyFaceReindexForward`/`applyFaceReindexReverse`
                // themselves — deleting BOTH of those reddens `mesh.d`'s own
                // `debug assert(false, "corner provenance: a face rewrite
                // reached buildLoops without declaring …")` at the tail of
                // `resizePolyVertexMaps()` (task 0901's "closed census"
                // assert: reaching that fallback loop AT ALL, once every
                // kernel is meant to declare, is itself the failure it
                // guards). Mechanism: each `dropCornerProvenance` call runs,
                // per entry, well before `finalize()`'s tail ever asks THIS
                // predicate anything, and sets `pendingCornerProvenance_` to
                // a `Dropped` declaration. `finalize()` then calls
                // `buildLoops()`, which consumes that declaration inside
                // `resizePolyVertexMaps()` and returns from its FIRST branch
                // (`decl.kind() == Dropped`) — before `finalize()` even
                // reaches its own `if (!carried && cornersRenumbered)
                // m.dropPolyVertexMaps();` line below, and before
                // `resizePolyVertexMaps()`'s own length-insurance tail loop
                // (where the assert above lives) is ever reached. Remove
                // BOTH declarations and neither `decl.declared()` nor
                // `wasArmed` is ever true (no site here opens
                // `beginCornerRewrite()`), so control falls through every
                // earlier branch into that tail loop — which is exactly the
                // state task 0901 declared unreachable. Kept `true` here
                // anyway, belt-and-braces, for a hypothetical future path
                // that reaches `finalize()` with a FaceReindex entry but
                // WITHOUT going through `applyFaceReindexForward`/`Reverse`'s
                // own declaration — but 1903 must not mistake removing this
                // `case` for removing the protection: the two
                // `dropCornerProvenance` calls are the mechanism, this
                // `return true;` is not.
                return true;
            case MeshOpEntry.Kind.ReshapeFaces:
                foreach (i, ref before; e.faceListsBefore) {
                    if (i >= e.faceListsAfter.length) return true;  // malformed ⇒ assume the worst
                    if (before.length != e.faceListsAfter[i].length) return true;
                }
                if (e.faceListsAfter.length != e.faceListsBefore.length) return true;
                break;
            default:
                break;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// MeshEditTracker — the recorder. Installed on a Mesh while a batch is open
// (via Mesh.beginEditBatch); the hooked mutation primitives append entries to
// its log. finish() moves the log into a MeshEditDelta.
// ---------------------------------------------------------------------------
struct MeshEditTracker {
    private MeshOpEntry[] log_;
    private MeshEditScope declared_ = MeshEditScope.None;

    /// Does this recorder want `FaceReindex` entries? Default FALSE. 1903
    /// turns it on per-op as it retires the redundant Add/Remove/Reshape
    /// records that already describe the same change. Shipping it on would
    /// double-revert: `mesh.d` (12 tracker calls) and `extrude.d` (9) already
    /// record their face changes through those other kinds, and a second
    /// entry describing the SAME change is not extra safety, it is a second,
    /// conflicting revert applied to one edit (plan §7.1).
    bool wantsFaceReindex = false;

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
    void recordAddFace(FaceIdx idx, in uint[] list) {
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

    void recordAddFaces(FaceIdx f0, uint f1, in uint[][] lists) {
        if (f1 <= f0) return;
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.AddFaces;
        e.fIdx      = [f0];
        e.faceLists = dupLists(lists);
        log_ ~= e;
    }

    // --- Class B: coarse bulk-op deltas -----------------------------------
    /// TAKES OWNERSHIP of every array passed in — the entry stores them as-is
    /// rather than copying (task 0680).
    ///
    /// The parameters are deliberately NOT `in`: the previous signature copied
    /// all five, and `faceLists` is an array-of-arrays, so the copy allocated
    /// once PER REMOVED FACE — on top of the per-face `.dup` its callers had
    /// already made building it. Removing a 99 856-face mesh therefore paid
    /// ~200 000 GC allocations to record one delta, and the collector work that
    /// followed showed up as +612% on the operation itself.
    ///
    /// Every call site builds these arrays immediately before the call from
    /// locals it never touches again (`deleteFacesByMask`, `dissolveVerticesByMask`,
    /// the merge path, `extrudeFacesByMask`), so handing the buffers over is
    /// safe. A future caller that wants to KEEP its arrays must `.dup` at the
    /// call site — the cost then lands on the one caller that needs it.
    void recordRemoveFaces(FaceIdx[] idx, uint[][] lists, uint[] mat, uint[] prt, uint[] sub,
                           ulong[] setm = null, int[] ord = null) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind       = MeshOpEntry.Kind.RemoveFaces;
        e.fIdx       = idx;
        e.faceLists  = lists;
        e.faceMat    = mat;
        e.facePrt    = prt;
        e.faceSub    = sub;
        e.faceSetMsk = setm;
        e.faceOrd    = ord;   // task 1902 Stage H — see MeshOpEntry.faceOrd's own doc
        log_ ~= e;
    }

    void recordReshapeFaces(in FaceIdx[] idx, in uint[][] before, in uint[][] after) {
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

    // Task 1902 Stage H — the face analogue, called from
    // `mesh_planes.rewriteFaces` (through `Mesh.recordFaceReindexIfWanted`,
    // the cross-module seam) right after the live carry runs. TAKES
    // OWNERSHIP of every array passed in (same convention as
    // `recordRemoveFaces`, task 0680) — the caller (`rewriteFaces`) builds
    // them immediately before this call and never touches them again.
    // Does NOT gate on `wantsFaceReindex` itself — the caller already did,
    // via `Mesh.wantsFaceReindexRecording()` — so this method unconditionally
    // appends; callers that skip the gate get an entry regardless, which is
    // why `Mesh.recordFaceReindexIfWanted` re-checks the flag before calling.
    void recordFaceReindex(uint[] oldOfNew, uint oldFaceCount, uint[][] newFaceLists,
                           FaceIdx[] dropIdx, uint[][] dropLists, uint[] dropMat,
                           uint[] dropPrt, uint[] dropSub, ulong[] dropSetMsk,
                           int[] dropOrd, FaceIdx[] survIdx, uint[][] survLists) {
        // Review finding B3: this used to read
        // `if (oldOfNew.length == 0 && newFaceLists.length == 0) return;` —
        // `oldOfNew.length` is `newFaces.length` at the call site, which is
        // ALSO zero for the destructive "drop every face" rewrite (select-all
        // + delete), not only for the genuine no-op "0 old faces in, 0 new
        // faces out". That guard silently swallowed the whole drop set on
        // exactly the case it most needed to record. `oldFaceCount == 0`
        // names the real no-op: nothing existed before AND nothing exists
        // after.
        if (oldFaceCount == 0 && newFaceLists.length == 0) return;
        MeshOpEntry e;
        e.kind              = MeshOpEntry.Kind.FaceReindex;
        e.faceOldOfNew      = oldOfNew;
        e.oldFaceCount      = oldFaceCount;
        e.newFaceLists      = newFaceLists;
        e.fIdx              = dropIdx;
        e.faceLists         = dropLists;
        e.faceMat           = dropMat;
        e.facePrt           = dropPrt;
        e.faceSub           = dropSub;
        e.faceSetMsk        = dropSetMsk;
        e.faceOrd           = dropOrd;
        e.faceSurvivorIdx   = survIdx;      // review finding B2
        e.faceSurvivorLists = survLists;    // review finding B2
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

    // Mirrors recordSubpatchDelta exactly (task 0613 §4.2/S1) — same sparse
    // face-indexed bit delta, one bit different. No production caller yet
    // (same status as recordSubpatchDelta itself, which also has none): this
    // is infrastructure that a future direct-mutation op can record into,
    // proven by its own unittest.
    void recordHideDelta(in uint[] idx, in uint[] before, in uint[] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind       = MeshOpEntry.Kind.HideDelta;
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

    // --- Task 0689: the per-corner (PolyVertex) map channel ----------------
    // The values of the corners the NEXT recorded entry destroys. Only ever
    // called by `Mesh.recordPolyVertexPayload`, which owns the capture and the
    // preconditions; the pairing with the entry that follows is by ADJACENCY,
    // so this must be recorded immediately before it and nothing may be
    // recorded in between.
    //
    // TAKES OWNERSHIP (same convention as recordRemoveFaces, task 0680): the
    // caller builds all three arrays for this call and never touches them
    // again, so they are stored as-is rather than copied.
    void recordPolyVertexValues(ubyte[] dims, uint[] arity, float[] vals) {
        if (arity.length == 0 || dims.length == 0) return;
        MeshOpEntry e;
        e.kind     = MeshOpEntry.Kind.MeshMapDelta;
        e.mapDims  = dims;
        e.mapArity = arity;
        e.mapVals  = vals;
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
        case MeshOpEntry.Kind.FaceReindex:
            applyFaceReindexForward(m, e);
            break;
        case MeshOpEntry.Kind.SelectionDelta:
            patchSelection(m, e.selDomain, e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.SubpatchDelta:
            patchSubpatch(m, e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.HideDelta:
            patchHide(m, e.markIdx, e.markAfter);
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
            removeFacesReverse(m, e.fIdx, e.faceLists, e.faceMat, e.facePrt, e.faceSub, e.faceSetMsk, e.faceOrd);
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
        case MeshOpEntry.Kind.FaceReindex:
            applyFaceReindexReverse(m, e);
            break;
        case MeshOpEntry.Kind.SelectionDelta:
            patchSelection(m, e.selDomain, e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.SubpatchDelta:
            patchSubpatch(m, e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.HideDelta:
            patchHide(m, e.markIdx, e.markBefore);
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
    // vertexMarks rides the SAME permutation as positions (task 0613 §4.2 —
    // the "vertex-mark permutation gap"). Without this, a kept vertex's whole
    // marks word — including a LOOSE vertex's own Hide bit, the only per-
    // vertex Hide state that is not self-healed by refreshHiddenDerived()
    // (a face-bound vertex's bit IS re-derived every geometry commit; a loose
    // vertex's is not, since it never has an incident face to derive from) —
    // stays parked at its OLD slot while the vertex itself moves to `p`,
    // exactly the "bit slides onto whoever moves into the vacated slot"
    // defect fixed at deleteFacesByMask's own compaction, here on the vertex
    // side of a Reindex replay.
    uint[] nm;
    nm.length = kept;
    // vertexSelectionOrder rides the SAME permutation (task 0613 §4.2, S3
    // code review): before this task neither vertexMarks nor the order
    // stamps moved with a compaction, so the two were consistently wrong
    // TOGETHER. Fixing only vertexMarks would leave a kept vertex's mark
    // word correctly at its new slot `p` while its selection-order stamp
    // stayed behind at the OLD slot — the same "stale stamp" class this
    // repository has already fixed three times elsewhere (see
    // SelectionSnapshot.restore's own S3 fix in snapshot.d).
    int[] no;
    no.length = kept;
    foreach (old, p; perm) {
        if (p == ~0u) continue;
        if (old < m.vertices.length) nv[p] = m.vertices[old];
        if (old < m.vertexMarks.length) nm[p] = m.vertexMarks[old];
        if (old < m.vertexSelectionOrder.length) no[p] = m.vertexSelectionOrder[old];
    }
    m.vertices             = nv;
    m.vertexMarks          = nm;
    m.vertexSelectionOrder = no;
    // Task 0930: every Point-domain MeshMap (vertex weight, vertex color)
    // rides the SAME permutation as `vertices`/`vertexMarks` above — the gap
    // this task closes. Before this, `m.meshMaps` was never touched by this
    // function at all; the tail `finalize()`'s `resizeAllMeshMaps()` only
    // grows/shrinks each map's `data` by LENGTH (a raw truncate/grow, not a
    // permutation), so a vertex dropped from the middle of a compaction left
    // every survivor after it wearing a neighbour's weight — the same
    // truncate-from-the-tail bug `compactUnreferenced` itself carried before
    // task 0920 fixed it there. This mirrors that fix's gather shape,
    // extended to the undo/redo replay side of the SAME compaction.
    foreach (ref mm; m.meshMaps) {
        if (mm.domain != MapDomain.Point) continue;
        const ubyte dim = mm.dim;
        float[] nd;
        nd.length = kept * dim;
        // Task 1069: the presence channel rides the SAME permutation, one
        // entry per ELEMENT (no `* dim`).
        const bool hasP = mm.present.length != 0;
        ubyte[] np;
        if (hasP) np.length = kept;
        foreach (old, p; perm) {
            if (p == ~0u) continue;
            const size_t ob = cast(size_t)old * dim;
            if (ob + dim > mm.data.length) continue; // defensive
            nd[p * dim .. p * dim + dim] = mm.data[ob .. ob + dim];
            if (hasP && old < mm.present.length) np[p] = mm.present[old];
        }
        mm.data = nd;
        if (hasP) mm.present = np;
    }
    // Task 1060: `vertexSetMask` rides the SAME permutation as the
    // Point-domain meshMaps loop just above (same gap `mesh.d`'s
    // `compactUnreferenced` closed for the live path — this is its
    // undo/redo replay twin).
    m.vertexSetMask = selSetGatherVertexMaskForward(m.vertexSetMask, perm, kept);
    // Task 1060, Stage 5b: the edge-set registry rides the SAME permutation
    // — `perm[old] == ~0u` is exactly `selSetRekeyEdges`'s "vertex gone"
    // sentinel already.
    selSetRekeyEdges(m, (uint v) => v < perm.length ? perm[v] : uint.max);
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
    // vertexMarks rides the SAME reverse permutation — see applyReindexForward's
    // comment (task 0613 §4.2). Dropped slots stay 0 (no bits), matching how
    // `nv`'s dropped slots stay a Vec3.init gap: both are filled by the
    // following RemoveVerts^-1 (positions only — see removeVertsReverse's own
    // comment for why a removed vertex's marks are not restored here).
    uint[] nm;
    nm.length = perm.length;
    // vertexSelectionOrder rides the SAME reverse permutation — see
    // applyReindexForward's comment (task 0613 §4.2, S3 code review).
    // Dropped slots stay 0 (not manually selected), same convention as
    // `nm`'s dropped slots.
    int[] no;
    no.length = perm.length;
    foreach (old, p; perm) {
        if (p == ~0u) continue;         // dropped slot — gap, filled by RemoveVerts^-1
        if (p < m.vertices.length) nv[old] = m.vertices[p];
        if (p < m.vertexMarks.length) nm[old] = m.vertexMarks[p];
        if (p < m.vertexSelectionOrder.length) no[old] = m.vertexSelectionOrder[p];
    }
    m.vertices             = nv;
    m.vertexMarks          = nm;
    m.vertexSelectionOrder = no;
    // Task 0930: every Point-domain MeshMap rides the SAME reverse
    // permutation — see applyReindexForward's comment. Dropped slots are
    // explicitly zeroed (not left at `float.init` == NaN, unlike `nm`/`no`'s
    // default-0 `uint`/`int` gaps) and stay that way until the following
    // RemoveVerts^-1 fills them — matching `nv`'s Vec3 gap and `nm`/`no`'s
    // documented "not restored here" convention.
    foreach (ref mm; m.meshMaps) {
        if (mm.domain != MapDomain.Point) continue;
        const ubyte dim = mm.dim;
        float[] nd;
        nd.length = perm.length * dim;
        nd[] = 0f;
        // Task 1069: presence rides the same reverse permutation. Gap slots
        // stay 0 == ABSENT, which is the right default for both morph kinds
        // and matches `nd`'s explicit zero fill above.
        const bool hasP = mm.present.length != 0;
        ubyte[] np;
        if (hasP) { np.length = perm.length; np[] = 0; }
        foreach (old, p; perm) {
            if (p == ~0u) continue;
            const size_t pb = cast(size_t)p * dim;
            if (pb + dim > mm.data.length) continue; // defensive
            nd[old * dim .. old * dim + dim] = mm.data[pb .. pb + dim];
            if (hasP && p < mm.present.length) np[old] = mm.present[p];
        }
        mm.data = nd;
        if (hasP) mm.present = np;
    }
    // Task 1060: `vertexSetMask` rides the SAME reverse permutation as the
    // Point-domain meshMaps loop just above.
    m.vertexSetMask = selSetGatherVertexMaskReverse(m.vertexSetMask, perm);
    // Inverse map: new -> old. Build it once, then rewrite face vids.
    uint[] inv;
    inv.length = m.vertices.length; // == perm.length now; safe upper bound for `new` ids
    // Initialise to identity-ish; only kept `new` slots matter.
    foreach (old, p; perm)
        if (p != ~0u && p < inv.length) inv[p] = cast(uint)old;
    // Task 1060, Stage 5b: re-key the edge-set registry through the SAME
    // inverse map that is about to rewrite face vertex ids below — `m`'s
    // vertices are back at pre-compaction (old) index space after this
    // function returns, so the edge-set keys must be too.
    selSetRekeyEdges(m, (uint v) => v < inv.length ? inv[v] : uint.max);
    foreach (ref f; m.faces)
        foreach (ref vid; f) {
            // A face vid here is a post-compaction `new` id; map back to old.
            // It must reference a kept vert, so inv[vid] is defined.
            if (vid < inv.length) vid = inv[vid];
        }
}

// ---------------------------------------------------------------------------
// FaceReindex forward/reverse (task 1902 Stage H, plan §7.2). Unlike
// Reindex (vertex-only, a pure permutation with no content change),
// FaceReindex's forward direction is the LIVE primitive itself — see
// applyFaceReindexForward's own comment for why a face's winding cannot be
// re-derived from the correspondence alone.
// ---------------------------------------------------------------------------

// Forward: redo. `rewriteFaces` IS the recorded operation (plan §7.2's "one
// implementation, so replay and live edit cannot drift") — this just hands
// it back the same `newFaceLists`/`faceOldOfNew` the live edit built. Safe to
// call unconditionally even on a mesh with an OPEN, armed batch: replay only
// ever runs after `Mesh.endEditBatch()` has detached the recorder (this
// entry's own log has already been finished by then), so `rewriteFaces`'s own
// internal `wantsFaceReindexRecording()` check reads `editRecorder_ is null`
// and records nothing — no double-append.
private void applyFaceReindexForward(ref Mesh m, ref const MeshOpEntry e) {
    // Review finding B3: `e.faceOldOfNew.length == 0` used to read as
    // "nothing to redo" and return early — but it is ALSO the shape of a
    // redo whose rewrite drops every face (`newFaces.length == 0`, e.g.
    // select-all + delete). That early return refused to redo exactly the
    // entry `recordFaceReindex`'s own B3 fix now records. `rewriteFaces`
    // already handles `newFaces.length == 0` correctly on its own (every
    // generated plane carries zero elements, `m.faces` becomes empty), so no
    // guard is needed here at all — the guard belongs solely at the record
    // site, and the two must agree on what "no-op" means (`oldFaceCount ==
    // 0`, not `faceOldOfNew.length == 0`).
    uint[][] nf;
    nf.reserve(e.newFaceLists.length);
    foreach (l; e.newFaceLists) nf ~= l.dup;
    rewriteFaces(m, nf, FaceSource(e.faceOldOfNew));
    // `rewriteFaces` is called with `rw = null` — same as 15 of the 19 live
    // sites (plan §2.6) — so it declares nothing about the PolyVertex corner
    // map itself. Those 15 sites each pair `rw = null` with their OWN bare
    // `dropCornerProvenance(CornerDrop.…)` call; this is FaceReindex's:
    // `CornerDrop.DeltaReplayDeclined` exists for exactly this ("the replay
    // normally carries the plane itself … and reaches this only when the
    // carry DECLINES" — mesh_corner_maps.d's own doc comment on that value).
    // `CornerCarry` (above) has no `Kind.FaceReindex` case yet (1903 owns
    // generalising it, plan §7.5), so the carry always declines for this
    // kind — an EXPLICIT drop here is what keeps `buildLoops()` from either
    // asserting (a length mismatch it cannot explain) or, worse, silently
    // leaving a length-correct-by-COINCIDENCE map sitting on the wrong
    // faces' corners.
    m.dropCornerProvenance(CornerDrop.DeltaReplayDeclined);
}

// Reverse: undo. Rebuilds the pre-reindex `faces` (and its five carried
// planes) at exactly `oldFaceCount` slots:
//   * an old index NAMED by >=1 new index restores from the CURRENT mesh
//     (still in its post-reindex state at this point in the LIFO replay) at
//     its FIRST naming new index — that data is live, not archived, because
//     the forward carry put it there verbatim via the same correspondence;
//   * an old index named by NO new index (the drop set) restores from
//     fIdx/faceLists/faceMat/facePrt/faceSub/faceSetMsk/faceOrd, captured
//     before the forward rewrite ran (same fields RemoveFaces carries).
// A `kNoSource` new face names no old index at all, so it contributes to
// neither bucket and simply vanishes — correct, per plan §7.2: "they had no
// prior existence".
private void applyFaceReindexReverse(ref Mesh m, ref const MeshOpEntry e) {
    // Review finding S4: this function used to open with
    // `if (e.oldFaceCount == 0) return;` — read as "nothing to undo", but it
    // is ALSO the shape of undoing a rewrite FROM an empty mesh (a
    // create-only op: `oldFaceCount == 0`, `faceOldOfNew` all `kNoSource`).
    // The correct reverse of THAT is to truncate every plane back to length
    // 0, which is exactly what the code below does on its own when
    // `e.oldFaceCount == 0` (every `rest*` array below is sized `0`) — no
    // special case needed, just no early exit to skip it.
    enum uint kNoneYet = uint.max;
    uint[] firstNew;
    firstNew.length = e.oldFaceCount;
    firstNew[] = kNoneYet;
    foreach (nf, of; e.faceOldOfNew) {
        if (of == kNoSource || of >= e.oldFaceCount) continue;
        if (firstNew[of] == kNoneYet) firstNew[of] = cast(uint) nf;
    }

    // Review finding B2: a survivor's winding, read off the CURRENT
    // (post-reindex) mesh at `nf`, is the POST-rewrite winding — not always
    // the PRE-rewrite one this entry must restore (e.g.
    // `Mesh.removeVertsByMask` drops a corner from a kept face's list while
    // its old index still survives). `mesh_planes.rewriteFaces` captures the
    // pre-rewrite winding for exactly the survivors where it differs
    // (`faceSurvivorIdx`/`faceSurvivorLists` — see their own doc comment in
    // `MeshOpEntry`); build an old-index -> capture-slot lookup once so the
    // restore loop below can prefer a captured winding over the live mesh.
    uint[] survivorSlot;
    survivorSlot.length = e.oldFaceCount;
    survivorSlot[] = kNoneYet;
    foreach (i, of; e.faceSurvivorIdx)
        if (of < e.oldFaceCount) survivorSlot[of] = cast(uint) i;

    uint[][] restFaces;  restFaces.length  = e.oldFaceCount;
    uint[]   restMarks;  restMarks.length  = e.oldFaceCount;
    uint[]   restMat;    restMat.length    = e.oldFaceCount;
    uint[]   restPrt;    restPrt.length    = e.oldFaceCount;
    int[]    restOrd;    restOrd.length    = e.oldFaceCount;
    ulong[]  restSetMsk; restSetMsk.length = e.oldFaceCount;

    foreach (of; 0 .. e.oldFaceCount) {
        const uint nf = firstNew[of];
        if (nf == kNoneYet) continue;   // filled from the drop set below
        // Bounds-guard the survivor-list read too, house style with the
        // fields around it: `faceSurvivorIdx`/`faceSurvivorLists` are meant
        // to stay parallel, but nothing in the type enforces it, and
        // `survivorSlot[of]` is built from `faceSurvivorIdx`'s own indices —
        // a malformed/hand-built entry with a shorter `faceSurvivorLists`
        // would otherwise index it out of bounds instead of falling back.
        restFaces[of]  = (survivorSlot[of] != kNoneYet
                          && survivorSlot[of] < e.faceSurvivorLists.length)
                        ? e.faceSurvivorLists[survivorSlot[of]].dup
                        : ((nf < m.faces.length) ? m.faces[nf].dup : null);
        restMarks[of]  = (nf < m.faceMarks.length) ? m.faceMarks[nf] : 0;
        restMat[of]    = (nf < m.faceMaterial.length) ? m.faceMaterial[nf] : 0;
        restPrt[of]    = (nf < m.facePart.length) ? m.facePart[nf] : 0;
        restOrd[of]    = (nf < m.faceSelectionOrder.length) ? m.faceSelectionOrder[nf] : 0;
        restSetMsk[of] = (nf < m.faceSetMask.length) ? m.faceSetMask[nf] : 0UL;
    }
    // Overlay the drop set. Same documented limit RemoveFaces's own reverse
    // has always had: the dropped face's whole `faceMarks` word (Select /
    // Hide) is NOT captured by this entry, only its Subpatch bit (`faceSub`,
    // restored by name below, after `m.faceMarks` exists at its new length) —
    // see removeFacesReverse's own comment for why.
    foreach (i, fi; e.fIdx) {
        if (fi >= e.oldFaceCount) continue;
        restFaces[fi]  = (i < e.faceLists.length) ? e.faceLists[i].dup : null;
        restMat[fi]    = (i < e.faceMat.length) ? e.faceMat[i] : 0;
        restPrt[fi]    = (i < e.facePrt.length) ? e.facePrt[i] : 0;
        restOrd[fi]    = (i < e.faceOrd.length) ? e.faceOrd[i] : 0;
        restSetMsk[fi] = (i < e.faceSetMsk.length) ? e.faceSetMsk[i] : 0UL;
    }

    // Review finding S6 (nit): a malformed entry must not send a
    // zero-length face into `buildLoops` — every old index in
    // `[0, oldFaceCount)` must be named either by `faceOldOfNew` (a
    // surviving/duplicated new face, `firstNew[of] != kNoneYet`) or by the
    // drop set (`fIdx`, overlaid just above). Cheap: reuses the two passes
    // above, one extra `bool[]`. `debug { }`, not a plain block: this is a
    // coverage ASSERTION, not a repair — under `-release` it must do no
    // work at all, matching the identical `debug { assert(...) }` shape at
    // `Mesh.dropCornerProvenance`'s own corner-space check (mesh.d).
    debug {
        bool[] covered;
        covered.length = e.oldFaceCount;
        foreach (of; 0 .. e.oldFaceCount) if (firstNew[of] != kNoneYet) covered[of] = true;
        foreach (fi; e.fIdx) if (fi < e.oldFaceCount) covered[fi] = true;
        foreach (of; 0 .. e.oldFaceCount)
            assert(covered[of],
                   "applyFaceReindexReverse: malformed entry — an old face "
                 ~ "index is named by neither faceOldOfNew nor the drop set "
                 ~ "(fIdx); reverse cannot rebuild it and would leave a "
                 ~ "zero-length face for buildLoops");
    }

    m.faces              = restFaces;
    m.faceMarks          = restMarks;
    m.faceMaterial       = restMat;
    m.facePart           = restPrt;
    m.faceSelectionOrder = restOrd;
    m.faceSetMask        = restSetMsk;

    if (e.faceSub.length == e.fIdx.length)
        foreach (i, fi; e.fIdx)
            if (fi < m.faces.length)
                m.setFaceSubpatch(fi, e.faceSub[i] != 0);

    // Same declared-drop obligation as applyFaceReindexForward's own comment
    // — this function assigns `m.faces` directly (no `rewriteFaces` call, so
    // no `rw` parameter to have passed null in the first place), but the
    // PolyVertex corner map is exactly as undeclared-for here, and
    // `buildLoops()` (later, in `finalize()`) enforces the same precondition
    // regardless of which code path rewrote `faces`. Runs unconditionally,
    // including when `oldFaceCount == 0` (S4 above).
    m.dropCornerProvenance(CornerDrop.DeltaReplayDeclined);
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
    // Drop the same indices from vertexMarks (task 0613 §4.2 — same
    // permutation-gap fix as applyReindexForward/Reverse above), so a
    // surviving vertex's marks stay aligned with the dropped-then-repacked
    // position array instead of one drifting relative to the other.
    uint[] nm;
    nm.reserve(m.vertexMarks.length);
    foreach (i, w; m.vertexMarks) if (i >= drop.length || !drop[i]) nm ~= w;
    m.vertexMarks = nm;
    // Same drop for vertexSelectionOrder (task 0613 §4.2, S3 code review) —
    // see applyReindexForward's comment for why the order stamp must move
    // with the mark word, not just the position.
    int[] no;
    no.reserve(m.vertexSelectionOrder.length);
    foreach (i, o; m.vertexSelectionOrder) if (i >= drop.length || !drop[i]) no ~= o;
    m.vertexSelectionOrder = no;
    // Task 0930: same parallel drop-filter for every Point-domain MeshMap —
    // see applyReindexForward's comment for why a surviving vertex's own
    // value must move with it rather than being left to finalize()'s tail
    // length-only resize. Same `i >= drop.length || !drop[i]` survive
    // condition as the three arrays above, scaled by the map's own `dim`.
    foreach (ref mm; m.meshMaps) {
        if (mm.domain != MapDomain.Point || mm.dim == 0) continue;
        const size_t dim = mm.dim;
        const size_t n   = mm.data.length / dim;
        float[] nd;
        nd.reserve(mm.data.length);
        // Task 1069: presence rides the SAME drop-filter, one entry per
        // ELEMENT, filtered on the identical survive condition.
        const bool hasP = mm.present.length != 0;
        ubyte[] np;
        if (hasP) np.reserve(mm.present.length);
        foreach (i; 0 .. n)
            if (i >= drop.length || !drop[i]) {
                nd ~= mm.data[i * dim .. i * dim + dim];
                if (hasP) np ~= (i < mm.present.length) ? mm.present[i] : cast(ubyte)0;
            }
        mm.data = nd;
        if (hasP) mm.present = np;
    }
    // Task 1060: `vertexSetMask` rides the SAME drop-filter as the
    // Point-domain meshMaps loop just above — computed BEFORE `m.vertices`
    // was reassigned, so `mm.data`'s pre-drop length still lines up with
    // `drop`. Re-derive the same relation for `vertexSetMask`.
    m.vertexSetMask = selSetDropFilterVertexMask(m.vertexSetMask, drop);
    // Task 1060, Stage 5b: re-key the edge-set registry through THIS drop's
    // prefix-sum remap — the drop-filter's own old->new correspondence,
    // built the same way `compactUnreferenced`'s `remap` is (kept indices
    // renumbered by how many earlier entries were dropped; a dropped
    // vertex maps to `uint.max`). This must run on the SAME `drop` array
    // used just above, before any caller reassigns `m.vertices` further.
    {
        uint[] vremap;
        vremap.length = drop.length;
        uint nextIdx = 0;
        foreach (i; 0 .. drop.length)
            vremap[i] = drop[i] ? uint.max : nextIdx++;
        selSetRekeyEdges(m, (uint v) => v < vremap.length ? vremap[v] : uint.max);
    }
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
//
// vertexMarks (task 0613 §4.2): kept in LENGTH lock-step with `vertices` at
// every step, mirroring each of the three position operations exactly —
// otherwise a LATER Reindex/RemoveVerts entry in the same batch (a multi-step
// compaction) would see `vertexMarks.length != vertices.length` mid-replay,
// not just at finalize()'s tail resize. The VALUE inserted is 0 (no bits),
// not a restored capture: `MeshOpEntry.RemoveVerts` only records `vIdx` +
// `pos` — a removed vertex's marks are not captured anywhere in the delta.
// Re-inserting a vertex that was hidden (a loose point's own bit; a
// face-bound vertex's bit self-heals via refreshHiddenDerived and needs no
// capture) therefore comes back VISIBLE, same as the reference's own convention that
// selection bits do not survive an index change elsewhere in mesh.d
// (`clearFaceSelectionResize` et al.) — not a regression, a documented limit.
//
// Task 0930: every Point-domain MeshMap gets the same treatment as
// `vertexMarks` in all three branches (gap-fill / tail-append / standalone
// insert) — length lock-step, value 0 (not a restored capture, same
// documented limit; `MeshOpEntry.RemoveVerts` does not carry a removed
// vertex's own map values any more than it carries its marks word).
//
// `vertexSelectionOrder` (task 0930, secondary finding) now gets the SAME
// standalone-insert treatment `vertexMarks` already had: the gap-fill and
// tail-append branches were already safe (the gap/tail slot arrives at 0 via
// applyReindexReverse's own permute / finalize()'s tail length-resize), but
// the standalone insertInPlace branch left it out of lock-step with
// `vertices`' mid-array growth — the same hole this task closed for
// `meshMaps` just above, on an array that already had the fix everywhere
// else. No live producer reaches this branch yet (a standalone RemoveVerts
// with no paired Reindex — see the doc comment above), so this is a
// preventive close, not a measured-by-value fix; closed here because the
// adjacent lines were already being touched for the meshMaps fix.
private void removeVertsReverse(ref Mesh m, in uint[] idx, in Vec3[] pos) {
    foreach (i, vi; idx) {
        if (vi < m.vertices.length) {
            m.vertices[vi] = pos[i];          // fill the gap re-opened by Reindex^-1
            if (vi < m.vertexMarks.length) m.vertexMarks[vi] = 0;
            foreach (ref mm; m.meshMaps) {
                if (mm.domain != MapDomain.Point || mm.dim == 0) continue;
                const size_t dim = mm.dim;
                if (vi * dim + dim <= mm.data.length) mm.data[vi * dim .. vi * dim + dim] = 0f;
                // Task 1069: same "not a restored capture" convention as the
                // value above — the re-inserted vertex has no entry.
                if (vi < mm.present.length) mm.present[vi] = 0;
            }
            // Task 1060: same "not a restored capture" convention as
            // vertexMarks/meshMaps just above — the re-inserted vertex's
            // own set membership was never captured by this entry.
            if (vi < m.vertexSetMask.length) m.vertexSetMask[vi] = 0UL;
        } else if (vi == m.vertices.length) {
            m.vertices ~= pos[i];             // contiguous append at the tail
            m.vertexMarks ~= 0u;
            foreach (ref mm; m.meshMaps) {
                if (mm.domain != MapDomain.Point || mm.dim == 0) continue;
                foreach (_; 0 .. mm.dim) mm.data ~= 0f;
                if (mm.present.length != 0) mm.present ~= cast(ubyte)0; // task 1069
            }
            m.vertexSetMask ~= 0UL;
        } else {
            m.vertices.insertInPlace(vi, pos[i]); // standalone removal (no Reindex)
            if (vi <= m.vertexMarks.length) m.vertexMarks.insertInPlace(vi, 0u);
            if (vi <= m.vertexSelectionOrder.length) m.vertexSelectionOrder.insertInPlace(vi, 0);
            foreach (ref mm; m.meshMaps) {
                if (mm.domain != MapDomain.Point || mm.dim == 0) continue;
                const size_t dim = mm.dim;
                if (vi * dim <= mm.data.length) {
                    float[] zeros;
                    zeros.length = dim;
                    zeros[] = 0f;
                    mm.data.insertInPlace(vi * dim, zeros);
                    // Task 1069: the presence channel shifts with the values.
                    if (mm.present.length != 0 && vi <= mm.present.length)
                        mm.present.insertInPlace(vi, cast(ubyte)0);
                }
            }
            if (vi <= m.vertexSetMask.length) m.vertexSetMask.insertInPlace(vi, 0UL);
            // Task 1060, Stage 5b: this is the STANDALONE insert branch — no
            // live producer reaches it today (see the comment above this
            // function), but the edge-set re-key belongs here for the same
            // reason the meshMaps insert does: inserting a vertex at `vi`
            // shifts every vertex index >= vi up by one, so any edge-set
            // entry with such an endpoint must shift with it or it silently
            // points at the wrong (or a now-nonexistent) pair. Preventive
            // close, not measured-by-value — mirrors the note on
            // `vertexSelectionOrder`'s insert two lines above.
            selSetRekeyEdges(m, (uint v) => v >= vi ? v + 1 : v);
        }
    }
}

// ---------------------------------------------------------------------------
// RemoveFaces forward/reverse.
// ---------------------------------------------------------------------------
private void removeFacesForward(ref Mesh m, in FaceIdx[] idx) {
    if (idx.length == 0) return;
    bool[] drop;
    drop.length = m.faces.length;
    foreach (i; idx) if (i < drop.length) drop[i] = true;
    uint[][] nf;
    nf.reserve(m.faces.length);
    foreach (i, ref f; m.faces) if (!drop[i]) nf ~= f.dup;
    m.faces = nf;
    // faceMarks rides the SAME compaction (task 0613 §4.2/S2 code review —
    // the face-side twin of removeVertsForward's vertexMarks fix above).
    // This is a real array compaction (drop + shift), not a positional
    // insert/remove, so a surviving face's WHOLE marks word (Subpatch +
    // Hide) must move with it to its new index — otherwise finalize()'s
    // tail `faceMarks.length = m.faces.length` truncate/grow leaves the
    // word at each surviving index stale, and a face's Hide bit silently
    // lands on whichever OTHER face slides into its old slot. Same class of
    // bug already fixed at deleteFacesByMask's own compaction
    // (`keptWord`, in `Mesh.finalizeTopologyEdit`). Reached on the apply/redo path of
    // MeshSessionEdit-backed tools (bevel, loop-slice, reduce,
    // topology-pen-remove — commands/mesh/session_edit.d:108); delete/remove
    // dodge it because their own revert() re-overlays the full pre-op word
    // afterward (see MeshDelete.revert) and their redo re-runs the kernel
    // instead of replaying this forward op.
    uint[] nm;
    nm.reserve(m.faceMarks.length);
    foreach (i, w; m.faceMarks) if (i >= drop.length || !drop[i]) nm ~= w;
    m.faceMarks = nm;
    // Task 0922: `faceMaterial` / `facePart` / `faceSelectionOrder` ride the
    // SAME drop-filter as `faces`/`faceMarks` just above — the same class of
    // bug, the same fix. Without this, `finalize()`'s tail
    // `faceMaterial.length = m.faces.length` (a raw truncate/grow, not a
    // compaction) left each of these three planes at their STALE pre-drop
    // position instead of following their own face through the drop, so a
    // face dropped anywhere but the array's tail left every survivor after
    // it wearing a neighbour's material/part/pick-order stamp. Reached on
    // the same apply/redo path as the faceMarks fix above.
    uint[] nmat;
    nmat.reserve(m.faceMaterial.length);
    foreach (i, v; m.faceMaterial) if (i >= drop.length || !drop[i]) nmat ~= v;
    m.faceMaterial = nmat;
    uint[] nprt;
    nprt.reserve(m.facePart.length);
    foreach (i, v; m.facePart) if (i >= drop.length || !drop[i]) nprt ~= v;
    m.facePart = nprt;
    // Task 1060, Stage 5c: `faceSetMask` rides the SAME drop-filter as
    // `facePart` just above — this is the undo/redo replay twin of the
    // face-drop carry `deleteFacesByMask`/`dissolveVerticesByMask`/etc.
    // already do on the live path.
    ulong[] nsetm;
    nsetm.reserve(m.faceSetMask.length);
    foreach (i, v; m.faceSetMask) if (i >= drop.length || !drop[i]) nsetm ~= v;
    m.faceSetMask = nsetm;
    int[] nord;
    nord.reserve(m.faceSelectionOrder.length);
    foreach (i, v; m.faceSelectionOrder) if (i >= drop.length || !drop[i]) nord ~= v;
    m.faceSelectionOrder = nord;
}

private void removeFacesReverse(ref Mesh m, in FaceIdx[] idx, in uint[][] lists,
                                in uint[] mat, in uint[] prt, in uint[] sub,
                                in ulong[] setm = null, in int[] ord = null) {
    // NEGATIVE CONTROL (test only): stub RemoveFaces^-1 to a no-op under
    // -version=UndoNegControlRemoveFaces so the delete/remove round-trip proves
    // the face re-insertion inverse is load-bearing (without it the deleted
    // faces never come back on undo → face count diverges from the pre-op mesh).
    version (UndoNegControlRemoveFaces) return;
    // Task 1902 Stage H (plan §7.3): `faceSelectionOrder` is now carried the
    // same way `facePrt`/`faceSetMsk` are — an entry recorded before this
    // task (or a hand-built test fixture with no `ord`) falls back to the
    // pre-existing "insert 0" behaviour, unchanged.
    const bool haveOrd = ord.length == idx.length;
    // Insert ascending so later indices stay valid.
    foreach (i, fi; idx) {
        if (fi <= m.faces.length)
            m.faces.insertInPlace(fi, lists[i].dup);
        // faceMarks shifts in LOCKSTEP with `m.faces` (task 0613 §4.2/S2 code
        // review — the reverse-direction twin of removeFacesForward's fix
        // above; mirrors how faceMaterial/facePart already insertInPlace at
        // `fi` just below). Without this, `m.faces` grows by one at `fi`
        // (shifting every surviving face after it up one slot) while
        // `m.faceMarks` sits untouched until finalize()'s tail
        // `faceMarks.length = m.faces.length` — a LENGTH GROW, which appends
        // zeros at the TAIL, not at `fi` — so every surviving face's word
        // ends up misaligned with its (now-shifted) face, not just the
        // re-inserted one. Insert 0 (no bits): a re-inserted face's OWN word
        // is not captured by this entry beyond `sub` (Subpatch, restored by
        // name just below) — same "not a regression, a documented limit" as
        // removeVertsReverse's vertexMarks insert above.
        if (fi <= m.faceMarks.length) m.faceMarks.insertInPlace(fi, 0u);
        // faceSelectionOrder shifts in LOCKSTEP too (task 0922 — the reverse
        // twin of the forward drop-filter fixed above). SelectionDelta only
        // ever patches the Select BIT (see patchSelection below); it does not
        // touch the pick-order stamp. Task 1902 Stage H: when `ord` is
        // carried, insert the DROPPED face's own recorded stamp instead of
        // the earlier unconditional 0 — the same carried/not-carried split
        // `facePrt`/`faceSetMsk` already use below.
        if (fi <= m.faceSelectionOrder.length)
            m.faceSelectionOrder.insertInPlace(fi, haveOrd ? ord[i] : 0);
    }
    // Restore parallel per-face arrays (material / part / subpatch) where
    // carried. The face SELECT bit is restored by the SelectionDelta /
    // whole-array path, not here (see faceSelectionOrder's own insert above
    // for why the pick-order STAMP is not restorable that way).
    if (mat.length == idx.length) {
        foreach (i, fi; idx) {
            // `<=`, not `<` (task 0922): `fi == m.faceMaterial.length` is the
            // legal TAIL-insert case `insertInPlace` accepts, and `facePart`
            // just below already uses `<=` for the identical insert. The
            // stricter `<` silently skipped exactly that tail re-insertion,
            // leaving a re-inserted face's material lost — not merely
            // deferred to finalize()'s tail pad, since that pad writes 0 at
            // the array's OWN new tail, which after this skip is one slot
            // short of where the restored face actually landed.
            if (fi <= m.faceMaterial.length) {
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
    // Task 1060, Stage 5c / review SHOULD-FIX 4: `faceSetMask` rides the SAME
    // carried/not-carried split `prt` uses just above, NOT an unconditional
    // 0-insert. The earlier comment here claimed this matched an "inherited"
    // limit of the per-face-part data — that was wrong: all four live
    // `recordRemoveFaces` call sites (`Mesh.deleteFacesByMask`,
    // `Mesh.dissolveVerticesByMask`, the merge path, `extrudeFacesByMask`)
    // already populate and pass `prt`, so `facePrt`'s "not carried" arm is
    // dead in practice — only reachable from a hand-built (pre-1060)
    // `MeshOpEntry`. `faceSetMask` had no capture field at all until this
    // fix, so its 0-insert was the ONLY reachable arm: every face-delete undo
    // silently dropped the restored face's set membership while its material
    // and part id came back correctly. Carried the same way `prt` is.
    if (setm.length == idx.length) {
        foreach (i, fi; idx) {
            if (fi <= m.faceSetMask.length)
                m.faceSetMask.insertInPlace(fi, setm[i]);
        }
    } else {
        // Not carried (a hand-built entry with no faceSetMsk, e.g. this
        // module's own S2 unittest fixture): insert 0UL to keep length
        // aligned with `m.faces`, same as `prt`'s fallback arm above.
        foreach (i, fi; idx) {
            if (fi <= m.faceSetMask.length)
                m.faceSetMask.insertInPlace(fi, 0UL);
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
    // §3.1 Select ∧ Hide = ∅ (doc/hide_geometry_plan.md, code review task
    // 0613 — S2) — this sparse patch is the delta-backed undo/redo replay's
    // own Select writer (delete / remove / edge extrude / edge extend), and
    // it does not go through any of mesh.d's guarded selectX /
    // setXSelectedFrom primitives. Refuse the same way they do — silently —
    // or a redo/undo round-trip could resurrect a Select bit on an element
    // that is (still) hidden at this index.
    if (on != 0 && (word & Mesh.Marks.Hide) != 0) return;
    if (on) word |=  Mesh.Marks.Select;
    else    word &= ~Mesh.Marks.Select;
}

private void patchSubpatch(ref Mesh m, in uint[] idx, in uint[] vals) {
    foreach (i, e; idx)
        if (e < m.faceMarks.length)
            m.setFaceSubpatch(e, vals[i] != 0);
}

// Mirrors patchSubpatch (task 0613 §4.2/S1) — sparse face-indexed Hide patch.
// Routes through setHideBit below rather than poking the word directly, for
// the same reason setSelectBit exists just above: this is a mark WRITER and
// owes the §3.1 invariant, not a caller-side convenience.
private void patchHide(ref Mesh m, in uint[] idx, in uint[] vals) {
    foreach (i, e; idx)
        if (e < m.faceMarks.length)
            setHideBit(m.faceMarks[e], vals[i]);
}

private void setHideBit(ref uint word, uint on) {
    // §3.1 Select ∧ Hide = ∅ — the same invariant setSelectBit enforces from
    // the OTHER direction (refuse Select while Hide is set); this is the Hide
    // side of it (clear Select when Hide gets set). Raw bit-twiddle — no
    // commitChange, no refreshHiddenDerived here: finalize() does both ONCE
    // for the whole replay (same convention as patchSubpatch/patchMaterial),
    // and refreshHiddenDerived() is what re-derives the vertex/edge planes
    // afterward — this function only owns the authoritative face bit.
    if (on != 0) {
        word |= Mesh.Marks.Hide;
        word &= ~Mesh.Marks.Select;
    } else {
        word &= ~Mesh.Marks.Hide;
    }
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
                      in uint[] edgeSelEnds = null, bool haveEdgeSel = false,
                      bool cornersRenumbered = false,
                      CornerCarry* carry = null) {
    // Per-corner (PolyVertex) map carry (task 0689) — FIRST, while the maps are
    // still in the pre-replay corner space and before `buildLoops` re-lays the
    // loop array. It leaves every map length-correct for the replayed faces, so
    // `resizePolyVertexMaps` inside `buildLoops` then no-ops (the same
    // relocate-then-rebuild order every kernel in mesh.d uses). May deactivate
    // itself on a self-check failure, in which case the stated drop below takes
    // over — so read `carry.active` AFTER this call, never before.
    if (carry !is null) carry.commit(m);
    const bool carried = (carry !is null && carry.active);
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
    // Task 1060 review SHOULD-FIX 3: `faceSetMask` was missing from this
    // length sync. `AddFaces`'s forward/reverse (`m.faces ~= …` / `m.faces.length
    // = f0`) carry NO parallel-array payload of their own — same as
    // facePart/faceMaterial, they rely entirely on this blanket resize to stay
    // aligned. Without this line an AddFaces-revert SHRINK left `faceSetMask`
    // over-long with stale, now out-of-range LIVE bits (add faces, put them in
    // a polygon set, undo): `selSetMembersPolygon` walks the mask, not
    // `m.faces`, so those out-of-range indices reached `/api/model` and the
    // `.v3d` writer, and the loader's own bounds guard then dropped the WHOLE
    // set on reload rather than the one stale entry.
    m.faceSetMask.length          = m.faces.length;
    m.resizeAllMeshMaps();
    // Per-corner maps (task 0689): the FALLBACK, reached only when the carry
    // above declined (no map, maps out of step at entry, or its self-check
    // fired). A replay that renumbered corners and carried no values must DROP
    // them explicitly — see `renumbersCorners` above for which entries count
    // and why the length test in `resizePolyVertexMaps` (already run by
    // `buildLoops`) cannot be trusted to catch this on its own. No-op when the
    // mesh has no per-corner map (the common case) or when nothing renumbered.
    if (!carried && cornersRenumbered) m.dropPolyVertexMaps();
    // Hide (code review, task 0613 — S4): refresh the derived vertex/edge
    // planes NOW, right after the length-resize above and BEFORE the edge
    // selection restore below. `rebuildEdges()` gave `edges`/`edgeIndexMap` a
    // brand-new index space, but `edgeMarks.length = m.edges.length` just
    // above is a raw truncate/grow — it does not move any bits — so until
    // this call, `edgeMarks[ei]`'s Hide bit is whatever stale word already
    // sat at position `ei` from BEFORE this transaction, not this edge's
    // real hidden state. `applyEdgeSelByEnds` (via the guarded `selectEdge`)
    // would otherwise filter against those stale bits instead of the correct
    // ones. faceMarks/vertexMarks ARE correct for their identity by this
    // point — but NOT because indices are merely "restored positionally":
    // the FORWARD direction (removeFacesForward / the RemoveVerts+Reindex
    // pair) is a real compaction (drop + shift), and the REVERSE direction
    // (removeFacesReverse / removeVertsReverse) re-grows the array via
    // insertInPlace at each recorded index — both a form of index movement.
    // Each of those four functions was written to carry the WHOLE marks word
    // through its own transformation (a parallel drop-filter on the forward
    // side, a parallel insertInPlace on the reverse side — task 0613 §4.2/S2
    // code review; a prior version of this comment claimed the positional
    // case never arises, which was true only of the reverse direction and
    // left the forward direction's compaction unfixed). Only the DERIVED
    // edge plane (and any transient vertex/edge desync from the resize
    // itself) needs this call's recompute.
    m.refreshHiddenDerived();
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
    // This raw bump touches topologyVersion only. It is decoupled from the
    // structVersion-keyed loops/edgeIndexMap validity stamp (mesh.d) — that
    // stamp is set by the rebuildEdges()+buildLoops() pair above, which
    // already landed Valid regardless of this line.
    if (!(scope_ & MeshEditScope.Geometry)) ++m.topologyVersion;
}

// Re-select the edges named by the flat vertex-index endpoint pairs
// [a0,b0, a1,b1, …] through the freshly-rebuilt edgeIndexMap. An endpoint pair
// with no matching edge (geometry diverged) is silently skipped.
private void applyEdgeSelByEnds(ref Mesh m, in uint[] ends) {
    import mesh : edgeKey;
    // Settled-mesh precondition (debug-only, stripped from release builds —
    // task 0724 / audit-4 M6). "Freshly-rebuilt" in the doc comment above is
    // exactly `edgeMapUsable()`: this helper resolves endpoint pairs THROUGH
    // the map, and a stale map does not fail loudly — it resolves the pair to
    // whatever edge index the PREVIOUS topology had, silently selecting the
    // wrong edge. The only caller is the delta finalizer below, which runs
    // rebuildEdges() + buildLoops() first.
    //
    // TASK 0833 — NOT demonstrable, and deliberately left that way. This
    // function is module-PRIVATE with exactly one caller, so the only way a
    // test could hand it a stale map is to widen its visibility; making a
    // guard reachable by loosening the very encapsulation that bounds its
    // caller set answers the wrong question. The identical body one function
    // down (`restoreSelectedEdgeEnds`) IS module-public, and its guard is
    // pinned by a stale-read test in tests/unit/mesh_edit_delta_test.d — so
    // the BEHAVIOUR is demonstrated; what is undemonstrated here is only the
    // reachability of this copy. Kept because it costs one debug-only compare
    // and it is what would catch a SECOND in-module caller added later.
    m.assertEdgeMapValid();
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
    // Settled-mesh precondition (debug-only — task 0724 / audit-4 M6). Same
    // silent-wrong-answer shape as applyEdgeSelByEnds: "the live
    // edgeIndexMap" in the doc comment above IS the stamp. This one is
    // module-PUBLIC, so unlike its private twin the set of callers is open —
    // the assert is what keeps a future destructive command from restoring
    // the edge selection against a map its kernel never rebuilt.
    // TASK 0833 — demonstrated live: tests/unit/mesh_edit_delta_test.d hands
    // this an importer-shaped mesh (`addFaceFast`, no terminal buildLoops) and
    // requires the throw, then requires the same call to land the selection
    // after buildLoops(). Deleting this line turns that block red.
    m.assertEdgeMapValid();
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

// ---------------------------------------------------------------------------
// T-OBJ4 (doc/hide_geometry_plan.md §7.1) — a SelectionDelta replay cannot
// select a hidden element. `recordSelectionDelta` itself has no production
// caller yet (same dormant status as `recordSubpatchDelta`/`recordHideDelta`
// — grep finds only this file's definition and dispatch), so this pins the
// invariant before the first real caller inherits it, not after.
//
// Discriminator: the delta patches BOTH a hidden face (2) and a visible one
// (3) in ONE entry. A delta touching only the hidden face could not tell
// "the guard fired" from "the replay did nothing" — both read
// isFaceSelected(2)==false. Requiring face 3 to end up selected proves the
// replay actually ran and the guard is selective, not a blanket no-op.
unittest {
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.setFaceHidden(2, true);
    assert(!m.isFaceSelected(2), "hiding drops any prior selection (§3.1)");

    MeshEditTracker rec;
    rec.recordSelectionDelta(MeshOpEntry.SelDomain.Face, [2, 3], [0, 0], [1, 1]);
    auto delta = rec.finish();
    assert(delta.apply(m));

    assert(!m.isFaceSelected(2),
        "T-OBJ4: setSelectBit must refuse Select on a hidden face during replay");
    assert(m.isFaceSelected(3),
        "T-OBJ4: the SAME replay must still select the untouched visible face — "
        ~ "otherwise the guard could be a blanket no-op instead of a selective refusal");
}


// ---------------------------------------------------------------------------
// S2 code review (doc/hide_geometry_plan.md §4.2 — "the face-side twin of
// the vertex-mark permutation gap"): removeFacesForward/Reverse must carry
// the WHOLE faceMarks word through the compaction in BOTH directions, the
// same way applyReindexForward/Reverse already do for vertexMarks. Fixture:
// 4 fully disconnected triangles (no shared vertices/edges — irrelevant to
// this test, which only exercises the array-compaction mechanics) so
// rebuildEdges()/buildLoops() inside finalize() have nothing non-manifold to
// trip over.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),  Vec3(1, 0, 0),  Vec3(0, 1, 0),    // face0 — dropped
        Vec3(10, 0, 0), Vec3(11, 0, 0), Vec3(10, 1, 0),   // face1 — survivor, HIDDEN
        Vec3(20, 0, 0), Vec3(21, 0, 0), Vec3(20, 1, 0),   // face2 — survivor
        Vec3(30, 0, 0), Vec3(31, 0, 0), Vec3(30, 1, 0),   // face3 — survivor
    ];
    m.addFace([0, 1, 2]);
    m.addFace([3, 4, 5]);
    m.addFace([6, 7, 8]);
    m.addFace([9, 10, 11]);
    m.buildLoops();
    m.syncSelection();
    m.setFaceHidden(1, true);   // face1, at its PRE-drop index
    assert(m.isFaceHidden(1));

    MeshOpEntry removeEntry;
    removeEntry.kind      = MeshOpEntry.Kind.RemoveFaces;
    // `assumeFaceSpace` (task 0831): a hand-built entry has no live mesh walk
    // to mint from, and a fixture asserting its own index space is exactly the
    // caller the escape exists for.
    removeEntry.fIdx      = [FaceIdx.assumeFaceSpace(0)];  // drop face0 — NOT the
                                               // highest index, so every survivor must shift down
    removeEntry.faceLists = [[0u, 1u, 2u]];
    removeEntry.faceMat   = [0u];
    removeEntry.facePrt   = [0u];
    removeEntry.faceSub   = [0u];

    MeshEditDelta delta;
    delta.log = [removeEntry];

    // FORWARD (apply/redo) — S2's primary finding: removeFacesForward used
    // to compact `m.faces` without moving `m.faceMarks` at all.
    assert(delta.apply(m));
    assert(m.faces.length == 3, "one face dropped");
    assert(m.isFaceHidden(0),
        "S2 forward: surviving hidden face (old face1) must carry its Hide "
        ~ "bit to its NEW compacted index (0), not leave it stranded at the "
        ~ "stale word finalize()'s truncate would otherwise read");
    assert(!m.isFaceHidden(1) && !m.isFaceHidden(2),
        "S2 forward: no OTHER face may have picked up the bit");

    // REVERSE (revert/undo), continuing from the compacted state above —
    // removeFacesReverse used to insertInPlace `m.faces` (and
    // faceMaterial/facePart) but never `m.faceMarks`.
    assert(delta.revert(m));
    assert(m.faces.length == 4, "the dropped face must be re-inserted");
    assert(m.isFaceHidden(1),
        "S2 reverse: the hidden face must return to its ORIGINAL pre-drop "
        ~ "index (1)");
    assert(!m.isFaceHidden(0) && !m.isFaceHidden(2) && !m.isFaceHidden(3),
        "S2 reverse: no OTHER face may have picked up the bit");
}

// ---------------------------------------------------------------------------
// Task 1060 review SHOULD-FIX 3: `finalize()`'s length sync omitted
// `faceSetMask`. `AddFaces` (forward: `m.faces ~= …`; reverse: `m.faces.length
// = f0`) carries no parallel-array payload of its own — like `facePart`/
// `faceMaterial`, it relies ENTIRELY on finalize()'s blanket resize to stay
// aligned with `m.faces`. Reproduces the review's exact scenario: add a face,
// put it in a polygon set, undo the add.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    import mesh_selsets : selSetEditPolygon, selSetMembersPolygon, SetEditMode;

    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),  Vec3(1, 0, 0),  Vec3(0, 1, 0),      // face0 — pre-existing
        Vec3(10, 0, 0), Vec3(11, 0, 0), Vec3(10, 1, 0),     // face1 — added by the entry
    ];
    m.addFace([0, 1, 2]);
    m.buildLoops();
    m.syncSelection();
    assert(m.faces.length == 1, "setup: one pre-existing face");

    MeshOpEntry addEntry;
    addEntry.kind      = MeshOpEntry.Kind.AddFaces;
    addEntry.fIdx      = [FaceIdx.assumeFaceSpace(1)];   // F0 = 1 (pre-add face count)
    addEntry.faceLists = [[3u, 4u, 5u]];

    MeshEditDelta delta;
    delta.log = [addEntry];

    assert(delta.apply(m), "forward replay (the add) must succeed");
    assert(m.faces.length == 2, "setup: the second face must have been appended");

    // Put the newly added face into a polygon set — through the real
    // selection-set API, not a raw poke, so this exercises the write path a
    // user's `select.set.store`/`.edit` actually takes.
    bool[] sel = new bool[](m.faces.length);
    sel[1] = true;
    selSetEditPolygon(m, "S", SetEditMode.add, sel);
    assert(m.faceSetMask.length >= 2 && (m.faceSetMask[1] & 1UL) != 0,
        "setup: face 1 must be a live member of set S");

    // Undo: AddFaces^-1 truncates m.faces back to 1. Before this fix,
    // finalize()'s length sync omitted faceSetMask, so it stayed at length 2
    // with face-index-1's bit still LIVE — an out-of-range member relative to
    // the post-undo face count.
    assert(delta.revert(m), "reverse replay (the undo) must succeed");
    assert(m.faces.length == 1, "setup: the added face must be gone again");
    assert(m.faceSetMask.length == m.faces.length,
        "faceSetMask must stay length-aligned with m.faces after an "
      ~ "AddFaces revert — got " ~ to!string(m.faceSetMask.length)
      ~ " against " ~ to!string(m.faces.length) ~ " faces");

    // The membership-enumeration consequence the review traced all the way to
    // /api/model and the .v3d writer (whose loader guard then drops the WHOLE
    // set on an out-of-range member): no reported member may be out of range.
    auto members = selSetMembersPolygon(m, "S");
    foreach (fi; members)
        assert(fi < m.faces.length,
            "an out-of-range polygon-set member reached the membership walk");
}
