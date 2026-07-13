module ai3d.scene_validator;

import std.math : abs, isFinite;
import std.string : representation;

import io.scene_ir : ImportedScene;

// The artifact DOWNLOAD byte cap lives in `ai3d.stage_artifact`
// (`Ai3dMaxArtifactBytes` there, enforced in getBytesBounded). This module only
// validates an already-parsed scene, so its budget is `Ai3dMaxValidatedSceneBytes`
// (below) — do NOT re-add a download-cap constant here; it would be dead.
enum size_t Ai3dMaxParts = 16;
enum size_t Ai3dMaxVerticesPerPart = 500_000;
enum size_t Ai3dMaxTotalVertices = 1_000_000;
enum size_t Ai3dMaxFacesPerPart = 500_000;  // = Ai3dMaxTotalFaces (a single-part
                                            // artifact may use the whole face
                                            // budget; the worker's create-job
                                            // requests a user-chosen `maxFaces`
                                            // up to this ceiling — see
                                            // ai3d.stage_artifact.clampMaxFaces
                                            // / commands/ai3d/generate.d — so a
                                            // one-part TripoSR-class mesh
                                            // up to the full budget must not be
                                            // rejected).
enum size_t Ai3dMaxTotalFaces = 500_000;
enum size_t Ai3dMaxCornersPerFace = 16;
enum size_t Ai3dMaxTotalCorners = 2_000_000;
enum size_t Ai3dMaxSurfaces = 32;
enum size_t Ai3dMaxUtf8NameBytes = 256;
enum size_t Ai3dMaxTotalUtf8NameBytes = 8_192;
enum size_t Ai3dMaxUvEntries = 2_000_000;
enum float Ai3dMaxAbsCoordinate = 10_000.0f;
enum float Ai3dMaxAbsUv = 100.0f;
enum size_t Ai3dMaxPositionComponents = 3_000_000;
enum size_t Ai3dMaxUvComponents = 4_000_000;
// Coupled to Ai3dMaxTotalFaces (raised alongside it, task ai3d-maxfaces):
// io/scene_import.d unconditionally sets `faceMaterial.length = faces.length`
// for every imported part (every face gets a material index, even with a
// single default material) — a cap lower than Ai3dMaxFacesPerPart would
// silently reject any real single-material mesh above its own value before
// the face cap ever gets a chance to.
enum size_t Ai3dMaxFaceMaterialEntries = 500_000;
enum size_t Ai3dMaxIndexEntries = 2_000_000;
enum size_t Ai3dMaxValidatedSceneBytes = 64 * 1024 * 1024;

struct Ai3dSceneValidation {
    bool ok;
    string code;
    string message;
}

Ai3dSceneValidation validateImportedSceneForAi3d(const ref ImportedScene scene) {
    size_t totalVertices;
    size_t totalFaces;
    size_t totalCorners;
    size_t totalUtf8NameBytes;
    size_t totalUvEntries;
    size_t totalPositionComponents;
    size_t totalUvComponents;
    size_t totalFaceMaterialEntries;
    size_t totalIndexEntries;
    size_t estimatedBytes;

    bool add(ref size_t target, size_t value) {
        if (value > size_t.max - target)
            return false;
        target += value;
        return true;
    }

    bool addProduct(ref size_t target, size_t a, size_t b) {
        if (a != 0 && b > size_t.max / a)
            return false;
        return add(target, a * b);
    }

    Ai3dSceneValidation fail(string code, string message) {
        return Ai3dSceneValidation(false, code, message);
    }

    if (scene.parts.length == 0)
        return fail("artifact_invalid", "AI3D scene has no parts");
    if (scene.parts.length > Ai3dMaxParts)
        return fail("artifact_invalid", "AI3D scene exceeds part limit");

    foreach (pi, ref part; scene.parts) {
        if (part.vertices.length == 0)
            return fail("artifact_invalid", "AI3D part has no vertices");
        if (part.faces.length == 0)
            return fail("artifact_invalid", "AI3D part has no faces");
        if (part.vertices.length > Ai3dMaxVerticesPerPart)
            return fail("artifact_invalid", "AI3D part exceeds vertex limit");
        if (part.faces.length > Ai3dMaxFacesPerPart)
            return fail("artifact_invalid", "AI3D part exceeds face limit");
        if (part.surfaces.length > Ai3dMaxSurfaces)
            return fail("artifact_invalid", "AI3D part exceeds surface limit");
        if (part.faceMaterial.length > Ai3dMaxFaceMaterialEntries)
            return fail("artifact_invalid", "AI3D part exceeds face-material limit");

        const nameBytes = part.name.representation.length;
        if (nameBytes > Ai3dMaxUtf8NameBytes)
            return fail("artifact_invalid", "AI3D part name exceeds byte limit");
        if (!add(totalUtf8NameBytes, nameBytes) ||
            totalUtf8NameBytes > Ai3dMaxTotalUtf8NameBytes)
            return fail("artifact_invalid", "AI3D scene exceeds name byte limit");
        foreach (ref surface; part.surfaces) {
            const surfNameBytes = surface.name.representation.length;
            if (surfNameBytes > Ai3dMaxUtf8NameBytes)
                return fail("artifact_invalid", "AI3D surface name exceeds byte limit");
            if (!add(totalUtf8NameBytes, surfNameBytes) ||
                totalUtf8NameBytes > Ai3dMaxTotalUtf8NameBytes)
                return fail("artifact_invalid", "AI3D scene exceeds name byte limit");
        }

        foreach (v; part.vertices) {
            if (!v.x.isFinite || !v.y.isFinite || !v.z.isFinite)
                return fail("artifact_invalid", "AI3D vertex coordinate is not finite");
            if (abs(v.x) > Ai3dMaxAbsCoordinate ||
                abs(v.y) > Ai3dMaxAbsCoordinate ||
                abs(v.z) > Ai3dMaxAbsCoordinate)
                return fail("artifact_invalid", "AI3D vertex coordinate exceeds range");
        }

        if (!add(totalVertices, part.vertices.length) ||
            totalVertices > Ai3dMaxTotalVertices)
            return fail("artifact_invalid", "AI3D scene exceeds vertex limit");
        if (!add(totalFaces, part.faces.length) ||
            totalFaces > Ai3dMaxTotalFaces)
            return fail("artifact_invalid", "AI3D scene exceeds face limit");
        if (!addProduct(totalPositionComponents, part.vertices.length, 3) ||
            totalPositionComponents > Ai3dMaxPositionComponents)
            return fail("artifact_invalid", "AI3D scene exceeds position component limit");
        if (!addProduct(estimatedBytes, part.vertices.length, 3 * float.sizeof))
            return fail("artifact_invalid", "AI3D scene size overflow");

        size_t expectedUvFloats;
        foreach (fi, face; part.faces) {
            if (face.length < 3)
                return fail("artifact_invalid", "AI3D face has fewer than three corners");
            if (face.length > Ai3dMaxCornersPerFace)
                return fail("artifact_invalid", "AI3D face exceeds corner limit");
            if (!add(totalCorners, face.length) ||
                totalCorners > Ai3dMaxTotalCorners)
                return fail("artifact_invalid", "AI3D scene exceeds corner limit");
            if (!add(totalIndexEntries, face.length) ||
                totalIndexEntries > Ai3dMaxIndexEntries)
                return fail("artifact_invalid", "AI3D scene exceeds index-entry limit");
            if (!addProduct(estimatedBytes, face.length, uint.sizeof))
                return fail("artifact_invalid", "AI3D scene size overflow");

            bool[uint] unique;
            foreach (idx; face) {
                if (idx >= part.vertices.length)
                    return fail("artifact_invalid", "AI3D face index is out of range");
                unique[idx] = true;
            }
            if (unique.length < 3)
                return fail("artifact_invalid", "AI3D face collapses below three unique corners");

            if (fi < part.faceMaterial.length) {
                const mat = part.faceMaterial[fi];
                if (part.surfaces.length > 0 && mat >= part.surfaces.length)
                    return fail("artifact_invalid", "AI3D material index is out of range");
                if (part.surfaces.length == 0 && mat != 0)
                    return fail("artifact_invalid", "AI3D material index is out of range");
            }
            expectedUvFloats += face.length * 2;
        }

        if (part.faceSubpatch.length != 0 && part.faceSubpatch.length < part.faces.length)
            return fail("artifact_invalid", "AI3D faceSubpatch stream is misaligned");
        if (part.faceMaterial.length != 0 && part.faceMaterial.length < part.faces.length)
            return fail("artifact_invalid", "AI3D faceMaterial stream is misaligned");
        if (part.uv.length != 0 && part.uv.length != expectedUvFloats)
            return fail("artifact_invalid", "AI3D UV stream is misaligned");
        if (part.uv.length > 0) {
            if ((part.uv.length % 2) != 0)
                return fail("artifact_invalid", "AI3D UV stream is malformed");
            const uvEntries = part.uv.length / 2;
            if (uvEntries > Ai3dMaxUvEntries)
                return fail("artifact_invalid", "AI3D part exceeds UV entry limit");
            if (!add(totalUvEntries, uvEntries) ||
                totalUvEntries > Ai3dMaxUvEntries)
                return fail("artifact_invalid", "AI3D scene exceeds UV entry limit");
            if (!add(totalUvComponents, part.uv.length) ||
                totalUvComponents > Ai3dMaxUvComponents)
                return fail("artifact_invalid", "AI3D scene exceeds UV component limit");
            if (!addProduct(estimatedBytes, part.uv.length, float.sizeof))
                return fail("artifact_invalid", "AI3D scene size overflow");
            foreach (uv; part.uv) {
                if (!uv.isFinite)
                    return fail("artifact_invalid", "AI3D UV coordinate is not finite");
                if (abs(uv) > Ai3dMaxAbsUv)
                    return fail("artifact_invalid", "AI3D UV coordinate exceeds range");
            }
        }

        if (!add(totalFaceMaterialEntries, part.faceMaterial.length) ||
            totalFaceMaterialEntries > Ai3dMaxFaceMaterialEntries)
            return fail("artifact_invalid", "AI3D scene exceeds face-material limit");
        if (!addProduct(estimatedBytes, part.faceMaterial.length, uint.sizeof) ||
            !addProduct(estimatedBytes, part.faceSubpatch.length, bool.sizeof))
            return fail("artifact_invalid", "AI3D scene size overflow");
        if (estimatedBytes > Ai3dMaxValidatedSceneBytes)
            return fail("artifact_invalid", "AI3D validated scene exceeds byte budget");
    }

    if (totalFaces == 0 || totalVertices == 0)
        return fail("artifact_invalid", "AI3D scene is empty");
    return Ai3dSceneValidation(true, null, null);
}

bool importedSceneIsValidForAi3d(const ref ImportedScene scene) {
    return validateImportedSceneForAi3d(scene).ok;
}

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
