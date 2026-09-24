// test_edge_slice_third_point_drag.d — item 22 witness: the third and later
// Edge Slice points slide with their own press-drag exactly like the second,
// a later drag never moves an earlier point, and an edge created by the
// chain's own cut is an accepted target (the point slides along it).
//
// Measured law (reference capture, the flat 4x4 grid): points on the edges
// through (0.5,0,0), (0.5,0,1), (0.5,0,2), each dragged the same pixel
// distance along its edge, end at 0.73 / 0.73 / 0.74 from 0.5; a third point
// pressed on the interior edge born of the 1-2 cut is accepted and slides
// (27 v / 17 f -> 28 v / 17 f). The reference's numbers are in ITS pixels, so
// the needle compares the third point against the first point's drag in the
// SAME run, not against the capture's values.
//
// Rig: tests/slice_grid_helpers.d (grid, top-down camera, real input).
// The same click+drag input is run on the polygonal grid and with subpatch
// ON; the born-edge block is last.
//
// Why a green run here is not the whole story: recorded input is held while
// a subpatch preview build is pending (`SubpatchPreview.scriptedInputHeld`),
// so play-events cannot land a click in the window where the edge picker's
// answer is stale. That window is reachable only by live input; see the task
// card for the live cell.

import slice_leak_helpers;
import slice_grid_helpers;
import http_client : getJson;
import std.format : format;
import std.math : abs;
import std.stdio : writeln;

void main() {}

enum int DRAG_STEP = 4, DRAG_STEPS = 3;   // 12 px along the edge

/// Press point k at the middle of the edge (0,0,z)-(1,0,z), then drag it
/// DRAG_STEPS x DRAG_STEP px along the edge's screen direction and release.
/// Returns the point's model position at the press.
double[3] pressAndDrag(size_t k, double z, long[2] pair, void delegate() afterPress) {
    const p = pixelOf(0.5, 0, z);
    hoverFloor(p, pair[0], pair[1], format("point %d", k + 1));
    slClickDown(p[0], p[1], format("press %d", k + 1));
    const atPress = latchedPositions();
    assert(atPress.length == k + 1,
           format("slice chain input: after press %d the chain has %d points", k + 1,
                  atPress.length));
    if (afterPress !is null) afterPress();
    const q = pixelOf(1.0, 0, z);
    const dx = q[0] - p[0], dy = q[1] - p[1];
    const len = abs(dx) + abs(dy);
    slDragUp(p[0], p[1], dx * DRAG_STEP / len, dy * DRAG_STEP / len, DRAG_STEPS,
             format("drag %d", k + 1));
    return atPress[k];
}

void thirdPointBlock(bool subpatchOn) {
    const tag = subpatchOn ? "subpatch" : "polygon";
    gridRig(subpatchOn);
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "slice floor: Edge Slice did not activate");
    const double[3] zs = [0.0, 1.0, 2.0];
    long[2][] P;
    foreach (z; zs) P ~= gridPair(0, z, 1, z);

    double[3][] press;
    double[3][] afterDrag2;
    foreach (k; 0 .. 3) {
        void floor3() {
            // Input floor before drag 3: the three pairs, and the bake behind
            // them produced both segments.
            auto c = slChain();
            assert(slNorm(c.pairs) == slNorm(P),
                   format("slice chain input (%s): after press 3 expected %s got %s",
                          tag, slPairsStr(slNorm(P)), slPairsStr(slNorm(c.pairs))));
            assert(bakedSegments() == 2,
                   format("slice chain input (%s): after press 3 the bake produced %d "
                          ~ "segment(s), expected 2", tag, bakedSegments()));
        }
        press ~= pressAndDrag(k, zs[k], P[k], k == 2 ? &floor3 : null);
        if (k == 1) afterDrag2 = latchedPositions();
    }
    const fin = latchedPositions();
    assert(fin.length == 3, format("slice chain input (%s): %d points after drag 3", tag, fin.length));
    double[3] delta;
    foreach (k; 0 .. 3) delta[k] = dist3(fin[k], press[k]);
    writeln(format("%s: press %s -> after drags %s, deltas %.4f / %.4f / %.4f, mesh %s",
                   tag, p3s(press), p3s(fin), delta[0], delta[1], delta[2], slMesh()));
    // Control: the drag moves points 1 and 2 at all.
    assert(delta[0] > 0.05 && delta[1] > 0.05,
           format("slice drag control (%s): points 1/2 moved %.4f / %.4f", tag, delta[0], delta[1]));
    assert(abs(delta[2] - delta[0]) <= 0.02,
           format("third point did not follow drag (%s): %.4f vs %.4f", tag, delta[2], delta[0]));
    foreach (k; 0 .. 2)
        assert(dist3(fin[k], afterDrag2[k]) <= 1e-5,
               format("a later drag moved an earlier point (%s): point %d %s -> %s",
                      tag, k + 1, p3(afterDrag2[k]), p3(fin[k])));
    slLine("tool.set mesh.edgeSliceTool off");
}

// The `bakedSegments` field the floors above read: it follows the scripted
// arm's bake (the param door) and returns to 0 when Enter commits the chain.
unittest {
    gridRig(false);
    slLine("tool.set mesh.edgeSliceTool on");
    auto m = getJson("/api/model");
    long[] es;
    foreach (z; [0.0, 1.0, 2.0]) {
        const pr = gridPair(0, z, 1, z);
        es ~= slEdgeOf(m, pr[0], pr[1]);
    }
    slLine(format("tool.attr mesh.edgeSliceTool edges {%d,%d,%d}", es[0], es[1], es[2]));
    slLine("tool.attr mesh.edgeSliceTool chainArm {1}");
    assert(slChain().pairs.length == 3 && slMesh().verts == 28,
           "bakedSegments floor: the scripted arm did not cut a 3-point chain: " ~ slMesh().toString);
    assert(bakedSegments() == 2,
           format("bakedSegments does not follow the scripted arm's bake: %d", bakedSegments()));
    slKey(13, 0, "Enter");
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 0 && slMesh().verts == 28,
           "bakedSegments floor: Enter did not commit the chain and keep the tool");
    assert(bakedSegments() == 0,
           format("bakedSegments survived the commit: %d", bakedSegments()));
    slLine("tool.set mesh.edgeSliceTool off");
}

// The polygonal grid.
unittest {
    thirdPointBlock(false);
}

// Subpatch ON: same input.
unittest {
    thirdPointBlock(true);
}

// The edge born of the chain's own cut, below the two blocks above.
unittest {
    gridRig(false);
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "slice floor: Edge Slice did not activate");
    const P1 = gridPair(0, 0, 1, 0), P2 = gridPair(0, 1, 1, 1);
    pressAndDrag(0, 0.0, P1, null);
    pressAndDrag(1, 1.0, P2, null);
    const before = slMesh();
    assert(before.verts == 27 && before.faces == 17,
           "born-edge floor: two points did not cut 27v/17f: " ~ before.toString);
    // The chord: the edge between the two vertices the cut created.
    auto m = getJson("/api/model");
    const born = verticesFrom(GRID_VERTS);
    assert(born.length == 2, format("born-edge floor: %d born vertices", born.length));
    const chord = slEdgeOf(m, GRID_VERTS, GRID_VERTS + 1);
    assert(chord >= 0, "born-edge floor: no edge joins the two born vertices");
    const mid = pixelOf((born[0][0] + born[1][0]) / 2, 0, (born[0][2] + born[1][2]) / 2);
    hoverFloor(mid, GRID_VERTS, GRID_VERTS + 1, "the born chord");
    slClickDown(mid[0], mid[1], "press 3 on the born chord");
    const onPress = slMesh();
    const pts = latchedPositions();
    writeln("born chord: after the press ", onPress, " points ", p3s(pts));
    assert(pts.length == 3 && onPress.verts == 28 && onPress.faces == 17,
           format("born edge rejected as a target: %d point(s), mesh %s", pts.length,
                  onPress.toString));
    const q = pixelOf(born[1][0], 0, born[1][2]);
    const dx = q[0] - mid[0], dy = q[1] - mid[1];
    const len = abs(dx) + abs(dy);
    slDragUp(mid[0], mid[1], dx * DRAG_STEP / len, dy * DRAG_STEP / len, DRAG_STEPS,
             "drag 3 along the born chord");
    const fin = latchedPositions();
    // Distance from the chord (a segment in the y = 0 plane).
    const ax = born[0][0], az = born[0][2], bx = born[1][0], bz = born[1][2];
    const t = ((fin[2][0] - ax) * (bx - ax) + (fin[2][2] - az) * (bz - az))
            / ((bx - ax) * (bx - ax) + (bz - az) * (bz - az));
    const double[3] foot = [ax + (bx - ax) * t, 0, az + (bz - az) * t];
    const off = dist3(fin[2], foot), moved = dist3(fin[2], pts[2]);
    writeln(format("born chord: point 3 %s -> %s, %.6f off the chord, moved %.4f",
                   p3(pts[2]), p3(fin[2]), off, moved));
    assert(fin.length == 3 && off <= 1e-4 && moved > 0.05,
           format("point on a born edge did not slide: off the chord %.6f, moved %.4f",
                  off, moved));
    slLine("tool.set mesh.edgeSliceTool off");
}
