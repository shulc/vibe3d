// Module unittests for `tools.alignment.mirror`, moved verbatim out of source/tools/alignment/mirror.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.alignment.mirror_test;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import std.math : PI;
import tool;
import mesh;
import math;
import params : Param, IntEnumEntry;
import command : Command, CmdFlags;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import editmode : EditMode;
import shader : Shader, LitShader, drawLitPreview;
import handler : MoveHandler, ToolHandles, Arrow, BoxHandler, gizmoSize, drawThickLinesExt;
import drag : planeDragDelta, screenAxisDelta, gesturePrevPixel;
import eventlog : queryMouse;
import std.conv : to;
import tools.alignment.mirror;

// ---------------------------------------------------------------------------
// Module unittest (fold #2, riskiest item §8.1 of the impl plan) — proves
// rebuildMirrorPreview is NON-CUMULATIVE: 5 successive calls against the same
// baseSnap/baseMask/params_ must all land on the SAME face/vertex count, not
// grow by 6 faces / 8 verts each time. CPU-only (plain Mesh, no GpuMesh/GL),
// so this runs in the dubtest lane without a GL context. A committed-count
// test (tests/test_mirror_tool.d) cannot exercise this directly, since
// deactivate() only ever calls mirrorFaces ONCE by construction — this is
// the only test that would catch a "preview recomputes on top of itself"
// regression.
// ---------------------------------------------------------------------------
unittest {
    Mesh cube = makeCube();               // 8 verts, 6 faces
    MeshSnapshot baseSnap = MeshSnapshot.capture(cube);
    bool[] baseMask = new bool[](cube.faces.length);
    baseMask[] = true;                    // whole-mesh mirror

    MirrorParams params_;
    params_.axis       = 0;               // X
    params_.center     = Vec3(1, 0, 0);
    params_.mergeVerts = false;           // weld = 0 -> no dedup
    params_.invertPolys = true;

    Mesh previewMesh;
    size_t expectedVerts = size_t.max, expectedFaces = size_t.max;
    foreach (i; 0 .. 5) {
        rebuildMirrorPreview(baseSnap, previewMesh, baseMask, params_);
        if (i == 0) {
            expectedVerts = previewMesh.vertices.length;
            expectedFaces = previewMesh.faces.length;
            assert(expectedVerts == 16, "expected 16 verts after one mirror, got "
                ~ expectedVerts.to!string);
            assert(expectedFaces == 12, "expected 12 faces after one mirror, got "
                ~ expectedFaces.to!string);
        } else {
            assert(previewMesh.vertices.length == expectedVerts,
                "preview accumulated verts on repeat #" ~ i.to!string ~ ": expected "
                ~ expectedVerts.to!string ~ ", got " ~ previewMesh.vertices.length.to!string);
            assert(previewMesh.faces.length == expectedFaces,
                "preview accumulated faces on repeat #" ~ i.to!string ~ ": expected "
                ~ expectedFaces.to!string ~ ", got " ~ previewMesh.faces.length.to!string);
        }
    }
}

// ---------------------------------------------------------------------------
// TILTED-plane non-cumulative preview (task 0230 M2 §5) — the same 5×-repeat
// proof as above, but with a genuinely non-axis-aligned normal (angle=45 off
// the X axis) to prove the oriented-plane preview path (rebuildMirrorPreview
// -> mirrorFacesPlane -> toolNormal) is non-cumulative too, not just the
// axis-aligned v1 path exercised above.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    Mesh cube = makeCube();               // 8 verts, 6 faces
    MeshSnapshot baseSnap = MeshSnapshot.capture(cube);
    bool[] baseMask = new bool[](cube.faces.length);
    baseMask[] = true;                    // whole-mesh mirror

    MirrorParams params_;
    params_.axis        = 0;              // base X ...
    params_.angle       = 45.0f;          // ... tilted 45 degrees off-axis
    params_.center      = Vec3(1, 0, 0);
    params_.mergeVerts  = false;          // weld = 0 -> no dedup
    params_.invertPolys = true;

    // Sanity: this really is a non-axis-aligned normal (not incidentally
    // reducing to +-X/+-Y/+-Z), so the test exercises the oriented path.
    Vec3 n = toolNormal(params_);
    assert(n.x > 0.01f && n.y > 0.01f && abs(n.z) < 1e-4f,
        "test setup: expected a tilted-in-XY normal, got " ~ n.to!string);

    Mesh previewMesh;
    size_t expectedVerts = size_t.max, expectedFaces = size_t.max;
    foreach (i; 0 .. 5) {
        rebuildMirrorPreview(baseSnap, previewMesh, baseMask, params_);
        if (i == 0) {
            expectedVerts = previewMesh.vertices.length;
            expectedFaces = previewMesh.faces.length;
            assert(expectedVerts == 16, "tilted preview: expected 16 verts, got "
                ~ expectedVerts.to!string);
            assert(expectedFaces == 12, "tilted preview: expected 12 faces, got "
                ~ expectedFaces.to!string);
        } else {
            assert(previewMesh.vertices.length == expectedVerts,
                "tilted preview accumulated verts on repeat #" ~ i.to!string
                ~ ": expected " ~ expectedVerts.to!string ~ ", got "
                ~ previewMesh.vertices.length.to!string);
            assert(previewMesh.faces.length == expectedFaces,
                "tilted preview accumulated faces on repeat #" ~ i.to!string
                ~ ": expected " ~ expectedFaces.to!string ~ ", got "
                ~ previewMesh.faces.length.to!string);
        }
    }
}
