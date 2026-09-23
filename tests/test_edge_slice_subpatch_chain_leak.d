// test_edge_slice_subpatch_chain_leak.d — task 7111 (S1-R), the MECHANISM
// witness for the slice-tool live-edit leak (items 21 and 23; mutation M1).
//
// Edge Slice keeps its standing preview only while its armed-mesh key still
// matches. With a live subpatch preview the cage upload publishes a Position
// change every refresh frame, which advances the counter that key is built on;
// the next drag motion then sees a "different" mesh and drops the chain
// without restoring the mesh or recording anything. The discriminating cell is
// the SAME real-input scenario with subpatch OFF (block A, must stay green)
// and ON (block B): only B can lose the chain.
//
// Input is real SDL events through /api/play-events, split per segment: "click
// k" = hover + LMB down, "drag k" = held motions + LMB up, the state read after
// each. The chain is read through the tool's `latchedPairs` (the stored vertex
// pair of every latched point, in chain order); pair orientation is not
// significant, order is. Pixels are found by hover, separately per block, and
// each click is sent only at a pixel that resolved the named edge.
//
// Rig and prologue: tests/slice_leak_helpers.d.

import slice_leak_helpers;
import std.format : format;
import std.stdio : writeln;

void main() {}

enum int[2][3] HINT_OFF = [[315, 303], [531, 355], [616, 270]];
enum int[2][3] HINT_ON  = [[323, 302], [507, 326], [606, 271]];

void chainBlock(bool subpatchOn) {
    const tag = subpatchOn ? "ON" : "OFF";
    auto pro = slPrologue(subpatchOn, "polygons", &slBackAndLeft, true);
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);

    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "slice floor: Edge Slice did not activate");
    const recordedHistoryLen = slHistoryLen();
    assert(recordedHistoryLen == pro.historyLen,
           "slice floor: activating the tool moved the history");

    const P = slFrontRightChain();
    const hints = subpatchOn ? HINT_ON : HINT_OFF;
    foreach (k; 0 .. 3) {
        const px = slEdgePixel(P[k][0], P[k][1], hints[k],
                               format("point %d (subpatch %s)", k + 1, tag));
        slClickDown(px[0], px[1], format("click %d", k + 1));
        const want = slNorm(P[0 .. k + 1]);
        auto c = slChain();
        assert(slNorm(c.pairs) == want,
               format("slice chain input: after click %d expected %s got %s (subpatch %s)",
                      k + 1, slPairsStr(want), slPairsStr(slNorm(c.pairs)), tag));
        if (k >= 1)
            assert(c.phase == "edgeB",
                   format("slice chain input: after click %d phase %s, expected edgeB (subpatch %s)",
                          k + 1, c.phase, tag));
        slDragUp(px[0], px[1], 0, 4, 3, format("drag %d", k + 1));
        c = slChain();
        assert(slNorm(c.pairs) == want,
               format("slice chain input: after drag %d expected %s got %s (subpatch %s)",
                      k + 1, slPairsStr(want), slPairsStr(slNorm(c.pairs)), tag));
        if (k >= 1)
            assert(c.phase == "edgeB",
                   format("slice chain input: after drag %d phase %s, expected edgeB (subpatch %s)",
                          k + 1, c.phase, tag));
    }

    const cut = slMesh();
    assert(cut.faces > 4, "slice floor: no cut on the mesh before cancel: " ~ cut.toString);
    writeln("subpatch ", tag, ": chain of 3 points stands, mesh ", cut);

    slRmb(475, 300);   // RMB -> cancelLiveEdit
    const after = slMesh();
    assert(after.verts == 8 && after.faces == 4 && after.canon == base.canon
           && slHistoryLen() == recordedHistoryLen,
           format("slice leak: RMB did not restore the recorded mesh (subpatch %s): "
                  ~ "mesh %s, history %d, recorded %d",
                  tag, after.toString, slHistoryLen(), recordedHistoryLen));
    slLine("tool.set mesh.edgeSliceTool off");
}

// Block A — subpatch OFF. Green on R and on F; red here means the mechanism
// is wrong or not the only one (the slice's split rule).
unittest {
    chainBlock(false);
}

// Block B — subpatch ON. Predicted red on HEAD after the FIRST drag of point
// 2: "slice chain input: after drag 2 expected [P1,P2] got []".
unittest {
    chainBlock(true);
}
