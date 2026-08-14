// Module unittests for `toolpipe.stages.axis`, moved verbatim out of source/toolpipe/stages/axis.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.axis_test;

import std.format : format;
import std.math   : abs, sqrt;
import math    : Vec3, Viewport, cross, dot, normalize, frameMatrix, frameMatrixInverse,
                 applyAffine, ModelSpace;
import mesh    : Mesh;
import editmode : EditMode;
import seltype : SelType;
import toolpipe.stage    : Stage, TaskCode, ordAxis;
import toolpipe.packets  : AxisPacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import popup_state       : setStatePath;
import document          : Layer;
import params            : IntEnumEntry, wireTagForValue, valueForWireTag,
                           tableCoversEnumOf;
import std.math : isClose, sin, cos, PI;
import math : matMul4, applyAffine, identityMatrix;
import operator : VectorStack;
import toolpipe.packets : SubjectPacket, AxisPacket;
import toolpipe.stages.axis;

unittest {
    // Non-trivial right-handed orthonormal frame: 30° about +Y.
    immutable float a = cast(float) PI / 6;
    immutable float c = cos(a), s = sin(a);
    Vec3 r = Vec3(c, 0, -s);
    Vec3 u = Vec3(0, 1, 0);
    Vec3 f = Vec3(s, 0,  c);

    auto st = new AxisStage();          // no mesh/editmode needed for Manual
    st.mode        = AxisStage.Mode.Manual;
    st.manualRight = r;
    st.manualUp    = u;
    st.manualFwd   = f;

    SubjectPacket subj;                 // viewport unused by Manual mode
    VectorStack vts;
    vts.put(&subj);
    assert(st.evaluate(vts));

    AxisPacket* pkt = vts.get!AxisPacket();
    assert(pkt !is null);

    enum float tol = 1e-5f;

    // Sanity: published basis is the non-trivial frame we set.
    assert(isClose(pkt.fwd.x, s, tol, tol) && !isClose(pkt.fwd.z, 1.0f, tol, tol));

    // 1) m's basis columns equal right/up/fwd (column-major, m[row + col*4]:
    //    column 0 = m[0..2], column 1 = m[4..6], column 2 = m[8..10]).
    assert(isClose(pkt.m[0], pkt.right.x, tol, tol));
    assert(isClose(pkt.m[1], pkt.right.y, tol, tol));
    assert(isClose(pkt.m[2], pkt.right.z, tol, tol));
    assert(isClose(pkt.m[4], pkt.up.x,    tol, tol));
    assert(isClose(pkt.m[5], pkt.up.y,    tol, tol));
    assert(isClose(pkt.m[6], pkt.up.z,    tol, tol));
    assert(isClose(pkt.m[8],  pkt.fwd.x,  tol, tol));
    assert(isClose(pkt.m[9],  pkt.fwd.y,  tol, tol));
    assert(isClose(pkt.m[10], pkt.fwd.z,  tol, tol));

    // 2) m * mInv ≈ identity (via the project's matMul4).
    auto prod = matMul4(pkt.m, pkt.mInv);
    foreach (i; 0 .. 16)
        assert(isClose(prod[i], identityMatrix[i], tol, tol));

    // 3) applyAffine(m, unit-x) == right — confirms the multiply convention
    //    is NOT transposed (a transposed m would yield mInv·x = a row, not right).
    auto mx = applyAffine(pkt.m, Vec3(1, 0, 0));
    assert(isClose(mx.x, pkt.right.x, tol, tol));
    assert(isClose(mx.y, pkt.right.y, tol, tol));
    assert(isClose(mx.z, pkt.right.z, tol, tol));
}

// ---------------------------------------------------------------------------
// Item mode 0614, Phase 2 — the AXIS "non-change" pin
// (doc/item_mode_transform_plan.md §Q3 / §(a)). L3 OVERTURNED the plan's
// original design: there is no item-basis redirect here at all — the
// measured default (Mode.None, world identity, Phase 0 case A′) already
// matches the capture with zero code, and adding a redirect would have
// INTRODUCED a divergence from behaviour vibe3d already had right. This
// test exists solely to guard that fact: "we changed nothing and it is
// already right" is only true until someone adds the redirect back.
// ---------------------------------------------------------------------------
unittest {
    import document : Layer;
    import seltype  : SelType;

    bool vecEq(Vec3 a, Vec3 b) {
        return isClose(a.x, b.x, 1e-6f, 1e-6f) && isClose(a.y, b.y, 1e-6f, 1e-6f)
            && isClose(a.z, b.z, 1e-6f, 1e-6f);
    }

    // The exact rig Phase 0 case A′ measured: item rotated 45° about world Y.
    auto itemLayer = new Layer();
    itemLayer.xform.rot = Vec3(0, 45, 0);
    Layer itemRef = itemLayer;

    // `currentSel` + the `() => currentSel` ctor delegate stand in for the
    // LIVE external selType source app.d wires (review Blocker 2 —
    // computeBasis() no longer reads a field cached from evaluate()).
    SelType currentSel = SelType.Vertex;
    auto st = new AxisStage(null, null, () => itemRef, () => currentSel);
    st.mode = AxisStage.Mode.None;   // the stage's own default (axis.d:166ish)

    Vec3 r, u, f;

    currentSel = SelType.Vertex;
    st.currentBasis(r, u, f);
    assert(vecEq(r, Vec3(1, 0, 0)) && vecEq(u, Vec3(0, 1, 0)) && vecEq(f, Vec3(0, 0, 1)),
        "Vertex subject, default mode: world identity (unchanged baseline)");

    currentSel = SelType.Item;
    st.currentBasis(r, u, f);
    assert(vecEq(r, Vec3(1, 0, 0)) && vecEq(u, Vec3(0, 1, 0)) && vecEq(f, Vec3(0, 0, 1)),
        "Item subject, default mode, ROTATED item: basis must STILL read "
        ~ "world identity — an item-basis redirect (r ≈ (0.707,0,-0.707)) "
        ~ "would be the overturned design (L3, phase0_findings.md case A′)");

    // Companion: Mode.Pivot IS the explicit route to the item's own basis,
    // and it stays reachable — the item's rotated frame shows up there,
    // proving L3 removed a DEFAULT, not a CAPABILITY.
    st.mode = AxisStage.Mode.Pivot;
    st.currentBasis(r, u, f);
    assert(!vecEq(r, Vec3(1, 0, 0)),
        "Mode.Pivot must still reflect the item's own (rotated) basis — "
        ~ "L3 only removed the DEFAULT redirect, not this explicit mode");
}

// ---------------------------------------------------------------------------
// Item mode 0614, Phase 2 — the Select/Local/Element guard
// (doc/item_mode_transform_plan.md §Q3 / §(a) step 2, R6-adjacent). A
// vertex/edge/face selection that survives a mode switch (EditMode persists
// under SelType.Item, seltype.d) must not orient the item gizmo. In item
// mode these three modes must fall onto their existing Auto fallback
// WITHOUT consulting the mesh selection at all, and axisTracksSelection()
// must report false so a flex-gizmo consumer does not believe a
// world-fixed item frame co-rotates with the gesture.
//
// Should-fix 1 (0614 review): `axisTracksSelection()` had ZERO production
// callers — the real consumer (xfrm_transform.d's renderBasis) reads
// `AxisPacket.tracksSelection` off the VectorStack, which it cannot reach
// without driving a real `evaluate()`. The second half of this test does
// exactly that, so the assertions pin the path production actually runs,
// not just the instance-method mirror of it.
// ---------------------------------------------------------------------------
unittest {
    import mesh     : makeCube;
    import seltype  : SelType;
    import std.conv : to;

    bool vecEq(Vec3 a, Vec3 b) {
        return isClose(a.x, b.x, 1e-6f, 1e-6f) && isClose(a.y, b.y, 1e-6f, 1e-6f)
            && isClose(a.z, b.z, 1e-6f, 1e-6f);
    }

    // A real, non-trivial face selection — if the guard failed to skip it,
    // computeSelectionBboxBasis would install a NON-identity basis here.
    Mesh cube = makeCube();
    cube.resetSelection();
    cube.selectFace(4);   // +Y face
    Mesh* meshPtr = &cube;
    EditMode em = EditMode.Polygons;

    SelType currentSel = SelType.Vertex;
    auto st = new AxisStage(() => meshPtr, &em, null, () => currentSel);

    foreach (m; [AxisStage.Mode.Select, AxisStage.Mode.Local, AxisStage.Mode.Element]) {
        st.mode = m;

        currentSel = SelType.Vertex;
        Vec3 r, u, f;
        st.currentBasis(r, u, f);
        assert(!vecEq(r, Vec3(1, 0, 0)) || !vecEq(u, Vec3(0, 1, 0)) || !vecEq(f, Vec3(0, 0, 1)),
            m.to!string ~ ": with a real selection and a Vertex subject, the "
            ~ "selection basis must be read (non-identity) — sanity check "
            ~ "that the rig actually discriminates");

        currentSel = SelType.Item;
        st.currentBasis(r, u, f);
        assert(vecEq(r, Vec3(1, 0, 0)) && vecEq(u, Vec3(0, 1, 0)) && vecEq(f, Vec3(0, 0, 1)),
            m.to!string ~ ": Item subject must skip the stale selection "
            ~ "entirely and fall onto the Auto (world) fallback");

        assert(!st.axisTracksSelection(),
            m.to!string ~ ": axisTracksSelection() must report false in item "
            ~ "mode — under the guard this mode no longer delivers a "
            ~ "selection-derived basis");
    }

    // Cross-check: the SAME modes with a Vertex subject still track.
    currentSel = SelType.Vertex;
    foreach (m; [AxisStage.Mode.Select, AxisStage.Mode.Local]) {
        st.mode = m;
        assert(st.axisTracksSelection(),
            m.to!string ~ ": Vertex subject must keep tracking the selection "
            ~ "(the guard is item-mode-only, `axisTracksSelection`'s own R6 gate "
            ~ "in this file is unaffected)");
    }

    // The REAL production path: drive evaluate() with an explicit
    // SubjectPacket (no reliance on the live `currentSel` source — this is
    // exactly how xfrm_transform.d's renderBasis reaches the value, via
    // `vts.get!AxisPacket().tracksSelection`) and check the published
    // packet field for Select (tracks) and its item-mode guard (does not).
    import operator         : VectorStack;
    import toolpipe.packets : SubjectPacket, AxisPacket;
    st.mode = AxisStage.Mode.Select;

    SubjectPacket subjVertex;
    subjVertex.mesh     = meshPtr;
    subjVertex.editMode = em;
    subjVertex.selType  = SelType.Vertex;
    VectorStack vtsVertex;
    vtsVertex.put(&subjVertex);
    assert(st.evaluate(vtsVertex), "evaluate() must succeed (Vertex subject)");
    auto pktVertex = vtsVertex.get!AxisPacket();
    assert(pktVertex !is null);
    assert(pktVertex.tracksSelection,
        "AxisPacket.tracksSelection must be true for Select+Vertex — the "
        ~ "exact field xfrm_transform.d's renderBasis reads");

    SubjectPacket subjItem;
    subjItem.mesh     = meshPtr;
    subjItem.editMode = em;
    subjItem.selType  = SelType.Item;
    VectorStack vtsItem;
    vtsItem.put(&subjItem);
    assert(st.evaluate(vtsItem), "evaluate() must succeed (Item subject)");
    auto pktItem = vtsItem.get!AxisPacket();
    assert(pktItem !is null);
    assert(!pktItem.tracksSelection,
        "AxisPacket.tracksSelection must be false for Select+Item — `type` "
        ~ "still reports Select (mode name unchanged) but the basis this "
        ~ "same evaluate() call published is the Auto/world fallback, so a "
        ~ "consumer keyed off `type` alone would wrongly believe it "
        ~ "co-rotates with the gesture");
}

// task 0678 P4 — knownAttrs must mirror applySetAttr's switch: every listed
// name is settable with a canonical sample value.  Before the fix this stage
// had NO attr universe at all (no params/fullParams/knownAttrs), so the
// forms-engine startup-strict validator (forms.d) would throw for the first
// form bound to "axis".
unittest {
    import toolpipe.stage : assertRejectsUndeclaredAttrs;
    auto st = new AxisStage();
    auto names = st.knownAttrs();
    assert(names.length > 0, "axis knownAttrs must not be empty");
    string[string] sample = ["mode": "auto"];
    foreach (n; names) {
        assert((n in sample) !is null,
               "no sample value for axis attr '" ~ n ~ "' — extend the test");
        assert(st.setAttr(n, sample[n]),
               "axis knownAttrs name '" ~ n ~ "' rejected by setAttr");
    }

    // task 0685 T1 — and the COMPLEMENT: the mirror must not be one-way.
    // The loop above proves `knownAttrs ⊆ accepted`; the defect 0678 P4 fixed
    // was the other inclusion (a `case` with no declaration), which every
    // assertion above stays green through. See `assertRejectsUndeclaredAttrs`.
    assertRejectsUndeclaredAttrs(new AxisStage(), "axis");
}
