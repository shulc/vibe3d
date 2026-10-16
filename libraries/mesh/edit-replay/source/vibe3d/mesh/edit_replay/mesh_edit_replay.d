module vibe3d.mesh.edit_replay.mesh_edit_replay;
import vibe3d.mesh.edit_log.mesh_edit_delta;

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

import vibe3d.mesh.change.change_bus : changeBus;   // the seam counters (task 1903 §5.8 / L1-P1)

import vibe3d.mesh.core.mesh;            // Mesh, Marks, edgeKey (mutual import — see note below)
import vibe3d.util.math.math : Vec3;
import vibe3d.mesh.core.mesh_selsets : selSetRekeyEdges, selSetGatherVertexMaskForward,
    selSetGatherVertexMaskReverse, selSetDropFilterVertexMask, WireKeyPolicy;
import vibe3d.mesh.core.mesh_planes : kNoSource, FaceSource, rewriteFaces,
                     kFacePlanes, kFacePlaneEntryField, FaceReindexRecord;   // task 1902 Stage H —
    // FaceReindex forward replay is the primitive itself (plan §7.2: "one
    // implementation, so replay and live edit cannot drift"). No cycle:
    // mesh_planes.d does not import mesh_edit_delta.d.

// NOTE on the mesh <-> mesh_edit_delta mutual import: D handles mutual module
// imports fine; there is no module-ctor cycle here (these are plain structs +
// free logic, no static this()). mesh.d holds a `MeshEditTracker*` and calls
// the recorder's `record*` methods from its mutation primitives; this module's
// apply()/revert() take `ref Mesh`. Neither references the other at static-init.

// ---------------------------------------------------------------------------
// THE `VIBE3D_UNDO_TRACKER` ESCAPE HATCH LIVED HERE AND IS GONE (task 1903
// stage N). It was a process-wide, read-once module global that fifteen sites
    // Forward replay — redo. Plays the log in execution order; each entry
    // re-applies its forward effect, then finalize() re-derives edges/loops.
    bool apply(ref const MeshEditDelta delta, ref Mesh m) {
        const auto log = delta.log;
        const auto scope_ = delta.scope_;
        // Per-corner (PolyVertex) map carry — task 0689. Snapshotting the
        // provenance BEFORE the first entry is the whole point: from here on
        // `faces` moves and the live corner indices move with it.
        // On apply/redo we want the POST-op selection, so the scan reads
        // `edgeEndsAfter`; `revert` below is the same code over
        // `edgeEndsBefore`.
        const(uint)[] edgeSel = null;
        bool haveEdgeSel = false;
        foreach (ref e; log)
            if (e.kind == MeshOpEntry.Kind.EdgeSelByEnds) {
                edgeSel = e.edgeEndsAfter;
                haveEdgeSel = true;
            }
        // TASK 1903 L0.P1 — ONE boolean, computed ONCE, ABOVE the replay loop.
        //
        // The `EdgeSelByEnds` scan is over `log` and independent of the replay,
        // so it hoists cleanly — and it MUST hoist. `indexSpaceStable(log)`
        // alone is a LOG-ONLY predicate; a `fast` wired to `finalize` from that
        // alone would lose the `edgeMapUsable` term, and losing it is not
        // loud. The edge-selection restore resolves endpoint pairs through
        // `edgeIndexMap`, whose validity stamp is refreshed by the very
        // rebuildEdges+buildLoops pair the fast path skips. If the map was
        // Valid on entry it stays Valid (nothing in a stable log bumps
        // `structVersion`); if it was INVALID on entry — the importer shape,
        // `addFaceFast` with no terminal `buildLoops` — today's path REPAIRS it
        // and the fast path would not, resolving each pair against the previous
        // topology's edge index and selecting the WRONG edges. Silently: the
        // guard that would catch it (`assertEdgeMapValid`) is `debug`-only and
        // the suite lane does not compile it. So: an invalid map with an
        // `EdgeSelByEnds` entry takes the SLOW path, which is exactly today's
        // behaviour.
        //
        // L1-P1 — `stable` is now NAMED rather than folded straight into
        // `fast`, because the replay loop needs the LOG-ONLY half on its own:
        // a `MapValueDelta` is refused when some other entry re-lays an index
        // space, and that question has nothing to do with `edgeMapUsable`.
        const bool stable = indexSpaceStable(log);
        const bool fast = stable
                       && (!haveEdgeSel || m.edgeMapUsable());
        const StableEntry e0 = captureStableEntry(m);
        CornerCarry carry;
        // Skipped on the fast path: on an all-stable log `begin` records
        // identity provenance, `commit`'s self-check cannot fire (nothing moved
        // faces) and the whole thing degenerates to a byte-identical gather.
        // The skip removes an O(F) allocation and an O(corners x maps) gather.
        if (!fast) carry.begin(m, log);
        foreach (i, ref e; log) {
            // THE MAP-VALUE EXCLUSION, REPLAY HALF (task 1903 L1-P1). The
            // SAME rule in both directions, deliberately spelled twice rather
            // than hoisted: a map value is addressed in its map's own element
            // space, and an unstable log means some OTHER entry is re-laying
            // that space, so writing here would land the values on the wrong
            // elements — silently, since for a `morphAbsolute` map a wrong
            // entry is a legal one. The geometry half of the log still
            // reverts; the map half is refused, counted and visible in the
            // plane dump as a plane that did not come back.
            //
            // This is the layer a caller cannot bypass: the recorder door can
            // be sidestepped with a hand-built entry (that is how every kind
            // with no production recorder is tested), `apply`/`revert` cannot.
            if (e.kind == MeshOpEntry.Kind.MapValueDelta && !stable) {
                ++changeBus.mapDeltaMixRefused;
                continue;
            }
            // Compaction pair (RemoveVerts immediately followed by Reindex): the
            // Reindex's perm carries the FULL old->new map INCLUDING the dropped
            // (~0u) slots, so restoreVertexReindexForward both drops AND repacks. The
            // preceding RemoveVerts forward must therefore be a NO-OP — otherwise
            // it would drop the verts first, shifting indices out from under the
            // perm (which is keyed in the pre-drop index space) → corruption.
            // (RemoveVerts' positions are only needed on REVERSE, to re-insert.)
            if (e.kind == MeshOpEntry.Kind.RemoveVerts
                && i + 1 < log.length
                && log[i + 1].kind == MeshOpEntry.Kind.Reindex)
                continue;
            carry.step(m, i, e, /*forward=*/true);
            // The stated drop inside `restoreFaceReindexForward` is now the
            // FALLBACK, not the policy: `CornerCarry` has a `Kind.FaceReindex`
            // case as of task 1903 Stage J, and `carry.active` — read AFTER the
            // step, which is where the case declines if it cannot vouch for
            // itself — is what says which of the two is in charge.
            applyForward(m, e, carry.active);
        }
        // Edge selection is endpoint-keyed and must be re-applied AFTER finalize
        // rebuilds the edge array + edgeIndexMap (edge indices are unstable
        // across rebuildEdges) — scanned above the loop, see the block there.
        finalize(m, scope_, edgeSel, haveEdgeSel, renumbersCorners(log),
                 fast ? null : &carry, log, fast, e0);
        return true;
    }

    // Reverse replay — undo. Plays the log LIFO; each entry inverts itself,
    // then finalize() re-derives edges/loops. See doc §2.3 for the extrude
    // reverse-composition trace this generalizes.
    bool revert(ref const MeshEditDelta delta, ref Mesh m) {
        const auto log = delta.log;
        const auto scope_ = delta.scope_;
        // On revert we want the PRE-op (before) edge selection.
        const(uint)[] edgeSel = null;
        bool haveEdgeSel = false;
        foreach (ref e; log)
            if (e.kind == MeshOpEntry.Kind.EdgeSelByEnds) {
                edgeSel = e.edgeEndsBefore;
                haveEdgeSel = true;
            }
        // TASK 1903 L0.P1 — ONE boolean, computed ONCE, ABOVE the replay loop.
        //
        // The `EdgeSelByEnds` scan is over `log` and independent of the replay,
        // so it hoists cleanly — and it MUST hoist. `indexSpaceStable(log)`
        // alone is a LOG-ONLY predicate; a `fast` wired to `finalize` from that
        // alone would lose the `edgeMapUsable` term, and losing it is not
        // loud. The edge-selection restore resolves endpoint pairs through
        // `edgeIndexMap`, whose validity stamp is refreshed by the very
        // rebuildEdges+buildLoops pair the fast path skips. If the map was
        // Valid on entry it stays Valid (nothing in a stable log bumps
        // `structVersion`); if it was INVALID on entry — the importer shape,
        // `addFaceFast` with no terminal `buildLoops` — today's path REPAIRS it
        // and the fast path would not, resolving each pair against the previous
        // topology's edge index and selecting the WRONG edges. Silently: the
        // guard that would catch it (`assertEdgeMapValid`) is `debug`-only and
        // the suite lane does not compile it. So: an invalid map with an
        // `EdgeSelByEnds` entry takes the SLOW path, which is exactly today's
        // behaviour.
        //
        // L1-P1 — `stable` is now NAMED rather than folded straight into
        // `fast`, because the replay loop needs the LOG-ONLY half on its own:
        // a `MapValueDelta` is refused when some other entry re-lays an index
        // space, and that question has nothing to do with `edgeMapUsable`.
        const bool stable = indexSpaceStable(log);
        const bool fast = stable
                       && (!haveEdgeSel || m.edgeMapUsable());
        const StableEntry e0 = captureStableEntry(m);
        CornerCarry carry;
        if (!fast) carry.begin(m, log);   // identity on a stable log — see apply
        foreach_reverse (i, ref e; log) {
            // THE MAP-VALUE EXCLUSION, REPLAY HALF (task 1903 L1-P1). The
            // SAME rule in both directions, deliberately spelled twice rather
            // than hoisted: a map value is addressed in its map's own element
            // space, and an unstable log means some OTHER entry is re-laying
            // that space, so writing here would land the values on the wrong
            // elements — silently, since for a `morphAbsolute` map a wrong
            // entry is a legal one. The geometry half of the log still
            // reverts; the map half is refused, counted and visible in the
            // plane dump as a plane that did not come back.
            //
            // This is the layer a caller cannot bypass: the recorder door can
            // be sidestepped with a hand-built entry (that is how every kind
            // with no production recorder is tested), `apply`/`revert` cannot.
            if (e.kind == MeshOpEntry.Kind.MapValueDelta && !stable) {
                ++changeBus.mapDeltaMixRefused;
                continue;
            }
            carry.step(m, i, e, /*forward=*/false);
            applyReverse(m, e, carry.active);
        }
        // The pre-op edge selection is re-applied after finalize rebuilds edges
        // (doc §1.3 / §2.3 step 1's endpoint-keyed part) — scanned above.
        finalize(m, scope_, edgeSel, haveEdgeSel, renumbersCorners(log),
                 fast ? null : &carry, log, fast, e0);
        return true;
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
        return payloadForCount(i, fIdx.length);
    }

    // The same pairing, keyed by the number of faces the payload must cover
    // rather than by a `fIdx` list. `Kind.FaceReindex` has no per-face index
    // list for its payload to be parallel to — the payload covers EVERY old
    // face, `[0, oldFaceCount)` in order — so the count is what the adjacency
    // check has to compare against (task 1903 Stage J).
    private int payloadForCount(size_t i, size_t nFaces) const {
        if (i == 0) return -1;
        const p = &log[i - 1];
        if (p.kind != MeshOpEntry.Kind.MeshMapDelta) return -1;
        if (p.mapArity.length != nFaces) return -1;
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

    // Mirror of restoreRemoveFaces's drop-filter, on the provenance array.
    private void dropAt(in FaceIdx[] idx) {
        bool[] drop;
        drop.length = src.length;
        foreach (i; idx) if (i < drop.length) drop[i] = true;
        Src[] ns;
        ns.reserve(src.length);
        foreach (i, ref s; src) if (!drop[i]) ns ~= s;
        src = ns;
    }

    // Resolve ONE new face's provenance from the provenance of the OLD face it
    // came from, given the two windings.
    //
    // Equal windings keep the slot-for-slot run — the documented convention
    // that per-corner values are addressed by (face, corner). Anything else
    // matches each new corner to the old corner standing on the SAME VERTEX,
    // which is exactly what `reshapeSrc` does for an arity change and what
    // `Mesh.carryPolyVertexMapsByCorner` (the LIVE carry this replay has to
    // reproduce) does for every corner; a new corner whose vertex the old face
    // never had gets NO source ⇒ the honest zero.
    //
    // A source whose values live in a PAYLOAD rather than in the live map
    // cannot be vertex-matched (`explicit` names LIVE corners, and there is no
    // slot in `Src` for "payload corner k at slot j"), so a winding change on
    // top of a payload declines to zero — the same answer `reshapeSrc` gives
    // in the same situation. Unreachable in FORWARD replay, where no branch
    // ever sets a payload; kept so the shape cannot be wrong later.
    // `s0` by VALUE, not `in`: `Src` holds a slice (`explicit`), and D
    // refuses a `const(Src)` -> `Src` copy for exactly that reason.
    private static Src reslotFrom(Src s0, const(uint)[] from, const(uint)[] to) {
        Src s = s0;
        s.arity = cast(uint) to.length;
        if (from == to) return s;                 // slot-for-slot, payload intact
        uint[] ex;
        ex.length = to.length;
        ex[] = ~0u;
        if (s0.payload < 0) {
            foreach (j, v; to) {
                foreach (k, u; from)
                    if (u == v) { ex[j] = liveCornerOf(s0, k); break; }
            }
        }
        s.explicit = ex;
        s.liveBase = ~0u;
        s.payload  = -1;
        s.recBase  = 0;
        return s;
    }

    // FaceReindex, forward (redo). The entry's `faceOldOfNew` is TOTAL over the
    // NEW face array, so the provenance array is rebuilt new-face by new-face
    // out of the old one — the same shape `mesh_planes.rewriteFaces` carries
    // its five per-face planes with, applied to corner provenance.
    private void faceReindexForward(ref Mesh m, ref const MeshOpEntry e) {
        // `src` and the live mesh must both describe the PRE-rewrite face
        // array this entry names, or `faceOldOfNew` would be resolved against
        // a foreign index space. Decline rather than guess (this struct's own
        // safety rule): the caller's stated drop then takes over.
        if (src.length != e.oldFaceCount || m.faces.length != e.oldFaceCount) {
            active = false;
            return;
        }
        Src[] ns;
        ns.length = e.faceOldOfNew.length;
        foreach (nf, of; e.faceOldOfNew) {
            const(uint)[] to = (nf < e.newFaceLists.length) ? e.newFaceLists[nf] : null;
            // CREATE (`kNoSource`): a new face with no ancestor, so there is no
            // corner anywhere to COPY from. ZERO — and that is MEASURED, not
            // chosen: the live forward op resolves such a face through
            // `Mesh.CornerRewrite.carriedPerFace`, whose `srcFaceOfNewFace`
            // entry is `~0u`, so `carryPolyVertexMapsByCorner` finds no source
            // face, writes `~0u` into `oldLoopOfNewLoop`, and
            // `remapPolyVertexMaps` zeroes the corner. Replaying anything else
            // here would make a redo disagree with the edit it redoes.
            //
            // SCOPE, exact (review round 1, MINOR-3): zero is the live answer
            // ABSENT A `PolyVertexGen` ON THAT CORNER. The gen pass inside
            // `carryPolyVertexMapsByCorner` runs AFTER the copy and is
            // addressed by LOOP, not by face, so a gen CAN write a
            // `kNoSource` face's corners — and then the live op's answer is
            // the generated value, not zero. No site does that today
            // (a face extrude's gens sit on the walls, which have a source
            // face), and the entry records no gen list, so this branch cannot
            // reproduce one. The day a site does, this is where the redo
            // diverges, and it is the same recorded remainder as the blend
            // corners named in `faceReindexReverse`'s comment below.
            if (of == kNoSource || of >= src.length) {
                ns[nf] = Src(~0u, cast(uint) to.length, null, -1, 0);
                continue;
            }
            // DUPLICATE: several new faces may name ONE old face. `src[of]` is
            // READ here, never consumed — a copy, not a move — so the second
            // and tenth namer inherit the same corner values as the first.
            // (Moving instead is the failure mode M-J mutates in: the first
            // duplicate keeps the UV and every later one comes back zeroed.)
            ns[nf] = reslotFrom(src[of], m.faces[of], to);
        }
        src = ns;
    }

    // FaceReindex, reverse (undo) — the half undo actually runs.
    //
    // The forward carry is MANY-TO-ONE and lossy: a corner standing on an
    // inserted vertex was a weighted BLEND of old corners and a wall corner was
    // GENERATED (`PolyVertexGen`), and neither the blend table nor the gen list
    // is recorded in the entry. So the pre-op corner values cannot be recovered
    // by inverting the correspondence, and this reverse does not try: it reads
    // them from the payload `mesh_planes.rewriteFaces` captured immediately
    // before the rewrite — one arity + one value block per OLD face, the same
    // `Kind.MeshMapDelta` channel `RemoveFaces`'s reverse already uses (task
    // 0689), paired by adjacency + count.
    //
    // With the payload every shape is exact: a survivor, a duplicate's source,
    // and a DROPPED old face (which has no live representative at all and is
    // the one shape a correspondence could never restore) all come back byte
    // for byte, and a CREATED face simply has no old slot to occupy.
    // Without it the carry declines, and the stated drop in
    // `restoreFaceReindexReverse` is what runs — today's behaviour, unchanged.
    private void faceReindexReverse(ref Mesh m, size_t i, ref const MeshOpEntry e) {
        if (src.length != e.faceOldOfNew.length
            || m.faces.length != e.faceOldOfNew.length) {
            active = false;
            return;
        }
        const int p = payloadForCount(i, e.oldFaceCount);
        if (p < 0) { active = false; return; }
        Src[] ns;
        ns.length = e.oldFaceCount;
        // Running corner base rather than `recBaseOf` per face: that helper
        // prefix-sums from 0 on every call, which is O(faces²) over a whole-
        // mesh rewrite (memory `on2_traps_in_mesh`).
        uint base = 0;
        foreach (of; 0 .. e.oldFaceCount) {
            const uint a = log[p].mapArity[of];
            ns[of] = Src(~0u, a, null, p, base);
            base += a;
        }
        src = ns;
    }

    // Track ONE entry's effect on the face array, in the direction it is being
    // replayed. Every branch mirrors the corresponding branch of
    // applyForward / applyReverse EXACTLY — that correspondence is the whole
    // correctness argument, and `commit`'s length check is its backstop.
    //
    // `m` is the mesh as it stands BEFORE this entry is applied (both
    // directions — `apply`/`revert` call this immediately before
    // `applyForward`/`applyReverse`), which is what lets the FaceReindex case
    // read the windings it is about to leave behind.
    void step(ref Mesh m, size_t i, ref const MeshOpEntry e, bool forward) {
        if (!active) return;
        switch (e.kind) {
            case MeshOpEntry.Kind.FaceReindex:
                if (forward) faceReindexForward(m, e);
                else         faceReindexReverse(m, i, e);
                break;
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
        // The backstop — and it must DECLARE the loss, not merely stop.
        //
        // Every OTHER decline in this struct is set inside `step`, which runs
        // immediately BEFORE its entry's apply, so `restoreFaceReindexForward` /
        // `restoreFaceReindexReverse` read `cornerCarryActive == false` and state
        // `CornerDrop.DeltaReplayDeclined` themselves. This one cannot borrow
        // that: `commit` is called from `finalize`, AFTER every apply has run
        // and read `active` as `true`. Nothing downstream covers it —
        // `finalize`'s own `if (!carried && cornersRenumbered)
        // m.dropPolyVertexMaps();` sits AFTER `buildLoops()`, and
        // `resizePolyVertexMaps` (inside `buildLoops`) therefore arrives with
        // no declaration and no armed rewrite, falls through to its
        // length-insurance tail, and hits the `debug assert(false, …)` task
        // 0901 put there for "a kernel outside the census". That is an ABORT,
        // not the graceful degrade this self-check is for (and under `-release`
        // it is a silent zero-fill of a plane nobody said was lost).
        //
        // So declare here, which is the last moment still ahead of the rebuild:
        // `resizePolyVertexMaps` then returns from its `Dropped` branch with a
        // length-correct, honestly-blank map, exactly as the two `applyFaceRe-
        // index*` fallbacks produce.
        if (src.length != m.faces.length) {
            active = false;
            m.dropCornerProvenance(CornerDrop.DeltaReplayDeclined);
            return;
        }

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
// `CornerCarry.commit`'s self-check must DECLARE — review round 1, MAJOR-2.
//
// The two cells below are the only ones in the tree that reach
// `commit`'s `src.length != m.faces.length` arm, and they live HERE rather
// than in `tests/unit/` because both `CornerCarry` and `finalize` are
// module-private. They also cannot be driven through a recorded log: every
// `step` branch mirrors its `applyForward`/`applyReverse` twin exactly, and
// `mesh_planes.rewriteFaces` asserts `oldOfNew.length == newFaces.length`
// before a hand-edited `Kind.FaceReindex` entry could desynchronise the two.
// The arm is a backstop against a log shape the recorder does not produce
// today — so it is forced here, at the struct, the same way this module's two
// `version (UndoNegControl…)` stubs force their inverses.
//
// `cornersRenumbered` is passed FALSE on purpose in both. It is the second,
// unnamed guard that would otherwise refuse first: `finalize`'s own
// `if (!carried && cornersRenumbered) m.dropPolyVertexMaps();` would blank the
// plane after the fact and the cells would go green over a `commit` that
// declared nothing. With it false, the ONLY thing standing between the
// decline and the rebuild is the declaration inside `commit`.
//
// Two cells because the failure has two different shapes, and only one of them
// is loud:
//   * corner total CHANGED — `resizePolyVertexMaps` falls through to its
//     length-insurance tail with nothing declared and nothing armed, which is
//     the state task 0901 declared unreachable: a `debug assert(false, …)`
//     ABORT in the unit lane (which builds `-debug`), a silent zero-fill under
//     `-release`;
//   * corner total UNCHANGED — the insurance tail `continue`s, so there is no
//     abort in EITHER build type and every stale value stays put, now sitting
//     on another face's corners. Nothing in the tree would have reddened.
// ---------------------------------------------------------------------------

unittest // commit declines with the corner TOTAL changed: a stated drop, not an abort
{
    import std.format : format;
    import std.conv : to;

    // Two disconnected quads; a live UV map with every corner distinct and
    // non-zero, so "blank" is a real observation rather than the stand's own
    // resting state.
    Mesh m;
    m.vertices = [Vec3(0, 0, 0),  Vec3(1, 0, 0),  Vec3(1, 1, 0),  Vec3(0, 1, 0),
                  Vec3(10, 0, 0), Vec3(11, 0, 0), Vec3(11, 1, 0), Vec3(10, 1, 0)];
    m.addFace([0, 1, 2, 3]);
    m.addFace([4, 5, 6, 7]);
    m.buildLoops();
    m.syncSelection();

    auto uv0 = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv0 !is null, "stand: UV map registration must succeed");
    assert(uv0.data.length == 16,
           "stand: 8 corners x dim 2 — if this is not 16 the cell is measuring "
         ~ "a map that never described these faces");
    foreach (i; 0 .. uv0.data.length) uv0.data[i] = cast(float)(i + 1);

    CornerCarry carry;
    carry.begin(m, null);
    assert(carry.active,
           "stand: the carry must ACTIVATE, or the decline below would be the "
         ~ "entry decline (`begin`) rather than the self-check in `commit`");
    assert(carry.src.length == 2, "stand: one provenance entry per face");

    // The mesh moves on; the provenance array does not. Exactly the state the
    // self-check exists to catch, and exactly what review mutation R-3
    // produced from the other side (`ns ~= Src.init;` inside the forward case).
    m.faces.length = 1;

    finalize(m, MeshEditScope.Polygons, null, false, /*cornersRenumbered=*/false,
             &carry);

    assert(!carry.active,
           "the self-check must deactivate the carry when the provenance array "
         ~ "and `faces` disagree");
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null, "the map must still be REGISTERED — a decline is a "
                      ~ "stated loss of VALUES, not of the channel");
    assert(uv.data.length == 4 * uv.dim,
           format("a declined carry must leave the map length-correct for the "
                ~ "surviving faces (4 corners x dim %d), got %d floats",
                  uv.dim, uv.data.length));
    foreach (i, v; uv.data)
        assert(v == 0.0f,
               format("commit's decline must DECLARE the drop: float %d came "
                    ~ "back %s. Reaching this line at all means `buildLoops` "
                    ~ "did not abort on task 0901's census assert, which is "
                    ~ "the point of the fix; a NON-zero value here means the "
                    ~ "declaration was consumed by something other than "
                    ~ "`resizePolyVertexMaps`'s Dropped branch",
                      i, v.to!string));
}

unittest // commit declines with the corner total UNCHANGED: the arm nothing else catches
{
    import std.format : format;
    import std.conv : to;

    // Four disconnected triangles — 12 corners. The rewrite below turns them
    // into THREE quads over the same 12 vertices: the face count changes, the
    // corner total does not. So every map stays length-correct and
    // `resizePolyVertexMaps`'s insurance tail has no reason to fire.
    Mesh m;
    foreach (i; 0 .. 4) {
        const float x = i * 10.0f;
        m.vertices ~= Vec3(x, 0, 0);
        m.vertices ~= Vec3(x + 1, 0, 0);
        m.vertices ~= Vec3(x, 1, 0);
    }
    foreach (i; 0 .. 4)
        m.addFace([cast(uint)(i * 3), cast(uint)(i * 3 + 1), cast(uint)(i * 3 + 2)]);
    m.buildLoops();
    m.syncSelection();

    auto uv0 = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv0 !is null && uv0.data.length == 24,
           "stand: 12 corners x dim 2");
    foreach (i; 0 .. uv0.data.length) uv0.data[i] = cast(float)(i + 1);

    CornerCarry carry;
    carry.begin(m, null);
    assert(carry.active && carry.src.length == 4, "stand: four faces carried");

    m.faces.length = 3;
    m.faces[0] = [0u, 1u, 2u, 3u];
    m.faces[1] = [4u, 5u, 6u, 7u];
    m.faces[2] = [8u, 9u, 10u, 11u];
    size_t corners = 0;
    foreach (fi; 0 .. m.faces.length) corners += m.faces[fi].length;
    assert(corners == 12,
           "stand: the corner TOTAL must be unchanged, or this cell degenerates "
         ~ "into the previous one and stops testing the silent arm");

    finalize(m, MeshEditScope.Polygons, null, false, /*cornersRenumbered=*/false,
             &carry);

    assert(!carry.active, "the self-check must deactivate the carry");
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null, "the map must still be registered");
    assert(uv.data.length == 12 * uv.dim,
           format("length-correct for 12 corners, got %d floats", uv.data.length));
    foreach (i, v; uv.data)
        assert(v == 0.0f,
               format("commit's decline must DECLARE the drop even when the "
                    ~ "corner total is unchanged: float %d is still %s, a "
                    ~ "pre-decline value now standing on another face's "
                    ~ "corner. This is the arm no length test can see — "
                    ~ "`resizePolyVertexMaps` keeps a length-correct map "
                    ~ "whatever is in it, so without the declaration the "
                    ~ "plane survives SCRAMBLED and nothing reddens",
                      i, v.to!string));
}

// The mesh quantities `finalize`'s fast branch asserts UNMOVED, captured in
// `apply`/`revert` BEFORE the replay loop runs.
//
// Every field is compared against ITSELF at two times — never against a sibling
// plane. That is not a stylistic choice: `addFace`/`addFaceFast` append to
// `faces` only and the mark/material/part/set planes are sized LAZILY (by
// `resetSelection` / `syncSelection`), so `makeCube()` and `makeGridPlane()`
// both leave `faceMaterial.length == 0` beside `faces.length` of 6 and 99 856.
// A "plane in step with its owner" assert would abort on the FIRST undo of any
// position command over a factory- or importer-built mesh that never selected
// anything — correct code, aborted. See §P1.3.
//
// STATE THE HOLE: a drop-free `Reindex` — a pure permutation — keeps
// `vertices.length`, `faces.length`, the corner total AND `structVersion`, so
// it slips ALL FOUR compares. Only the skipped `rebuildEdges` would have
// repaired `edges`' now-wrong vertex indices. These asserts are a cheap
// always-on backstop for the LOUD half of a misclassification, never the proof
// of the predicate — that is what the witness cells are for.
private struct StableEntry {
    size_t nV = size_t.max;
    size_t nF = size_t.max;
    ulong  sv = ulong.max;
    version (unittest) size_t corners = size_t.max;
}

private StableEntry captureStableEntry(in Mesh m) {
    StableEntry e;
    e.nV = m.vertices.length;
    e.nF = m.faces.length;
    e.sv = m.structVersion;
    version (unittest) {
        size_t c = 0;
        foreach (ref f; m.faces) c += f.length;
        e.corners = c;
    }
    return e;
}

// ---------------------------------------------------------------------------
// W3 / W7 — task 1903 L0.P1's two IN-MODULE witnesses.
//
// They live here and not in `tests/unit/` for two DIFFERENT reasons, and both
// reasons are load-bearing:
//
//   * W3 calls the four module-private predicates directly. A `tests/unit/`
//     cell cannot; driving them through `g_rebuildEdgesRuns` instead would be
//     weaker AND would only ever reach `indexSpaceStable`.
//   * W7 shows that the fast path's asserts FIRE — it drives them through
//     `finalize` and requires the throw, which only an in-module caller can do
//     for a module-private function with module-private parameter types.
//
// Precedent for a `finalize` caller in this module: the two `CornerCarry`
// self-check cells further up.
//
// ---------------------------------------------------------------------------
// A PLAN PREMISE THAT DIED ON MEASUREMENT — read this before moving either
// block, and before writing `debug assert` anywhere in `finalize`.
// ---------------------------------------------------------------------------
// §P1.4 placed W7 here on the reasoning that "`source/**` is compiled by BOTH
// gate lanes, and only one of them can see the difference between `assert` and
// `debug assert`": `run_test.d` compiles with no `-debug`, so a `debug assert`
// would vanish there and W7 would redden, while `dub test --config=tests`
// defines `-debug` and W7 stays green.
//
// The first half is FALSE, and it was measured rather than read (2026-08-27).
// `./run_test.d` never RUNS a `source/**` unittest at all: source-backed tests
// LINK the prebuilt `libvibe3d_test.a` (`run_test.d :: buildProjectLib`), and
// the `dmd -unittest -i` line beside it is only the fallback for when that lib
// fails to build. THE EXPERIMENT: an unconditional, hard failure planted in
// this module's W3 census left `./run_test.d test_falloff_combine` GREEN.
//
// So the blocks below run in ONE gate lane, `dub test --config=tests` — and
// that lane defines `-debug`, where `debug assert` throws exactly like a plain
// one. A `debug assert` in `finalize` would therefore be invisible to BOTH
// gates: stripped from the binary the suite lane builds (which never runs
// these blocks anyway) and indistinguishable from a plain assert in the lane
// that does.
//
// WHAT CLOSES IT is a SOURCE-TEXT census —
// `tests/unit/mesh_edit_delta_carveout_test.d`'s "the fast-path asserts are
// PLAIN" cell — which reads this file and refuses the spelling outright. It
// runs in the lane that runs, and its own mutation reddens it there. The
// blocks below keep their own job: they say the asserts FIRE, which no text
// scan can.
// ---------------------------------------------------------------------------

unittest // W7 — the fast path's asserts are COMPILED (see the header above)
{
    import core.exception : AssertError;
    import vibe3d.mesh.contracts.mesh_corner_maps : CornerDrop;

    Mesh m = makeGridPlane(2);
    m.resetSelection();
    m.buildLoops();
    // A registered per-corner map is a PRECONDITION of the hazard, not stand
    // decoration: `Mesh.declareCornerProvenance` returns early when
    // `hasPolyVertexMap()` is false ("no per-corner plane ⇒ no obligation"), so
    // on a map-less mesh no declaration is ever outstanding and the assert
    // under test is unreachable by construction.
    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "stand: the UV map must register");

    // A declaration nobody will consume. On the SLOW path finalize's buildLoops
    // eats it silently; the fast path has no buildLoops, so the next one to run
    // would consume it against faces it never described.
    m.dropCornerProvenance(CornerDrop.DeltaReplayDeclined);
    assert(m.cornerRewritePending(),
        "stand: the provenance declaration must be ARMED, or the cell below "
      ~ "measures nothing at all");

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Position;
    MeshOpEntry e;
    e.kind      = MeshOpEntry.Kind.SetPos;
    e.vIdx      = [0u];
    e.posBefore = [m.vertices[0]];
    e.posAfter  = [Vec3(9, 9, 9)];
    d.log = [e];

    bool threw = false;
    string msg;
    try
        d.revert(m);
    catch (AssertError err) {
        threw = true;
        msg = err.msg;
    }
    assert(threw,
        "the fast path ran with a corner-provenance declaration still pending "
      ~ "and said nothing. Either the assert is not there, or it was written "
      ~ "`debug assert` (which vanishes from every build without `-debug` — "
      ~ "see the source-text census in "
      ~ "tests/unit/mesh_edit_delta_carveout_test.d), or the fast path was not "
      ~ "taken at all.");
    assert(msg.length > 0 && msg.canFindSub("corner-provenance"),
        "the throw came from somewhere else: " ~ msg);
}

unittest // W7b — the owner-length backstop is compiled, and it is PLAIN
{
    import core.exception : AssertError;

    Mesh m = makeGridPlane(2);
    m.resetSelection();
    m.buildLoops();

    // Entry state captured, then an index-space move the predicate would have
    // refused. Calling `finalize` directly with `fast = true` is the in-module
    // privilege this cell exists to use: it drives the backstop without
    // mutating the predicate, so the cell is a real check and not a mutation
    // rehearsal.
    const StableEntry e0 = captureStableEntry(m);
    m.vertices ~= Vec3(0, 0, 0);

    bool threw = false;
    string msg;
    try
        finalize(m, MeshEditScope.Position, null, false, false, null, null,
                 /*fast=*/true, e0);
    catch (AssertError err) {
        threw = true;
        msg = err.msg;
    }
    assert(threw,
        "the fast path accepted a log that changed vertices.length. The "
      ~ "always-on backstop is either missing or was written `debug assert`, "
      ~ "which vanishes from every build that does not define `-debug`.");
    assert(msg.canFindSub("vertices.length"),
        "the throw came from somewhere else: " ~ msg);
}

version (unittest) private bool canFindSub(string hay, string needle) {
    import std.algorithm.searching : canFind;
    return hay.canFind(needle);
}

// ---------------------------------------------------------------------------
// W-K1 / W-K2 — task 1903 Stage L1-P1's two IN-MODULE witnesses.
//
// They live here for the same reason W3 does: they call module-private things a
// `tests/unit/` cell cannot reach — `MeshEditTracker`'s private `append` funnel
// (through its public recorders, but asserting on the private latches' EFFECT)
// and the replay guard's counter around a hand-built log. Everything that can
// be driven from outside the module is in
// `tests/unit/map_value_delta_test.d` instead.
//
// The stand is built here rather than imported: `tests/unit/fixtures.d` is
// compiled only by the `tests` configuration, and a `source/**` module that
// imported it would not build under `modeling`.
// ---------------------------------------------------------------------------

version (unittest) private enum float kWK1Sentinel = 999.0f;

version (unittest) private Mesh wk1Stand() {
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();
    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "W-K1 stand: the UV map must register");
    assert(uv.data.length == m.loops.length * 2,
        "W-K1 stand: the UV map must be sized to the corner space, or the "
      ~ "entry below addresses nothing");
    foreach (i; 0 .. uv.data.length) uv.data[i] = 1.0f + 0.5f * cast(float)i;
    return m;
}

version (unittest) private float[] uvPlane(ref Mesh m) {
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null, "W-K1: the UV map vanished");
    return uv.data.dup;
}

// One hand-built map entry over the first three corners, carrying a value that
// appears NOWHERE in the stand. That is the anti-vacuity device: if the write
// lands, the sentinel is in the plane, and no amount of corner relocation can
// invent it.
version (unittest) private MeshOpEntry wk1MapEntry() {
    MeshOpEntry e;
    e.kind          = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp         = MeshOpEntry.MapOp.Values;
    e.mapAddr       = MeshOpEntry.MapAddressing.Listed;
    e.mapName       = kUvMapName;
    e.mapDim        = 2;
    e.mapDomain     = MapDomain.PolyVertex;
    e.mapKind       = MapKind.unclassified;   // the raw addMeshMap door
    e.mapElemIdx    = [0u, 1u, 2u];
    e.mapValsBefore = [kWK1Sentinel, kWK1Sentinel, kWK1Sentinel,
                       kWK1Sentinel, kWK1Sentinel, kWK1Sentinel];
    e.mapValsAfter  = [-kWK1Sentinel, -kWK1Sentinel, -kWK1Sentinel,
                       -kWK1Sentinel, -kWK1Sentinel, -kWK1Sentinel];
    return e;
}

// Delete face 0 under a recording batch and hand back the mesh in its POST-op
// state plus the real, recorded log. Two calls give two independent meshes in
// the same state — which is what makes the differential below a control and
// not a re-read of one buffer (a `Mesh` copy SHARES its array buffers).
version (unittest) private Mesh wk1Deleted(out MeshEditDelta delta) {
    Mesh m = wk1Stand();
    // `MeshEditBatch`, not the older `beginEditBatch`/`endEditBatch` pair: its
    // destructor pops the frame if anything escapes, which is what lets a
    // helper in this module open a batch without the
    // `scope(failure) mesh.abortEditBatch();` that
    // `tests/unit/commit_seam_census_test.d` requires of every raw opener in
    // `source/**` — and a `version (unittest)` FUNCTION body is not blanked by
    // that census the way a `unittest` block's is.
    size_t removed;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        bool[] mask = new bool[](m.faces.length);
        mask[0] = true;
        removed = ed.deleteFacesByMask(mask);
        delta = ed.close();
    }
    assert(removed == 1, "W-K1 stand: face 0 must actually be deleted");
    assert(!indexSpaceStable(delta.log),
        "W-K1 stand: the delete's log must be index-space UNSTABLE, or the "
      ~ "guard under test is never reached and this cell measures nothing");
    return m;
}

unittest // W-K1 — the exclusion is enforced at REPLAY, and it is what refuses
{
    import std.algorithm.searching : canFind;
    import std.format : format;

    // --- the CONTROL: the recorded log, reverted with no map entry in it ----
    MeshEditDelta ctlDelta;
    Mesh ctl = wk1Deleted(ctlDelta);
    const float[] preOp = uvPlane(ctl);          // post-DELETE, pre-revert
    ctlDelta.revert(ctl);
    const float[] ctlPlane = uvPlane(ctl);

    assert(!ctlPlane.canFind(kWK1Sentinel) && !ctlPlane.canFind(-kWK1Sentinel),
        "W-K1 non-vacuity: the sentinel is already in the control plane, so "
      ~ "its presence in the mixed plane below would prove nothing");
    bool ctlNonZero = false;
    foreach (v; ctlPlane) if (v != 0.0f) { ctlNonZero = true; break; }
    assert(ctlNonZero, format(
        "W-K1 non-vacuity: the control revert left the UV plane ALL ZEROS "
      ~ "(%d values). Two all-zero planes compare equal whatever the guard "
      ~ "does, so the differential below would be a dead cell.",
        ctlPlane.length));
    assert(preOp.length > 0);

    // --- the SUBJECT: the same log with a map entry spliced in front --------
    const ulong refusedBefore = changeBus.mapDeltaMixRefused;
    MeshEditDelta mixDelta;
    Mesh mix = wk1Deleted(mixDelta);
    mixDelta.log = [wk1MapEntry()] ~ mixDelta.log;
    mixDelta.revert(mix);
    const float[] mixPlane = uvPlane(mix);
    const ulong refusedDelta = changeBus.mapDeltaMixRefused - refusedBefore;

    assert(refusedDelta == 1, format(
        "W-K1: the replay guard refused %d map entries, expected exactly 1. "
      ~ "A MapValueDelta sharing a log with an index-space-moving kind must "
      ~ "be SKIPPED and COUNTED: its element indices are in a space another "
      ~ "entry in the same log is re-laying, so writing lands the values on "
      ~ "the wrong elements — silently, since for a morphAbsolute map a wrong "
      ~ "entry is a legal one.", refusedDelta));

    assert(mixPlane.length == ctlPlane.length, format(
        "W-K1: the mixed replay left a UV plane of %d values against the "
      ~ "control's %d", mixPlane.length, ctlPlane.length));
    foreach (i, v; mixPlane)
        assert(*cast(const(uint)*)&v == *cast(const(uint)*)&ctlPlane[i], format(
            "W-K1: corner value %d is %s after reverting the MIXED log and %s "
          ~ "after reverting the SAME log without the map entry. The refused "
          ~ "entry wrote anyway — that is the whole failure, and the sentinel "
          ~ "%s is how you can tell it apart from a relocation.",
            i, v, ctlPlane[i], kWK1Sentinel));

    // --- POTENCY: the same entry ALONE is not inert -------------------------
    // Without this the two assertions above are satisfied by a gate that
    // refuses EVERYTHING, which is the "second, unnamed guard refuses first"
    // shape.
    MeshEditDelta soloDelta;
    Mesh solo = wk1Deleted(soloDelta);
    MeshEditDelta only;
    only.scope_ = MeshEditScope.Maps;
    only.log    = [wk1MapEntry()];
    assert(indexSpaceStable(only.log),
        "W-K1 potency: a map-only log must be index-space STABLE");
    const ulong refusedBefore2 = changeBus.mapDeltaMixRefused;
    only.revert(solo);
    assert(changeBus.mapDeltaMixRefused == refusedBefore2,
        "W-K1 potency: a map-ONLY log must not be refused");
    const float[] soloPlane = uvPlane(solo);
    assert(soloPlane.canFind(kWK1Sentinel), format(
        "W-K1 POTENCY FAILED: the same entry replayed alone wrote nothing "
      ~ "(the sentinel %s is absent from %d values). Then the cell above is "
      ~ "not measuring a refusal — it is measuring an entry that never "
      ~ "applies, and it would stay green with the guard deleted.",
        kWK1Sentinel, soloPlane.length));
}

private void applyForward(ref Mesh m, ref const MeshOpEntry e,
                          bool cornerCarryActive) {
    final switch (e.kind) {
        case MeshOpEntry.Kind.AddVerts:
            m.restoreAppendVertices(e.pos);
            break;
        case MeshOpEntry.Kind.RemoveVerts:
            // Forward: drop the listed verts (descending so indices stay valid).
            m.restoreRemoveVertices(e);
            break;
        case MeshOpEntry.Kind.SetPos:
            m.restorePositions(e.vIdx, e.posAfter);
            break;
        case MeshOpEntry.Kind.AddFaces:
            m.restoreAppendFaces(e.faceLists);
            break;
        case MeshOpEntry.Kind.RemoveFaces:
            m.restoreRemoveFaces(e);
            break;
        case MeshOpEntry.Kind.ReshapeFaces:
            m.restoreFaceWindings(e.fIdx, e.faceListsAfter);
            break;
        case MeshOpEntry.Kind.Reindex:
            m.restoreVertexReindexForward(e.perm);
            break;
        case MeshOpEntry.Kind.FaceReindex:
            m.restoreFaceReindexForward(e, cornerCarryActive);
            break;
        case MeshOpEntry.Kind.SelectionDelta:
            m.restoreSelectionValues(e.selDomain, e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.SubpatchDelta:
            patchSubpatch(m, e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.HideDelta:
            m.restoreHideValues(e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.MaterialDelta:
            m.restoreMaterialValues(e.markIdx, e.markAfter);
            break;
        case MeshOpEntry.Kind.EdgeSelByEnds:
            break; // handled in finalize (post-rebuildEdges, endpoint-keyed)
        case MeshOpEntry.Kind.MeshMapDelta:
            break; // deferred (Q4)
        case MeshOpEntry.Kind.MapValueDelta:
            patchMapValues(m, e, /*forward=*/true);
            break;
        case MeshOpEntry.Kind.EdgeSetRekey:
            // Re-run the weld's own re-key through the map it recorded. NOT a
            // no-op and not derivable from the reverse payload: see the Kind
            // doc — a forward that did nothing would leave the restored
            // pre-weld keys for the following `Reindex` to drop outright.
            // Weld replay is non-injective. Wire keys moved by it were
            // intentionally dropped live and have no inverse payload; this
            // arm is therefore a declared no-op for authored wires today.
            selSetRekeyEdges(m, (uint v) =>
                v < e.perm.length ? e.perm[v] : v,
                WireKeyPolicy.dropMoved);
            break;
    }
}

private void applyReverse(ref Mesh m, ref const MeshOpEntry e,
                          bool cornerCarryActive) {
    final switch (e.kind) {
        case MeshOpEntry.Kind.AddVerts:
            // Inverse of append = truncate the tail [V0..V0+N).
            assert(e.vIdx.length == 1);
            const v0 = e.vIdx[0];
            m.restoreVertexTail(v0);
            break;
        case MeshOpEntry.Kind.RemoveVerts:
            // Inverse of drop = re-insert at the recorded (pre-removal) indices.
            m.restoreInsertVertices(e);
            break;
        case MeshOpEntry.Kind.SetPos:
            m.restorePositions(e.vIdx, e.posBefore);
            break;
        case MeshOpEntry.Kind.AddFaces:
            assert(e.fIdx.length == 1);
            const f0 = e.fIdx[0];
            m.restoreFaceTail(f0);
            break;
        case MeshOpEntry.Kind.RemoveFaces:
            m.restoreInsertFaces(e);
            break;
        case MeshOpEntry.Kind.ReshapeFaces:
            // NEGATIVE CONTROL (test only): stub ReshapeFaces^-1 to a no-op
            // under -version=UndoNegControlReshape so the reshape round-trip
            // test (c) proves the in-place-reshape inverse is load-bearing.
            version (UndoNegControlReshape) {} else {
                m.restoreFaceWindings(e.fIdx, e.faceListsBefore);
            }
            break;
        case MeshOpEntry.Kind.Reindex:
            m.restoreVertexReindexReverse(e.perm);
            break;
        case MeshOpEntry.Kind.FaceReindex:
            m.restoreFaceReindexReverse(e, cornerCarryActive);
            break;
        case MeshOpEntry.Kind.SelectionDelta:
            m.restoreSelectionValues(e.selDomain, e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.SubpatchDelta:
            patchSubpatch(m, e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.HideDelta:
            m.restoreHideValues(e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.MaterialDelta:
            m.restoreMaterialValues(e.markIdx, e.markBefore);
            break;
        case MeshOpEntry.Kind.EdgeSelByEnds:
            break; // handled in finalize (post-rebuildEdges, endpoint-keyed)
        case MeshOpEntry.Kind.MeshMapDelta:
            break; // deferred (Q4)
        case MeshOpEntry.Kind.MapValueDelta:
            patchMapValues(m, e, /*forward=*/false);
            break;
        case MeshOpEntry.Kind.EdgeSetRekey:
            m.restoreEdgeSetImage(e.edgeSetKeys, e.edgeSetWords);
            break;
    }
}

// Inverse of a same-space MERGE re-key: install the recorded PRE-image whole.
//
// AN EMPTY PAYLOAD IS "NOTHING TO RESTORE", NOT "CLEAR THE PLANE", and the
// recorder is what makes that true — it refuses to record an empty pre-image
// (`recordEdgeSetRekey` asserts it), so an empty array here can only mean an
// entry hand-built by a test. Clearing on empty would turn a malformed entry
// into a silent whole-plane wipe.
//
// The keys are in the PRE-weld vertex space. By the time this runs, LIFO has
// already put the mesh back into that space: the weld itself renumbers nothing
// (its map is same-space), and the compaction that follows it is undone by the
// `Reindex` / `RemoveVerts` entries recorded AFTER this one.
// ---------------------------------------------------------------------------
// patchMapValues — `Kind.MapValueDelta`'s dispatch (task 1903 Stage L1-P1).
//
// BIND FIRST, THEN WRITE, AND REFUSE THE ENTRY **WHOLE**. Never partially,
// never truncated to `min(dim_rec, dim_live)`, never zero-filled. The
// neighbouring `MeshMapDelta`'s doc offers "degrade to a zero-fill" as its
// precedent; it is right about not shuffling floats between maps and WRONG as
// a default here — Stage F1 MEASURED a revert that restored a map's length,
// zeroed all 48 of its values (36 of them non-zero) and answered `true`. A
// zero-fill IS that failure. Leaving the live values untouched is a visible
// divergence in the parity dump; zero-filling looks like a clean restore.
//
// WHAT THE BINDING DELIBERATELY IS NOT. It is not the face-rewrite gate — the
// dangerous rewrites are exactly the count-preserving ones (an equal-arity
// `ReshapeFaces` keeps `loops.length`, a drop-free `Reindex` keeps
// `vertices.length`, a `FaceReindex` keeps `faces.length`), so every length
// term below passes on precisely the logs the exclusion exists to refuse. The
// two mechanisms answer two different questions and neither substitutes for
// the other.
//
// NO `commitChange` HERE. Same convention as `restoreSubpatchValues` / `restoreHideValues` /
// `restoreMaterialValues`: `finalize` publishes ONCE for the whole replay.
// ---------------------------------------------------------------------------
private void patchMapValues(ref Mesh m, ref const MeshOpEntry e, bool forward) {
    final switch (e.mapOp) with (MeshOpEntry.MapOp) {
        case Values:
            m.restoreMapValues(e, forward);
            break;
        case Create:
            // FORWARD-FAITHFUL. `session_edit.d`'s `if (useDelta_)
            // delta_.apply(*mesh);` is a shipped forward-replay consumer, so
            // "redo re-runs the kernel" is false for every factory built on
            // that carrier; a create that replayed empty would silently lose a
            // morphAbsolute's dense base or a copied UV channel.
            // `uint.max` — a Create's forward APPENDS, which is what the
            // kernel it replays did; only a Remove's reverse has a position
            // to restore.
            if (forward) m.restoreMapRegister(e, true);
            else         m.restoreMapUnregister(e);
            break;
        case Remove:
            if (forward) m.restoreMapUnregister(e);
            else         m.restoreMapRegister(e, false);
            break;
        case Rename:
            if (forward) m.restoreMapRename(e, e.mapName, e.mapNameTo);
            else         m.restoreMapRename(e, e.mapNameTo, e.mapName);
            break;
    }
}

// ---------------------------------------------------------------------------
// finalize — the byte-identical tail of MeshSnapshot.restore (snapshot.d:97).
// Re-derive edges + loops + map lengths, bump both version counters ONCE.
// ---------------------------------------------------------------------------
private void finalize(ref Mesh m, MeshEditScope scope_,
                      in uint[] edgeSelEnds = null, bool haveEdgeSel = false,
                      bool cornersRenumbered = false,
                      CornerCarry* carry = null,
                      in MeshOpEntry[] log = null,
                      bool fast = false,
                      StableEntry e0 = StableEntry.init) {
    // TASK 1903 L0.P1 — THE CARVE-OUT.
    //
    // `fast` says the log is index-space stable AND (if it restores an edge
    // selection) the edge map is usable — see `MeshEditDelta.revert`, which is
    // where the ONE boolean is computed. Steps SKIPPED on the fast path: the
    // corner carry, `rebuildEdges`, `buildLoops`, and (provably, see the assert
    // below) the corner-map drop. Steps KEPT: the nine length-syncs,
    // `resizeAllMeshMaps`, `refreshHiddenDerived`, the edge-selection restore,
    // `commitRestored`. Step 10, the tail bump, is per-KIND.
    //
    // BOTH NEW PARAMETERS DEFAULT TO THE SLOW PATH, and that is a ruling rather
    // than tidiness: `finalize` has FOUR callers, and the two in-module
    // `unittest` cells further up build a `CornerCarry` out of band and pass a
    // NULL log. Any log-derived predicate answers "stable" over a null log —
    // the gate reporting clean over an empty input — so `fast` defaults FALSE
    // and those two cells provably keep the slow path.
    assert(!(fast && carry !is null),
        "mesh_edit_delta.finalize: the fast path was entered with a live "
      ~ "CornerCarry. The fast path skips carry.commit, so the carry's payload "
      ~ "would be dropped silently; a caller that built a carry out of band "
      ~ "must take the slow path (leave `fast` at its default).");

    if (fast) {
        // §P1.3 — the always-on backstop for the LOUD half of a
        // misclassification. PLAIN asserts, and the spelling is pinned by a
        // source census (see W7-TEXT in
        // tests/unit/mesh_edit_delta_carveout_test.d) because neither gate can
        // tell the two spellings apart at runtime: `run_test.d` builds its
        // project test-lib with `dmd -lib -unittest` and NO `-debug`, so the
        // conditional form would be stripped from the very binary the
        // source-backed suite tests call `finalize` through, while
        // `dub test --config=tests` defines `-debug` and would see no
        // difference at all. Precedent for the plain spelling: mesh.d's
        // `assert(g_deliveryDepth > 0, …)` inside `commitStamps`.
        //
        // Each compares a quantity against ITSELF at two times — never against
        // a sibling plane. See `StableEntry` for why the sibling form would
        // abort on `makeCube()`.
        assert(m.vertices.length == e0.nV,
            "mesh_edit_delta: an index-space-stable log changed vertices.length. "
          ~ "indexSpaceStable() classified a kind wrong — the skipped "
          ~ "rebuildEdges/buildLoops would have re-derived edges and loops over "
          ~ "the new vertex space.");
        assert(m.faces.length == e0.nF,
            "mesh_edit_delta: an index-space-stable log changed faces.length. "
          ~ "indexSpaceStable() classified a kind wrong — `edges` and the loops "
          ~ "family are functions of `faces` and are now stale.");
        // recorded remainder (1906 §3.6): `structVersion` owns this compare and
        // KEEPS it, and it is not the shape §3.6 exists to police. Every site
        // in that table is a FRESHNESS poll — "is my cache still valid for the
        // current counter" — and the objection against those is that a gizmo
        // drag is version-silent, so a change class would have answered better.
        // This compare asks the opposite question, of the SAME counter, inside
        // one call: `e0.sv` was read from THIS mesh a few statements ago in
        // `apply`/`revert`, and the assert says the replay in between wrote no
        // edges. A bus class cannot answer that — delivery happens at the edit
        // BOUNDARY, which is after `finalize` has already had to decide — and
        // there is no cache here to key on an epoch. Nothing is memoised, no
        // work is skipped on the strength of it: it is an ASSERT, and its only
        // effect is to abort.
        assert(m.structVersion == e0.sv,
            "mesh_edit_delta: an index-space-stable log wrote `edges` "
          ~ "(structVersion moved). Not a general structural witness (it counts "
          ~ "writes to `edges` and misses a face DROP), but on an all-stable log "
          ~ "it must not move at all: indexSpaceStable() classified a kind wrong.");
        version (unittest) {
            // O(F) — test-lane oracle only. Covers the equal-LENGTH hole the
            // three compares above leave: a `ReshapeFaces` that changes arity
            // keeps `faces.length` and moves every corner after it.
            size_t corners = 0;
            foreach (ref f; m.faces) corners += f.length;
            assert(corners == e0.corners,
                "mesh_edit_delta: an index-space-stable log changed the CORNER "
              ~ "count. An arity-changing ReshapeFaces was classified stable and "
              ~ "buildLoops was skipped over a re-laid loop array.");
        }
        // The second latent repair the skip removes. `buildLoops` is what
        // CONSUMES a pending CornerProvenance declaration (inside
        // `resizePolyVertexMaps`). Nothing in an all-stable replay ARMS one —
        // the only armers are restoreFaceReindexForward/Reverse and
        // CornerCarry.commit's self-check, all of them skipped or unstable — so
        // a declaration pending at ENTRY is one somebody else left outstanding
        // across a command boundary. Today `finalize` eats it and the bug is
        // invisible; here it is loud.
        assert(!m.cornerRewritePending(),
            "mesh_edit_delta: a corner-provenance declaration was already "
          ~ "pending when a fast-path replay began. The skipped buildLoops would "
          ~ "have consumed it, and the NEXT buildLoops will now consume it "
          ~ "against the wrong faces. Find the kernel that declared and did not "
          ~ "rebuild.");
        // Ties the two predicates together: `renumbersCorners` answers true
        // only for AddFaces / RemoveFaces / FaceReindex, all of which
        // `indexSpaceStable` classifies UNSTABLE. Widening the predicate to any
        // of those three reddens HERE, always-on, before any geometry check
        // runs. It covers 3 of the 8 unstable kinds and no more — the witness
        // cells cover the rest.
        assert(!cornersRenumbered,
            "mesh_edit_delta: the fast path was entered for a log that "
          ~ "renumbers corners (AddFaces / RemoveFaces / FaceReindex). "
          ~ "indexSpaceStable() and renumbersCorners() disagree — the former was "
          ~ "widened without the latter.");
    }

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
    //
    // L0.P1 — SKIPPED as a PAIR on the fast path, and only as a pair: removing
    // the tail bump alone is INERT, because `rebuildEdges` publishes its own
    // `commitChange(MeshEditScope.Polygons)` and so moves topologyVersion
    // anyway (measured, task 2060 mutation M3). The derivation half is safe —
    // `edges` is a pure function of `faces` plus live authored-wire keys
    // (index pairs; positions never enter), while loops and `edgeIndexMap`
    // are functions of that edge table. No index-space-stable kind writes
    // faces or authored-wire keys. Their
    // structVersion-keyed validity stamps stay Valid because `structVersion`
    // does not move either (asserted above). The PUBLISH half is NOT part of
    // the win and is re-issued per kind at `commitRestored` below.
    if (!fast) {
        m.rebuildEdges();
        m.buildLoops();
    }
    m.restoreParallelPlaneLengths();
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
    // the FORWARD direction (restoreRemoveFaces / the RemoveVerts+Reindex
    // pair) is a real compaction (drop + shift), and the REVERSE direction
    // (restoreInsertFaces / restoreInsertVertices) re-grows the array via
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
    // `commitRestored`, not `commitChange` (task 1903 §3.2 S4): replay is the
    // third whole-state restoration door and fires on every delta undo AND
    // redo. Same version bumps, same derive, same delivery; it just does not
    // tick `changeBus.unbatchedGeometryCommits`, whose whole job is to count
    // MUTATION sites that have not yet moved behind a batch.
    //
    // L0.P1 — on the fast path this publish also carries the class the skipped
    // `rebuildEdges` was publishing incidentally (`displayTermFor`). On the
    // slow path the term is 0 and the call is byte-identical to what it was.
    const uint displayTerm = fast ? displayTermFor(log) : 0u;
    // The guard that makes the re-issue checkable. It is quantified over the
    // kinds that OWE a display refresh — see `owesDisplayRefresh` for the
    // argued deviation from §P1.2b's unquantified form and the measurement
    // behind it.
    assert(!fast || !owesDisplayRefresh(log)
                 || ((scope_ | displayTerm) & DisplayRefreshMask) != 0,
        "mesh_edit_delta: a fast-path replay would publish only Marks — the "
      ~ "display would never refresh. MEASURED precedent: mesh.d's "
      ~ "setFaceHiddenFrom, where a Marks-only hide left /api/gpu/face-vbo's "
      ~ "faceVertCount at 36.");
    m.commitRestored(scope_ | displayTerm);
    // This raw bump touches topologyVersion only. It is decoupled from the
    // structVersion-keyed loops/edgeIndexMap validity stamp (mesh.d) — that
    // stamp is set by the rebuildEdges()+buildLoops() pair above, which
    // already landed Valid regardless of this line.
    //
    // L0.P1 — PER KIND on the fast path. The comment above says the bump exists
    // because finalize ALWAYS rebuilt; on the fast path nothing was rebuilt, so
    // that premise is gone and `owesTopologyBump` decides from the kind's own
    // live writer instead (and from an ACTUAL mark flip). Note the guard reads
    // the PUBLISHED flags, not `scope_`: for a `SubpatchDelta` the `Polygons`
    // term above is a Geometry class, so `commitRestored` has already bumped
    // topologyVersion through the funnel and a raw bump here would double it.
    // `HideDelta` publishes `Marks|Visibility`, neither of them Geometry, and
    // takes the raw bump — which is exactly the shape `setFaceHiddenFrom`
    // already ships (`noteChange(Visibility); ++topologyVersion;`).
    if (fast) {
        if (!((scope_ | displayTerm) & MeshEditScope.Geometry) && owesTopologyBump(log))
            m.restoreTopologyEpoch();
    } else {
        if (!(scope_ & MeshEditScope.Geometry)) m.restoreTopologyEpoch();
    }
}

// Re-select the edges named by the flat vertex-index endpoint pairs
// [a0,b0, a1,b1, …] through the freshly-rebuilt edgeIndexMap. An endpoint pair
// with no matching edge (geometry diverged) is silently skipped.
private void applyEdgeSelByEnds(ref Mesh m, in uint[] ends) {
    import vibe3d.mesh.core.mesh : edgeKey;
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
// the vertex-mark permutation gap"): restoreRemoveFaces/Reverse must carry
// the WHOLE faceMarks word through the compaction in BOTH directions, the
// same way restoreVertexReindexForward/Reverse already do for vertexMarks. Fixture:
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

    // FORWARD (apply/redo) — S2's primary finding: restoreRemoveFaces used
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
    // restoreInsertFaces used to insertInPlace `m.faces` (and
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
    import vibe3d.mesh.core.mesh_selsets : selSetEditPolygon, selSetMembersPolygon, SetEditMode;

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

private void patchSubpatch(ref Mesh m, in uint[] idx, in uint[] vals) {
        foreach (i, e; idx)
            if (e < m.faceMarks.length)
                m.setFaceSubpatch(e, vals[i] != 0);
    }

