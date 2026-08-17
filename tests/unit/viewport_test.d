// Module unittests for `viewport`, moved verbatim out of source/viewport.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.viewport_test;

import view          : View, ProjKind, ViewPreset;
import viewcache     : VertexCache, FaceBoundsCache, EdgeCache;
import gpu_select    : GpuSelectBuffer;
import math          : Viewport, Vec3, Orientation;
import display_state : ViewportDisplay, DrawPlan, resolveDrawPlan, kBackdropDim;
import bindbc.opengl;
import std.conv : to;
import viewport;
import image_cache   : imagePixelCache;

unittest {
    // DirtyKey must discriminate on toolMat alone: two keys identical in
    // every other field but different toolMat must compare unequal, or an
    // inactive cell's dirty-key compare would silently ignore a live drag on
    // another cell (the exact freeze this field exists to fix).
    DirtyKey a, b;
    a.meshMutVer = 7; b.meshMutVer = 7;
    a.selEpoch   = 3; b.selEpoch   = 3;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.toolMat[12] = 1.5f; // e.g. a translate baked into the tool matrix
    assert(a != b, "keys differing only in toolMat must compare unequal");
}

unittest {
    // Task 0206 Phase 1: DirtyKey must also discriminate on the overlay
    // term alone — two keys identical in every other field (including
    // toolMat, at rest = identity/0) but differing only in overlayKind or
    // overlayCenter must compare unequal. This is the exact idle-freeze
    // this term exists to fix: a tool/falloff gizmo appearing or moving
    // with no live drag in progress (meshMutVer/selEpoch/toolMat all
    // unchanged).
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.overlayKind = 1; // tool gizmo activated
    assert(a != b, "keys differing only in overlayKind must compare unequal");

    b.overlayKind = 0;
    b.overlayCenter = [1.0f, 0.0f, 0.0f]; // gizmo pivot moved (no drag, e.g. panel edit)
    assert(a != b, "keys differing only in overlayCenter must compare unequal");

    b.overlayCenter = [0.0f, 0.0f, 0.0f];
    b.falloffCenter = [0.0f, 0.0f, 2.0f];
    assert(a != b, "keys differing only in falloffCenter must compare unequal");

    b.falloffCenter = [0.0f, 0.0f, 0.0f];
    b.falloffRadius = 3.0f;
    assert(a != b, "keys differing only in falloffRadius must compare unequal");
}

unittest {
    // Task 0647: the item-highlight term must discriminate ON ITS OWN. The
    // three hover fields stay at -1 for the whole of an item-mode hover (no
    // element is hovered) and `selEpoch` does not move when an ITEM is
    // selected, so without this the pointer crossing from one item to another
    // would change what is drawn and change no key.
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    a.hovV = -1;  b.hovV = -1;
    a.hovE = -1;  b.hovE = -1;
    a.hovF = -1;  b.hovF = -1;
    assert(a == b, "sanity: identical keys must compare equal");

    b.itemHighlightKey = 0x1234_5678_9abc_def0UL;
    assert(a != b,
        "keys differing only in itemHighlightKey must compare unequal — with "
        ~ "every element-hover field pinned at -1, which is what an item-mode "
        ~ "hover actually looks like");
}

unittest {
    // Task 0210: DirtyKey must also discriminate on gpuUploadVer alone —
    // two keys identical in every other field (including toolMat/overlay*
    // at rest) but differing only in gpuUploadVer must compare unequal.
    // This is the exact freeze this term exists to fix: a soft/falloff
    // drag re-uploads the shared VBO every frame without moving
    // meshMutVer, toolMat, or any overlay term.
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.gpuUploadVer = 1;
    assert(a != b, "keys differing only in gpuUploadVer must compare unequal");
}

unittest {
    // Task 0209: DirtyKey must also discriminate on overlayHot alone — two
    // keys identical in every other field (including toolMat/overlay*/
    // gpuUploadVer at rest) but differing only in overlayHot must compare
    // unequal. This is the exact stale-highlight freeze this term exists to
    // fix: the cursor rolls onto/off a handle in the hovered (owner) cell,
    // flipping the shared `hot` part with no drag/mesh/view change, and every
    // OTHER eligible cell must still notice and re-render to mirror it.
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.overlayHot = 3; // e.g. a move-arrow handle rolled over
    assert(a != b, "keys differing only in overlayHot must compare unequal");
}

unittest {
    // Task 0559: DirtyKey must discriminate on the DISPLAY term alone — two
    // keys identical in every other field (toolMat/overlay*/gpuUploadVer all
    // at rest) but differing only in the resolved draw plan must compare
    // unequal.
    //
    // This is the fifth instance of a bug this file has already shipped four
    // times, and the first one that is per-CELL: without the term, switching
    // a Quad/Split cell's display mode re-blits the cached colour texture and
    // the mode change appears to do nothing until that cell's camera moves.
    //
    // Note the mutated values below are all DIFFERENT from `DrawPlan`'s own
    // defaults. Writing a field's default value back is a no-op assignment and
    // the assertion that follows it proves nothing — which is how the first
    // draft of this block managed to fail, by "changing" the backdrop dim to
    // 1.0f when 1.0f is what an unresolved plan already holds.
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.planActive.drawFaces = false;   // e.g. switched to a lines-only style
    assert(a != b, "keys differing only in the active draw plan must compare unequal");

    b = a;
    b.planActive.drawWire = false;    // e.g. overlay switched off
    assert(a != b, "keys differing only in the active overlay must compare unequal");

    b = a;
    b.planBackdrop.dim = kBackdropDim;  // backdrop picked up its dim (0.45 != 1.0)
    assert(b.planBackdrop.dim != a.planBackdrop.dim,
        "sanity: the mutation must actually change the field");
    assert(a != b, "keys differing only in the BACKDROP plan must compare unequal");
}

unittest {
    // Task 0559, the per-cell half of the same trap. Every OTHER DirtyKey
    // term is stamped identically into all four cells; this one is not. Two
    // cells whose display state differs must therefore resolve to different
    // plans — if `resolveDrawPlan` ever collapsed distinct states onto one
    // plan, the key could not tell the cells apart and they would share a
    // cached texture no matter how carefully the stamping site was written.
    import display_state : ViewportDisplay, DisplayStyle, WireOverlay,
                           BackdropStyle;

    ViewportDisplay cell0;                                  // shipped default
    ViewportDisplay cell1; cell1.active.style = DisplayStyle.Wireframe;
    ViewportDisplay cell2; cell2.active.wire  = WireOverlay.None;
    ViewportDisplay cell3; cell3.backdropStyle = BackdropStyle.Hidden;

    DirtyKey k0, k1, k2, k3;
    foreach (i, d; [cell0, cell1, cell2, cell3]) {
        auto k = [&k0, &k1, &k2, &k3][i];
        k.planActive   = resolveDrawPlan(d, false);
        k.planBackdrop = resolveDrawPlan(d, true);
    }

    assert(k0 != k1, "a cell in a lines-only style must not alias the default cell");
    assert(k0 != k2, "a cell with the overlay off must not alias the default cell");
    assert(k0 != k3, "a cell hiding its backdrop must not alias the default cell");
    assert(k1 != k2, "two differently-configured cells must not alias each other");
}

unittest {
    // Task 0589 — THE CLAIM THIS BLOCK EXISTS TO CHECK, not to assume: the
    // unshaded fill needed NO new dirty-key term.
    //
    // That is the payoff of the design decision two blocks up (key = the
    // resolved plans, not an enumeration of display fields), and the brief for
    // this task said to verify it rather than take it on trust — every one of
    // the five freezes this file documents began as somebody being sure a term
    // was covered. So: a Solid cell and a Shaded cell differ in exactly one
    // `DrawPlan` field (`facesLit`), and the key must separate them anyway.
    //
    // If it did not, the symptom would be specific and nasty: switching a
    // non-hovered Quad cell to Solid would re-blit its cached colour texture
    // and the style change would appear to do nothing until that cell's camera
    // moved — the fill and the shaded surface share a silhouette, so it would
    // look like a viewport that simply ignores the command.
    import display_state : ViewportDisplay, DisplayStyle, DrawPlan,
                           resolveDrawPlan, SurfaceShading;

    // 1. The field alone discriminates.
    //
    // Task 1090 turned `facesLit` from storage into a derived accessor over a
    // three-valued `shading` field, so the mutation is written against the
    // storage. It is the same mutation: `Fill` is what `facesLit == false`
    // used to mean, and the accessor still reports it as such below.
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");
    b.planActive.shading = SurfaceShading.Fill;  // the default is Material
    assert(b.planActive.facesLit != a.planActive.facesLit,
        "sanity: the mutation must actually change the field");
    assert(a != b,
        "keys differing only in facesLit must compare unequal — an unshaded "
        ~ "fill is a render input like any other");

    // 2. And it is reached from the real resolution path, which is the half a
    //    hand-written field mutation cannot prove. Shaded vs Solid must resolve
    //    to plans that differ, and they must differ ONLY in facesLit — if a
    //    future edit made Solid also drop the wireframe or the face pass, this
    //    catches that too, at the resolution level rather than in pixels.
    ViewportDisplay shadedCell;                                  // shipped default
    ViewportDisplay solidCell;  solidCell.active.style = DisplayStyle.Solid;

    immutable DrawPlan ps = resolveDrawPlan(shadedCell, false);
    immutable DrawPlan pl = resolveDrawPlan(solidCell,  false);
    assert(ps != pl, "Solid must not resolve to the same plan as Shaded");
    assert(ps.facesLit && !pl.facesLit, "the difference must be the lighting term");
    assert(ps.drawFaces == pl.drawFaces && pl.drawFaces,
        "Solid still draws a filled surface — it is Shaded minus the shading, "
        ~ "not Wireframe with a different name");
    assert(ps.drawWire == pl.drawWire && ps.wireAlpha == pl.wireAlpha
        && ps.wireColor == pl.wireColor && ps.drawVerts == pl.drawVerts
        && ps.dim == pl.dim,
        "Solid must disturb nothing in the overlay group");

    DirtyKey ks, kl;
    ks.planActive = ps; ks.planBackdrop = resolveDrawPlan(shadedCell, true);
    kl.planActive = pl; kl.planBackdrop = resolveDrawPlan(solidCell,  true);
    assert(ks != kl,
        "a cell showing an unshaded fill must not alias a shaded cell — "
        ~ "no new key TERM was added for this style, so this is the assertion "
        ~ "that the plan-derived key really did cover it");
}

// T-D1 (task 0612) — the reference-image term discriminates on its own.
//
// Wrong implementation: no term added at all — the plane is not a `DrawPlan`
// field, so nothing else in this struct moves when a plane's channel,
// transform, link or texture changes. Reads: two EQUAL keys, and the
// user-visible symptom is a `pixelSize` edit that does nothing until the mouse
// moves, i.e. a feature that ships not repainting.
//
// This half asserts only the FIELD. The other half — that the value stamped
// into it actually moves when the plane does — is `image_plane.d`'s digest
// unittest, and it is the one that catches a term added but under-covered.
// Splitting them is deliberate: a field test alone is exactly the shape that
// passed four times in this file's history while a render input stayed stale.
unittest {
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");
    b.imagePlaneKey = 0x9E3779B97F4A7C15UL;
    assert(a != b,
        "keys differing only in imagePlaneKey must compare unequal — a "
        ~ "reference image is a render input like any other, and it reaches no "
        ~ "DrawPlan");
}

unittest {
    // --test byte-neutrality guard: cellCount == 1 must return exactly
    // [activeId] (the owner), never taking the multi-cell visual branch.
    assert(overlayDrawOrder(1, 0) == [0]);
}

unittest {
    // Quad (cellCount == 4): owner drawn last, every other cell visited
    // exactly once, order of the non-owner cells otherwise unspecified but
    // stable (ascending scan order here).
    assert(overlayDrawOrder(4, 2) == [0, 1, 3, 2]);
    assert(overlayDrawOrder(4, 0) == [1, 2, 3, 0]);
}

// ---------------------------------------------------------------------------
// Unittests — pure (no GL), verifying the data-model invariants the refactor
// rests on.  Run via `dub test --config=tests`.
// ---------------------------------------------------------------------------
unittest {
    // 1. Basic construction: 4 allocated cells, cellCount=1, correct initial IDs.
    auto m = new ViewportManager(10, 20, 640, 480);
    assert(m.views.length == 4,   "must pre-allocate 4 cells (stable array)");
    assert(m.cellCount    == 1,   "cellCount must start at 1");
    assert(m.activeId     == 0,   "activeId must start at 0");
    assert(m.hoveredId    == 0,   "hoveredId must start at 0");
    assert(m.dragOriginId == -1,  "dragOriginId must start at -1");
    assert(m.layout       == LayoutPreset.Single, "layout must start as Single");

    // 2. Router identity: inside vs. outside the single-cell rect [10,650)×[20,500).
    //    With Single layout, views[0].winRect = (10,20,640,480).
    assert(m.viewportUnderCursor(100, 100) == 0,  "cursor inside → 0");
    assert(m.viewportUnderCursor(0,   0)   == -1, "(0,0) outside → -1");
    assert(m.viewportUnderCursor(9,   19)  == -1, "just outside origin → -1");
    assert(m.viewportUnderCursor(649, 499) == 0,  "last inside pixel → 0");
    assert(m.viewportUnderCursor(650, 499) == -1, "right edge outside → -1");
    assert(m.viewportUnderCursor(649, 500) == -1, "bottom edge outside → -1");

    // 3. activeCamera() aliases views[0].camera (not a copy).
    assert(m.activeCamera() is m.views[0].camera,
           "activeCamera() must alias views[0].camera");

    // 4. Mutation through activeCamera() is observable on views[0].
    m.activeCamera().orbit(5, 5);
    assert(m.activeCamera().azimuth == m.views[0].camera.azimuth,
           "mutation through activeCamera() must be visible on views[0]");

    // 5. hoveredCamera() falls back to activeCamera() when hoveredId < 0.
    m.hoveredId = -1;
    assert(m.hoveredCamera() is m.views[m.activeId].camera,
           "hoveredCamera() with hoveredId=-1 must fall back to activeCamera()");
    m.hoveredId = 0;   // restore

    // 6. originCamera(): no gesture → active cell; gesture → origin cell.
    assert(m.originCamera() is m.views[0].camera,
           "originCamera() with no gesture must return active cell camera");
    m.dragOriginId = 0;
    assert(m.originCamera() is m.views[0].camera,
           "originCamera() with dragOriginId=0 must return views[0].camera");
    m.dragOriginId = -1;  // restore

    // 7. snapshotOf sanity: same construction args → same snapshot output.
    //    Uses a FRESH manager (m's camera was mutated by orbit() in test 4).
    {
        auto m2         = new ViewportManager(10, 20, 640, 480);
        auto standalone = new View(10, 20, 640, 480);
        assert(m2.snapshotOf(0) == standalone.viewport(),
               "snapshotOf must match an equivalent standalone View.viewport()");
    }

    // 8. windowId: each cell gets a stable id string.
    {
        auto m3 = new ViewportManager(0, 0, 800, 600);
        assert(m3.views[0].windowId == "Viewport##0");
        assert(m3.views[1].windowId == "Viewport##1");
        assert(m3.views[2].windowId == "Viewport##2");
        assert(m3.views[3].windowId == "Viewport##3");
    }
}

// ---------------------------------------------------------------------------
// cellsFor + cellRectsFor unittests
// ---------------------------------------------------------------------------
unittest {
    // cellsFor.
    assert(ViewportManager.cellsFor(LayoutPreset.Single) == 1);
    assert(ViewportManager.cellsFor(LayoutPreset.SplitH) == 2);
    assert(ViewportManager.cellsFor(LayoutPreset.SplitV) == 2);
    assert(ViewportManager.cellsFor(LayoutPreset.Quad)   == 4);

    // cellRectsFor — Single: must equal the full rect (MINOR-8 pixel-identity).
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.Single, 10, 20, 640, 480,
                                     xs, ys, ws, hs);
        assert(xs[0] == 10 && ys[0] == 20 && ws[0] == 640 && hs[0] == 480,
               "Single must return the whole rect");
    }

    // cellRectsFor — SplitH: two exact halves, no gap, no overlap.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.SplitH, 0, 0, 640, 480,
                                     xs, ys, ws, hs);
        // Left + right widths sum to total; no overlap.
        assert(ws[0] + ws[1] == 640,      "SplitH widths must sum to total");
        assert(xs[1] == xs[0] + ws[0],    "SplitH: right starts where left ends");
        assert(ys[0] == 0 && hs[0] == 480, "SplitH: same height");
        assert(ys[1] == 0 && hs[1] == 480, "SplitH: same height R");
    }

    // cellRectsFor — SplitV: two exact halves top/bottom.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.SplitV, 0, 0, 640, 480,
                                     xs, ys, ws, hs);
        assert(hs[0] + hs[1] == 480,       "SplitV heights must sum to total");
        assert(ys[1] == ys[0] + hs[0],     "SplitV: bottom starts where top ends");
        assert(xs[0] == 0 && ws[0] == 640, "SplitV: same width");
        assert(xs[1] == 0 && ws[1] == 640, "SplitV: same width B");
    }

    // cellRectsFor — Quad: four tiles, no gap, no overlap.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsFor(LayoutPreset.Quad, 100, 50, 640, 480,
                                     xs, ys, ws, hs);
        // Column widths.
        assert(ws[0] + ws[1] == 640, "Quad: top row widths sum to total");
        assert(ws[2] + ws[3] == 640, "Quad: bottom row widths sum to total");
        assert(ws[0] == ws[2],       "Quad: left column same width");
        assert(ws[1] == ws[3],       "Quad: right column same width");
        // Row heights.
        assert(hs[0] + hs[2] == 480, "Quad: left column heights sum to total");
        assert(hs[1] + hs[3] == 480, "Quad: right column heights sum to total");
        assert(hs[0] == hs[1],       "Quad: top row same height");
        assert(hs[2] == hs[3],       "Quad: bottom row same height");
        // Origin offsets.
        assert(xs[0] == 100 && ys[0] == 50,  "Quad TL origin");
        assert(xs[1] == 100 + ws[0] && ys[1] == 50, "Quad TR origin");
        assert(xs[2] == 100 && ys[2] == 50 + hs[0], "Quad BL origin");
        assert(xs[3] == 100 + ws[0] && ys[3] == 50 + hs[0], "Quad BR origin");
    }
}

// ---------------------------------------------------------------------------
// cellRectsForRatios unittests (task 0223, quad cross splitter, M0)
// ---------------------------------------------------------------------------
unittest {
    // Byte-neutrality: at hR=vR=0.5, cellRectsForRatios must reproduce
    // cellRectsFor exactly for every preset, across even AND odd dimensions
    // (proves the truncating cast(int) matches the existing `rw/2` divide).
    foreach (dims; [[640, 480], [641, 481], [101, 51], [1, 1]]) {
        int rw = dims[0], rh = dims[1];
        foreach (p; [LayoutPreset.Single, LayoutPreset.SplitH,
                     LayoutPreset.SplitV, LayoutPreset.Quad]) {
            int[4] xs0, ys0, ws0, hs0;
            int[4] xs1, ys1, ws1, hs1;
            ViewportManager.cellRectsFor(p, 7, 11, rw, rh, xs0, ys0, ws0, hs0);
            ViewportManager.cellRectsForRatios(p, 7, 11, rw, rh, 0.5f, 0.5f,
                                                xs1, ys1, ws1, hs1);
            assert(xs0 == xs1 && ys0 == ys1 && ws0 == ws1 && hs0 == hs1,
                   "cellRectsForRatios(0.5,0.5) must equal cellRectsFor");
        }
    }

    // Naming-trap mapping (see cellRectsForRatios' doc comment): SplitH's
    // divider is VERTICAL and driven by hRatio — cell0 width must track hR,
    // NOT vR. Use an asymmetric ratio pair so a swapped mapping would fail.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsForRatios(LayoutPreset.SplitH, 0, 0, 640, 480,
                                            0.25f, 0.75f, xs, ys, ws, hs);
        assert(ws[0] == cast(int)(640 * 0.25f),
               "SplitH cell0 width must be driven by hRatio, not vRatio");
        assert(ys[0] == 0 && hs[0] == 480, "SplitH: full height, no vRatio effect");
    }

    // SplitV's divider is HORIZONTAL and driven by vRatio — cell0 height
    // must track vR, NOT hR.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsForRatios(LayoutPreset.SplitV, 0, 0, 640, 480,
                                            0.75f, 0.25f, xs, ys, ws, hs);
        assert(hs[0] == cast(int)(480 * 0.25f),
               "SplitV cell0 height must be driven by vRatio, not hRatio");
        assert(xs[0] == 0 && ws[0] == 640, "SplitV: full width, no hRatio effect");
    }

    // Quad: both axes independently driven by hRatio/vRatio.
    {
        int[4] xs, ys, ws, hs;
        ViewportManager.cellRectsForRatios(LayoutPreset.Quad, 0, 0, 640, 480,
                                            0.25f, 0.75f, xs, ys, ws, hs);
        int hw = cast(int)(640 * 0.25f), hh = cast(int)(480 * 0.75f);
        assert(ws[0] == hw && ws[2] == hw, "Quad left column width == hRatio*rw");
        assert(hs[0] == hh && hs[1] == hh, "Quad top row height == vRatio*rh");
        assert(ws[1] == 640 - hw && ws[3] == 640 - hw, "Quad right column remainder");
        assert(hs[2] == 480 - hh && hs[3] == 480 - hh, "Quad bottom row remainder");
        // No gap / no overlap, edge-to-edge like cellRectsFor.
        assert(xs[1] == xs[0] + ws[0] && xs[3] == xs[2] + ws[2]);
        assert(ys[2] == ys[0] + hs[0] && ys[3] == ys[1] + hs[1]);
    }
}

// ---------------------------------------------------------------------------
// viewportUnderCursor multi-cell + applyLayout unittests
// ---------------------------------------------------------------------------
unittest {
    // Quad hit-test via applyLayout (lx/ly/lw/lh must be set first).
    auto m = new ViewportManager(0, 0, 640, 480);
    m.lx = 0; m.ly = 0; m.lw = 640; m.lh = 480;
    m.applyLayout(LayoutPreset.Quad);

    assert(m.cellCount == 4,  "Quad layout must produce 4 live cells");
    assert(!m.views[0].dirty || m.views[0].dirty, "dirtyAll ran — just checking no crash");

    // Each cell's top-left interior pixel must map to the correct index.
    // TL=0: top-left quadrant, TR=1: top-right, BL=2: bottom-left, BR=3: bottom-right.
    // Cell rects: 0=(0,0,320,240), 1=(320,0,320,240), 2=(0,240,320,240), 3=(320,240,320,240)
    assert(m.viewportUnderCursor(1,   1)   == 0, "TL interior → cell 0");
    assert(m.viewportUnderCursor(321, 1)   == 1, "TR interior → cell 1");
    assert(m.viewportUnderCursor(1,   241) == 2, "BL interior → cell 2");
    assert(m.viewportUnderCursor(321, 241) == 3, "BR interior → cell 3");
    // Outside the whole rect.
    assert(m.viewportUnderCursor(640, 0)   == -1, "right of last cell → -1");
    assert(m.viewportUnderCursor(0,   480) == -1, "below last cell → -1");

    // applyLayout hygiene: clamp indices, clear dragOriginId.
    m.activeId    = 3;
    m.hoveredId   = 3;
    m.masterId    = 3;
    m.dragOriginId = 2;
    m.applyLayout(LayoutPreset.Single);
    assert(m.cellCount    == 1,  "Single: cellCount=1");
    assert(m.activeId     == 0,  "activeId clamped to 0");
    assert(m.hoveredId    == 0,  "hoveredId clamped to 0");
    assert(m.masterId     == 0,  "masterId clamped to 0");
    assert(m.dragOriginId == -1, "dragOriginId cleared");
    assert(m.layoutDirty,        "layoutDirty raised");

    // Single layout router after applyLayout — same as old single-rect test.
    m.views[0].winX = 0; m.views[0].winY = 0;
    m.views[0].winW = 640; m.views[0].winH = 480;
    assert(m.viewportUnderCursor(100, 100) == 0,   "inside single cell → 0");
    assert(m.viewportUnderCursor(640, 0)   == -1,  "right of single cell → -1");
}

// ---------------------------------------------------------------------------
// followHover() unittests — task 0220 (focus-follows-mouse; key-driven
// per-cell commands like fit target the HOVERED cell, not the last-clicked
// one).
// ---------------------------------------------------------------------------
unittest {
    auto m = new ViewportManager(0, 0, 640, 480);
    m.lx = 0; m.ly = 0; m.lw = 640; m.lh = 480;
    m.applyLayout(LayoutPreset.Quad);

    // No gesture in progress: activeId must track hoveredId as the mouse
    // moves into another cell (motion event into cell 2, active was 0).
    m.activeId     = 0;
    m.hoveredId    = 2;
    m.dragOriginId = -1;
    m.followHover();
    assert(m.activeId == 2,
        "followHover(): no drag in progress → activeId must follow hoveredId");

    // Mid-gesture: activeId must stay PINNED to the drag-origin cell even
    // though hoveredId has since wandered into a different cell (the
    // per-cell picking caches indexed by activeId must not switch mid-drag).
    m.activeId     = 1;
    m.dragOriginId = 1;
    m.hoveredId    = 3;
    m.followHover();
    assert(m.activeId == 1,
        "followHover(): drag in progress → activeId must NOT follow hoveredId");

    // Cursor outside every cell (e.g. over a docked panel): sticky-last —
    // activeId is left untouched rather than snapping to an arbitrary cell.
    m.activeId     = 2;
    m.dragOriginId = -1;
    m.hoveredId    = -1;
    m.followHover();
    assert(m.activeId == 2,
        "followHover(): hoveredId < 0 → activeId must stay put (sticky-last)");
}

// ---------------------------------------------------------------------------
// inputSnapshot() unittests — task 0209 (Quad/Split any-cell input).
// ---------------------------------------------------------------------------
unittest {
    // Quad layout: inputSnapshot() must resolve to the HOVERED cell (no
    // drag in progress) — the whole point of this task.
    auto m = new ViewportManager(0, 0, 640, 480);
    m.lx = 0; m.ly = 0; m.lw = 640; m.lh = 480;
    m.applyLayout(LayoutPreset.Quad);

    m.activeId  = 0;
    m.hoveredId = 2;
    assert(m.dragOriginId == -1, "no gesture in progress");
    auto snap = m.inputSnapshot();
    auto want = m.resolvedSnapshot(2);
    assert(snap.view == want.view && snap.proj == want.proj,
           "inputSnapshot() with no drag must resolve to the HOVERED cell (2), not active (0)");

    // During a gesture, inputSnapshot() must stay pinned to the DRAG-ORIGIN
    // cell even though the cursor has since wandered into another cell —
    // the drag-pin invariant (frozen basis / flip-fix depend on this).
    m.dragOriginId = 1;
    m.hoveredId    = 3; // cursor now over a DIFFERENT cell mid-drag
    snap = m.inputSnapshot();
    want = m.resolvedSnapshot(1);
    assert(snap.view == want.view && snap.proj == want.proj,
           "inputSnapshot() during a drag must stay pinned to dragOriginId (1), ignoring hoveredId (3)");
    m.dragOriginId = -1; // restore

    // hoveredId == -1 (cursor outside all cells, e.g. over an ImGui panel)
    // must fall back to the active cell, same as hoveredCamera().
    m.hoveredId = -1;
    snap = m.inputSnapshot();
    want = m.resolvedSnapshot(m.activeId);
    assert(snap.view == want.view && snap.proj == want.proj,
           "inputSnapshot() with hoveredId=-1 must fall back to the active cell");

    // Single layout (cellCount==1): inputSnapshot() must be IDENTICAL to
    // originSnapshot() — the byte-neutrality invariant `--test` relies on.
    m.applyLayout(LayoutPreset.Single);
    m.views[0].winX = 0; m.views[0].winY = 0;
    m.views[0].winW = 640; m.views[0].winH = 480;
    assert(m.cellCount == 1, "Single: cellCount=1");
    m.hoveredId = 0;
    auto inSnap  = m.inputSnapshot();
    auto orgSnap = m.originSnapshot();
    assert(inSnap.view == orgSnap.view && inSnap.proj == orgSnap.proj,
           "cellCount==1: inputSnapshot() must be identical to originSnapshot()");
}

// ---------------------------------------------------------------------------
// ViewportFbo unittests — pure size-decision logic (no GL context needed).
// ---------------------------------------------------------------------------
unittest {
    ViewportFbo f;

    // Initial state.
    assert(f.w == 0 && f.h == 0 && f._allocGen == 0, "initial state must be zeroed");

    // ensure with invalid sizes must be a no-op.
    f.ensure(0, 100);
    assert(f._allocGen == 0, "ensure(0,100) must be a no-op");
    f.ensure(100, 0);
    assert(f._allocGen == 0, "ensure(100,0) must be a no-op");
    f.ensure(-1, -1);
    assert(f._allocGen == 0, "ensure(-1,-1) must be a no-op");

    // First valid call allocates storage.
    f.ensure(100, 100);
    assert(f.w == 100 && f.h == 100, "ensure(100,100) must set w=100, h=100");
    assert(f._allocGen == 1, "first ensure must bump _allocGen to 1");

    // Same size → idempotent (no realloc).
    f.ensure(100, 100);
    assert(f._allocGen == 1, "same-size ensure must NOT bump _allocGen");

    // Size change → realloc.
    f.ensure(200, 100);
    assert(f.w == 200 && f.h == 100, "size-change ensure must update w/h");
    assert(f._allocGen == 2, "size-change ensure must bump _allocGen");

    f.ensure(200, 300);
    assert(f._allocGen == 3, "second size-change must bump _allocGen again");

    // Idempotent after second change.
    f.ensure(200, 300);
    assert(f._allocGen == 3, "same size after resize must be idempotent");

    // destroy resets tracking fields.
    f.destroy();
    assert(f.w == 0 && f.h == 0 && f._allocGen == 0,
           "destroy must reset w, h, _allocGen to 0");

    // ensure works again after destroy.
    f.ensure(64, 64);
    assert(f.w == 64 && f.h == 64 && f._allocGen == 1,
           "ensure after destroy must work as a fresh first call");
}

// ---------------------------------------------------------------------------
// Phase-5 resolveFollow + Quad-default unittests
// ---------------------------------------------------------------------------
unittest {
    // 2-cell manager: cell 0 = follower, cell 1 = master.
    auto m = new ViewportManager(0, 0, 800, 600);
    m.lx = 0; m.ly = 0; m.lw = 800; m.lh = 600;

    // Give each cell a distinct camera state.
    m.views[0].camera.focus    = Vec3(1, 0, 0);
    m.views[0].camera.distance = 2.0f;
    m.views[0].camera.azimuth  = 0.1f;
    m.views[0].camera.elevation = 0.2f;

    m.views[1].camera.focus    = Vec3(9, 0, 0);
    m.views[1].camera.distance = 7.0f;
    m.views[1].camera.azimuth  = 1.5f;
    m.views[1].camera.elevation = 0.8f;

    // Point cell 0 at cell 1 as per-cell master.
    m.views[0].masterId = 1;
    m.cellCount = 2;   // make both cells live

    Vec3 fo; float di, a, e;

    // indCenter=true, indScale=true, indRotate=true → all own
    m.views[0].indCenter = true; m.views[0].indScale = true; m.views[0].indRotate = true;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f,  "own center: focus.x must be 1");
    assert(di   == 2.0f,  "own scale: distance must be 2");
    assert(a    == 0.1f,  "own rotate: azimuth must be 0.1");
    assert(e    == 0.2f,  "own rotate: elevation must be 0.2");

    // indCenter=false → follow master's focus
    m.views[0].indCenter = false;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 9.0f, "follow center: focus.x must be 9");
    assert(di   == 2.0f, "scale still own");

    // indScale=false → follow master's distance
    m.views[0].indCenter = true;
    m.views[0].indScale = false;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f, "center own again");
    assert(di   == 7.0f, "follow scale: distance must be 7");

    // indRotate=false → follow master's az+el
    m.views[0].indScale  = true;
    m.views[0].indRotate = false;
    m.resolveFollow(0, fo, di, a, e);
    import std.math : isClose;
    assert(isClose(a, 1.5f, 1e-5f), "follow rotate: az must be 1.5");
    assert(isClose(e, 0.8f, 1e-5f), "follow rotate: el must be 0.8");

    // Reset flags for next subtests
    m.views[0].indCenter = true; m.views[0].indScale = true; m.views[0].indRotate = true;

    // Self-master: masterId=-1, group masterId=0 → self
    m.views[0].masterId = -1;
    m.masterId = 0;
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f, "self-master: must return own focus");
    assert(di   == 2.0f, "self-master: must return own distance");

    // Out-of-range master → self
    m.views[0].masterId = 99;
    m.views[0].indCenter = false;  // would follow master if master were valid
    m.resolveFollow(0, fo, di, a, e);
    assert(fo.x == 1.0f, "out-of-range master → self, own focus");
    m.views[0].indCenter = true;
    m.views[0].masterId = -1;
}

unittest {
    // Quad layout defaults: cells 0-2 indCenter=false, indScale=false, indRotate=true;
    // cell 3 fully-independent; group masterId=3.
    auto m = new ViewportManager(0, 0, 640, 480);
    m.lx = 0; m.ly = 0; m.lw = 640; m.lh = 480;
    m.applyLayout(LayoutPreset.Quad);

    assert(m.masterId == 3, "Quad group masterId must be 3");
    foreach (k; 0..3) {
        assert(!m.views[k].indCenter, "Quad ortho cell indCenter must be false");
        assert(!m.views[k].indScale,  "Quad ortho cell indScale must be false");
        assert( m.views[k].indRotate, "Quad ortho cell indRotate must be true");
        assert( m.views[k].masterId == -1, "Quad ortho cell masterId must be -1 (use group)");
    }
    // Persp cell (3) stays fully independent (reset block then no override)
    assert( m.views[3].indCenter, "Quad persp cell indCenter must be true");
    assert( m.views[3].indScale,  "Quad persp cell indScale must be true");
    assert( m.views[3].indRotate, "Quad persp cell indRotate must be true");

    // Layout switch hygiene: Quad → Single → Quad resets cleanly
    m.applyLayout(LayoutPreset.Single);
    assert(m.views[0].indCenter, "Single: cell 0 must reset to indCenter=true");
    assert(m.views[0].indScale,  "Single: cell 0 must reset to indScale=true");
    assert(m.views[0].indRotate, "Single: cell 0 must reset to indRotate=true");
    assert(m.masterId == 0,      "Single: group masterId must be 0");

    m.applyLayout(LayoutPreset.Quad);
    assert(!m.views[0].indCenter, "Quad again: cell 0 indCenter must be false");
    assert(!m.views[1].indScale,  "Quad again: cell 1 indScale must be false");
    assert(m.masterId == 3,       "Quad again: group masterId must be 3");
}

unittest {
    // BANK rides on indRotate, and a follower renders the MASTER's bank.
    //
    // The failure this pins: `resolvedSnapshot` used to build a follower's
    // matrices from the master's azimuth/elevation but the FOLLOWER's own
    // object. A `viewportWith` that quietly defaulted the rotation to
    // `this.orientation` would compile there and render two linked cells with
    // mutually rotated horizons while both reported the same rotation.
    import std.math : isClose, abs;
    auto m = new ViewportManager(0, 0, 800, 600);
    m.lx = 0; m.ly = 0; m.lw = 800; m.lh = 600;
    m.cellCount = 2;
    m.views[0].camera.azimuth = 0.1f; m.views[0].camera.elevation = 0.2f;
    m.views[0].camera.roll    = 0.30f;
    m.views[1].camera.azimuth = 1.5f; m.views[1].camera.elevation = 0.8f;
    m.views[1].camera.roll    = -0.70f;
    m.views[0].masterId = 1;

    Vec3 fo; float di; Orientation ro;

    m.views[0].indRotate = true;
    m.resolveFollow(0, fo, di, ro);
    assert(isClose(ro.roll, 0.30f, 1e-5f), "own rotate: bank must be the cell's own");

    m.views[0].indRotate = false;
    m.resolveFollow(0, fo, di, ro);
    assert(isClose(ro.roll, -0.70f, 1e-5f), "follow rotate: bank must be the master's");
    // The WHOLE rotation follows, not just the bank — the heading too.
    assert(isClose(ro.azimuth, 1.5f, 1e-5f),
           "follow rotate: the master's heading must come with its bank");

    // The resolved SNAPSHOT must render that rotation, not the follower's.
    Viewport got  = m.resolvedSnapshot(0);
    Viewport want = m.views[1].camera.viewportWith(fo, di, ro);
    assert(got.view == want.view,
           "a follower's snapshot must be built on the master's rotation");
    // Non-vacuous: the follower's OWN rotation gives a different matrix.
    Viewport wrong = m.views[0].camera.viewportWith(
        fo, di, m.views[0].camera.orientation);
    assert(got.view != wrong.view,
           "the follower's own rotation must NOT be what gets rendered");

    // The four-out overload still answers the four it always did.
    Vec3 fo4; float di4, a4, e4;
    m.resolveFollow(0, fo4, di4, a4, e4);
    assert(isClose(a4, ro.azimuth, 1e-5f) && isClose(e4, ro.elevation, 1e-5f) &&
           di4 == di && fo4.x == fo.x,
           "the four-out overload must agree with the orientation overload");

    // And the published JSON carries it.
    import std.json : parseJSON;
    auto j = parseJSON(m.resolvedCameraJson(0));
    assert(isClose(cast(float)j["roll"].floating, -0.70f, 1e-5f),
           "resolved camera JSON must publish the resolved bank");
    m.views[0].indRotate = true;
    m.views[0].masterId  = -1;
}

