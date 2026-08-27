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

import change_bus : changeBus;   // the seam counters (task 1903 §5.8 / L1-P1)

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
    //   `edgeSetKeyDropped` / `edgeSetWordDropped` — the EDGE half, parallel
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
    ulong[]   edgeSetKeyDropped;
    ulong[]   edgeSetWordDropped;

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
        import plane_bytes : planeBytes;
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
            n += planeBytes(e.edgeSetKeyDropped);
            n += planeBytes(e.edgeSetWordDropped);
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

    // Forward replay — redo. Plays the log in execution order; each entry
    // re-applies its forward effect, then finalize() re-derives edges/loops.
    bool apply(ref Mesh m) const {
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
            // (~0u) slots, so applyReindexForward both drops AND repacks. The
            // preceding RemoveVerts forward must therefore be a NO-OP — otherwise
            // it would drop the verts first, shifting indices out from under the
            // perm (which is keyed in the pre-drop index space) → corruption.
            // (RemoveVerts' positions are only needed on REVERSE, to re-insert.)
            if (e.kind == MeshOpEntry.Kind.RemoveVerts
                && i + 1 < log.length
                && log[i + 1].kind == MeshOpEntry.Kind.Reindex)
                continue;
            carry.step(m, i, e, /*forward=*/true);
            // The stated drop inside `applyFaceReindexForward` is now the
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
    bool revert(ref Mesh m) const {
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
    // `applyFaceReindexReverse` is what runs — today's behaviour, unchanged.
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
        // immediately BEFORE its entry's apply, so `applyFaceReindexForward` /
        // `applyFaceReindexReverse` read `cornerCarryActive == false` and state
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
private bool kindHoldsIndexSpace(MeshOpEntry.Kind k) {
    final switch (k) with (MeshOpEntry.Kind) {
        case SetPos: case SelectionDelta: case SubpatchDelta:
        case HideDelta: case MaterialDelta: case EdgeSelByEnds:
        // Writes only `MeshMap.data` / `MeshMap.present` and — for
        // Create/Remove — the `meshMaps` MEMBERSHIP. No vertex, edge, face or
        // corner changes identity, so every structure `finalize` re-derives
        // from `faces`/`vertices` is already correct. Safe *because* of the
        // exclusion above, not because of the payload's own nature.
        case MapValueDelta:
            return true;                     // value-only: index space held
        case AddVerts: case RemoveVerts: case AddFaces: case RemoveFaces:
        case ReshapeFaces: case Reindex: case FaceReindex: case MeshMapDelta:
            return false;                    // moves verts, faces, or corners
    }
}

private bool indexSpaceStable(in MeshOpEntry[] log) {
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
private bool owesTopologyBump(in MeshOpEntry[] log) {
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
            case EdgeSelByEnds:
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
private bool mapEntryIsCreaseChannel(ref const MeshOpEntry e) {
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
private bool mapEntryChangesValues(ref const MeshOpEntry e) {
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
private bool sameFloatBits(float a, float b) {
    return *cast(const(uint)*)&a == *cast(const(uint)*)&b;
}

// The display class the SKIPPED `rebuildEdges` was publishing incidentally, and
// which the fast path therefore has to re-issue itself.
//
// `rebuildEdges` ends in its own `commitChange(MeshEditScope.Polygons)`, which
// is inside `display_sync.DisplayRefreshMask`. `Marks` deliberately is NOT in
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
private uint displayTermFor(in MeshOpEntry[] log) {
    uint term = 0;
    foreach (ref e; log) {
        final switch (e.kind) with (MeshOpEntry.Kind) {
            case SubpatchDelta:
                term |= MeshEditScope.Polygons; break;
            case SetPos: case SelectionDelta: case HideDelta:
            case MaterialDelta: case EdgeSelByEnds:
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
private bool owesDisplayRefresh(in MeshOpEntry[] log) {
    foreach (ref e; log) {
        final switch (e.kind) with (MeshOpEntry.Kind) {
            case SelectionDelta: case EdgeSelByEnds:
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
    static assert(EnumMembers!K.length == 15,
        "MeshOpEntry.Kind gained or lost a member. Add its row to the table "
      ~ "below — deciding indexSpaceStable / owesTopologyBump / displayTermFor "
      ~ "/ owesDisplayRefresh for it is the point of this cell, and the four "
      ~ "`final switch`es have already refused to compile until you answered "
      ~ "them there.");
    static assert(K.max == K.MapValueDelta,
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
                 ~ "Only SelectionDelta and EdgeSelByEnds owe nothing — their "
                 ~ "whole payload is the highlight, which DisplayRefreshMask "
                 ~ "deliberately excludes.",
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

unittest // W7 — the fast path's asserts are COMPILED (see the header above)
{
    import core.exception : AssertError;
    import mesh_corner_maps : CornerDrop;

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
                           in ulong[] edgeSetKeyDropped,
                           in ulong[] edgeSetWordDropped) {
        if (idx.length == 0) return;
        assert(vertSetMaskBefore.length == 0
            || vertSetMaskBefore.length == idx.length,
            "recordRemoveVerts: the vertex set-mask payload must be empty or "
          ~ "parallel to `idx` — a partial one would restore membership onto "
          ~ "whichever vertices happen to line up");
        assert(edgeSetKeyDropped.length == edgeSetWordDropped.length,
            "recordRemoveVerts: the dropped edge-set keys and words are not "
          ~ "parallel");
        MeshOpEntry e;
        e.kind = MeshOpEntry.Kind.RemoveVerts;
        e.vIdx = idx.dup;
        e.pos  = pos.dup;
        e.vertSetMaskBefore  = vertSetMaskBefore.dup;
        e.edgeSetKeyDropped  = edgeSetKeyDropped.dup;
        e.edgeSetWordDropped = edgeSetWordDropped.dup;
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
private void applyForward(ref Mesh m, ref const MeshOpEntry e,
                          bool cornerCarryActive) {
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
            applyFaceReindexForward(m, e, cornerCarryActive);
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
        case MeshOpEntry.Kind.MapValueDelta:
            patchMapValues(m, e, /*forward=*/true);
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
            if (v0 <= m.vertices.length)
                m.vertices.length = v0;
            break;
        case MeshOpEntry.Kind.RemoveVerts:
            // Inverse of drop = re-insert at the recorded (pre-removal) indices.
            removeVertsReverse(m, e.vIdx, e.pos, e.vertSetMaskBefore,
                               e.edgeSetKeyDropped, e.edgeSetWordDropped);
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
            applyFaceReindexReverse(m, e, cornerCarryActive);
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
        case MeshOpEntry.Kind.MapValueDelta:
            patchMapValues(m, e, /*forward=*/false);
            break;
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
private void applyFaceReindexForward(ref Mesh m, ref const MeshOpEntry e,
                                    bool cornerCarryActive) {
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
    // `CornerCarry` (above) HAS a `Kind.FaceReindex` case as of task 1903
    // Stage J, so this drop is the FALLBACK rather than the policy: it runs
    // only when the carry has declined (no PolyVertex map at all, maps out of
    // step with `faces` at replay entry, or the case's own index-space check
    // fired). An EXPLICIT drop in that case is what keeps `buildLoops()` from
    // either asserting (a length mismatch it cannot explain) or, worse,
    // silently leaving a length-correct-by-COINCIDENCE map sitting on the
    // wrong faces' corners. When the carry IS active it will place the values
    // itself in `finalize` — declaring a drop here would zero them, because
    // `resizePolyVertexMaps` consumes the declaration and returns from its
    // FIRST branch without ever looking at what the carry wrote.
    if (!cornerCarryActive)
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
private void applyFaceReindexReverse(ref Mesh m, ref const MeshOpEntry e,
                                    bool cornerCarryActive) {
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
    // regardless of which code path rewrote `faces`. Same FALLBACK gate as
    // the forward direction (task 1903 Stage J): declared only when
    // `CornerCarry` has declined, including when `oldFaceCount == 0` (S4
    // above), where the carry's own `payloadForCount` finds no payload for
    // zero faces and declines on its own.
    if (!cornerCarryActive)
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
// TASK 1903 STAGE L5-b — `vertexSetMask` LEFT THAT CLASS AND THE OTHERS DID
// NOT. Read the paragraph above as history: it lumps four planes together
// (`vertexMarks`, the Point-map values, the `present` bytes, and the set mask)
// under one "documented limit", and exactly one of the four is now RESTORED.
//
//   RESTORED, from the entry's own payload: `vertexSetMask`, on all three
//       arms, plus the `edgeSetMask` entries whose endpoint vanished (re-
//       inserted after the loop, in the pre-compaction key space
//       `applyReindexReverse` has just put the mesh back into).
//   STILL ZEROED, unchanged: `vertexMarks`, every Point-domain `MeshMap`
//       value and its `present` byte.
//
// WHY THE SPLIT IS NOT ARBITRARY. The set mask is DOCUMENT state a user
// names, saves in `.v3d` and reloads — "a named selection set vanished on
// Ctrl+Z" is a data-loss report (task 2280). A re-inserted vertex coming back
// VISIBLE and un-marked is the convention the rest of `mesh.d` already
// follows for index changes (`clearFaceSelectionResize` et al.), and the
// Point-map half is covered belt-and-braces by the migrated commands' own
// `preMaps_` capture. Widening the payload to the other three is a separate
// decision with its own byte cost; it is NOT implied by this one.
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
private void removeVertsReverse(ref Mesh m, in uint[] idx, in Vec3[] pos,
                                in ulong[] vertSetMaskBefore,
                                in ulong[] edgeSetKeyDropped,
                                in ulong[] edgeSetWordDropped) {
    // Task 1903 Stage L5-b. EMPTY means "nothing to restore" — the honest
    // empty a mesh with no selection sets produces — and a payload of the
    // WRONG length is refused WHOLE rather than applied to the prefix that
    // happens to line up: a set membership landing on the wrong vertex is a
    // legal-looking wrong answer, which is worse than the zero it replaces.
    const bool haveVsm = vertSetMaskBefore.length == idx.length;
    ulong vsmFor(size_t i) { return haveVsm ? vertSetMaskBefore[i] : 0UL; }
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
            // Task 1903 Stage L5-b: this IS a restored capture now — the
            // one plane of the four that left the "documented limit" class.
            // See this function's header for which three did not.
            if (vi < m.vertexSetMask.length) m.vertexSetMask[vi] = vsmFor(i);
        } else if (vi == m.vertices.length) {
            m.vertices ~= pos[i];             // contiguous append at the tail
            m.vertexMarks ~= 0u;
            foreach (ref mm; m.meshMaps) {
                if (mm.domain != MapDomain.Point || mm.dim == 0) continue;
                foreach (_; 0 .. mm.dim) mm.data ~= 0f;
                if (mm.present.length != 0) mm.present ~= cast(ubyte)0; // task 1069
            }
            m.vertexSetMask ~= vsmFor(i);   // task 1903 Stage L5-b
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
            if (vi <= m.vertexSetMask.length)
                m.vertexSetMask.insertInPlace(vi, vsmFor(i));   // Stage L5-b
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
    // Task 1903 Stage L5-b — the EDGE half, AFTER the whole loop and not
    // inside it. The recorded keys name PRE-compaction vertex indices, which
    // is the space the mesh is in only once every arm above has run (the
    // standalone-insert arm shifts existing keys up as it goes). Merged with
    // `|=` rather than assigned, matching `selSetRekeyEdges`' own conservative
    // rule for two old keys landing on one new one: a restore may add
    // membership back, never take it away.
    foreach (k, key; edgeSetKeyDropped) {
        if (auto p = key in m.edgeSetMask) *p |= edgeSetWordDropped[k];
        else                               m.edgeSetMask[key] = edgeSetWordDropped[k];
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
    import change_bus : BusSelDomain = SelDomain;
    bool any = false;
    BusSelDomain busDom;
    final switch (dom) {
        case MeshOpEntry.SelDomain.Vertex:
            busDom = BusSelDomain.Vertex;
            foreach (i, e; idx) if (e < m.vertexMarks.length) any |= setSelectBit(m.vertexMarks[e], vals[i]);
            break;
        case MeshOpEntry.SelDomain.Edge:
            busDom = BusSelDomain.Edge;
            foreach (i, e; idx) if (e < m.edgeMarks.length) any |= setSelectBit(m.edgeMarks[e], vals[i]);
            break;
        case MeshOpEntry.SelDomain.Face:
            busDom = BusSelDomain.Face;
            foreach (i, e; idx) if (e < m.faceMarks.length) any |= setSelectBit(m.faceMarks[e], vals[i]);
            break;
    }
    // TASK 1903 L0.P1 — NOTE THE SELECTION DOMAIN, on BOTH paths.
    //
    // This loop writes Select marks RAW (see `setSelectBit` below) and, until
    // now, noted no selection domain at all: on the slow path the incidental
    // full `Polygons` re-upload that `rebuildEdges` publishes repainted the
    // highlight by brute force, so nobody noticed. The carve-out drops that
    // publish, and `Marks` is deliberately outside `display_sync`'s
    // DisplayRefreshMask, so the domain note is what a selection consumer has
    // left to key on.
    //
    // Placed HERE rather than in the fast branch so the two paths cannot
    // diverge: it is the funnel every guarded marks setter on `Mesh` already
    // uses, it accumulates without delivering (`finalize`'s `commitRestored`
    // is the delivery), and it can only invalidate MORE, never less.
    //
    // Guarded on a REAL flip, like every one of those setters — `setSelectBit`
    // reports whether the word actually changed. The recorders guard only
    // `idx.length == 0`, so a `before == after` entry is representable, and a
    // no-op restore must not publish (памятка: a paint stroke without
    // compare-before-set delivered 280 times for 42 edits).
    if (any) m.noteSelectionChange(busDom);
}

// Returns TRUE iff the word actually changed — see `patchSelection`'s domain
// note above for why the caller needs to know.
private bool setSelectBit(ref uint word, uint on) {
    // §3.1 Select ∧ Hide = ∅ (doc/hide_geometry_plan.md, code review task
    // 0613 — S2) — this sparse patch is the delta-backed undo/redo replay's
    // own Select writer (delete / remove / edge extrude / edge extend), and
    // it does not go through any of mesh.d's guarded selectX /
    // setXSelectedFrom primitives. Refuse the same way they do — silently —
    // or a redo/undo round-trip could resurrect a Select bit on an element
    // that is (still) hidden at this index.
    if (on != 0 && (word & Mesh.Marks.Hide) != 0) return false;
    const uint was = word;
    if (on) word |=  Mesh.Marks.Select;
    else    word &= ~Mesh.Marks.Select;
    return word != was;
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
// NO `commitChange` HERE. Same convention as `patchSubpatch` / `patchHide` /
// `patchMaterial`: `finalize` publishes ONCE for the whole replay.
// ---------------------------------------------------------------------------
private void patchMapValues(ref Mesh m, ref const MeshOpEntry e, bool forward) {
    final switch (e.mapOp) with (MeshOpEntry.MapOp) {
        case Values:
            patchMapValuesWrite(m, e, forward);
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
            if (forward) mapRegister(m, e, e.mapValsAfter, e.presentAfter,
                                     uint.max);
            else         mapUnregister(m, e);
            break;
        case Remove:
            if (forward) mapUnregister(m, e);
            else         mapRegister(m, e, e.mapValsBefore, e.presentBefore,
                                     e.mapSlot);
            break;
        case Rename:
            if (forward) mapRename(m, e, e.mapName, e.mapNameTo);
            else         mapRename(m, e, e.mapNameTo, e.mapName);
            break;
    }
}

// Resolve the entry's map and check every REFUSAL term the payload carries.
// Returns null (having ticked the counter) on any mismatch.
private MeshMap* bindMapForEntry(ref Mesh m, ref const MeshOpEntry e, string name) {
    auto live = m.meshMap(name);
    if (live is null)          { ++changeBus.mapDeltaBindRefused; return null; }
    if (live.dim    != e.mapDim
     || live.domain != e.mapDomain
     || live.kind   != e.mapKind) { ++changeBus.mapDeltaBindRefused; return null; }
    return live;
}

private void patchMapValuesWrite(ref Mesh m, ref const MeshOpEntry e, bool forward) {
    auto live = bindMapForEntry(m, e, e.mapName);
    if (live is null) return;

    const bool tracks = kindInfo(live.kind).tracksPresence;
    const(float)[] vals = forward ? e.mapValsAfter  : e.mapValsBefore;
    const(ubyte)[] pres = forward ? e.presentAfter : e.presentBefore;

    final switch (e.mapAddr) with (MeshOpEntry.MapAddressing) {
        case Listed:
            // A `Listed` entry with NO indices is a DROPPED plane, not "all
            // elements" — refuse it rather than rewriting the whole map with
            // whatever the value arrays hold. That inference is the
            // empty-means-all trap this addressing enum exists to close.
            if (e.mapElemIdx.length == 0) { ++changeBus.mapDeltaBindRefused; return; }
            const size_t want = e.mapElemIdx.length * live.dim;
            if (e.mapValsBefore.length != want || e.mapValsAfter.length != want) {
                ++changeBus.mapDeltaBindRefused; return;
            }
            if (tracks) {
                if (e.presentBefore.length != e.mapElemIdx.length
                 || e.presentAfter.length  != e.mapElemIdx.length) {
                    ++changeBus.mapDeltaBindRefused; return;
                }
                // THE LIVE CHANNEL'S OWN LENGTH, and this term is not
                // decoration. `present.length == 0` LEGALLY means "every
                // element is present", and every writer in `mesh.d` guards on
                // `i < present.length` — so without this compare a Listed
                // restore writes `data`, silently drops the presence half, and
                // every other length term still passes with no counter moving.
                // `data` then compares equal to the recorded values, so a
                // value-plane assertion does not see it either.
                if (live.present.length != m.elementCount(live.domain)) {
                    ++changeBus.mapDeltaBindRefused; return;
                }
            } else if (e.presentBefore.length != 0 || e.presentAfter.length != 0) {
                ++changeBus.mapDeltaBindRefused; return;
            }
            foreach (idx; e.mapElemIdx) {
                const size_t b = cast(size_t)idx * live.dim;
                if (idx >= m.elementCount(live.domain) || b + live.dim > live.data.length) {
                    ++changeBus.mapDeltaBindRefused; return;
                }
            }
            // Bound. From here every write lands, and DELIBERATELY WITHOUT a
            // second `idx < live.present.length` guard: the bind terms above
            // are the single authority, and a belt-and-braces guard here would
            // be an unnamed second refusal standing in front of the named one —
            // the shape that makes a witness green on the broken code. If the
            // live-presence bind term is ever removed, this line is a
            // bounds-checked abort in `-debug` and an out-of-bounds WRITE in
            // `-release`; that is a feature of the arrangement, not an
            // oversight. (The plan predicted a silent drop here, on the
            // assumption that this loop would guard the way `mesh.d`'s own
            // setters do. It does not, so the term protects more than the
            // plan said. Recorded rather than "fixed" by adding the guard.)
            foreach (k, idx; e.mapElemIdx) {
                const size_t b = cast(size_t)idx * live.dim;
                live.data[b .. b + live.dim] = vals[k * live.dim .. (k + 1) * live.dim];
                if (tracks) live.present[idx] = pres[k];
            }
            break;

        case WholeArray:
            if (e.mapValsBefore.length != live.data.length
             || e.mapValsAfter.length  != live.data.length) {
                ++changeBus.mapDeltaBindRefused; return;
            }
            if (tracks) {
                if (e.presentBefore.length != live.present.length
                 || e.presentAfter.length  != live.present.length) {
                    ++changeBus.mapDeltaBindRefused; return;
                }
            } else if (e.presentBefore.length != 0 || e.presentAfter.length != 0) {
                ++changeBus.mapDeltaBindRefused; return;
            }
            live.data[] = vals[];
            if (tracks) live.present[] = pres[];
            break;

        case DefaultInit:
            // Meaningless for a value write — it is the `Create` arm's "the
            // content `addMeshMapOfKind` produces". A `Values` entry that
            // carries it is malformed, and saying so is cheaper than guessing
            // which of the two shapes the recorder meant.
            ++changeBus.mapDeltaBindRefused;
            break;
    }
}

// Register the entry's map and, unless the entry says DefaultInit, fill it
// from the supplied image. Used by `Create` FORWARD and `Remove` REVERSE —
// the same operation, reached from the two arms whose payload class differs.
private void mapRegister(ref Mesh m, ref const MeshOpEntry e,
                         const(float)[] vals, const(ubyte)[] pres, uint slot) {
    if (e.mapName.length == 0)          { ++changeBus.mapDeltaBindRefused; return; }
    if (m.meshMap(e.mapName) !is null)  { ++changeBus.mapDeltaBindRefused; return; }

    // Through the CLASSIFIED door when the kind declares a shape, so dim and
    // domain come from `kindInfo` and cannot drift from the shape table; the
    // raw door otherwise (`unclassified` has no declarable shape — `kindInfo`
    // gives it dim 0, which `addMeshMap` rejects outright).
    MeshMap* live;
    if (e.mapKind == MapKind.unclassified)
        live = m.addMeshMap(e.mapName, e.mapDim, e.mapDomain);
    else
        live = m.addMeshMapOfKind(e.mapKind, e.mapName);

    // `addMeshMap` returns NULL at the MAX_MESH_MAPS ceiling as well as on a
    // duplicate name. A reverse that dereferenced it would crash; a reverse
    // that ignored it would restore nothing and answer `true`.
    if (live is null) { ++changeBus.mapDeltaBindRefused; return; }

    // The shape the classified door produced must be the shape recorded, or
    // the fill below writes into the wrong layout.
    if (live.dim != e.mapDim || live.domain != e.mapDomain) {
        m.removeMeshMap(e.mapName);
        ++changeBus.mapDeltaBindRefused;
        return;
    }

    if (e.mapAddr == MeshOpEntry.MapAddressing.DefaultInit) {
        // "the content addMeshMapOfKind produces" — already there.
        mapMoveLastTo(m, slot);
        return;
    }

    const bool tracks = kindInfo(live.kind).tracksPresence;
    if (vals.length != live.data.length
     || (tracks && pres.length != live.present.length)
     || (!tracks && pres.length != 0)) {
        // Refuse the entry WHOLE — including the registration it just made,
        // so a half-restored map never reaches the document.
        m.removeMeshMap(e.mapName);
        ++changeBus.mapDeltaBindRefused;
        return;
    }
    live.data[] = vals[];
    if (tracks) live.present[] = pres[];
    // LAST, and it must be last: `live` points into `meshMaps` and the move
    // below rewrites that array. Fill through the pointer, then place.
    mapMoveLastTo(m, slot);
}

// Rotate the just-appended map from the end of `meshMaps` into `slot`,
// shifting the maps in between right by one — the inverse of the splice
// `removeMeshMap` performed. A no-op for `uint.max` and for any slot at or
// past the end.
//
// CLAMPS RATHER THAN REFUSES, and the reason is in `MeshOpEntry.mapSlot`: the
// registry may legitimately have shrunk between record and replay, and a map
// restored at the wrong index is a smaller error than a map not restored at
// all. Every pointer into `meshMaps` is invalid after this call.
private void mapMoveLastTo(ref Mesh m, uint slot) {
    if (slot == uint.max || m.meshMaps.length == 0) return;
    const size_t last = m.meshMaps.length - 1;
    if (cast(size_t)slot >= last) return;
    auto moved = m.meshMaps[last];
    foreach_reverse (i; cast(size_t)slot .. last)
        m.meshMaps[i + 1] = m.meshMaps[i];
    m.meshMaps[cast(size_t)slot] = moved;
}

// Drop the entry's map — `Create` REVERSE and `Remove` FORWARD. Binds first,
// with the same refusal terms, so a map that came back reshaped between record
// and replay is not deleted on this entry's word.
private void mapUnregister(ref Mesh m, ref const MeshOpEntry e) {
    auto live = bindMapForEntry(m, e, e.mapName);
    if (live is null) return;
    m.removeMeshMap(e.mapName);
}

// Rename `from` -> `to`, in whichever direction the caller asked for.
//
// BOTH ENDS BIND. `Mesh.meshMap()` and `Mesh.removeMeshMap()` each take the
// FIRST name match, so a DUPLICATE source name would rename the wrong map and
// leave the other permanently unreachable; and the shipped rename command
// throws on a taken target, which this arm must not quietly undercut.
private void mapRename(ref Mesh m, ref const MeshOpEntry e, string from, string to) {
    if (from.length == 0 || to.length == 0) { ++changeBus.mapDeltaBindRefused; return; }
    auto live = bindMapForEntry(m, e, from);
    if (live is null) return;
    size_t matches = 0;
    foreach (ref mm; m.meshMaps) if (mm.name == from) ++matches;
    if (matches != 1)                { ++changeBus.mapDeltaBindRefused; return; }
    if (m.meshMap(to) !is null)      { ++changeBus.mapDeltaBindRefused; return; }
    live.name = to;
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
    import display_sync : DisplayRefreshMask;
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
        // the only armers are applyFaceReindexForward/Reverse and
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
    // `edges` is a pure function of `faces` (index pairs; positions never
    // enter), the loops family and `edgeIndexMap` are functions of `faces`
    // alone, and no index-space-stable kind writes `faces`. Their
    // structVersion-keyed validity stamps stay Valid because `structVersion`
    // does not move either (asserted above). The PUBLISH half is NOT part of
    // the win and is re-issued per kind at `commitRestored` below.
    if (!fast) {
        m.rebuildEdges();
        m.buildLoops();
    }
    // Keep the per-element marks / order arrays length-correct with the
    // restored geometry (the same resize primitives the topology mutators run).
    // These GROW/SHRINK without clearing; the SelectionDelta entries restored
    // the actual bits, so this only fixes lengths after a count change.
    m.vertexMarks.length          = m.vertices.length;
    m.vertexSelectionOrder.length = m.vertices.length;
    // TASK 1903 STAGE L2-c — `vertexSetMask` was missing from this length sync,
    // the SAME hole task 1060's review closed for `faceSetMask` two lines below
    // and for the same reason. `AddVerts`'s forward/reverse (`m.vertices ~= …` /
    // `m.vertices.length = v0`) carry no parallel-array payload of their own, so
    // they rely entirely on this blanket resize to stay aligned; `RemoveVerts`'s
    // reverse splices its own entry in and this line is a no-op for it.
    //
    // FOUND BY THE FROZEN PARITY ORACLE, not by review: `mesh.split_edge`'s
    // `resetSelection()` grows `vertexSetMask` to V+1 on the forward, and the
    // delta revert put `vertices` back to V and left the mask at V+1 —
    // `create_stable.json [mesh.split_edge/postUndo]: plane 'vertexSetMask'
    // differs`. The snapshot path restored the array whole and did not.
    //
    // THE USER-VISIBLE HALF, which is why this is a fix and not hygiene:
    // `mesh_selsets.selSetMembersVertex` walks the MASK, not `m.vertices`, so a
    // stale out-of-range entry reaches `/api/model` and the `.v3d` writer, and
    // the loader's own bounds guard then drops the WHOLE named set on reload
    // rather than the one bad entry — the exact incident `faceSetMask`'s line
    // records.
    m.vertexSetMask.length        = m.vertices.length;
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
            ++m.topologyVersion;
    } else {
        if (!(scope_ & MeshEditScope.Geometry)) ++m.topologyVersion;
    }
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
