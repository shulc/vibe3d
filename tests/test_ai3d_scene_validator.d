import ai3d.scene_validator;
import io.scene_ir;
import math;

ImportedPart triPart() {
    ImportedPart p;
    p.name = "ok";
    p.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)];
    p.faces = [[0u, 1u, 2u]];
    p.surfaces = [ImportedSurface()];
    p.faceMaterial = [0u];
    p.uv = [0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f];
    return p;
}

ImportedScene sceneWith(ImportedPart p) {
    ImportedScene s;
    s.parts = [p];
    return s;
}

void assertValid(ImportedScene s) {
    auto got = validateImportedSceneForAi3d(s);
    assert(got.ok, got.message);
}

void assertInvalid(ImportedScene s) {
    auto got = validateImportedSceneForAi3d(s);
    assert(!got.ok, "scene should be rejected");
    assert(got.code == "artifact_invalid", got.code);
}

unittest {
    assertValid(sceneWith(triPart()));
}

unittest {
    ImportedScene s;
    assertInvalid(s);
}

unittest {
    auto p = triPart();
    p.vertices = null;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.faces = null;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.faces = [[0u, 1u]];
    p.uv = null;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.faces = [[0u, 1u, 99u]];
    p.uv = null;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.faces = [[0u, 0u, 1u]];
    p.uv = null;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.vertices[0].x = float.nan;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.vertices[0].x = Ai3dMaxAbsCoordinate + 1.0f;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.uv[0] = float.infinity;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.uv[0] = Ai3dMaxAbsUv + 1.0f;
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.uv = [0.0f, 0.0f];
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.faceMaterial = [1u];
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.faceMaterial = [0u, 0u];
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.faceSubpatch = [false, true];
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.name.length = Ai3dMaxUtf8NameBytes;
    assertValid(sceneWith(p));
    p.name ~= "x";
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    p.vertices.length = Ai3dMaxVerticesPerPart;
    foreach (i; 3 .. p.vertices.length)
        p.vertices[i] = Vec3(cast(float)(i % 997), 0, 0);
    assertValid(sceneWith(p));
    p.vertices ~= Vec3(1, 1, 1);
    assertInvalid(sceneWith(p));
}

unittest {
    auto p = triPart();
    uint[] face;
    face.length = Ai3dMaxCornersPerFace;
    p.vertices.length = Ai3dMaxCornersPerFace;
    foreach (i; 0 .. Ai3dMaxCornersPerFace) {
        p.vertices[i] = Vec3(cast(float) i, 0, 0);
        face[i] = cast(uint) i;
    }
    p.vertices[2].y = 1;
    p.faces = [face];
    p.faceMaterial = [0u];
    p.uv = null;
    assertValid(sceneWith(p));
    face ~= cast(uint) Ai3dMaxCornersPerFace;
    p.vertices ~= Vec3(cast(float) Ai3dMaxCornersPerFace, 1, 0);
    p.faces = [face];
    assertInvalid(sceneWith(p));
}
