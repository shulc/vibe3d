// map_edit_undo — the two arms every migrated MAP command shares
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
// Here: the ARM DISPATCH — redo, then recorded — and the mesh half of the
// revert. Both arms are identical for every map command in the family and
// getting one of them wrong (recording a second delta over the first on a
// redo; paying a `.dup` on an unrecorded path) is a defect that reads the same
// in all of them.
//
// TASK 1903 STAGE N — THERE WERE THREE ARMS AND THE THIRD ONE IS GONE. Until
// this stage a `VIBE3D_UNDO_TRACKER=0` arm captured a whole-mesh
// `MeshSnapshot` into a `ref MeshSnapshot snap` this function took, and
// twenty caller files declared a field for no other purpose (each commented
// `// the hatch's arm only`). That third arm is why Stages L1 and L2 could not
// use a `MeshSnapshot` DECLARATION census as their closing gate — the count
// was immovable, green on the migrated and the unmigrated file alike (card
// 2290). Deleting it is what makes that observable honest, and the census it
// enables is worth more than the flag it deletes.
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
// TASK 1903 STAGE L2-a — THE NAME IS NOW HISTORICAL, AND DELIBERATELY NOT
// CHANGED. Stage L2's `mesh.flip`, `mesh.fixOrientation` and `mesh.spinEdge`
// take `runMapEdit` unchanged: nothing in its body is about MAPS — the arm
// dispatch is the same two arms for any family, and
// `declared` is the caller's scope, here `MeshEditScope.Geometry` rather than
// `Material`. A private copy in a geometry file would be the SECOND
// implementation of one mechanism, which is what this module's own header
// refuses; a rename to `recorded_edit` would touch 75 references across eleven
// files in a lane that has just landed, for no behaviour. So the mechanism is
// shared under L1's name and the misnomer is written down rather than hidden.
// (`mapSlotOf` below IS map-specific and has no geometry caller.) Renaming it
// is carried as a follow-up, not taken here.
module commands.mesh.map_edit_undo;

import command        : Command;
import mesh            : Mesh, MeshEditBatch;
import commands.mesh.position_undo : RecordedUndo;

/// Run `kernel` under whichever of the two arms applies, and leave the
/// command's undo image in `undo`.
///
/// `declared` is the batch's `MeshEditScope`. Each group passes what its
/// commands ALREADY published before the migration — `Material` for the UV and
/// weight families, `Maps` for morph — because reclassifying a publisher is a
/// behaviour change (`docRevision`, and therefore the unsaved-changes
/// asterisk) and is carried as an open question, not as a migration side
/// effect. See `mesh_edit_delta.MeshEditScope.Maps`, whose own doc says the
/// pre-existing `setMeshMapValue` publishers keep `Material` so that no
/// existing consumer changes behaviour.
/// TASK 2500 — `self` is passed straight through to `RecordedUndo.arm`, which
/// is where the undo image and its flag are raised in one statement. The
/// per-command `applied_` bit this used to be paired with is gone: an empty
/// delta leaves the holder disarmed and the flag down, and `Command.revert`
/// answers that case before any command body runs.
bool runMapEdit(Command self, Mesh* mesh, ref RecordedUndo undo,
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
    auto ed = MeshEditBatch(*mesh, declared);
    const ok = kernel(ed);
    undo.arm(self, ed.close());
    if (!ok) { undo.disarm(self); return false; }
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

