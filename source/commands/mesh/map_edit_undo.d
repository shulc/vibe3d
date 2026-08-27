// map_edit_undo — the three arms every migrated MAP command shares
// (task 1903 Stage L1).
//
// EXTRACTED FROM `morph.d` AT STAGE L1-b, NOT RE-WRITTEN. Stage L1-a spelled
// these two functions once, privately, for five commands in one file. L1-b
// migrates thirteen more across seven files, and a private copy per file would
// be eight implementations of one mechanism — the shape `RecordedUndo`'s own
// header refuses for the same reason. The bodies are verbatim; only the home
// moved, and `morph.d` now imports them.
//
// WHAT LIVES HERE AND WHAT DELIBERATELY DOES NOT.
//
// Here: the ARM DISPATCH — redo, recorded, hatch — and the mesh half of the
// revert. Those three arms are identical for every map command in the family
// and getting one of them wrong (recording a second delta over the first on a
// redo; paying a `.dup` on an unrecorded path) is a defect that reads the same
// in all of them.
//
// NOT here: the answer to an EMPTY edit. Each command's `revert()` keeps its
// own arm, next to the guard that makes it reachable or not — the rule
// `commands/mesh/position_undo.d` states for L0-d, whose reason was measured:
// four position commands must answer TRUE on an empty edit because a `false`
// makes `CommandHistory.undo` discard the entry AND its trailing suffix
// (regression 0099). Folding that into a shared revert would decide N
// questions with one answer.
//
// Also NOT here: the non-mesh tail. Three of morph's five commands re-point
// the `morph_target` binding after the mesh half; no UV or weight command has
// one. A shared tail would have to know about all of them.
//
// THE KERNEL RUNS INSIDE THE BATCH AND MAY ONLY `return false`, NEVER THROW.
// An exception between the open and the close leaves `~MeshEditBatch` to pop
// the frame and tick `changeBus.batchLeaks`, which the suite asserts is 0.
// Every guard that can refuse is therefore resolved by the caller BEFORE
// `runMapEdit` is entered — which for the L1-b groups meant hoisting the
// duplicate-name and `MAX_MESH_MAPS` pre-checks out of the create paths, where
// they used to be a `throw` from the middle of the mutation.
module commands.mesh.map_edit_undo;

import mesh            : Mesh, MeshEditBatch;
import snapshot        : MeshSnapshot;
import mesh_edit_delta : undoTrackerEnabled;
import commands.mesh.position_undo : RecordedUndo;

/// Run `kernel` under whichever of the three arms applies, and leave the
/// command's undo image in `undo` (tracker) or `snap` (hatch).
///
/// `declared` is the batch's `MeshEditScope`. Each group passes what its
/// commands ALREADY published before the migration — `Material` for the UV and
/// weight families, `Maps` for morph — because reclassifying a publisher is a
/// behaviour change (`docRevision`, and therefore the unsaved-changes
/// asterisk) and is carried as an open question, not as a migration side
/// effect. See `mesh_edit_delta.MeshEditScope.Maps`, whose own doc says the
/// pre-existing `setMeshMapValue` publishers keep `Material` so that no
/// existing consumer changes behaviour.
bool runMapEdit(Mesh* mesh, ref RecordedUndo undo, ref MeshSnapshot snap,
                uint declared, scope bool delegate(ref MeshEditBatch) kernel)
{
    // REDO: `CommandHistory.redo` re-runs `apply()`, so a second `evaluate`
    // on an armed command must re-run the kernel UNRECORDED and keep the
    // FIRST delta rather than record a second one over it.
    if (undo.armed()) {
        auto ed = MeshEditBatch.unrecorded(*mesh, declared);
        const ok = kernel(ed);
        ed.close();
        return ok;
    }
    if (undoTrackerEnabled()) {
        auto ed = MeshEditBatch(*mesh, declared);
        const ok = kernel(ed);
        undo.arm(ed.close());
        if (!ok) { undo.disarm(); return false; }
        return true;
    }
    // THE HATCH (`VIBE3D_UNDO_TRACKER=0`). The same kernel through an
    // UNRECORDED batch, so a migrated file's commit seam is identical on both
    // paths and only the undo IMAGE differs.
    snap = MeshSnapshot.capture(*mesh);
    auto ed = MeshEditBatch.unrecorded(*mesh, declared);
    const ok = kernel(ed);
    ed.close();
    if (!ok) snap = MeshSnapshot.init;
    return ok;
}

/// The mesh half of every migrated `revert()`. The command's own non-mesh tail
/// stays at the call site.
bool revertMapEdit(Mesh* mesh, ref RecordedUndo undo, ref MeshSnapshot snap) {
    if (undo.armed()) return undo.revert(*mesh);
    if (!snap.filled) return false;
    snap.restore(*mesh);
    return true;
}

/// The map's index in `Mesh.meshMaps`, or `uint.max` when it is not there.
///
/// RECORDED BY EVERY `Remove` ARM, and it is not decoration: `removeMeshMap`
/// SPLICES the registry while the delta's re-registration APPENDS, so a
/// reverse that does not carry the slot restores the map's CONTENT at the
/// wrong position. `meshPlanesJson` reads `meshMaps` in ARRAY ORDER and
/// `MeshSnapshot.restore` put the array back whole, so that is a plane the
/// migration would silently restore LESS of than the snapshot did — measured
/// at Stage L1-a on `mesh.morph.remove` and again at L1-b on
/// `mesh.weightmap.remove` and `uv.delete`, all three against the frozen
/// oracle. See `MeshOpEntry.mapSlot`.
uint mapSlotOf(Mesh* m, string name) {
    foreach (i, ref mm; m.meshMaps) if (mm.name == name) return cast(uint) i;
    return uint.max;
}

/// `revertMapEdit`, except that a command which recorded NOTHING answers
/// **true**.
///
/// THE CHOICE BETWEEN THE TWO SPELLINGS IS THE COMMAND'S, WHICH IS WHY THEY
/// ARE TWO NAMES AND NOT A FLAG — `position_undo.d`'s rule, and its reason was
/// measured: `CommandHistory.undo` discards an entry whose `revert()` answers
/// false AND the whole trailing suffix after it (regression 0099,
/// `tests/test_edge_slide.d`). So the answer belongs next to the guard that
/// decides whether the empty case is reachable at all.
///
/// WHICH COMMANDS TAKE THIS ONE. Every caller of the POST-HOC door
/// `MeshEditBatch.recordMapValueDiff`: it records nothing when no element
/// moved bitwise, and "no element moved" is reachable on a forward that
/// SUCCEEDED — `uv.rotate` by 0 degrees, `uv.fit` on an already-fitted map,
/// `uv.pack` on one island already at the origin. Those forwards return true
/// and land a history entry, and before the migration their `revert()` was a
/// no-op `MeshSnapshot.restore` that answered true. Answering false here would
/// be both a regression-0099 shape AND a divergence from the dense path.
///
/// WHICH DO NOT. The eight commands that record through the tracker directly
/// (`recordMapValues/Create/Remove/Rename`): those recorders are unconditional
/// once their command's own guards have passed, so on the tracker path the log
/// always carries an entry and this arm is UNREACHABLE for them. They take
/// `revertMapEdit`, and a `false` from it means a real failure rather than an
/// empty edit.
///
/// `forwardSucceeded` IS A PARAMETER BECAUSE THE STATE IS NOT DERIVABLE, and
/// three shipped cells proved it rather than a review: `test_uv_transform.d`
/// ("revert without apply must return false"), `test_uv_pack.d` and
/// `test_uv_project.d` all assert a FALSE revert after a forward that refused
/// or never ran. "The forward refused" and "the forward succeeded and moved
/// nothing" are BOTH `!armed && !filled`, so a helper that reads only those
/// two would answer true for a command nobody applied — the mis-ordered-caller
/// case `RecordedUndo.revert` exists to make loud. The caller therefore holds
/// a bit its own `applyImpl` sets, and the two answers stay separate.
///
/// The first draft of this function did NOT take it, went green in lane U on
/// every cell written for it, and reddened only in lane S. Recorded here
/// because "no delta and no snapshot" reads like one state and is two.
bool revertMapEditEmptyOk(Mesh* mesh, ref RecordedUndo undo, ref MeshSnapshot snap,
                          bool forwardSucceeded) {
    if (!undo.armed() && !snap.filled) return forwardSucceeded;
    return revertMapEdit(mesh, undo, snap);
}
