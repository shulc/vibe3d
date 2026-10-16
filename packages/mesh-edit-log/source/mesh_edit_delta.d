module mesh_edit_delta;
public import vibe3d.mesh.contracts.mesh_scope : MeshEditScope, DisplayRefreshMask;
import vibe3d.mesh.change.change_bus : changeBus;
import math : Vec3;
import vibe3d.mesh.contracts.mesh_types;
import vibe3d.mesh.contracts.mesh_plane_types : FaceReindexRecord, kFacePlanes, kFacePlaneEntryField;

// ---------------------------------------------------------------------------
// THE `VIBE3D_UNDO_TRACKER` ESCAPE HATCH LIVED HERE AND IS GONE (task 1903
// stage N). It was a process-wide, read-once module global that fifteen sites
// branched on: eleven position commands, the shared `runMapEdit`, `morph.d`'s
// apply, and the two interactive edge tools. Under `=off` each took the same
// kernel through an UNRECORDED batch and undid through a whole-mesh
// `MeshSnapshot` instead of the op-log.
//
// It was load-bearing until the commit that removed it, and the number is
// recorded rather than asserted after the fact, because after the fact there
// is nothing left to compare: each of the fifteen sites was driven twice in
// one process, and every one recorded 0 op-log entries with the hatch shut and
// more than 0 with it open. No site was already dead.
//
// What it cost while it lived: twenty command files declared a `MeshSnapshot`
// field that fed nothing else, so a declaration census — the obvious closing
// gate for a migration — read the same on migrated and unmigrated code, and
// two stages had to abandon it and find another observable.
// ---------------------------------------------------------------------------

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
        // DORMANT — no production publisher, and none is coming from task
        // 1903 Stage L0 (owner's ruling of 2026-08-27, Q5). NOT shipped
        // functionality; a reader who takes this kind for a working feature
        // has read it wrong.
        //
        // THE COUNT THAT MAKES THIS LOAD-BEARING, measured on this tree
        // 2026-08-27 over a code view (comments and string literals blanked):
        // `MeshEditTracker.recordSubpatchDelta` — the only thing that can put
        // this kind into a log — occurs ONCE in `source/**`, and that once is
        // its own declaration. Production callers: ZERO. Test callers: ONE,
        // `tests/test_mesh_edit_delta.d`'s round-trip cell (d). So every
        // `SubpatchDelta` that has ever existed was made by a test.
        //
        // WHY IT STAYS THAT WAY. The only command that would publish it is
        // `mesh.subpatch_toggle`, and it is declared PERMANENTLY DENSE at its
        // own class (`source/commands/mesh/subpatch_toggle.d`): it already
        // keeps a per-index bit capture and already writes back exactly the
        // indices it captured, so a log here would be the same delta spelled
        // twice with nothing gained. The kind is kept — its dispatch and its
        // L0.P1 rulings are correct and tested — but its status is
        // infrastructure, not feature.
        //
        // The census that keeps this honest is
        // `tests/unit/l0_declined_census_test.d`: it pins the two counts
        // above, so a FIRST caller cannot be added while this comment still
        // says there is none.
        SubpatchDelta,  // markIdx + markBefore / markAfter (Subpatch bit, by face)
        // DORMANT — no publisher at all, and none is coming from task 1903
        // Stage L0 (owner's ruling of 2026-08-27, Q5). NOT shipped
        // functionality.
        //
        // THE COUNT THAT MAKES THIS LOAD-BEARING, measured on this tree
        // 2026-08-27 over a code view (comments and string literals blanked):
        // `MeshEditTracker.recordHideDelta` occurs ONCE in `source/**` — its
        // own declaration — and ZERO times in `tests/**`. It has NO caller
        // anywhere, production or test. No `MeshEditTracker` has ever put a
        // `HideDelta` into a log, so the RECORDER-to-dispatch path has never
        // run and no mutation of `recordHideDelta` can redden anything.
        //
        // WHAT THAT DOES *NOT* MEAN, and the plan said otherwise until this
        // was checked: the DISPATCH is not unexercised. Three unit modules
        // hand-build a `MeshOpEntry` with `kind = HideDelta` and drive
        // `apply` / `revert` directly, bypassing the recorder —
        // `mesh_edit_delta_carveout_hide_test.d` (witness W5, the derived
        // vertex/edge planes after a fast-path revert),
        // `mesh_edit_delta_carveout_delivery_test.d` and
        // `mesh_edit_delta_carveout_preview_test.d`. So `patchHide` DOES run,
        // and a mutation aimed at it reddens W5. "Zero callers of the
        // recorder" and "the branch never executes" are different facts, and
        // only the first one is true here.
        //
        // WHY IT STAYS DORMANT. The four commands that would publish it are
        // declared PERMANENTLY DENSE at `HideRevertCommon`
        // (`source/commands/mesh/hide.d`), because a measured capture shows
        // one undo of a Hide must also restore the component selection, its
        // ORDER and other domains — nine planes this kind does not carry. A
        // `HideDelta`-only revert answers `true` and loses them.
        //
        // The census that keeps this honest is
        // `tests/unit/l0_declined_census_test.d`: it pins the two counts
        // above, so a FIRST caller cannot be added while this comment still
        // says there is none.
        HideDelta,      // markIdx + markBefore / markAfter (Hide bit, by face — task 0613)
        MaterialDelta,  // markIdx + markBefore / markAfter (faceMaterial[], by face)
        EdgeSelByEnds,  // edge selection keyed by VERTEX-INDEX endpoint pairs,
                        //   re-applied through edgeIndexMap AFTER finalize rebuilds
                        //   edges (edge indices are unstable across rebuildEdges,
                        //   so this is endpoint-keyed — doc §1.3). The vertex
                        //   indices are in the space that finalize restores, so
                        //   forward uses `edgeEndsAfter`, reverse `edgeEndsBefore`.
        MeshMapDelta,   // per-corner (PolyVertex) map values of the faces the
                        //   NEXT entry in forward order destroys — or, for a
                        //   `FaceReindex`, of EVERY old face it renumbers
                        //   (task 1903 Stage J: a face rewrite re-lays the
                        //   whole corner space, and the reverse restores each
                        //   old face from here rather than inverting a carry
                        //   that blends and generates) — mapDims /
                        //   mapArity / mapVals below. Applies nothing itself
                        //   (see applyForward/applyReverse): the corner plane
                        //   cannot be written mid-replay, because `loops` is
                        //   only rebuilt in finalize. It is READ by
                        //   `CornerCarry`, which is the thing that places it.
                        //   ITS NEIGHBOUR BELOW, `MapValueDelta`, carries map
                        //   floats too and APPLIES them — the one-line
                        //   difference is which of the two writes its own
                        //   values. Read both before picking one by name.

        /// A MAP-VALUE edit: `MeshMap.data` / `MeshMap.present`, or the map
        /// REGISTRY itself (create / remove / rename). Task 1903 Stage L1.
        ///
        /// THIS ONE APPLIES. Read the two `case`s, not the field list: the
        /// neighbour immediately above, `MeshMapDelta`, carries map floats
        /// too and its dispatch arms are both `break;` — it is a carry
        /// PASSENGER that `CornerCarry` places in a second pass. This kind
        /// writes its own values, in `patchMapValues`.
        ///
        /// IT MAY NEVER SHARE A LOG WITH AN INDEX-SPACE-MOVING KIND, and that
        /// is not advice — it is enforced twice: at `MeshEditTracker.append`
        /// (the recorder funnel, which DETECTS and counts, see
        /// `changeBus.mapDeltaMixRecorded`) and in the replay loops of
        /// `apply`/`revert` (which REFUSE, see `mapDeltaMixRefused`). A map
        /// value is addressed in its map's OWN element space — Point =>
        /// vertex, Edge => edge, PolyVertex => loop — and every kind
        /// `kindHoldsIndexSpace` answers false for re-lays at least one of
        /// those three. The corruption is silent: for a `morphAbsolute` map a
        /// wrong answer is a LEGAL one (an absent entry means "stay at the
        /// base", not "zero").
        ///
        /// `MapOp.Create` is FORWARD-FAITHFUL, and the reason is a shipped
        /// caller: `commands/mesh/session_edit.d` replays a delta FORWARD for
        /// redo (`if (useDelta_) delta_.apply(*mesh);`), and `MeshSessionEdit`
        /// is the generic carrier many factories are built on — so "redo
        /// re-runs the kernel" is true of individual commands and FALSE of the
        /// carrier. A create that replayed empty would silently lose a
        /// `morphAbsolute` map's dense base snapshot or a copied UV channel.
        /// The empty case is carried EXPLICITLY, as
        /// `MapAddressing.DefaultInit`, never inferred from empty value
        /// arrays.
        ///
        /// NOT ITS CALLERS: `source/commands/select/sets.d`'s five classes.
        /// They write the SET registry (`vertexSetNames`/`vertexSetMask`,
        /// `edgeSetNames`/`edgeSetMask`, `polygonSetNames`/`faceSetMask`),
        /// which is a different plane, and `SelectSetApply` additionally binds
        /// several meshes at once. Owner's ruling of 2026-08-27.
        ///
        /// AT THE COMMIT THAT INTRODUCED IT this kind has ZERO recorder
        /// callers in production — its first is task 1903 Stage L1-a
        /// (`source/commands/mesh/morph.d`). That is NOT the same fact as
        /// "the branch never executes": the dispatch is driven by hand-built
        /// entries in `tests/unit/map_value_delta_test.d`, exactly the way
        /// `HideDelta`'s three carve-out modules drive `patchHide`.
        MapValueDelta,

        /// TASK 2310 — the edge-set registry's PRE-IMAGE across a same-space
        /// MERGE re-key. Its payload is `perm` (forward) plus
        /// `edgeSetKeys`/`edgeSetWords` (reverse); it adds no field.
        ///
        /// WHY A KIND OF ITS OWN, and it is not tidiness. Both weld remaps
        /// (`Mesh.applyVertexRemapAndRebuild`, `Mesh.applyVertexRemap`) re-key
        /// `Mesh.edgeSetMask` through a map that is SAME-SPACE and NOT
        /// INJECTIVE: two old endpoint pairs collapse onto one survivor key and
        /// `mesh_selsets.selSetRekeyEdges` OR-merges their words. `RemoveVerts`'
        /// edge half (Stage L5-b, the two arrays below) mirrors
        /// `compactUnreferenced`'s DROP predicate only, so a merge is recorded
        /// by nothing and inverted by nothing: after undo the membership sits on
        /// the survivor edge, which was not a member, and is off the edge that
        /// was — with V, F, E, every mark word, `vertexSetMask`, `faceSetMask`
        /// and every other plane comparing EQUAL. There is no count that can
        /// see it, which is why it shipped.
        ///
        /// IT CANNOT RIDE `RemoveVerts`. That entry is recorded by
        /// `compactUnreferenced`, a DIFFERENT function that runs after the weld
        /// (and not at all when the weld leaves nothing unreferenced), and its
        /// reverse INSERTS keys rather than assigning the plane — which restores
        /// the lost half and leaves the spurious half in place.
        ///
        /// THE REVERSE ASSIGNS THE WHOLE PLANE, and that is the point: a merge
        /// is not invertible entry-by-entry (the survivor's word is a union, and
        /// "was this key here before?" is not derivable from the post-state), so
        /// the pre-image is stored and written back verbatim. It is O(TAGGED
        /// edges), not O(mesh edges), and it is recorded ONLY when the mesh has
        /// edge sets AND the re-key actually changed the table — a mesh with no
        /// selection sets, which is the common case, pays zero bytes.
        ///
        /// THE FORWARD IS NOT A NO-OP, and leaving it one would have traded an
        /// undo defect for a redo defect: `MeshSessionEdit` replays a delta
        /// FORWARD for redo, and without this arm the restored pre-weld keys
        /// would then be dropped outright by the following `Reindex` (their
        /// endpoint is gone in the compacted space). `perm` — the same field
        /// `Reindex` uses, and the same meaning, old -> new vertex index — is
        /// what lets the forward re-run the identical re-key.
        EdgeSetRekey,
    }
    Kind kind;

    // Domain on which a SelectionDelta operates (Select bit lives on every
    // element type; the delta names which array to patch).
    enum SelDomain : ubyte { Vertex, Edge, Face }
    SelDomain selDomain;

    /// What a `MapValueDelta` entry DOES. FOUR arms, not four kinds: together
    /// they owe a branch in ONE `final switch` in this module
    /// (`patchMapValues`) and in NONE of the six over `Kind`. The precedent is
    /// `SelDomain` directly above, which `patchSelection` switches on the same
    /// way.
    ///
    /// `Rename` is a REQUIRED arm and the reason is a measurement, not
    /// tidiness: expressed as Remove+Create its payload is the WHOLE map —
    /// task 2210 measured that as the difference between "two strings" and
    /// 3.05 MB, on four command classes.
    enum MapOp : ubyte { Values, Create, Remove, Rename }

    /// How a `MapValueDelta` entry ADDRESSES its elements. EXPLICIT, never
    /// inferred from `mapElemIdx.length == 0`: an empty-means-all channel
    /// turns a DROPPED index list into a silent whole-map rewrite, which is a
    /// legal wrong answer on every plane. `DefaultInit` is the `Create` arm's
    /// "whatever content `addMeshMapOfKind` produces" — also explicit, for the
    /// same reason: a `WholeArray` create whose value arrays were dropped must
    /// be a refusal, not an empty map that looks correct.
    enum MapAddressing : ubyte { Listed, WholeArray, DefaultInit }

    MapOp         mapOp;
    MapAddressing mapAddr;

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

    // --- RemoveVerts SELECTION-SET payload (task 1903 Stage L5-b) ----------
    //
    // WHAT IT FIXES, and it is a shipped user-visible defect rather than a
    // completeness itch: a named selection set VANISHED ON Ctrl+Z, on the
    // shipped default path, for every command whose kernel compacts a vertex.
    // Found by task 2280's frozen parity fixture, closed there by a
    // three-field BELT in `commands/mesh/delete.d` and `remove.d` ONLY. Every
    // other compacting command carried the identical loss — `mesh.cleanup` on
    // four paths, three of L6's five, all thirteen of L10's — so the belt was
    // a six-line copy queued for ~30 classes. This is the structural place.
    //
    // TWO HALVES, because the plane has two shapes:
    //
    //   `vertSetMaskBefore` — the VERTEX half. One word per entry of `vIdx`,
    //       in the same order, read off `Mesh.vertexSetMask` at record time.
    //       `removeVertsReverse` writes it back instead of the 0 it used to
    //       write on all three of its arms.
    //
    //   `edgeSetKeys` / `edgeSetWords` — the EDGE half, parallel
    //       arrays. `Mesh.edgeSetMask` is an `ulong[ulong]` keyed by ENDPOINT
    //       PAIR, and `selSetRekeyEdges` DROPS an entry whose endpoint maps to
    //       `uint.max`. The keys here are in the PRE-compaction vertex space —
    //       the space `applyReindexReverse` has already restored by the time
    //       `removeVertsReverse` runs — so they are re-inserted verbatim.
    //
    // THE EDGE HALF IS COMPUTED AT THE RECORDER AND THAT WAS MEASURED, NOT
    // ASSUMED (P0-L5-2, 2026-08-28). The drop happens in `mesh_selsets.d`, one
    // call AFTER `recordRemoveVerts`, so the question was whether the recorder
    // can predict it from `remap` + the live mask alone. On
    // `makeTaggedGridDirty(3)` the predicted key set and the set
    // `selSetRekeyEdges` actually dropped were IDENTICAL, both ways, keys and
    // words — {(0,17), (1,17)} — so no call had to move.
    //
    // AN EMPTY ARRAY MEANS "NOTHING TO RESTORE", not "the recorder forgot",
    // and the recorder is what makes that true: it captures the vertex half
    // only when some dropped vertex actually carries a bit, so a mesh with no
    // selection sets (the common case) pays ZERO bytes and keeps the previous
    // behaviour bit-for-bit. `vertSetMaskBefore.length` is therefore either 0
    // or `vIdx.length`, never anything else — the recorder asserts it and
    // `removeVertsReverse` re-checks it rather than half-applying.
    //
    // WHAT THIS DELIBERATELY DOES *NOT* CARRY. `vertexMarks`, the
    // Point-domain `MeshMap` values and their `present` bytes are still zeroed
    // on the three re-insert arms, by the SAME convention this payload just
    // stopped applying to the set mask. That is not an oversight, and the
    // comment at `removeVertsReverse` says which planes are now in which
    // class — a comment that lumps four planes together while one of them is
    // restored is a trap for the next reader.
    ulong[]   vertSetMaskBefore;
    ulong[]   edgeSetKeys;
    ulong[]   edgeSetWords;

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
    // FOLLOWING entry destroys (for a `FaceReindex`: of every old face it
    // renumbers — see that Kind's doc above), captured by
    // `Mesh.recordPolyVertexPayload` at the last moment they are still
    // readable.
    //
    //   mapDims  — `dim` of each PolyVertex map, in registration order. The
    //              replay refuses the payload unless the mesh still presents
    //              the same map set (count + dims), so a map added or removed
    //              between record and replay degrades to a zero-fill rather
    //              than shuffling one map's floats into another.
    //   mapArity — corner count of each face, POSITIONALLY parallel to the
    //              following entry's `fIdx` — or, for a `FaceReindex`, to
    //              `[0, oldFaceCount)` in order (a payload carries no face
    //              indices of its own — see recordPolyVertexPayload for why).
    //              `CornerCarry.payloadForCount` is what checks the count each
    //              kind expects, so the two conventions cannot be confused for
    //              one another.
    //   mapVals  — face-major, then corner, then map: `Σ mapDims` floats per
    //              corner, `Σ mapArity` corners in total.
    //
    // --- AND, ON A `Kind.RemoveVerts` ENTRY, THE POINT-DOMAIN MAP-VALUE
    //     PAYLOAD (task 1903 Stage L7-P3) -----------------------------------
    //
    // TWO KINDS SHARE THESE THREE ARRAYS, AND THAT IS THE DESIGN, not an
    // accident to tidy up later. `MeshOpEntry.sizeof` is charged PER ENTRY, so
    // a new field moves every pinned `byteSize` number in the tree — a cost
    // paid once already (560 -> 608 for L5-b's three arrays, seven numbers) and
    // deliberately not paid again, exactly as `Kind.EdgeSetRekey` re-used
    // `edgeSetKeys`/`edgeSetWords`/`perm` rather than adding two (card 2310).
    // Nothing can confuse the two readings: every reader of the MeshMapDelta
    // meaning binds through `CornerCarry.payloadForCount`, whose FIRST test is
    // `p.kind != MeshMapDelta -> decline`, and `removeVertsReverse` is reached
    // only from the `RemoveVerts` arm of the two dispatch switches.
    //
    //   mapDims  — `dim` of each POINT-domain map with `dim > 0`, in
    //              registration order. Same role as above (identity by
    //              count + dims + order), on the other domain.
    //   mapVals  — VERTEX-major, then map: `Σ mapDims` floats per entry of
    //              `vIdx`, in the same order as `vIdx`. Length is therefore
    //              either 0 or `vIdx.length * Σ mapDims`.
    //   presentBefore — one byte per (dropped vertex, map), same order, so
    //              `vIdx.length * mapDims.length` or 0. It is the field the
    //              REVERSE reads for `MapValueDelta` too, which is the same
    //              direction this payload is for.
    //   mapArity — NOT USED by `RemoveVerts`. A payload is addressed by
    //              vertex, not by face, and `CornerCarry`'s adjacency guard
    //              keys on this array's length, so leaving it empty is what
    //              keeps a `RemoveVerts` entry from ever being mistaken for a
    //              corner payload even if the kind test above were removed.
    //
    // WHICH MAPS: ALL Point-domain channels with `dim > 0`, never a named
    // subset. The payload mirrors `removeVertsReverse`'s own zeroing predicate
    // (`domain == Point && dim != 0`) TERM FOR TERM, so the two cannot drift;
    // a subset would be a second, unstated predicate with no census to keep it
    // honest. It matters most for the channels a subset would be tempted to
    // skip: a `morphAbsolute` map's zero is a LEGAL value ("stay at the base"),
    // so a zeroed morph entry is a silent geometric answer, not a blank.
    //
    // EMPTY MEANS "NOTHING TO RESTORE", never "the recorder forgot". The
    // recorder drops an all-zero block (a mesh with no Point map, or one whose
    // dropped vertices carry nothing, pays ZERO bytes and behaves bit-for-bit
    // as before), so `mapDims.length == 0` on a `RemoveVerts` entry means the
    // reverse zeroes exactly as it always did and refuses NOTHING.
    //
    // A PRESENT PAYLOAD THAT DOES NOT BIND IS REFUSED **WHOLE** — all channels,
    // never the prefix that happens to line up, never per-channel. The
    // precedent is `MapValueDelta`'s own bind refusal and the reason is
    // measured: Stage L1 recorded a revert that restored a map's LENGTH while
    // zeroing every value and answered success. A per-channel accept would
    // reproduce exactly that, one channel at a time. The refusal ticks
    // `changeBus.mapDeltaBindRefused` and the vertex re-insertion still runs:
    // the geometry half of a `RemoveVerts` entry is never skipped, because
    // "refuse the entry" for THIS kind would leave the mesh short a vertex.
    ubyte[]   mapDims;
    uint[]    mapArity;
    float[]   mapVals;

    // --- MapValueDelta payload (task 1903 Stage L1) ------------------------
    // NOT shared with the three fields directly above. `mapVals` belongs to
    // `MeshMapDelta`, which is a carry PASSENGER; these belong to the kind
    // that applies. Two kinds, one plane, different jobs — see both Kind docs.

    /// THE IDENTITY of the map this entry addresses. A name, never a registry
    /// index and never a `MeshMap*`: `Mesh.removeMeshMap` SPLICES `meshMaps`,
    /// so every index after the removed one shifts and every outstanding
    /// pointer is invalid. `mesh.d` states that law twice at its own sites.
    string    mapName;
    /// `MapOp.Rename` only — the name the map takes on FORWARD replay. The
    /// reverse assigns `mapName` back.
    string    mapNameTo;

    /// REFUSAL terms, not identity. The replay binds `meshMap(mapName)` and
    /// then refuses the entry WHOLE unless the live map still presents this
    /// dim, this domain and this kind. `MapKind` is load-bearing beyond a
    /// sanity check: `morphRelative` and `morphAbsolute` are both Point/dim 3
    /// with no reserved name, so neither of the two mechanisms that exist
    /// (reserved name, declared shape) can tell them apart — and they differ
    /// in `absentIsZero`, so a kind-blind restore into the other one is a
    /// GEOMETRIC error, not a cosmetic one.
    ubyte     mapDim;
    MapDomain mapDomain;
    MapKind   mapKind;

    /// `MapOp.Remove` ONLY — the map's POSITION in `Mesh.meshMaps` at record
    /// time, so the REVERSE puts it back where it was. `uint.max` means
    /// "append", which is what `Create`'s forward wants and what every
    /// hand-built entry gets by default.
    ///
    /// MEASURED, task 2230, and it is a finding of Stage L1-a rather than a
    /// design: `Mesh.removeMeshMap` SPLICES, and the reverse re-registers
    /// through `addMeshMap`, which APPENDS. On the frozen L1 parity stand the
    /// registry is `uv W uv2 crease MA MR`; removing `MA` and re-adding it
    /// yields `uv W uv2 crease MR MA`. `meshPlanesJson` emits `meshMaps` in
    /// ARRAY ORDER and `MeshSnapshot.restore` puts the whole array back, so
    /// without this field `mesh.morph.remove`'s undo produced a different
    /// registry from the snapshot it replaces — a plane the oracle reads.
    ///
    /// This is NOT an identity term and must never become one: it is not
    /// stable (every splice moves it) and it is not compared at bind time. It
    /// is a placement HINT applied after the content is restored, and a stale
    /// one clamps to the end rather than refusing — the entry's job is to
    /// bring the map back, and refusing the whole restore because the registry
    /// grew in between would trade a wrong ORDER for a missing MAP.
    ///
    /// Costs nothing per entry: it lands in the 4-byte padding hole after
    /// `mapKind`, so `MeshOpEntry.sizeof` was unchanged at 560 by THIS field
    /// (measured before and after) and no pinned `byteSize` moved for it.
    /// (`sizeof` is 608 since task 1903 Stage L5-b, which added three dynamic
    /// arrays to `Kind.RemoveVerts` — 3 x 16 B of header, measured — and moved
    /// the two pins in `tests/unit/mesh_ops/extrude_test.d` by exactly
    /// `entries x 48`. The claim above is about the padding hole and still
    /// holds; the absolute number is not this field's to own.)
    uint      mapSlot = uint.max;

    /// `MapAddressing.Listed`: the element indices, in the MAP'S OWN element
    /// space (Point => vertex, Edge => edge, PolyVertex => loop), which is the
    /// space `MeshMap.data`'s own invariant is written in
    /// (`data.length == elementCount(domain) * dim`).
    ///
    /// DELIBERATELY NOT `markIdx`. Sharing it would save 16 bytes and cost a
    /// correctness property: `owesTopologyBump` walks
    /// `markIdx`/`markBefore`/`markAfter` for every owing kind, so a kind that
    /// put its indices there and its values elsewhere would read empty value
    /// arrays and answer "no flip" — a check satisfied by the broken code.
    uint[]    mapElemIdx;
    /// dim-major values, `mapElemIdx.length * mapDim` under `Listed` and the
    /// map's whole `data` under `WholeArray`. Forward writes `After`, reverse
    /// writes `Before`.
    float[]   mapValsBefore;
    float[]   mapValsAfter;
    /// Per ELEMENT, with NO `* mapDim` — an element is present or absent as a
    /// whole (the `MeshMap.present` invariant).
    ///
    /// `presentBefore` IS ALSO THE PRESENCE HALF OF `Kind.RemoveVerts`'
    /// Point-domain payload (Stage L7-P3) — see the `mapDims`/`mapVals` block
    /// above for the shape and for why the two kinds share the field.
    /// `presentAfter` is NOT: a `RemoveVerts` payload is a before-image
    /// restored on the reverse, and the FORWARD direction owes nothing —
    /// measured, and not by reading the nearest plausible function. On the
    /// compaction path the log is `[RemoveVerts, Reindex]` and it is
    /// `applyReindexForward`'s Point-map GATHER that re-drops the restored
    /// value on a redo; `removeVertsForward`'s own map drop-filter is not on
    /// that path at all (defeating it leaves the redo cell green, defeating
    /// the gather reddens it). So this stage does not repeat card 2310's edge
    /// -set lesson — where an undo fix bought a loss on the redo — but the
    /// reason is the entry AFTER this one, not this one.
    ///
    /// THE MAP'S "empty means all present" CONVENTION DOES NOT APPLY INSIDE AN
    /// ENTRY, and inverting it here is deliberate: these must have the
    /// addressed element count iff `kindInfo(mapKind).tracksPresence`, and
    /// length zero otherwise — derived from the KIND, never from the array. A
    /// recorder that violates it is a refused bind, not a zero-fill.
    ubyte[]   presentBefore;
    ubyte[]   presentAfter;
}

// ---------------------------------------------------------------------------
// MeshEditDelta — the net, invertible record of one finished edit batch.
// apply() = forward replay; revert() = LIFO inverse replay.
// ---------------------------------------------------------------------------
struct MeshEditDelta {
    MeshEditScope scope_;
    MeshOpEntry[] log;       // execution order; revert plays backward

    bool isEmpty() const { return log.length == 0; }

    /// Stored byte size of the whole op-log, under the ONE accounting rule in
    /// `source/plane_bytes.d` — the same rule `MeshSnapshot.byteSize()` uses,
    /// which is what makes the §8 delta-vs-snapshot RATIO a measurement rather
    /// than a comparison of two definitions of the word "size".
    ///
    /// REPAIRED IN TASK 1903 STAGE B (plan §8.2). The earlier body counted 19
    /// of `MeshOpEntry`'s 26 heap arrays and omitted SEVEN: `facePrt`,
    /// `faceSetMsk`, `faceOrd`, `faceOldOfNew`, `newFaceLists`,
    /// `faceSurvivorIdx` and `faceSurvivorLists`. (`oldFaceCount` was the
    /// eighth name on the plan's list and is NOT an omission — it is a `uint`
    /// already inside the `MeshOpEntry.sizeof` term below.) Six of the seven
    /// belong to `Kind.FaceReindex`, so the undercount grew exactly with the
    /// entries this task is about to start emitting: the instrument was biased
    /// in the DELTA's favour, the opposite direction from the snapshot bias the
    /// card warns about.
    ///
    /// EVERY ARRAY FIELD MUST APPEAR BELOW. `tests/unit/byte_size_test.d`
    /// enumerates `MeshOpEntry`'s fields through `FieldNameTuple` and reddens
    /// on any dynamic array this method does not read — so a field added later
    /// without an accounting line cannot go quiet, which is precisely how the
    /// seven above were lost.
    ///
    /// `@nogc` is deliberate and not decoration: a measuring device that
    /// allocates perturbs the GC readout printed beside its own number.
    size_t byteSize() const pure nothrow @safe @nogc {
        import vibe3d.util.plane_bytes.plane_bytes : planeBytes;
        size_t n = 0;
        foreach (ref e; log) {
            // Rule 5: the entry's own struct bytes, once. `kind`, `selDomain`
            // and `oldFaceCount` are scalars and live inside this term.
            n += MeshOpEntry.sizeof;
            n += planeBytes(e.vIdx);
            n += planeBytes(e.fIdx);
            n += planeBytes(e.pos);
            n += planeBytes(e.posBefore);
            n += planeBytes(e.posAfter);
            n += planeBytes(e.faceLists);
            n += planeBytes(e.faceListsBefore);
            n += planeBytes(e.faceListsAfter);
            n += planeBytes(e.faceMat);
            n += planeBytes(e.facePrt);
            n += planeBytes(e.faceSub);
            n += planeBytes(e.faceSetMsk);
            n += planeBytes(e.faceOrd);
            n += planeBytes(e.perm);
            // Kind.RemoveVerts' selection-set payload (task 1903 Stage L5-b).
            // Three lines, because `byte_size_test.d` walks `MeshOpEntry`
            // through `FieldNameTuple` and reddens on any dynamic array this
            // method does not read — which is exactly how the seven arrays
            // Stage B recovered went missing in the first place.
            n += planeBytes(e.vertSetMaskBefore);
            n += planeBytes(e.edgeSetKeys);
            n += planeBytes(e.edgeSetWords);
            // Kind.FaceReindex's own payload — the six arrays whose absence
            // made this method under-report exactly the entries task 1903 adds.
            n += planeBytes(e.faceOldOfNew);
            n += planeBytes(e.newFaceLists);
            n += planeBytes(e.faceSurvivorIdx);
            n += planeBytes(e.faceSurvivorLists);
            n += planeBytes(e.markIdx);
            n += planeBytes(e.markBefore);
            n += planeBytes(e.markAfter);
            n += planeBytes(e.edgeEndsBefore);
            n += planeBytes(e.edgeEndsAfter);
            n += planeBytes(e.mapDims);
            n += planeBytes(e.mapArity);
            n += planeBytes(e.mapVals);
            // Kind.MapValueDelta's own payload (task 1903 Stage L1). The
            // two `string`s are heap arrays too — `isDynamicArray!string` is
            // true, so `byte_size_test.d`'s FieldNameTuple walk covers them
            // and omitting either would redden by name.
            n += planeBytes(e.mapName);
            n += planeBytes(e.mapNameTo);
            n += planeBytes(e.mapElemIdx);
            n += planeBytes(e.mapValsBefore);
            n += planeBytes(e.mapValsAfter);
            n += planeBytes(e.presentBefore);
            n += planeBytes(e.presentAfter);
        }
        return n;
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
bool renumbersCorners(in MeshOpEntry[] log) {
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
                //
                // STILL TRUE after task 1903 Stage J, and worth saying because
                // the opposite is the tempting reading. Stage J made both
                // declarations CONDITIONAL on `CornerCarry` still being active,
                // which looks like it promotes this line to load-bearing. It
                // does not: every path on which the carry declines states
                // `CornerDrop.DeltaReplayDeclined` at the point it declines, so
                // `resizePolyVertexMaps` returns from its `Dropped` branch and
                // `finalize`'s own `if (!carried && cornersRenumbered)` line is
                // still never what saves the plane. Deleting this `case` is
                // still inert — measured again at Stage J, not carried over on
                // trust.
                //
                // CORRECTED at review round 1 (MAJOR-2): the sentence above
                // used to read "…runs through one of those two
                // `dropCornerProvenance` calls anyway (the decline is set
                // inside `step`, which runs immediately BEFORE the apply)".
                // That is true of every decline in `step`, and FALSE of the one
                // in `CornerCarry.commit`, which fires from `finalize` after
                // every apply has already read `active` as `true` — so no
                // `applyFaceReindex*` fallback could have covered it, and the
                // review measured the result as a `-debug` abort inside
                // `buildLoops`, not a degrade. `commit` now declares the drop
                // itself; the conclusion above survives because of that fix,
                // not in spite of it.
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
// TASK 1903 L0.P1 — the rulings the `finalize` carve-out is made of.
//
// Four module-private predicates over `MeshOpEntry.Kind`, ALL `final switch`
// ON PURPOSE: a new kind must be a COMPILE ERROR in each of them, never a
// silent `default:` into whichever answer happened to be cheapest. That is the
// whole reason they are switches and not `canFind` over a spelling list.
//
// TASK 1903 L1-P1 — the first of them is now SPLIT into a per-KIND half
// (`kindHoldsIndexSpace`) and a per-LOG loop, because that one answer decides
// TWO things: whether the log may take `finalize`'s fast path, and whether a
// `Kind.MapValueDelta` entry in it may be replayed at all. Same predicate, so
// ONE spelling — two would drift, and the drift would be silent in the
// direction that corrupts a map plane. The `final switch` count over `Kind` is
// unchanged at six; `tests/unit/map_delta_census_test.d` pins the inventory.
//
// `renumbersCorners` directly above is the OLDER shape (a plain `switch` with
// a `default: break;`) and is deliberately left alone — converting it is a
// separate behaviour question (its `default` currently answers "does not
// renumber" for every unlisted kind) and putting that in this commit would mix
// two changes.
//
// The plan section is doc/mesh_edit_seam_plan.md §L0.P1; the ruling table is
// §P1.2 and the switches are §P1.2b.
// ---------------------------------------------------------------------------

// True iff replaying this log moves NO index space: no vertex, edge, face or
// CORNER changes identity, so every structure `finalize` re-derives from
// `faces`/`vertices` — `edges`, `loops`, `faceLoop`, `vertLoop`, `loopEdge`,
// `edgeIndexMap` and their `structVersion` stamps — is already correct and
// re-deriving it would be a byte-identical O(mesh) no-op.
//
// IT READS THE ENTRY KINDS, NEVER THE DECLARED `scope_`. A log whose `scope_`
// is `Position` but which carries a `FaceReindex` (task 1902 Stage H/K) answers
// FALSE and takes the full path; a `Points`-scoped log whose entries are all
// `SetPos` answers TRUE and takes the fast path. `scope_` then survives only
// where it always did — in `commitRestored(scope_)`.
//
// `MeshMapDelta` is classified UNSTABLE even though it applies nothing itself
// (`applyForward`/`applyReverse` are no-ops for it): its presence means the
// per-corner plane is in play and `CornerCarry` has a payload to place, and
// `CornerCarry.payloadForCount` makes its adjacency to the next entry
// contractual. Conservative by construction.
//
// SPLIT INTO TWO (task 1903 Stage L1-P1), and the split is the point. The
// per-KIND half below answers TWO questions with ONE spelling:
//
//   1. may this log take `finalize`'s fast path? (the L0.P1 carve-out), and
//   2. may a `MapValueDelta` entry in this log be REPLAYED at all? (the L1
//      exclusion — a map value is addressed in its map's own element space,
//      and a kind that answers false here is re-laying one of the three
//      spaces a map can be indexed in).
//
// They are the same predicate, so they are one function; two spellings would
// drift and the drift would be silent in the direction that corrupts. Still a
// `final switch`: a fifteenth kind is a compile error here, and the single
// answer whoever adds it writes is what admits or excludes it from BOTH.
bool kindHoldsIndexSpace(MeshOpEntry.Kind k) {
    final switch (k) with (MeshOpEntry.Kind) {
        case SetPos: case SelectionDelta: case SubpatchDelta:
        case HideDelta: case MaterialDelta: case EdgeSelByEnds:
        // Writes only `MeshMap.data` / `MeshMap.present` and — for
        // Create/Remove — the `meshMaps` MEMBERSHIP. No vertex, edge, face or
        // corner changes identity, so every structure `finalize` re-derives
        // from `faces`/`vertices` is already correct. Safe *because* of the
        // exclusion above, not because of the payload's own nature.
        // TASK 2310. It rewrites ONE associative array keyed by ENDPOINT
        // PAIR. No vertex, edge, face or corner changes identity, and none of
        // the three spaces a `MeshMap` can be indexed in is re-laid, so it
        // admits a `MapValueDelta` to the same log and lets `finalize` take the
        // fast path. Its NEIGHBOURS in a weld log (`FaceReindex`, `Reindex`,
        // `RemoveVerts`) all answer false, so in production the log is never
        // fast because of this arm alone.
        case EdgeSetRekey:
        case MapValueDelta:
            return true;                     // value-only: index space held
        case AddVerts: case RemoveVerts: case AddFaces: case RemoveFaces:
        case ReshapeFaces: case Reindex: case FaceReindex: case MeshMapDelta:
            return false;                    // moves verts, faces, or corners
    }
}

bool indexSpaceStable(in MeshOpEntry[] log) {
    foreach (ref e; log)
        if (!kindHoldsIndexSpace(e.kind)) return false;
    return true;
}

// Does this log owe `finalize`'s tail `++topologyVersion` on the FAST path?
//
// The tail bump's own comment says it exists because "finalize ALWAYS rebuilds
// edges + loops, so it ALWAYS bumped topologyVersion before". On the fast path
// nothing is rebuilt, so that premise is false and the bump is not owed for
// `SetPos` / `SelectionDelta` / `MaterialDelta` / `EdgeSelByEnds`.
//
// It IS owed for `SubpatchDelta` and `HideDelta` — and NOT for the rebuild's
// sake. `topologyVersion` is the subpatch-preview + GPU LAYOUT key, and each of
// those two kinds' LIVE writers carries the bump explicitly with the reason at
// its own site: `Mesh.setSubpatch` ("commitChange(Marks) alone would not, since
// Marks is not a Geometry class"), `Mesh.setFaceHidden` / `setFaceHiddenFrom`
// ("the preview + GPU LAYOUT key"). A THIRD member of that family already
// exists — `Mesh.setCreaseWeight`, which publishes `Material` and bumps for the
// same preview reason — and there is no crease KIND in the enum today, so this
// switch has no arm for it. When one lands, the `final switch` is what forces
// someone to decide, and this comment names the writer to read it off.
//
// THE FLIP GUARD IS NOT PEDANTRY. Every one of those live writers bumps only on
// an actual flip (`if (cur != on)`, `if (hideChanged)`) — the guards exist
// precisely to stop a no-op gesture forcing a preview rebuild and a GPU
// re-upload. The RECORDERS above guard only `idx.length == 0`, so a
// `before == after` entry IS representable. Bumping on a non-empty index list
// would therefore over-bump exactly where those guards were put to prevent it.
//
// L1-P1 adds a THIRD owing member, and it is a member of the same family for
// the same reason: `Mesh.setCreaseWeight` publishes `Material` and bumps
// `topologyVersion` explicitly, because a crease weight is an INPUT TO THE
// LIMIT SURFACE and `topologyVersion` is the subpatch-preview + GPU layout
// key. The comment above named that writer as the one to read the ruling off;
// this is it. The map arm carries no mark arrays, so it brings its own flip
// guard — `mapEntryChangesValues` — and the two halves (which entries are in
// the family, and whether this one really changed) are kept SEPARABLE so a
// witness can mutate one without the other.
bool owesTopologyBump(in MeshOpEntry[] log) {
    foreach (ref e; log) {
        bool owing  = false;
        bool mapArm = false;
        final switch (e.kind) with (MeshOpEntry.Kind) {
            case SubpatchDelta: case HideDelta:
                owing = true;  break;
            case MapValueDelta:
                owing  = mapEntryIsCreaseChannel(e);
                mapArm = true;
                break;
            case SetPos: case SelectionDelta: case MaterialDelta:
            case EdgeSelByEnds: case EdgeSetRekey:
            case AddVerts: case RemoveVerts: case AddFaces: case RemoveFaces:
            case ReshapeFaces: case Reindex: case FaceReindex: case MeshMapDelta:
                owing = false; break;
        }
        if (!owing) continue;
        if (mapArm) {
            if (mapEntryChangesValues(e)) return true;
            continue;
        }
        const size_t n = e.markIdx.length;
        foreach (i; 0 .. n)
            if (i < e.markBefore.length && i < e.markAfter.length
                && e.markBefore[i] != e.markAfter[i])
                return true;
    }
    return false;
}

// Is this map entry addressing the CREASE-WEIGHT channel?
//
// THE FILTER IS NAME-**OR**-KIND, AND A POSITIVE KIND TEST ALONE IS A BUG
// `mesh.d` NAMES IN ADVANCE. `MapKind.unclassified`'s own declaration says a
// pre-1069 `.v3d`'s maps and everything created through the raw `addMeshMap`
// read back `unclassified`, and that "every filter that excludes a kind must
// be written NEGATIVELY, or it drops every legacy map"; `creaseWeightMap()`
// resolves the channel BY NAME. A legacy crease map — Edge, dim 1, named
// `crease`, kind `unclassified` — would therefore skip the topology bump on
// undo and leave the subpatch preview holding a stale layout key, which is the
// exact failure this ruling exists to prevent.
//
// `mapNameTo` counts too: a rename INTO the reserved name makes a map the
// crease channel and a rename AWAY from it stops one being it, and the limit
// surface changes either way.
bool mapEntryIsCreaseChannel(ref const MeshOpEntry e) {
    return e.mapName   == kCreaseWeightMapName
        || e.mapNameTo == kCreaseWeightMapName
        || e.mapKind   == MapKind.creaseWeight;
}

// Did this map entry actually CHANGE anything? The flip guard, re-spelled for
// a kind that carries no mark arrays.
//
// `Create` / `Remove` / `Rename` always did — the registry moved. `Values` is
// compared BITWISE per component, never with `==`: `==` says `-0.0 == +0.0`,
// and a sign flip in a crease weight is a real write. Spelled as a 32-bit
// compare rather than `std.math.isIdentical`, which takes `real` and so pays
// an x87 round trip per operand (0.94 ms vs 0.08 ms per 100 489, measured at
// task 2160).
bool mapEntryChangesValues(ref const MeshOpEntry e) {
    final switch (e.mapOp) with (MeshOpEntry.MapOp) {
        case Create: case Remove: case Rename:
            return true;
        case Values:
            if (e.mapValsBefore.length != e.mapValsAfter.length) return true;
            foreach (i, v; e.mapValsBefore)
                if (!sameFloatBits(v, e.mapValsAfter[i])) return true;
            if (e.presentBefore.length != e.presentAfter.length) return true;
            foreach (i, v; e.presentBefore)
                if (v != e.presentAfter[i]) return true;
            return false;
    }
}

// Bit identity for one float — `MeshEditBatch.sameBits`'s spelling, per
// component. Local because that one is `private static` inside a struct in
// `mesh.d`; the predicate is the same and its reasoning is stated there.
bool sameFloatBits(float a, float b) {
    return *cast(const(uint)*)&a == *cast(const(uint)*)&b;
}

// The display class the SKIPPED `rebuildEdges` was publishing incidentally, and
// which the fast path therefore has to re-issue itself.
//
// `rebuildEdges` ends in its own `commitChange(MeshEditScope.Polygons)`, which
// is inside `mesh_edit_delta.DisplayRefreshMask`. `Marks` deliberately is NOT in
// that mask (it would re-upload the whole mesh on every selection click). So:
//
//   * `SetPos` (`Position`), `MaterialDelta` (`Material`) and `HideDelta`
//     (`Visibility`) already publish a class inside the mask through `scope_`
//     — nothing is lost and this returns 0;
//   * `SubpatchDelta`'s surviving `scope_` is `Marks` ALONE. Undo a Tab toggle
//     and the cage would stay on screen at the old geometry. This returns
//     `Polygons` — byte-identical to what the slow path published, which is the
//     argument for `Polygons` rather than an invented class — and it delivers
//     the topology bump through the funnel at the same time (`Polygons` is a
//     Geometry class), which is the direction CLAUDE.md's "every bump goes
//     through the funnel" law wants.
//
// The identical failure is already MEASURED at mesh.d's `setFaceHiddenFrom`:
// with the Marks-only publish, hiding a cube face left `/api/gpu/face-vbo`'s
// faceVertCount at 36.
uint displayTermFor(in MeshOpEntry[] log) {
    uint term = 0;
    foreach (ref e; log) {
        final switch (e.kind) with (MeshOpEntry.Kind) {
            case SubpatchDelta:
                term |= MeshEditScope.Polygons; break;
            case SetPos: case SelectionDelta: case HideDelta:
            case MaterialDelta: case EdgeSelByEnds:
            // A selection-SET membership is a registry plane; nothing draws it
            // until a `select.set.apply` turns it into `Marks.Select`, which is
            // a different entry with its own answer here.
            case EdgeSetRekey:
            // A map batch declares `Maps` or `Material`, and BOTH are inside
            // `DisplayRefreshMask` — so nothing was lost and there is nothing
            // to re-issue. Returning `Polygons` here would invent a class and
            // would force a topology bump on every UV undo.
            case MapValueDelta:
            case AddVerts: case RemoveVerts: case AddFaces: case RemoveFaces:
            case ReshapeFaces: case Reindex: case FaceReindex: case MeshMapDelta:
                break;
        }
    }
    return term;
}

// Does this log change anything the DISPLAY shows — as opposed to only the
// selection highlight?
//
// WRITER'S DEVIATION FROM THE PLAN, ARGUED (task 2090; see the card's
// "Отклонение" section). §P1.2b specifies the guard below `finalize`'s fast
// branch as the UNQUANTIFIED
//
//     assert(((scope_ | displayTermFor(log)) & DisplayRefreshMask) != 0, …)
//
// and that assert CONTRADICTS the same section's own ruling three paragraphs
// later, which states — correctly — that a `SelectionDelta` fast path must
// publish `Marks` alone, because "`Marks`'s absence from `DisplayRefreshMask`
// is a deliberate, documented decision" and a selection undo that stops forcing
// a full re-upload "is the mask's doctrine working, not a regression". A
// `SelectionDelta`-only log has `scope_ == Marks` and `displayTermFor == 0`, so
// the unquantified assert ABORTS on exactly the case the ruling blesses — and
// W12's `SelectionDelta` row is the cell that hits it. Measured, not reasoned:
// see the card's Мутация table, row W12-guard.
//
// So the guard keeps its subject and gains the quantifier §P1.2b's prose
// already implies: *a kind that owes a display refresh must not lose it*. The
// two kinds whose entire payload IS the selection highlight owe none.
//
// This is a FOURTH `final switch` where the plan named three. Same property,
// same reason: a new kind is a compile error here too, and whoever adds one has
// to answer "does undoing this change what is on screen?" instead of inheriting
// an answer from a `default:`.
bool owesDisplayRefresh(in MeshOpEntry[] log) {
    foreach (ref e; log) {
        final switch (e.kind) with (MeshOpEntry.Kind) {
            case SelectionDelta: case EdgeSelByEnds:
            // TASK 2310 — a THIRD member, and it widens this arm's sentence
            // from "the highlight" to "nothing the viewport reads". The
            // edge-set registry is drawn by nothing; it becomes visible only
            // through a later `select.set.apply`, which records its own
            // `EdgeSelByEnds`/`SelectionDelta`. In production this kind never
            // appears alone anyway — its log always carries the weld's
            // `FaceReindex`/`Reindex`, which answer true.
            case EdgeSetRekey:
                break;                       // the highlight, and only it
            case SetPos: case SubpatchDelta: case HideDelta: case MaterialDelta:
            // A map value change is DRAWN: `setMorphValue`'s own comment says
            // the viewport draws base+delta (Phase 0, measured), a UV write
            // changes the textured display and a crease write changes the
            // limit surface. Only the two kinds whose entire payload IS the
            // highlight owe nothing.
            case MapValueDelta:
            case AddVerts: case RemoveVerts: case AddFaces: case RemoveFaces:
            case ReshapeFaces: case Reindex: case FaceReindex: case MeshMapDelta:
                return true;
        }
    }
    return false;
}

unittest // W3 — the classification census: every Kind, all four rulings
{
    import std.traits : EnumMembers;
    import std.format : format;
    alias K = MeshOpEntry.Kind;

    // The count term is read from the ENUM, not from the table — an
    // independent source, so this cell cannot be "an enumeration gate keyed on
    // the list it guards". The `final switch`es give the COMPILE-time half for
    // free (a new kind is a build error in all four); this is the RUN-time
    // half, which catches a kind added to the enum and to all four switches but
    // never argued here.
    static assert(EnumMembers!K.length == 16,
        "MeshOpEntry.Kind gained or lost a member. Add its row to the table "
      ~ "below — deciding indexSpaceStable / owesTopologyBump / displayTermFor "
      ~ "/ owesDisplayRefresh for it is the point of this cell, and the four "
      ~ "`final switch`es have already refused to compile until you answered "
      ~ "them there.");
    static assert(K.max == K.EdgeSetRekey,
        "the LAST member of MeshOpEntry.Kind changed — the table below is "
      ~ "ordered against EnumMembers and its tail row is now wrong.");

    struct Ruling {
        K    kind;
        bool stable;        // indexSpaceStable
        bool owesBump;      // owesTopologyBump, given an entry that really flips
        uint displayTerm;   // displayTermFor
        bool owesDisplay;   // owesDisplayRefresh
    }
    // Order matches EnumMembers!K exactly and is asserted to, below.
    const Ruling[] table = [
        Ruling(K.AddVerts,       false, false, 0,                      true ),
        Ruling(K.RemoveVerts,    false, false, 0,                      true ),
        Ruling(K.SetPos,         true,  false, 0,                      true ),
        Ruling(K.AddFaces,       false, false, 0,                      true ),
        Ruling(K.RemoveFaces,    false, false, 0,                      true ),
        Ruling(K.ReshapeFaces,   false, false, 0,                      true ),
        Ruling(K.Reindex,        false, false, 0,                      true ),
        Ruling(K.FaceReindex,    false, false, 0,                      true ),
        Ruling(K.SelectionDelta, true,  false, 0,                      false),
        Ruling(K.SubpatchDelta,  true,  true,  MeshEditScope.Polygons, true ),
        Ruling(K.HideDelta,      true,  true,  0,                      true ),
        Ruling(K.MaterialDelta,  true,  false, 0,                      true ),
        Ruling(K.EdgeSelByEnds,  true,  false, 0,                      false),
        Ruling(K.MeshMapDelta,   false, false, 0,                      true ),
        // `owesBump` is `true` GIVEN AN ENTRY THAT REALLY OWES ONE, which for
        // this kind means a CREASE-channel entry with a real value change —
        // not a mark flip. The loop below builds that shape for this row
        // specially; without it the row would assert the wrong thing (a uv
        // entry owes no bump, and the row would then be green under a deleted
        // crease arm).
        Ruling(K.MapValueDelta,  true,  true,  0,                      true ),
        // TASK 2310. `stable` because it rewrites ONE endpoint-keyed AA and
        // re-lays no vertex/edge/face/corner identity; no bump because nothing
        // it touches is an input to the limit surface or the GPU layout; no
        // display term and no display refresh because the selection-SET
        // registry is drawn by nothing until a `select.set.apply` turns it into
        // `Marks.Select` — which is a different entry with its own row here.
        Ruling(K.EdgeSetRekey,   true,  false, 0,                      false),
    ];
    assert(table.length == EnumMembers!K.length,
        format("the ruling table lists %d kinds, the enum has %d",
               table.length, EnumMembers!K.length));

    foreach (i, m; EnumMembers!K)
        assert(table[i].kind == m,
            format("row %d of the ruling table is %s where the enum's member "
                 ~ "%d is %s — the table lists a kind twice and skips another, "
                 ~ "so some kind is going unasserted", i, table[i].kind, i, m));

    foreach (ref r; table) {
        // One entry of this kind, carrying a REAL mark flip so that
        // owesTopologyBump's kind ruling is what decides the answer and not its
        // flip guard. The flip guard has its own cell below.
        MeshOpEntry e;
        e.kind       = r.kind;
        e.markIdx    = [0u];
        e.markBefore = [0u];
        e.markAfter  = [1u];
        // `MapValueDelta` carries NO mark arrays — its flip guard reads its
        // own values, and its kind test is the crease channel. So this row
        // gets the shape that OWES: the reserved crease name, a real change.
        if (r.kind == K.MapValueDelta) {
            e.mapOp         = MeshOpEntry.MapOp.Values;
            e.mapAddr       = MeshOpEntry.MapAddressing.Listed;
            e.mapName       = kCreaseWeightMapName;
            e.mapDim        = 1;
            e.mapDomain     = MapDomain.Edge;
            e.mapKind       = MapKind.creaseWeight;
            e.mapElemIdx    = [0u];
            e.mapValsBefore = [0.0f];
            e.mapValsAfter  = [1.0f];
        }
        const MeshOpEntry[] log = [e];

        assert(indexSpaceStable(log) == r.stable,
            format("indexSpaceStable(%s) answered %s, the table says %s. A "
                 ~ "kind that MOVES an index space classified stable takes the "
                 ~ "fast path, where edges/loops are never re-derived; a stable "
                 ~ "kind classified unstable only costs the rebuild.",
                   r.kind, indexSpaceStable(log), r.stable));
        assert(owesTopologyBump(log) == r.owesBump,
            format("owesTopologyBump(%s) answered %s, the table says %s. The "
                 ~ "owing family is the kinds whose LIVE writers carry the bump "
                 ~ "explicitly — Mesh.setSubpatch and Mesh.setFaceHidden/"
                 ~ "setFaceHiddenFrom — because topologyVersion is the subpatch-"
                 ~ "preview + GPU layout key.",
                   r.kind, owesTopologyBump(log), r.owesBump));
        assert(displayTermFor(log) == r.displayTerm,
            format("displayTermFor(%s) answered %d, the table says %d. This is "
                 ~ "the class the SKIPPED rebuildEdges was publishing "
                 ~ "incidentally; drop it for a kind whose scope_ is Marks "
                 ~ "alone and the display never refreshes.",
                   r.kind, displayTermFor(log), r.displayTerm));
        assert(owesDisplayRefresh(log) == r.owesDisplay,
            format("owesDisplayRefresh(%s) answered %s, the table says %s. "
                 ~ "Only SelectionDelta, EdgeSelByEnds and EdgeSetRekey owe "
                 ~ "nothing — the first two ARE the highlight, which "
                 ~ "DisplayRefreshMask deliberately excludes, and the third is a "
                 ~ "registry plane nothing draws.",
                   r.kind, owesDisplayRefresh(log), r.owesDisplay));
    }

    // An EMPTY log answers stable — stated, because it is the shape that makes
    // `finalize`'s `fast` default to FALSE necessary: the two in-module callers
    // above pass a NULL log, and a log-derived predicate over null is the gate
    // reporting clean over an empty input.
    const MeshOpEntry[] empty = null;
    assert(indexSpaceStable(empty),
        "a null log must answer stable — that is exactly why finalize's `fast` "
      ~ "parameter defaults to false instead of being derived here.");
}

unittest // W3b — the FLIP GUARD: a no-op mark entry owes no topology bump
{
    alias K = MeshOpEntry.Kind;
    foreach (kind; [K.SubpatchDelta, K.HideDelta]) {
        MeshOpEntry flat;
        flat.kind       = kind;
        flat.markIdx    = [0u, 1u, 2u];
        flat.markBefore = [1u, 0u, 1u];
        flat.markAfter  = [1u, 0u, 1u];        // a representable no-op entry
        assert(!owesTopologyBump([flat]),
            "owesTopologyBump bumped on a non-empty index list whose values "
          ~ "did not move. The recorders guard only `idx.length == 0`, so a "
          ~ "before == after entry IS representable, and every live writer "
          ~ "guards on an ACTUAL flip precisely so a no-op gesture cannot force "
          ~ "a preview rebuild and a GPU re-upload for nothing.");

        MeshOpEntry moved = flat;
        moved.markAfter = [1u, 0u, 0u];        // one word, at the tail
        assert(owesTopologyBump([moved]),
            "POTENCY: the same entry with ONE value changed must owe the bump. "
          ~ "If this fails the cell above is vacuous — it would read false for "
          ~ "a flipped entry too.");
    }
}

unittest // W-K2 — the recorder door DETECTS the forbidden adjacency, and APPENDS
{
    import std.format : format;

    // --- the subject: a map entry, then an index-space move -----------------
    const ulong before = changeBus.mapDeltaMixRecorded;
    MeshEditTracker t;
    t.recordMapValuesOwned(kUvMapName, 2, MapDomain.PolyVertex,
                           MapKind.unclassified,
                           MeshOpEntry.MapAddressing.Listed,
                           [0u], [1.0f, 2.0f], [3.0f, 4.0f], null, null);
    t.recordRemoveFaces([FaceIdx.assumeFaceSpace(0)], [[0u, 1u, 2u, 3u]],
                        [0u], [0u], [0u]);
    const ulong ticked = changeBus.mapDeltaMixRecorded - before;
    auto d = t.finish();

    assert(ticked == 1, format(
        "W-K2: the recorder door ticked %d times, expected exactly 1. This is "
      ~ "the door where the mistake is MADE, so it is the door that names it "
      ~ "while the developer is still writing the command.", ticked));
    assert(d.log.length == 2, format(
        "W-K2: finish() returned a %d-entry log, expected 2. THE ENTRY IS "
      ~ "ALWAYS APPENDED — withholding it makes the delta come back EMPTY "
      ~ "from a kernel that already mutated, and commands/mesh/delete.d's "
      ~ "`affected == 0 || delta_.isEmpty` branch then clears every pre-image "
      ~ "and returns false with NOTHING rolling the mesh back. A loud partial "
      ~ "undo beats a lost mesh.", d.log.length));

    // --- the CONTROL: two map entries in a row tick NOTHING -----------------
    // Without this row the latch could be "tick on every append" and the
    // assertion above would still read 1.
    const ulong before2 = changeBus.mapDeltaMixRecorded;
    MeshEditTracker t2;
    t2.recordMapValuesOwned("a", 1, MapDomain.Point, MapKind.unclassified,
                            MeshOpEntry.MapAddressing.Listed,
                            [0u], [1.0f], [2.0f], null, null);
    t2.recordMapValuesOwned("b", 1, MapDomain.Point, MapKind.unclassified,
                            MeshOpEntry.MapAddressing.Listed,
                            [1u], [3.0f], [4.0f], null, null);
    auto d2 = t2.finish();
    assert(changeBus.mapDeltaMixRecorded == before2, format(
        "W-K2 control: two MAP entries in one log ticked the counter. The "
      ~ "latch fires on the ADJACENCY of a map entry and an index-space move, "
      ~ "not on every append — otherwise every L1 command reports a bug."));
    assert(d2.log.length == 2, "W-K2 control: both map entries must be logged");

    // --- the OTHER ORDER, because the latch is two-sided --------------------
    const ulong before3 = changeBus.mapDeltaMixRecorded;
    MeshEditTracker t3;
    t3.recordRemoveFaces([FaceIdx.assumeFaceSpace(0)], [[0u, 1u, 2u, 3u]],
                         [0u], [0u], [0u]);
    t3.recordMapValuesOwned(kUvMapName, 2, MapDomain.PolyVertex,
                            MapKind.unclassified,
                            MeshOpEntry.MapAddressing.Listed,
                            [0u], [1.0f, 2.0f], [3.0f, 4.0f], null, null);
    auto d3 = t3.finish();
    assert(changeBus.mapDeltaMixRecorded - before3 == 1,
        "W-K2: move-then-map must tick too — the exclusion is symmetric and a "
      ~ "one-sided latch misses every kernel that edits geometry first");
    assert(d3.log.length == 2, "W-K2: move-then-map must still log both");

    // --- the latch is per-LOG: `finish()` clears it -------------------------
    const ulong before4 = changeBus.mapDeltaMixRecorded;
    t3.recordMapValuesOwned(kUvMapName, 2, MapDomain.PolyVertex,
                            MapKind.unclassified,
                            MeshOpEntry.MapAddressing.Listed,
                            [0u], [1.0f, 2.0f], [3.0f, 4.0f], null, null);
    assert(changeBus.mapDeltaMixRecorded == before4,
        "W-K2: the adjacency latches survived finish(). They describe ONE "
      ~ "log; carrying them into the next one reports a bug in a batch that "
      ~ "does not have it.");
}

// ---------------------------------------------------------------------------
// MeshEditTracker — the recorder. Installed on a Mesh while a batch is open
// (via Mesh.beginEditBatch); the hooked mutation primitives append entries to
// its log. finish() moves the log into a MeshEditDelta.
// ---------------------------------------------------------------------------
struct MeshEditTracker {
    private MeshOpEntry[] log_;
    private MeshEditScope declared_ = MeshEditScope.None;

    // --- The map-value exclusion's RECORD-time half (task 1903 L1-P1) -----
    //
    // A `MapValueDelta` may never share a log with an index-space-moving kind
    // (see that Kind's declaration). This is the door where the mistake is
    // made, so it is the door where the developer is told — but it is a
    // DETECTOR, not a filter.
    private bool sawMapValues_;   // a MapValueDelta is in this log
    private bool sawIndexMove_;   // an index-space-moving entry is in this log

    /// THE ONLY `log_ ~=` IN THIS MODULE. Sixteen recorder methods append
    /// through here, because a rule spelled sixteen times is a rule that
    /// drifts; `tests/unit/map_delta_census_test.d` pins that count at one.
    ///
    /// THE ENTRY IS ALWAYS APPENDED. Not withheld, and not thrown over —
    /// both alternatives LOSE DATA, and the evidence is shipped code:
    ///
    ///   * withholding makes `finish()` return an EMPTY delta from a kernel
    ///     that already mutated. `commands/mesh/delete.d`'s
    ///     `affected == 0 || delta_.isEmpty` branch then clears every
    ///     pre-image and returns `false` with NOTHING rolling the mesh back —
    ///     `scope(failure)` does not fire on a plain `return`. The result is
    ///     "answers error, changed everything", which is strictly worse than a
    ///     partial undo.
    ///   * throwing runs `scope(failure) mesh.abortEditBatch()`, and
    ///     `popLeakedEditFrame` pops the frame WITHOUT restoring anything. The
    ///     violation is detected mid-kernel, so that is the same half-mutated
    ///     mesh with, additionally, no delta at all.
    ///
    /// So the door's only action is a counter, and the REPLAY door is the only
    /// place anything is refused. A loud partial undo beats a lost mesh.
    ///
    /// No `assert` either: an assert cannot be driven by a cell without
    /// catching an `Error`, a `debug assert` is invisible to both gate lanes
    /// (measured), and a counter survives `-release` — which is where the
    /// corruption would actually happen.
    private void append(MeshOpEntry e) {
        const bool moves = !kindHoldsIndexSpace(e.kind);
        const bool maps  =  e.kind == MeshOpEntry.Kind.MapValueDelta;
        if ((maps && sawIndexMove_) || (moves && sawMapValues_))
            ++changeBus.mapDeltaMixRecorded;   // DETECT ONLY — see above
        sawMapValues_ |= maps;
        sawIndexMove_ |= moves;
        log_ ~= e;
    }

    /// Does this recorder want `FaceReindex` entries? Default FALSE. 1903
    /// turns it on per-op as it retires the redundant Add/Remove/Reshape
    /// records that already describe the same change. Shipping it on would
    /// double-revert: `mesh.d` (12 tracker calls) and `extrude.d` (9) already
    /// record their face changes through those other kinds, and a second
    /// entry describing the SAME change is not extra safety, it is a second,
    /// conflicting revert applied to one edit (plan §7.1).
    bool wantsFaceReindex = false;

    // Invocation rollback protects the accepted prefix and its mutable tail
    // without copying the whole log (task 20261110; rollback amendment).
    struct Checkpoint {
    private:
        MeshEditTracker* owner;
        size_t length;
        MeshOpEntry tail;
        MeshEditScope declared;
        bool mapValues, indexMove, faceReindex;
    public:
        @disable this(this);
    }

    Checkpoint checkpoint() {
        Checkpoint c;
        c.owner = &this;
        c.length = log_.length;
        if (c.length) {
            c.tail = log_[$ - 1];
            if (c.tail.kind == MeshOpEntry.Kind.AddVerts)
                c.tail.pos = c.tail.pos.dup;
            if (c.tail.kind == MeshOpEntry.Kind.AddFaces)
                c.tail.faceLists = c.tail.faceLists.dup;
        }
        c.declared = declared_;
        c.mapValues = sawMapValues_;
        c.indexMove = sawIndexMove_;
        c.faceReindex = wantsFaceReindex;
        return c;
    }

    void restore(ref Checkpoint c) nothrow @nogc {
        assert(c.owner is &this, "recorder checkpoint belongs to another owner");
        assert(log_.length >= c.length, "accepted recorder prefix was drained");
        if (c.length) log_[c.length - 1] = c.tail;
        log_ = log_[0 .. c.length];
        declared_ = c.declared;
        sawMapValues_ = c.mapValues;
        sawIndexMove_ = c.indexMove;
        wantsFaceReindex = c.faceReindex;
        c.owner = null;
    }

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
        append(e);
    }

    void recordAddVerts(uint v0, uint v1, in Vec3[] pos) {
        if (v1 <= v0) return;
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.AddVerts;
        e.vIdx = [v0];
        e.pos  = pos.dup;
        append(e);
    }

    /// Record a vertex drop, WITH the selection-set planes the re-insert
    /// cannot otherwise recover (task 1903 Stage L5-b — see
    /// `MeshOpEntry.vertSetMaskBefore` for the defect and the measurement).
    ///
    /// THE THREE PAYLOAD PARAMETERS ARE REQUIRED, not defaulted, and that is
    /// the point of the signature: there is exactly ONE production publisher
    /// (`Mesh.compactUnreferenced`), and a second one added later must make
    /// the same decision explicitly rather than inherit a silent `null` that
    /// re-opens the "a named selection set vanished on Ctrl+Z" defect for its
    /// own family. Pass `null, null, null` to mean "the dropped vertices carry
    /// no set membership" — the honest empty, which costs nothing and restores
    /// exactly what the pre-L5-b code did.
    void recordRemoveVerts(in uint[] idx, in Vec3[] pos,
                           in ulong[] vertSetMaskBefore,
                           in ulong[] edgeSetKeys,
                           in ulong[] edgeSetWords,
                           in ubyte[] pointMapDims = null,
                           in float[] pointMapVals = null,
                           in ubyte[] pointMapPresent = null) {
        if (idx.length == 0) return;
        assert(vertSetMaskBefore.length == 0
            || vertSetMaskBefore.length == idx.length,
            "recordRemoveVerts: the vertex set-mask payload must be empty or "
          ~ "parallel to `idx` — a partial one would restore membership onto "
          ~ "whichever vertices happen to line up");
        assert(edgeSetKeys.length == edgeSetWords.length,
            "recordRemoveVerts: the dropped edge-set keys and words are not "
          ~ "parallel");
        // Task 1903 Stage L7-P3. The same "empty, or exactly parallel" law the
        // set-mask half has, on the two arrays that carry the Point-domain map
        // values — asserted at the RECORDER so a malformed payload cannot
        // reach a replay that would have to guess what to do with it.
        // `removeVertsReverse` re-checks rather than trusting this, because a
        // hand-built entry never passes through here.
        {
            size_t stride = 0;
            foreach (d; pointMapDims) stride += d;
            assert(pointMapDims.length == 0
                || pointMapVals.length == idx.length * stride,
                "recordRemoveVerts: the Point-domain map payload must be empty "
              ~ "or hold `vIdx.length * Σ dims` floats, vertex-major — a "
              ~ "partial one would slice one channel's values into another");
            assert(pointMapPresent.length == 0
                || pointMapPresent.length == idx.length * pointMapDims.length,
                "recordRemoveVerts: the Point-domain presence payload must be "
              ~ "empty or hold one byte per (dropped vertex, map)");
        }
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.RemoveVerts;
        e.vIdx = idx.dup;
        e.pos  = pos.dup;
        e.vertSetMaskBefore  = vertSetMaskBefore.dup;
        e.edgeSetKeys  = edgeSetKeys.dup;
        e.edgeSetWords = edgeSetWords.dup;
        // Stage L7-P3 — the Point-domain map values, on the three fields
        // `Kind.MeshMapDelta` uses for the PolyVertex domain. `mapArity` stays
        // empty on purpose: see the field's own doc for why that is a guard and
        // not an omission.
        e.mapDims       = pointMapDims.dup;
        e.mapVals       = pointMapVals.dup;
        e.presentBefore = pointMapPresent.dup;
        append(e);
    }

    /// Record a same-space MERGE re-key of the edge-set registry (task 2310).
    ///
    /// `remap` is the weld's own map (`remap[old]` = the survivor's index, never
    /// `uint.max` — a weld drops no vertex); `keysBefore`/`wordsBefore` are the
    /// WHOLE pre-re-key `Mesh.edgeSetMask`, parallel, in the pre-weld vertex
    /// space. See `MeshOpEntry.Kind.EdgeSetRekey` for why the pre-image is
    /// stored whole rather than as a diff, and why the forward needs `remap`.
    ///
    /// THE EMPTY PRE-IMAGE IS REFUSED RATHER THAN STORED. A mesh with no edge
    /// sets must produce NO entry at all — its caller is what decides that, and
    /// this assert is what stops the decision drifting into an entry whose
    /// reverse would then have to guess between "restore nothing" and "clear the
    /// plane". Two answers, opposite consequences, no way to tell them apart
    /// from the payload.
    void recordEdgeSetRekey(in uint[] remap,
                            in ulong[] keysBefore, in ulong[] wordsBefore) {
        assert(keysBefore.length == wordsBefore.length,
            "recordEdgeSetRekey: the pre-image keys and words are not parallel");
        assert(keysBefore.length != 0,
            "recordEdgeSetRekey: an EMPTY pre-image must not be recorded — a "
          ~ "mesh with no edge sets records no entry at all, so an empty payload "
          ~ "here is unrepresentable and its reverse would be ambiguous");
        MeshOpEntry e;
        e.kind          = MeshOpEntry.Kind.EdgeSetRekey;
        e.perm          = remap.dup;
        e.edgeSetKeys   = keysBefore.dup;
        e.edgeSetWords  = wordsBefore.dup;
        append(e);
    }

    void recordSetPos(in uint[] idx, in Vec3[] before, in Vec3[] after) {
        if (idx.length == 0) return;
        recordSetPosOwned(idx.dup, before.dup, after.dup);
    }

    /// `recordSetPos` without the three copies, for a caller that built the
    /// arrays FOR this entry and keeps no reference to them (task 2160).
    ///
    /// WHY IT EXISTS. `recordSetPos` duplicates because its `in` parameters may
    /// alias state the caller mutates later — `magnet`'s `touchedIdx_` and
    /// `touchedPrev_` are class fields refilled on the next apply, and a delta
    /// aliasing them would silently rewrite an installed history entry. But
    /// `MeshEditBatch.setVertexPositions` builds its three arrays inside the
    /// call, hands them over and drops them, so there the `.dup` was a whole
    /// second copy of the edit for nothing. MEASURED on the perf lane's
    /// `jitter|quantize|smooth /whole` at n=316 (100 489 verts): the three
    /// duplicates are 2.68 MB of the ~10 MB the forward gained at task 1903
    /// §L0-d.
    ///
    /// THE CONTRACT IS OWNERSHIP, NOT SPEED. After this call the entry owns the
    /// three slices; a caller that writes through its own reference to any of
    /// them is mutating an installed undo record. If ownership is not certain,
    /// call `recordSetPos` — the copy is the safe default and stays the one
    /// every external publisher gets.
    void recordSetPosOwned(uint[] idx, Vec3[] before, Vec3[] after) {
        if (idx.length == 0) return;
        assert(idx.length == before.length && idx.length == after.length,
            "MeshEditTracker.recordSetPosOwned: the three arrays must be in "
          ~ "step — a SetPos entry whose posBefore is shorter than vIdx has no "
          ~ "inverse and would throw mid-revert, leaving a half-restored mesh");
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.SetPos;
        e.vIdx      = idx;
        e.posBefore = before;
        e.posAfter  = after;
        append(e);
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
        append(e);
    }

    void recordAddFaces(FaceIdx f0, uint f1, in uint[][] lists) {
        if (f1 <= f0) return;
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.AddFaces;
        e.fIdx      = [f0];
        e.faceLists = dupLists(lists);
        append(e);
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
        append(e);
    }

    void recordReshapeFaces(in FaceIdx[] idx, in uint[][] before, in uint[][] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind            = MeshOpEntry.Kind.ReshapeFaces;
        e.fIdx            = idx.dup;
        e.faceListsBefore = dupLists(before);
        e.faceListsAfter  = dupLists(after);
        append(e);
    }

    // --- Class R: reindex permutation -------------------------------------
    void recordReindex(in uint[] perm) {
        if (perm.length == 0) return;
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.Reindex;
        e.perm = perm.dup;
        append(e);
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
    void recordFaceReindex(FaceReindexRecord rec) {
        // Review finding B3: this used to read
        // `if (oldOfNew.length == 0 && newFaceLists.length == 0) return;` —
        // `oldOfNew.length` is `newFaces.length` at the call site, which is
        // ALSO zero for the destructive "drop every face" rewrite (select-all
        // + delete), not only for the genuine no-op "0 old faces in, 0 new
        // faces out". That guard silently swallowed the whole drop set on
        // exactly the case it most needed to record. `oldFaceCount == 0`
        // names the real no-op: nothing existed before AND nothing exists
        // after.
        //
        // TASK 4059 REVIEW — and the assert below is the half B3's fix could
        // not state while the call was twelve compulsory parameters. It is
        // eight default-initialised fields now, so "the caller omitted
        // `oldFaceCount`" is a thing that compiles, and this guard would
        // swallow such a record whole. The guard's real precondition is that
        // a no-op record is EMPTY; `firstAssignedField` says so over EVERY
        // field, generated from `.tupleof`, so a ninth field is covered
        // without an edit here.
        if (rec.oldFaceCount == 0 && rec.newFaceLists.length == 0) {
            assert(rec.firstAssignedField() is null,
                   "FaceReindexRecord is being dropped as a no-op "
                 ~ "(oldFaceCount == 0 and newFaceLists is empty) while its "
                 ~ "field `" ~ rec.firstAssignedField() ~ "` is filled — a "
                 ~ "caller built the record and omitted `oldFaceCount`. Twelve "
                 ~ "compulsory parameters became eight default-initialised "
                 ~ "fields in task 4059; this assert is what replaced the "
                 ~ "compiler's arity check. See "
                 ~ "mesh_planes.FaceReindexRecord.firstAssignedField.");
            return;
        }
        MeshOpEntry e;
        e.kind              = MeshOpEntry.Kind.FaceReindex;
        e.faceOldOfNew      = rec.oldOfNew;
        e.oldFaceCount      = rec.oldFaceCount;
        e.newFaceLists      = rec.newFaceLists;
        e.fIdx              = rec.dropIdx;
        e.faceLists         = rec.dropLists;
        // TASK 4059 — the per-face plane group, from `kFacePlanes` through
        // `kFacePlaneEntryField`. This is the line that makes "a plane added
        // to kFacePlanes with no matching MeshOpEntry field" a COMPILE error
        // (the AA index fails at CTFE) instead of a silently uncarried undo
        // payload that only the census test could catch, and only at runtime.
        static foreach (n; kFacePlanes) {
            {
                enum string entryField = kFacePlaneEntryField[n];
                __traits(getMember, e, entryField) =
                    __traits(getMember, rec.dropPlanes, n);
            }
        }
        e.faceSurvivorIdx   = rec.survIdx;      // review finding B2
        e.faceSurvivorLists = rec.survLists;    // review finding B2
        append(e);
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
        append(e);
    }

    void recordSubpatchDelta(in uint[] idx, in uint[] before, in uint[] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind       = MeshOpEntry.Kind.SubpatchDelta;
        e.markIdx    = idx.dup;
        e.markBefore = before.dup;
        e.markAfter  = after.dup;
        append(e);
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
        append(e);
    }

    void recordMaterialDelta(in uint[] idx, in uint[] before, in uint[] after) {
        if (idx.length == 0) return;
        MeshOpEntry e;
        e.kind       = MeshOpEntry.Kind.MaterialDelta;
        e.markIdx    = idx.dup;
        e.markBefore = before.dup;
        e.markAfter  = after.dup;
        append(e);
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
        append(e);
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
        append(e);
    }

    // --- Class M: the map-value recorders (task 1903 Stage L1-P1) ---------
    //
    // ALL FOUR TAKE OWNERSHIP of the arrays handed to them — the
    // `recordSetPosOwned` / `recordPolyVertexValues` convention: the slices are
    // stored AS-IS, not copied, because a recorder that `dup`s pays the whole
    // payload twice and this family's payload IS the win. A caller that keeps
    // a reference and then writes through it is mutating the undo record: the
    // revert restores whatever the array says at REPLAY time, which is a
    // silent wrong answer on the plane this family is worst at seeing. Hand
    // over a fresh `.dup` (or an array nobody else holds) and forget it.
    //
    // AT THIS COMMIT ALL FOUR HAVE ZERO PRODUCTION CALLERS. The first is Stage
    // L1-a (`source/commands/mesh/morph.d`), which is the only group that
    // exercises all four arms.

    /// A per-element value write on one map. `addr` says how `elemIdx`
    /// addresses the map — never inferred from the arrays.
    void recordMapValuesOwned(string name, ubyte dim, MapDomain dom, MapKind kind,
                              MeshOpEntry.MapAddressing addr, uint[] elemIdx,
                              float[] before, float[] after,
                              ubyte[] presBefore, ubyte[] presAfter) {
        if (name.length == 0 || dim == 0) return;
        // A `Listed` entry with no indices addresses nothing; recording it
        // would put a shape into the log that the replay can only refuse.
        if (addr == MeshOpEntry.MapAddressing.Listed && elemIdx.length == 0) return;
        MeshOpEntry e;
        e.kind          = MeshOpEntry.Kind.MapValueDelta;
        e.mapOp         = MeshOpEntry.MapOp.Values;
        e.mapAddr       = addr;
        e.mapName       = name;
        e.mapDim        = dim;
        e.mapDomain     = dom;
        e.mapKind       = kind;
        e.mapElemIdx    = elemIdx;
        e.mapValsBefore = before;
        e.mapValsAfter  = after;
        e.presentBefore = presBefore;
        e.presentAfter  = presAfter;
        append(e);
    }

    /// A map CREATED with the content `addMeshMapOfKind` produces — zeroed
    /// data, everything absent. Faithful in BOTH directions for a command that
    /// creates and does not fill (`morphRelative`, `WeightmapCreate`), and it
    /// keeps those rows carrying no array at all.
    ///
    /// The two create spellings are separate methods on purpose: which one a
    /// call site uses is the difference between a redo that restores a
    /// morphAbsolute's dense base and one that silently replaces it with
    /// zeros, so it must be visible at the call site and countable by a
    /// census, not hidden in a defaulted argument.
    void recordMapCreate(string name, ubyte dim, MapDomain dom, MapKind kind) {
        if (name.length == 0 || dim == 0) return;
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.MapValueDelta;
        e.mapOp     = MeshOpEntry.MapOp.Create;
        e.mapAddr   = MeshOpEntry.MapAddressing.DefaultInit;
        e.mapName   = name;
        e.mapDim    = dim;
        e.mapDomain = dom;
        e.mapKind   = kind;
        append(e);
    }

    /// A map created and FILLED — the content is carried, so a forward replay
    /// (redo through `MeshSessionEdit`, which replays the delta rather than
    /// re-running the kernel) reproduces it.
    void recordMapCreateFilledOwned(string name, ubyte dim, MapDomain dom,
                                    MapKind kind, float[] data, ubyte[] present) {
        if (name.length == 0 || dim == 0) return;
        MeshOpEntry e;
        e.kind          = MeshOpEntry.Kind.MapValueDelta;
        e.mapOp         = MeshOpEntry.MapOp.Create;
        e.mapAddr       = MeshOpEntry.MapAddressing.WholeArray;
        e.mapName       = name;
        e.mapDim        = dim;
        e.mapDomain     = dom;
        e.mapKind       = kind;
        e.mapValsAfter  = data;
        e.presentAfter  = present;
        append(e);
    }

    /// A map REMOVED. The reverse re-registers it and refills both channels,
    /// so the whole content is the payload — all six `MeshMap` fields
    /// accounted for (`name`/`dim`/`domain`/`kind` as scalars here, `data` and
    /// `present` as the two arrays; `MeshMap.dup`'s `tupleof.length == 6`
    /// tripwire is the one that fires if a seventh appears).
    /// `slot` is the map's index in `Mesh.meshMaps` BEFORE the splice — see
    /// `MeshOpEntry.mapSlot`. Pass `uint.max` to accept an append; a caller
    /// that has the index and passes `uint.max` anyway restores the map's
    /// CONTENT and loses its position in the registry, which the plane dump
    /// reads and `MeshSnapshot` preserved.
    void recordMapRemoveOwned(string name, ubyte dim, MapDomain dom, MapKind kind,
                              uint slot, float[] data, ubyte[] present) {
        if (name.length == 0 || dim == 0) return;
        MeshOpEntry e;
        e.kind          = MeshOpEntry.Kind.MapValueDelta;
        e.mapOp         = MeshOpEntry.MapOp.Remove;
        e.mapAddr       = MeshOpEntry.MapAddressing.WholeArray;
        e.mapName       = name;
        e.mapDim        = dim;
        e.mapDomain     = dom;
        e.mapKind       = kind;
        e.mapSlot       = slot;
        e.mapValsBefore = data;
        e.presentBefore = present;
        append(e);
    }

    /// A map RENAMED. Two strings, and that is the whole reason the arm exists
    /// — spelled as Remove+Create the payload is the entire map (task 2210
    /// measured "two strings" against 3.05 MB on four command classes).
    void recordMapRename(string from, string to, ubyte dim, MapDomain dom, MapKind kind) {
        if (from.length == 0 || to.length == 0 || from == to) return;
        MeshOpEntry e;
        e.kind      = MeshOpEntry.Kind.MapValueDelta;
        e.mapOp     = MeshOpEntry.MapOp.Rename;
        e.mapAddr   = MeshOpEntry.MapAddressing.DefaultInit;
        e.mapName   = from;
        e.mapNameTo = to;
        e.mapDim    = dim;
        e.mapDomain = dom;
        e.mapKind   = kind;
        append(e);
    }

    bool isEmpty() const { return log_.length == 0; }

    // Move the accumulated log into a finished, invertible MeshEditDelta.
    MeshEditDelta finish() {
        MeshEditDelta d;
        d.scope_ = declared_;
        d.log    = log_;
        log_     = null;
        // The two adjacency latches are per-LOG, so they are cleared with it.
        sawMapValues_ = false;
        sawIndexMove_ = false;
        return d;
    }
}

// ===========================================================================
// Forward / reverse entry application. These are free functions (not Mesh
// methods) so the inverse machinery lives entirely in this module and can be
// stubbed by the unit test's negative control.
// ===========================================================================

// `cornerCarryActive` — whether `CornerCarry` is still vouching for the
// per-corner plane at this entry. Only `Kind.FaceReindex` reads it (task 1903
// Stage J); every other kind leaves the corner plane to the carry
// unconditionally, exactly as before.
// ---------------------------------------------------------------------------
// acceptRecordedEdit — the post-close ruling for a command that ran its kernel
// inside a RECORDING batch (task 1903 stage L3-a, ruling Q-K6).
//
// Placed here rather than in either command because the eight lines it
// replaces were BYTE-IDENTICAL in `commands/mesh/delete.d` and
// `commands/mesh/remove.d`, and because this module is already the home of
// "a helper both delete and remove import" (`captureSelectedEdgeEnds` /
// `restoreSelectedEdgeEnds`, just below). It adds NO import edge: the module
// already imports `change_bus : changeBus` for the seam counters.
//
// NO `cmdName` PARAMETER, and that is a decision. A `string` argument with no
// reader is a presence bit with a signature. The counter is numeric only; in
// the unit lane the cell that ticked it identifies the caller, and in the
// field the command that answered `status:error` at that instant does. If
// attribution is wanted later the smallest honest form is a companion `string`
// field on the bus PLUS a witness that the endpoint reports it — not a
// parameter that goes nowhere.
// ---------------------------------------------------------------------------

/// Should the command record `delta` as its undo entry?
///
///   `affected == 0`               -> `false`. A CORRECT REFUSAL: the kernel
///                                    mutated nothing, and this is exactly
///                                    what the snapshot arm does for the same
///                                    condition, so the two paths agree. No
///                                    counter moves.
///   `affected > 0 && delta empty` -> `false`, AND
///                                    `changeBus.emptyDeltaOverMutation` ticks.
///                                    A CONTRADICTION: the kernel mutated and
///                                    recorded nothing.
///
/// **THE COUNTER DOES NOT FIX THE SECOND CASE.** The command still answers
/// `false`, the funnel still throws, the mesh is still left mutated with no
/// history entry, and nothing rolls it back. What the tick buys is that the
/// event stops being invisible: every instrument that exists today reads clean
/// on it — a geometry compare sees an errored command, a plane dump sees no
/// undo, `isOperationInverse()` answers `false` correctly and uselessly, and
/// `batchLeaks` / `nestedBatchOpens` / `batchUpgradeRefusals` are all zero
/// because the batch opened and closed cleanly. The full ruling, and the two
/// refuted remedies, are at `changeBus.emptyDeltaOverMutation`'s declaration.
///
/// THE TWO ARMS ARE DELIBERATELY NOT ONE `||`. Folded together the counter
/// would read 1 for an honest refusal and stop separating "the kernel did
/// nothing" from "the kernel did something and nobody recorded it" — which is
/// the only question the number is asked.
bool acceptRecordedEdit(size_t affected, in MeshEditDelta delta) {
    if (affected == 0) return false;
    if (delta.isEmpty) {
        ++changeBus.emptyDeltaOverMutation;
        return false;
    }
    return true;
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

