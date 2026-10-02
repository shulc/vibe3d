// The pure halves of the per-item face pass: the shared face normal, the
// reverse polygon order index list, and the plan -> FacePass mapping.
//
// The pixels are pinned by the suite test `tests/test_retopology_depth_fill.d`;
// these cells pin what the pixels cannot name: that the one face-normal home is
// BYTE-identical to the arithmetic it replaced (so the face VBO did not move),
// that every reverse-order range is the face it claims to be, and that the
// mode-off Shaded plan maps to the surface-culled pass (S1d, model M6) while
// `DrawPlan.init` still maps to exactly `FacePass.init`.
module tests.unit.retopology_face_pass_test;

import std.file : readText;
import std.format : format;
import std.math : sqrt;
import std.path : buildPath, dirName;
import std.string : count;

import display_state : DrawPlan, ViewportDisplay, resolveDrawPlan;
import item_xform : ItemXform;
import math : Vec3, faceNormalFirst3, identityMatrix;
import mesh_gpu : FacePass, buildReverseFaceIndices;
import ui.viewport_render : facePassFor;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The upload's normal as it was written inline before the extraction, kept
// verbatim so the equality below is a statement about the bytes.
private void legacyNormal(Vec3 v0, Vec3 v1, Vec3 v2,
                          out float nx, out float ny, out float nz)
{
    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
    float cx = ay*bz - az*by;
    float cy = az*bx - ax*bz;
    float cz = ax*by - ay*bx;
    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
    if (nlen > 1e-6f) { float inv = 1.0f/nlen; nx=cx*inv; ny=cy*inv; nz=cz*inv; }
    else              { nx=0; ny=1; nz=0; }
}

unittest // faceNormalFirst3 is the upload's normal, bit for bit
{
    immutable Vec3[3][] tris = [
        [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],                 // +Z
        [Vec3(0.3f, -1.7f, 2.1f), Vec3(1.13f, 0.21f, -0.4f),
         Vec3(-0.77f, 0.9f, 0.05f)],                                     // oblique
        [Vec3(1e-2f, 2e-2f, 0), Vec3(3e-2f, 1e-2f, 5e-3f),
         Vec3(-2e-2f, 7e-2f, 1e-2f)],                                    // small, not degenerate
        [Vec3(0, 0, 0), Vec3(1, 1, 1), Vec3(2, 2, 2)],                   // collinear
    ];
    int compared = 0, degenerates = 0;
    foreach (t; tris) {
        bool deg;
        immutable Vec3 n = faceNormalFirst3(t[0], t[1], t[2], deg);
        float nx, ny, nz;
        legacyNormal(t[0], t[1], t[2], nx, ny, nz);
        assert(n.x is nx && n.y is ny && n.z is nz,
            format("faceNormalFirst3 %s differs from the upload's arithmetic (%s,%s,%s)",
                   n, nx, ny, nz));
        ++compared;
        if (deg) ++degenerates;
    }
    assert(compared == 4 && degenerates == 1,
        format("population: compared %s (4), degenerate %s (1)", compared, degenerates));
    // A deterministic spread of triangles: the three hand-picked ones above
    // can round alike under a different operation order; a few hundred cannot.
    uint seed = 12345;
    float rnd() {
        seed = seed * 1664525u + 1013904223u;
        return (seed >> 8) * (1.0f / (1 << 24)) * 4.0f - 2.0f;
    }
    int spread = 0;
    foreach (t; 0 .. 400) {
        immutable Vec3 a0 = Vec3(rnd(), rnd(), rnd()), a1 = Vec3(rnd(), rnd(), rnd()),
                       a2 = Vec3(rnd(), rnd(), rnd());
        bool dg;
        immutable Vec3 n = faceNormalFirst3(a0, a1, a2, dg);
        float nx, ny, nz;
        legacyNormal(a0, a1, a2, nx, ny, nz);
        assert(n.x is nx && n.y is ny && n.z is nz,
            format("triangle %s: faceNormalFirst3 %s, upload arithmetic (%s,%s,%s)",
                   t, n, nx, ny, nz));
        ++spread;
    }
    assert(spread == 400);
    bool deg;
    assert(faceNormalFirst3(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), deg) == Vec3(0, 0, 1)
        && !deg, "a +Z triangle must give (0,0,1), not degenerate");
    assert(faceNormalFirst3(Vec3(0, 0, 0), Vec3(1, 1, 1), Vec3(2, 2, 2), deg) == Vec3(0, 1, 0)
        && deg, "a collinear triangle falls back to (0,1,0) and says so");
}

unittest // the face VBO has ONE normal home: no inline copy survives in mesh_gpu.d
{
    const src = readText(buildPath(repoRoot, "source", "mesh_gpu.d"));
    immutable calls = src.count("faceNormalFirst3(");
    // None since the incremental refresh (task 9070): the flat stream reads
    // `vertex_normals.faceUnitNormal`, the one face-normal home, whose
    // per-face results the smooth stream shares.
    assert(calls == 0, format("mesh_gpu.d: expected no faceNormalFirst3 call "
        ~ "(the flat normal comes from vertex_normals.faceUnitNormal), got %s", calls));
    const vn = readText(buildPath(repoRoot, "source", "vertex_normals.d"));
    assert(vn.count("faceNormalFirst3(") == 1 && vn.count("Vec3 faceUnitNormal(") == 1,
        "vertex_normals.d: faceUnitNormal must be the one faceNormalFirst3 caller");
    assert(src.count("1e-6f") == 0 && src.count("nlen") == 0,
        "mesh_gpu.d: an inline face-normal copy is back; call math.faceNormalFirst3");
}

unittest // reverse polygon order: descending faces, fans intact, ranges exact
{
    // Four faces; face 1 is hidden (count 0, its start aliases face 2's).
    immutable int[] start = [0, 3, 3, 9];
    immutable int[] cnt   = [3, 0, 6, 3];
    uint[12] idx;
    buildReverseFaceIndices(start, cnt, idx[]);
    assert(idx == [9, 10, 11, 3, 4, 5, 6, 7, 8, 0, 1, 2],
        format("reverse index list %s", idx));
    // Each face's range [total - (s + c), total - s) holds exactly its own
    // vertices, in its own order — the formula drawFacesHighlighted uses.
    enum int total = 12;
    int checked = 0;
    foreach (fi; 0 .. start.length) {
        immutable int first = total - (start[fi] + cnt[fi]);
        foreach (k; 0 .. cnt[fi]) {
            assert(idx[first + k] == start[fi] + k,
                format("face %s corner %s at reverse slot %s reads %s", fi, k,
                       first + k, idx[first + k]));
            ++checked;
        }
    }
    assert(checked == total, format("population: %s of %s slots checked", checked, total));
}

unittest // FacePass's members, pinned (a new member is a decision at every reader)
{
    static assert([__traits(allMembers, FacePass)]
                  == ["cullBack", "alpha", "reverseOrder", "mirrored", "bySurface"],
        "FacePass members changed: facePassFor, previewFacePass, faceSidesFor and "
        ~ "begin/endFacePass must each decide the new one");
}

unittest // plan -> FacePass: mode off culls by surface; the mode and a mirror are read
{
    float[16] ident = identityMatrix;
    // `DrawPlan.init` (every non-scene user) is today's uncull'd pass exactly.
    DrawPlan bare;
    assert(facePassFor(bare, ident) == FacePass.init,
        format("DrawPlan.init must map to FacePass.init, got %s", facePassFor(bare, ident)));
    ViewportDisplay d;
    DrawPlan off = resolveDrawPlan(d, false);
    immutable FacePass fOff = facePassFor(off, ident);
    FacePass wantOff;
    wantOff.bySurface = true;
    assert(fOff == wantOff,
        format("mode off (Shaded) must be the surface-culled opaque forward pass, got %s", fOff));

    d.retopology = true;
    DrawPlan on = resolveDrawPlan(d, false);
    immutable FacePass fOn = facePassFor(on, ident);
    assert(fOn.cullBack && fOn.alpha == on.faceAlpha && fOn.alpha < 1.0f
        && fOn.reverseOrder && !fOn.mirrored && !fOn.bySurface,
        format("mode on: cull, alpha %s, reverse order, not mirrored; got %s",
               on.faceAlpha, fOn));

    ItemXform mirror;
    mirror.scl.x = -1;
    float[16] mm = mirror.composedMatrix();
    assert(facePassFor(on, mm).mirrored, "scl.x = -1 must flip the front face");
    ItemXform turned;
    turned.rot.y = 40;
    turned.scl = Vec3(2, 0.5f, 3);
    float[16] tm = turned.composedMatrix();
    assert(!facePassFor(on, tm).mirrored,
        "a rotation with positive scales is not a mirror");

    // The order is the plan's field, never inferred from the alpha: each
    // field moves its own FacePass member and only that one.
    DrawPlan orderOnly;
    orderOnly.reverseFaceOrder = true;
    immutable FacePass fOrder = facePassFor(orderOnly, ident);
    assert(fOrder.reverseOrder && fOrder.alpha == 1.0f && !fOrder.cullBack,
        format("reverseFaceOrder alone must reverse an opaque, unculled pass, got %s",
               fOrder));
    // Reachable plans set cull, order and depth-clear together, so each is
    // varied alone here: a mapping that derives one member from a sibling
    // field is green on every reachable plan and red only on these.
    DrawPlan cullOnly;
    cullOnly.cullBackFaces = true;
    immutable FacePass fCull = facePassFor(cullOnly, ident);
    assert(fCull.cullBack && !fCull.reverseOrder,
        format("a culling plan without reverseFaceOrder stays forward, got %s", fCull));
    // `clearDepthFirst` belongs to the item head (`beginItem`), not the face
    // pass: alone it leaves the face pass at today's default exactly.
    DrawPlan clearOnly;
    clearOnly.clearDepthFirst = true;
    immutable FacePass fClear = facePassFor(clearOnly, ident);
    assert(fClear == FacePass.init,
        format("clearDepthFirst alone must not move the face pass, got %s", fClear));
    DrawPlan alphaOnly;
    alphaOnly.faceAlpha = 0.5f;
    immutable FacePass fAlpha = facePassFor(alphaOnly, ident);
    assert(!fAlpha.reverseOrder && fAlpha.alpha == 0.5f,
        format("a translucent plan without reverseFaceOrder stays forward, got %s",
               fAlpha));
}

unittest // a face-layout build moves the layout generation, on the prepared path too
{
    import mesh : makeCube;
    import mesh_gpu : GpuMesh, GpuUploadOwner, PreparedGpuUploadToken,
                      ValidatedGpuUploadToken;
    GpuMesh gpu;
    gpu.faceLayoutGen = 3;
    auto owner = GpuUploadOwner.fakeForTest(&gpu);
    auto cube = makeCube();
    PreparedGpuUploadToken prepared;
    assert(owner.beginPreparedUpload(cube, null, null, null, prepared),
        "prepared upload refused");
    assert(gpu.faceLayoutGen == 3, "a PREPARED layout must not touch the live header");
    ValidatedGpuUploadToken validated;
    assert(owner.validatePreparedUpload(prepared, 7, 11, validated),
        "prepared upload validation refused");
    owner.installPreparedUpload(validated);
    assert(gpu.faceTriStart.length == cube.faces.length,
        "population: the install did not land the new layout");
    assert(gpu.faceLayoutGen == 4,
        format("the installed layout must carry a new generation (4), got %s",
               gpu.faceLayoutGen));
}

unittest // the face pass restores every GL state it sets (source census)
{
    // The picker saves the cull ENABLE only, and nothing else in the frame
    // resets the front face, the blend or the lit program's face alpha; a
    // missing restore after a mirrored or translucent pass leaks into every
    // later culled or lit draw. The pixels see the cull and the alpha leak;
    // this pins all four restores at their one site.
    import std.algorithm : canFind;
    import std.string : indexOf;
    const src = readText(buildPath(repoRoot, "source", "mesh_gpu.d"));
    immutable at = src.indexOf("private void endFacePass(");
    assert(at >= 0, "mesh_gpu.d: endFacePass not found");
    string bodyOf(string head) {
        immutable a = src.indexOf(head);
        assert(a >= 0, "mesh_gpu.d: " ~ head ~ " not found");
        immutable close = src[a .. $].indexOf("\n}\n");
        assert(close > 0, "mesh_gpu.d: " ~ head ~ " has no closing brace");
        return src[a .. a + close];
    }
    const body = bodyOf("private void endFacePass(");
    immutable string[4] restores = [
        "glFrontFace(GL_CCW);",
        "glUniform1f(shader.locFaceAlpha, 1.0f);", "glDisable(GL_BLEND);",
        "glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);"];
    int found = 0;
    foreach (r; restores) {
        assert(body.canFind(r), "endFacePass no longer restores: " ~ r);
        ++found;
    }
    assert(found == 4);
    // The front face is restored under the SAME condition it was set
    // (opponent S1d addendum 6): one predicate guards both.
    assert(bodyOf("private void beginFacePass(").canFind("if (faceWindingSet(pass))")
        && body.canFind("if (faceWindingSet(pass))"),
        "begin/endFacePass must set and restore the front face under faceWindingSet(pass)");
    // The per-side cull state (model M6) is restored after every culling side.
    const sideEnd = bodyOf("private void endFaceSide(");
    immutable string[3] sideRestores = [
        "glDisable(GL_CULL_FACE);", "glCullFace(GL_BACK);",
        "glUniform1i(shader.locBackSide, 0);"];
    int sideFound = 0;
    foreach (r; sideRestores) {
        assert(sideEnd.canFind(r), "endFaceSide no longer restores: " ~ r);
        ++sideFound;
    }
    assert(sideFound == 3);
    // Both face entry points go through both pairs.
    assert(src.count("beginFacePass(shader, pass);") == 2
        && src.count("endFacePass(shader, pass);") == 2,
        "drawFaces and drawFacesHighlighted must each bracket their pass");
    assert(src.count("beginFaceSide(shader, sides.side[k]);") == 2
        && src.count("endFaceSide(shader, sides.side[k]);") == 2,
        "drawFaces and drawFacesHighlighted must each bracket every side");
}
