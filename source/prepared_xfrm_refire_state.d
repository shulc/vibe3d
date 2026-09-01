module prepared_xfrm_refire_state;

import math : Vec3;
import toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;

/// Detached wrapper-private half of an idle Rotate/Scale pipe refire. History
/// owns the prepared command separately; this image owns only the exact scalar
/// and packet state that `recordPipeRefire` changes after enlisting it.
struct PreparedXfrmRefireStateImage {
    Vec3[] expectedAnchor, nextAnchor;
    bool expectedPreValid, nextPreValid;
    FalloffPacket expectedPreFalloff, nextPreFalloff;
    SnapPacket expectedPreSnap, nextPreSnap;
    SymmetryPacket expectedPreSymmetry, nextPreSymmetry;
    ulong expectedLastMutation, nextLastMutation;
    ulong expectedGestureMutation, nextGestureMutation;
    ulong expectedUndoEpoch, nextUndoEpoch;
    bool valid;
    void clear() nothrow @nogc { this = PreparedXfrmRefireStateImage.init; }
}
