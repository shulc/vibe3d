// Module unittests for `ai3d.scene_validator`, moved verbatim out of source/ai3d/scene_validator.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai3d.scene_validator_test;

import std.math : abs, isFinite;
import std.string : representation;
import io.scene_ir : ImportedScene;
import ai3d.scene_validator;

unittest {
    // task ai3d-maxfaces (ceiling raise, follow-up to the 0381 face-cap
    // regression): a single-part artifact may use the WHOLE face budget —
    // Ai3dMaxFacesPerPart == Ai3dMaxTotalFaces == the ceiling
    // ai3d.stage_artifact.clampMaxFaces enforces on the user-chosen
    // `maxFaces` (commands/ai3d/generate.d). Every face also gets a
    // faceMaterial entry (io/scene_import.d always sizes it to
    // faces.length), so `mk()` below populates that stream too — this is
    // the real shape of an imported single-material mesh, not a stripped-down
    // approximation, and it exercises the Ai3dMaxFaceMaterialEntries cap
    // raised alongside the face caps above.
    //
    // Constructing/validating a real Ai3dMaxFacesPerPart(+1)-face part is
    // O(faces) but still fast in practice (sub-second) — the shipped
    // ceiling is tested directly rather than against a scaled-down stand-in.
    import io.scene_ir : ImportedScene, ImportedPart;
    import math : Vec3;

    static ImportedPart mk(size_t nFaces) {
        ImportedPart p;
        p.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
        p.faces.length = nFaces;
        foreach (ref f; p.faces) f = [0u, 1u, 2u];
        p.faceMaterial.length = nFaces; // always 0 (default material)
        return p;
    }

    ImportedScene atBudget;
    atBudget.parts = [mk(Ai3dMaxFacesPerPart)];
    assert(validateImportedSceneForAi3d(atBudget).ok,
        "a single part at the full per-part face budget must pass");

    ImportedScene overBudget;
    overBudget.parts = [mk(Ai3dMaxFacesPerPart + 1)];
    const r = validateImportedSceneForAi3d(overBudget);
    assert(!r.ok, "an over-budget face count must be rejected");
    // The reason must be carried so the UI modal can display WHY (not stderr-only).
    assert(r.message == "AI3D part exceeds face limit",
        "rejection must carry the face-limit reason: " ~ r.message);
    assert(Ai3dMaxFacesPerPart == Ai3dMaxTotalFaces,
        "per-part face cap must equal the total budget for the single-part case");
}
