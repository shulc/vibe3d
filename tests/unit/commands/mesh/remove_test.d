// Module unittests for `commands.mesh.remove_`, moved verbatim out of source/commands/mesh/remove.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.commands.mesh.remove_test;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot, SelectionSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshEditScope,
                        captureSelectedEdgeEnds, restoreSelectedEdgeEnds,
                        undoTrackerEnabled;
import commands.mesh.delete_ : MeshDelete;
import math : Vec3;
import mesh : makeGridPlane;
import commands.mesh.remove_;

// task 0693 — undo of a remove/delete must bring the UV map BACK.
//
// Task 0689 closed the first half of the delta path's map behaviour: a replay
// that renumbers corners now DROPS the plane openly instead of leaving values
// on foreign corners. This is the second half, and it is the one the user
// feels: the KERNEL carries UV correctly on the way in (deleteFacesByMask runs
// the mechanism-(a) relocate), so before this fix the map survived the delete
// and then vanished on Ctrl+Z — a loss the snapshot path this replaced never
// had.
//
// Fixture keying: each corner's `u` NAMES the vertex it sits on (vertex index
// + 1), so a value restored onto the WRONG corner fails exactly as loudly as a
// value that vanished. An "is the map non-empty" assert would only catch the
// second.
unittest {
    import mesh : makeCube, kUvMapName, MapDomain;
    import std.math : abs;
    import std.conv : to;

    Mesh m = makeCube();
    m.buildLoops();
    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null);
    foreach (fi; 0 .. m.faces.length)
        foreach (k, vi; m.faces[fi]) {
            const size_t loop = m.faceCornerLoop(cast(uint) fi, cast(uint) k);
            uv.data[loop * 2]     = cast(float)(vi + 1);
            uv.data[loop * 2 + 1] = 0.5f;
        }
    const size_t cornersBefore = uv.data.length;

    m.syncSelection();   // grow the mark planes before touching them
    m.selectFace(0);
    View v = new View(0, 0, 800, 600);
    auto rm = new MeshRemove(&m, v, EditMode.Polygons);
    assert(rm.apply(), "mesh.remove must apply to a selected face");
    assert(m.faces.length == 5, "one face must be gone");

    assert(rm.revert(), "undo must succeed");
    assert(m.faces.length == 6, "undo must bring the face back");

    auto after = m.meshMap(kUvMapName);
    assert(after !is null, "undo must not delete the map itself");
    assert(after.data.length == cornersBefore,
           "undo must restore the map to its pre-op length");

    size_t zeros = 0;
    foreach (fi; 0 .. m.faces.length)
        foreach (k, vi; m.faces[fi]) {
            const size_t loop = m.faceCornerLoop(cast(uint) fi, cast(uint) k);
            const float got = after.data[loop * 2];
            if (got == 0.0f) ++zeros;
            assert(abs(got - cast(float)(vi + 1)) < 1e-6f,
                   "corner of face " ~ to!string(fi) ~ " sits on vertex "
                   ~ to!string(vi) ~ " so it must carry " ~ to!string(vi + 1)
                   ~ ", got " ~ to!string(got));
        }
    assert(zeros == 0, "no corner may come back zeroed");
}
