// Module unittests for `tools.edit.tack`, moved verbatim out of source/tools/edit/tack.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.edit.tack_test;

import bindbc.opengl;
import bindbc.sdl;
import std.math : atan2, abs, PI;
import std.json : JSONValue;
import operator : VectorStack;
import tool;
import mesh;
import math;
import change_bus : MeshEditScope;
import params : Param;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import shader : Shader, LitShader, drawLitPreview;
import hover_state : g_hoveredFace;
import eventlog : queryMouse;
import document : primaryModelSpace;
import std.conv : to;
import tools.edit.tack;

// ---------------------------------------------------------------------------
// Module unittests — the dubtest-lane parity gate (task 0126 brief). Golden
// numbers are the hand-verified two-disjoint-cubes fixture from
// doc/tack_tool_plan.md's Phase-0 capture (source island = Box A, target =
// Box B's tilted top face); reproduced exactly (not re-derived) here.
// ---------------------------------------------------------------------------
unittest { // computeTackTransform: matches the captured R/t to ~1e-4
    Vec3 srcCentroid = Vec3(-2.0f, 0.5f, 0.075f);
    Vec3 srcNormal   = Vec3(0, 1, 0);
    Vec3 tgtNormal   = Vec3(0, 0.7808688276063116f, -0.624695024850322f);
    Vec3 clicked     = Vec3(2.9793753623962402f, 0.6579021662473679f, -0.30262226052582264f);

    auto xf = computeTackTransform(srcCentroid, srcNormal, tgtNormal, clicked);

    // Expected R (hand-verified against every known after-vertex, see brief):
    //   [[-1, 0,                 0                ],
    //    [ 0, 0.7808688096637183, -0.6246950477309746],
    //    [ 0, -0.6246950477309746, -0.7808688096637183]]
    // Stored column-major (m[row + col*4]) per math.d's convention.
    float[9] expectedR = [
        -1.0f, 0.0f, 0.0f,
        0.0f, 0.7808688096637183f, -0.6246950477309746f,
        0.0f, -0.6246950477309746f, -0.7808688096637183f,
    ];
    foreach (row; 0 .. 3) {
        foreach (col; 0 .. 3) {
            float got = xf.rotation[row + col * 4];
            float exp = expectedR[row * 3 + col];
            assert(abs(got - exp) < 1e-3f,
                "R[" ~ row.to!string ~ "][" ~ col.to!string ~ "]: expected "
                ~ exp.to!string ~ ", got " ~ got.to!string);
        }
    }

    // Expected t = (0.9793753623962402, 0.3143199104822213, 0.06829042545866845)
    Vec3 expT = Vec3(0.9793753623962402f, 0.3143199104822213f, 0.06829042545866845f);
    assert(abs(xf.translation.x - expT.x) < 1e-3f, "t.x: " ~ xf.translation.x.to!string);
    assert(abs(xf.translation.y - expT.y) < 1e-3f, "t.y: " ~ xf.translation.y.to!string);
    assert(abs(xf.translation.z - expT.z) < 1e-3f, "t.z: " ~ xf.translation.z.to!string);

    // Defining identity #1: R * srcCentroid + t == clickedPoint.
    Vec3 landed = transformPoint(xf.rotation, srcCentroid) + xf.translation;
    assert(abs(landed.x - clicked.x) < 1e-4f, "anchor identity x");
    assert(abs(landed.y - clicked.y) < 1e-4f, "anchor identity y");
    assert(abs(landed.z - clicked.z) < 1e-4f, "anchor identity z");

    // Defining identity #2: R * srcNormal == tgtNormal (co-facing, dot = 1).
    Vec3 rotatedNormal = transformPoint(xf.rotation, srcNormal);
    // transformPoint applies the affine matrix including its (zero)
    // translation column, so for a pure-rotation matrix this equals R*v.
    assert(abs(dot(normalize(rotatedNormal), normalize(tgtNormal)) - 1.0f) < 1e-3f,
        "source normal should rotate onto the target normal (co-facing)");
}

unittest { // applyTackTransform + full 8-vertex island: every AFTER position
           // matches the golden fixture (doc/tack_tool_plan.md capture).
    // Box A (source island, indices 0-7) — unit cube centered at (-2,0,0)
    // with local (-0.5,0.5,-0.5) nudged +Z by 0.30.
    Mesh m;
    m.vertices = [
        Vec3(-2.5f, -0.5f, -0.5f),  // 0
        Vec3(-2.5f, -0.5f,  0.5f),  // 1
        Vec3(-2.5f,  0.5f, -0.2f),  // 2  nudged corner
        Vec3(-2.5f,  0.5f,  0.5f),  // 3
        Vec3(-1.5f, -0.5f, -0.5f),  // 4
        Vec3(-1.5f, -0.5f,  0.5f),  // 5
        Vec3(-1.5f,  0.5f, -0.5f),  // 6
        Vec3(-1.5f,  0.5f,  0.5f),  // 7
        // Box B (target island, indices 8-15) — unit cube centered at
        // (3,0,0) with its local (y=0.5,z=0.5) top edge raised +Y by 0.8.
        Vec3(2.5f, -0.5f, -0.5f),   // 8
        Vec3(2.5f, -0.5f,  0.5f),   // 9
        Vec3(2.5f,  0.5f, -0.5f),   // 10
        Vec3(2.5f,  1.3f,  0.5f),   // 11 raised
        Vec3(3.5f, -0.5f, -0.5f),   // 12
        Vec3(3.5f, -0.5f,  0.5f),   // 13
        Vec3(3.5f,  0.5f, -0.5f),   // 14
        Vec3(3.5f,  1.3f,  0.5f),   // 15 raised
    ];
    // Faces per corner index = 4*xbit + 2*ybit + zbit (verified against
    // makeCube()'s winding convention — matches the given source/target
    // polygon loop orders exactly).
    m.addFace([0, 2, 6, 4]);    // Box A z=0 (-Z)
    m.addFace([1, 5, 7, 3]);    // Box A z=1 (+Z)
    m.addFace([0, 1, 3, 2]);    // Box A x=0 (-X)
    m.addFace([4, 6, 7, 5]);    // Box A x=1 (+X)
    m.addFace([2, 3, 7, 6]);    // Box A y=1 (+Y) -- SOURCE polygon
    m.addFace([0, 4, 5, 1]);    // Box A y=0 (-Y)
    m.addFace([8, 10, 14, 12]); // Box B z=0 (-Z)
    m.addFace([9, 13, 15, 11]); // Box B z=1 (+Z)
    m.addFace([8, 9, 11, 10]);  // Box B x=0 (-X)
    m.addFace([12, 14, 15, 13]);// Box B x=1 (+X)
    m.addFace([10, 11, 15, 14]);// Box B y=1 (+Y) -- TARGET polygon
    m.addFace([8, 12, 13, 9]);  // Box B y=0 (-Y)
    m.buildLoops();

    enum uint srcFaceIdx = 4;
    enum uint tgtFaceIdx = 10;

    // Sanity: face indices resolve to the documented centroid/normal.
    Vec3 srcCentroid = m.faceCentroid(srcFaceIdx);
    assert(abs(srcCentroid.x - (-2.0f))  < 1e-4f, "source centroid x");
    assert(abs(srcCentroid.y -   0.5f )  < 1e-4f, "source centroid y");
    assert(abs(srcCentroid.z -   0.075f) < 1e-3f, "source centroid z");

    Vec3 tgtCentroid = m.faceCentroid(tgtFaceIdx);
    assert(abs(tgtCentroid.x - 3.0f) < 1e-4f, "target centroid x");
    assert(abs(tgtCentroid.y - 0.9f) < 1e-4f, "target centroid y");
    assert(abs(tgtCentroid.z - 0.0f) < 1e-4f, "target centroid z");

    Vec3 clicked = Vec3(2.9793753623962402f, 0.6579021662473679f, -0.30262226052582264f);
    Vec3 srcNormal = m.faceNormal(srcFaceIdx);
    Vec3 tgtNormal = m.faceNormal(tgtFaceIdx);

    bool[] island = m.connectedComponentVertices(srcFaceIdx);
    size_t islandCount = 0;
    foreach (i, b; island) { if (b) { assert(i < 8, "island leaked into Box B"); ++islandCount; } }
    assert(islandCount == 8, "expected exactly Box A's 8 verts, got " ~ islandCount.to!string);

    auto xf = computeTackTransform(srcCentroid, srcNormal, tgtNormal, clicked);
    applyTackTransform(m, island, xf.rotation, xf.translation);

    // Golden AFTER positions for the 4 source-face verts (hand-verified).
    static struct Golden { uint idx; Vec3 pos; }
    Golden[4] goldenFace = [
        Golden(2, Vec3(3.4793753623962402f, 0.8296933174133301f, -0.0878833457827568f)),
        Golden(3, Vec3(3.4793753623962402f, 0.39240679144859314f, -0.634491503238678f)),
        Golden(7, Vec3(2.4793753623962402f, 0.39240679144859314f, -0.634491503238678f)),
        Golden(6, Vec3(2.4793753623962402f, 1.017101764678955f, 0.1463773101568222f)),
    ];
    foreach (g; goldenFace) {
        Vec3 got = m.vertices[g.idx];
        assert(abs(got.x - g.pos.x) < 1e-3f, "vert " ~ g.idx.to!string ~ " x: expected "
            ~ g.pos.x.to!string ~ " got " ~ got.x.to!string);
        assert(abs(got.y - g.pos.y) < 1e-3f, "vert " ~ g.idx.to!string ~ " y: expected "
            ~ g.pos.y.to!string ~ " got " ~ got.y.to!string);
        assert(abs(got.z - g.pos.z) < 1e-3f, "vert " ~ g.idx.to!string ~ " z: expected "
            ~ g.pos.z.to!string ~ " got " ~ got.z.to!string);
    }

    // Box B (target) is read-only — every one of its 8 verts is untouched.
    Vec3[8] boxBBefore = [
        Vec3(2.5f, -0.5f, -0.5f), Vec3(2.5f, -0.5f, 0.5f),
        Vec3(2.5f,  0.5f, -0.5f), Vec3(2.5f,  1.3f, 0.5f),
        Vec3(3.5f, -0.5f, -0.5f), Vec3(3.5f, -0.5f, 0.5f),
        Vec3(3.5f,  0.5f, -0.5f), Vec3(3.5f,  1.3f, 0.5f),
    ];
    foreach (i; 0 .. 8) {
        Vec3 got = m.vertices[8 + i];
        Vec3 exp = boxBBefore[i];
        assert(abs(got.x - exp.x) < 1e-6f && abs(got.y - exp.y) < 1e-6f && abs(got.z - exp.z) < 1e-6f,
            "target island must stay untouched: vert " ~ (8 + i).to!string);
    }
}

unittest { // rebuildTackPreview is NON-CUMULATIVE — 5 repeat calls land on
           // the identical vertex positions (no drift/accumulation).
    Mesh m;
    m.vertices = [
        Vec3(-2.5f, -0.5f, -0.5f), Vec3(-2.5f, -0.5f,  0.5f),
        Vec3(-2.5f,  0.5f, -0.2f), Vec3(-2.5f,  0.5f,  0.5f),
        Vec3(-1.5f, -0.5f, -0.5f), Vec3(-1.5f, -0.5f,  0.5f),
        Vec3(-1.5f,  0.5f, -0.5f), Vec3(-1.5f,  0.5f,  0.5f),
        Vec3(2.5f, -0.5f, -0.5f), Vec3(2.5f, -0.5f,  0.5f),
        Vec3(2.5f,  0.5f, -0.5f), Vec3(2.5f,  1.3f,  0.5f),
        Vec3(3.5f, -0.5f, -0.5f), Vec3(3.5f, -0.5f,  0.5f),
        Vec3(3.5f,  0.5f, -0.5f), Vec3(3.5f,  1.3f,  0.5f),
    ];
    m.addFace([0, 2, 6, 4]);
    m.addFace([1, 5, 7, 3]);
    m.addFace([0, 1, 3, 2]);
    m.addFace([4, 6, 7, 5]);
    m.addFace([2, 3, 7, 6]);
    m.addFace([0, 4, 5, 1]);
    m.addFace([8, 10, 14, 12]);
    m.addFace([9, 13, 15, 11]);
    m.addFace([8, 9, 11, 10]);
    m.addFace([12, 14, 15, 13]);
    m.addFace([10, 11, 15, 14]);
    m.addFace([8, 12, 13, 9]);
    m.buildLoops();

    enum uint srcFaceIdx = 4;
    enum uint tgtFaceIdx = 10;
    Vec3 clicked = Vec3(2.9793753623962402f, 0.6579021662473679f, -0.30262226052582264f);
    Vec3 tgtNormal = m.faceNormal(tgtFaceIdx);
    bool[] island = m.connectedComponentVertices(srcFaceIdx);

    MeshSnapshot baseSnap = MeshSnapshot.capture(m);
    Mesh previewMesh;
    Vec3[] expected;
    foreach (i; 0 .. 5) {
        rebuildTackPreview(baseSnap, previewMesh, island, srcFaceIdx, tgtNormal, clicked);
        assert(previewMesh.vertices.length == 16,
            "preview must not grow/shrink vertex count on repeat #" ~ i.to!string);
        if (i == 0) {
            expected = previewMesh.vertices.dup;
        } else {
            foreach (vi; 0 .. 16) {
                Vec3 e = expected[vi];
                Vec3 got = previewMesh.vertices[vi];
                assert(abs(got.x - e.x) < 1e-5f && abs(got.y - e.y) < 1e-5f && abs(got.z - e.z) < 1e-5f,
                    "preview drifted on repeat #" ~ i.to!string ~ " vert " ~ vi.to!string);
            }
        }
    }
}
