// PenRenderOps — every pixel the Topology Pen draws: the `draw()` entry point,
// the one-per-gesture ghost helpers it calls in a load-bearing order, the
// hover/fill affordances, and the cross-hatch scanline fill they share.
//
// Mixed into `TopologyPenTool` (`tools.edit.topology_pen.tool`) with
// `mixin PenRenderOps;` -- the house pattern for lifting a member family out
// of a large type without changing what the type IS
// (`mesh_ops/loop_slice.d` -> `struct Mesh` is the same shape). Bodies below
// are a verbatim cut/paste; only this wrapper is new. A mixed-in member reads
// the class's own state, `private` members included, exactly as it did while
// it lived in the class body -- so this split widened NOTHING (measured:
// task 0718).
//
// Nothing here mutates the mesh or raycasts; every helper re-reads state some
// gesture already classified. That is why they can be read, and moved, as one
// family.
//
// This module deliberately imports NOTHING. A template mixin's body resolves
// its identifiers in the scope it is mixed INTO, so `Vec3`, `Viewport`,
// `ImGui`, `Mesh` and the rest come from `tool.d`'s import list; imports
// repeated here would be inert, and inert code that looks load-bearing is
// worse than none (verified by deleting them: the build is byte-identical
// either way).
module tools.edit.topology_pen.render;


mixin template PenRenderOps() {
    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase 4):
    // an even-odd, rotated-axis scanline fill — draws a dark diagonal
    // CROSS-HATCH (two 45°/135° families) over an arbitrary screen-space
    // polygon. Correct for convex AND concave n-gons: for each family,
    // sweep parallel diagonal lines across the polygon's own AABB, collect
    // each line's intersection parameters with every polygon edge, sort
    // them along the sweep direction, and draw between consecutive (even,
    // odd) pairs — the classic even-odd interior test, no clip-rect spill
    // (the intersections are already bounded to the polygon itself).
    // `poly` must be a simple (non-self-intersecting) closed loop, in
    // either winding order — the algorithm is winding-independent.
    private static void hatchScreenPolygon(ImGui.ImDrawList* dl, const ImVec2[] poly, uint col,
                                           float spacingPx, float widthPx,
                                           const ref Viewport vp) {
        if (poly.length < 3) return;

        float minX = poly[0].x, maxX = poly[0].x;
        float minY = poly[0].y, maxY = poly[0].y;
        foreach (p; poly) {
            if (p.x < minX) minX = p.x; else if (p.x > maxX) maxX = p.x;
            if (p.y < minY) minY = p.y; else if (p.y > maxY) maxY = p.y;
        }

        // Bundled review SHOULD-FIX (#27 review /
        // doc/topopen_p12_smoothloop_plan.md "hover-highlight SHOULD-FIX"):
        // clamp the AABB to the VIEWPORT rect BEFORE computing the sweep
        // range below — an off-frustum boundary-face vertex (e.g. a large
        // polygon whose silhouette partly leaves the visible viewport)
        // would otherwise make `cMin..cMax` sweep thousands of lines for
        // hatch that is never visible anyway (a render hitch, not just
        // wasted work). Off-viewport hatch isn't visible, so clamping is
        // lossless for what actually gets drawn.
        immutable float vpMinX = cast(float)vp.x,              vpMaxX = cast(float)(vp.x + vp.width);
        immutable float vpMinY = cast(float)vp.y,              vpMaxY = cast(float)(vp.y + vp.height);
        if (minX < vpMinX) minX = vpMinX;
        if (maxX > vpMaxX) maxX = vpMaxX;
        if (minY < vpMinY) minY = vpMinY;
        if (maxY > vpMaxY) maxY = vpMaxY;
        if (minX > maxX || minY > maxY) return;   // polygon's AABB is entirely off-viewport

        // `mainDiag==true` sweeps the (+1,+1) family (lines of constant
        // x - y); `false` sweeps the (+1,-1) family (lines of constant
        // x + y). Adjacent lines within a family are `spacingPx` apart in
        // the PERPENDICULAR direction; since both invariants change by
        // `sqrt(2)` per unit of perpendicular travel along a 45° line, the
        // invariant step is `spacingPx * SQRT2`.
        void sweepFamily(bool mainDiag) {
            immutable float step = spacingPx * SQRT2;
            if (step <= 0.0f) return;   // defensive: no infinite loop below
            immutable float cMin = mainDiag ? (minX - maxY) : (minX + minY);
            immutable float cMax = mainDiag ? (maxX - minY) : (maxX + maxY);

            // Bundled review SHOULD-FIX: ONE scratch buffer reused across
            // every sweep line in this family (`.length = 0` keeps the
            // underlying GC allocation's capacity, so the `~=` below grows
            // it in place instead of allocating fresh per line) rather than
            // a brand-new `ImVec2[]` per line — a convex face (the common
            // real call-site shape, a mesh polygon) needs only 2 slots per
            // line; a concave n-gon's extra crossings just grow this same
            // buffer. `assumeSafeAppend` after the length reset preserves the
            // append-capacity so `~=` reuses the block instead of reallocating
            // fresh each sweep line (safe: `hits` is never sliced or escaped —
            // the sort is in-place and AddLine copies the points).
            ImVec2[] hits;
            for (float c = cMin; c <= cMax; c += step) {
                hits.length = 0;
                hits.assumeSafeAppend();
                immutable size_t n = poly.length;
                foreach (i; 0 .. n) {
                    ImVec2 A = poly[i];
                    ImVec2 B = poly[(i + 1) % n];
                    float fA = mainDiag ? (A.x - A.y - c) : (A.x + A.y - c);
                    float fB = mainDiag ? (B.x - B.y - c) : (B.x + B.y - c);
                    if (fA == 0.0f && fB == 0.0f) continue;   // whole edge on the line: ill-defined
                    if ((fA > 0.0f && fB > 0.0f) || (fA < 0.0f && fB < 0.0f)) continue;   // same side
                    if (fA == fB) continue;   // defensive: avoid div-by-zero below
                    float s = fA / (fA - fB);
                    if (s < 0.0f || s > 1.0f) continue;   // defensive clamp
                    hits ~= ImVec2(A.x + s * (B.x - A.x), A.y + s * (B.y - A.y));
                }
                if (hits.length < 2) continue;   // guard: need a pair to draw a segment

                import std.algorithm : sort;
                // Both 45°-family directions are monotonic in x along the
                // sweep line, so sorting by x alone orders the crossings
                // correctly for either family.
                sort!((a, b) => a.x < b.x)(hits);

                size_t i = 0;
                while (i + 1 < hits.length) {
                    dl.AddLine(hits[i], hits[i + 1], col, widthPx);
                    i += 2;
                }
            }
        }

        sweepFamily(true);
        sweepFamily(false);
    }

    // Split into one private helper per ghost (refactor — pure extraction,
    // no behavior change; every block below moved verbatim, comments
    // included). Draw order is unchanged and load-bearing: every
    // ARMED-gesture ghost first, each independent of `lastHit_`/CONS and
    // therefore BEFORE the `!lastHit_.hit` early-return (see each helper's
    // own header for why); then the unarmed hover/fill affordances; then
    // the CONS-hit marker and the two ghosts keyed off it.
    override void draw(const ref Shader shader, const ref Viewport vp,
                       ref VectorStack vts, bool visualOnly = false) {
        auto dl = ImGui.GetForegroundDrawList();

        drawAddLoopGhost(dl, vp);
        drawSlideGhost(dl, vp);
        drawSmoothGhost(dl);
        drawSplitGhost(dl, vp);
        drawMoveLoopGhost(dl, vp);
        drawDupGhosts(dl, vp);
        drawSmoothLoopGhost(dl, vp);
        drawHoverHighlight(dl, vp);
        drawFillRingPreview(dl, vp);
        drawFillRadiusOverlay(dl);

        if (!lastHit_.hit) return;

        drawSnapTargetMarker(dl, vp);
        drawBuildGhost(dl, vp);
        drawMoveGhost(dl, vp);
    }

    // P6 (doc/topopen_p6_addloop_plan.md Phase 5): the Add Loop ghost is
    // independent of `lastHit_`/CONS (this gesture never touches the
    // background constraint — pure current-layer topology op), so it is
    // drawn BEFORE the `lastHit_.hit` early-return below: a primary-only
    // scene with no background layer (hence no CONS hit ever) must still
    // preview the armed seed ring. Purely re-reads already-classified
    // state (`addLoopSeed_`/`seedRailA_`/`seedRailB_`/`addLoopRatio_`) —
    // no mesh mutation, no raycast.
    private void drawAddLoopGhost(ImDrawList* dl, const ref Viewport vp) {
        if (addLoopArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && addLoopSeed_ >= 0 && addLoopSeed_ < cast(int)m.edges.length) {
                // Pixel (§1.1), once for the whole ring (§3).
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
                enum uint loopCol = IM_COL32(255, 90, 220, 220);   // add-loop magenta
                foreach (ei; m.loopSliceRingEdges(cast(uint)addLoopSeed_)) {
                    if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                    auto ringE = m.edges[ei];
                    ImVec2 ra, rb;
                    if (projectLocalPt(m.vertices[ringE[0]], vpAim, ra)
                     && projectLocalPt(m.vertices[ringE[1]], vpAim, rb))
                        dl.AddLine(ra, rb, loopCol, 2.0f);
                }
                // The ghost marker previews what a release WOULD commit, so
                // it reads the same `addLoopFrac` law `addLoopUp` does — with
                // the "at the Middle" option on, the marker pins to 50% of
                // the rail and stops following the cursor.
                // LOCAL: `seedRailA_`/`seedRailB_` are raw `m.vertices[]`
                // reads (`seedRail`), and a lerp between two local points is
                // local. Task 0619 corrected two comments in this file that
                // called them "WORLD".
                Vec3 markerPos = seedRailA_
                               + (seedRailB_ - seedRailA_) * addLoopFrac(addLoopRatio_);
                ImVec2 mk;
                if (projectLocalPt(markerPos, vpAim, mk))
                    dl.AddCircleFilled(mk, 5.0f, loopCol, 16);
            }
        }
    }

    // P7 (doc/topopen_p7_slide_plan.md Phase 4): the Slide ghost is
    // likewise independent of `lastHit_`/CONS (Slide never touches the
    // background constraint — pure current-layer edge-line constrained
    // move), so it too is drawn BEFORE the `lastHit_.hit` early-return,
    // mirroring the Add Loop ghost above. Purely re-reads already-armed
    // state (`slideEndA_`/`slideEndB_`/`slideNbrA_`/`slideNbrB_`/
    // `slideDeltaK_`) — no mesh mutation, no raycast. A
    // held-fixed endpoint (`slideNbrA_`/`slideNbrB_ < 0`) draws at its
    // CURRENT (unmoved) position, same as `commitSlide` would leave it.
    // The ghost runs the SAME `slideEndpointPos` the commit does, so an
    // unbounded (past-the-neighbour) slide previews truthfully — the
    // faint rail below is drawn edge-to-neighbour only and is a reference
    // line, not a bound.
    private void drawSlideGhost(ImDrawList* dl, const ref Viewport vp) {
        if (slideArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null
             && slideEndA_ >= 0 && slideEndA_ < cast(int)m.vertices.length
             && slideEndB_ >= 0 && slideEndB_ < cast(int)m.vertices.length) {
                enum uint slideCol     = IM_COL32(120, 200, 255, 220);   // slide cyan-blue
                enum uint slideRailCol = IM_COL32(120, 200, 255, 90);    // faint rail

                // Pixel (§1.1), once for the whole ghost (§3). Every point
                // below is LOCAL: `slideEndpointPos` moves a local vertex
                // along a rail built from two more local vertices.
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());

                Vec3 pA = (slideNbrA_ >= 0 && slideNbrA_ < cast(int)m.vertices.length)
                    ? slideEndpointPos(m.vertices[slideEndA_], m.vertices[slideNbrA_], slideDeltaK_)
                    : m.vertices[slideEndA_];
                Vec3 pB = (slideNbrB_ >= 0 && slideNbrB_ < cast(int)m.vertices.length)
                    ? slideEndpointPos(m.vertices[slideEndB_], m.vertices[slideNbrB_], slideDeltaK_)
                    : m.vertices[slideEndB_];

                ImVec2 pa, pb;
                if (projectLocalPt(pA, vpAim, pa) && projectLocalPt(pB, vpAim, pb)) {
                    dl.AddLine(pa, pb, slideCol, 2.5f);
                    dl.AddCircleFilled(pa, 4.0f, slideCol, 16);
                    dl.AddCircleFilled(pb, 4.0f, slideCol, 16);
                }

                void faintRail(int end, int nbr) {
                    if (nbr < 0 || nbr >= cast(int)m.vertices.length) return;
                    ImVec2 ra, rb;
                    if (projectLocalPt(m.vertices[end], vpAim, ra)
                     && projectLocalPt(m.vertices[nbr], vpAim, rb))
                        dl.AddLine(ra, rb, slideRailCol, 1.0f);
                }
                faintRail(slideEndA_, slideNbrA_);
                faintRail(slideEndB_, slideNbrB_);
            }
        }
    }

    // P8 (doc/topopen_p8_smooth_plan.md Phase 4): a cheap "Smooth
    // armed" affordance — a colored ring at the CURSOR'S OWN screen
    // position while `smoothArmed_`. Unlike the P1 hover marker below
    // (which needs a CONS hit against a background layer) or the Add
    // Loop/Slide ghosts above (which key off an armed seed edge's
    // LAYER-LOCAL position — task 0619 corrected "WORLD" here), Smooth has
    // neither a source pick nor a
    // background dependency — it relaxes the WHOLE primary mesh, so
    // tying its affordance to `lastHit_.point` would make it invisible
    // in exactly the bg-less scene this preview must still cover.
    // Drawn in pure screen space (no projectPt/raycast, no mesh
    // access), so it is unconditionally visible and unconditionally
    // cheap; placed BEFORE the `lastHit_.hit` early-return immediately
    // below, mirroring the Add Loop/Slide ghosts' positioning in this
    // function. No per-pass relaxation preview (deferred/expensive —
    // consistent with the deferred-commit divergence, plan §Undo).
    private void drawSmoothGhost(ImDrawList* dl) {
        if (smoothArmed_) {
            enum uint smoothCol = IM_COL32(120, 255, 200, 220);   // smoothing green-blue
            ImVec2 cur = ImVec2(cast(float)smoothLastX_, cast(float)smoothLastY_);
            dl.AddCircle(cur, 14.0f, smoothCol, 24, 2.5f);
            dl.AddCircleFilled(cur, 4.0f, smoothCol, 16);
        }
    }

    // P9 (doc/topopen_p9_split_plan.md Phase 4): the Split ghost is
    // likewise independent of `lastHit_`/CONS (Split never touches the
    // background constraint — pure current-layer topology op), so it too
    // is drawn BEFORE the `lastHit_.hit` early-return, mirroring the Add
    // Loop/Slide ghosts above. A line from the armed source A to the
    // current snap target C (drawn only once C resolves to a real
    // vertex — a release that resolves no vertex is a no-op, so there
    // is nothing to preview),
    // plus a small filled circle at C as the snap affordance. Purely
    // re-reads already-armed state (`splitSourceVert_`/
    // `splitTargetVert_`) — no mesh mutation, no raycast.
    private void drawSplitGhost(ImDrawList* dl, const ref Viewport vp) {
        if (splitArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && splitSourceVert_ >= 0 && splitSourceVert_ < cast(int)m.vertices.length) {
                enum uint splitCol = IM_COL32(80, 200, 230, 220);   // split cyan
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());   // Pixel (§1.1)
                ImVec2 aPt;
                if (projectLocalPt(m.vertices[splitSourceVert_], vpAim, aPt)
                 && splitTargetVert_ >= 0 && splitTargetVert_ < cast(int)m.vertices.length) {
                    ImVec2 cPt;
                    if (projectLocalPt(m.vertices[splitTargetVert_], vpAim, cPt)) {
                        dl.AddLine(aPt, cPt, splitCol, 2.0f);
                        dl.AddCircleFilled(cPt, 5.0f, splitCol, 16);
                    }
                }
            }
        }
    }

    // P10 (doc/topopen_p10_moveloop_plan.md Phase 4): the Move Loop
    // ghost is likewise independent of `lastHit_`/CONS's OWN hit
    // (unlike P4 Move's ghost below, which reuses `lastHit_.point` —
    // MOVE-LOOP resolves its OWN N per-vertex re-snap targets via
    // `resnapToBackground`, not the single CONS-published hit), so it
    // too is drawn BEFORE the `lastHit_.hit` early-return, mirroring
    // every other armed-gesture ghost above: a primary-only scene with
    // no background layer must still preview the armed loop (every
    // vertex simply staying at its own original position, per the miss
    // policy). Purely re-reads already-armed state
    // (`moveLoopSeed_`/`moveLoopVerts_`/`moveLoopStartX_`/`_Y_`/
    // `moveLoopCurX_`/`_Y_`) plus the live cursor delta — no mesh
    // mutation.
    private void drawMoveLoopGhost(ImDrawList* dl, const ref Viewport vp) {
        if (moveLoopArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && moveLoopSeed_ >= 0 && moveLoopSeed_ < cast(int)m.edges.length) {
                enum uint moveLoopCol = IM_COL32(255, 140, 60, 220);   // move-loop ghost orange
                int dx = moveLoopCurX_ - moveLoopStartX_;
                int dy = moveLoopCurY_ - moveLoopStartY_;

                // Pixel (§1.1), once for the whole ghost (§3).
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());

                // `ghostPos` used to be a MIXED-SPACE map — the rename is
                // what exposed it: a miss stored `orig` (LOCAL) while a hit
                // stored `resnapToBackground`'s answer, which was WORLD
                // because `closestPointOnMeshes` folds every background
                // source to world. Neither classification was honest for the
                // three reads below, and drawing both branches through the
                // world viewport (what this code always did) put the ghost
                // for a HIT vertex at a different pixel from the ghost for a
                // MISSED one on the same transformed layer. Since
                // `resnapToBackground` now returns the primary's LOCAL
                // coordinate — the space its consumers write — the map has
                // one space and every read is `projectLocalPt`.
                Vec3[uint] ghostPos;
                foreach (vi; moveLoopVerts_) {
                    if (vi >= m.vertices.length) continue;
                    Vec3 orig = m.vertices[vi];
                    Vec3 g    = orig;   // default: miss (or off-screen) keeps the original
                    ImVec2 pt;
                    if (projectLocalPt(orig, vpAim, pt)) {
                        int px = cast(int)(pt.x + cast(float)dx);
                        int py = cast(int)(pt.y + cast(float)dy);
                        Vec3 hitPt2;
                        if (resnapToBackground(orig, px, py, vp, hitPt2)) g = hitPt2;
                    }
                    ghostPos[vi] = g;
                }

                foreach (ei; (*m).selectLoopEdges(cast(uint)moveLoopSeed_)) {
                    if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                    auto ringE = m.edges[ei];
                    auto ga = ringE[0] in ghostPos;
                    auto gb = ringE[1] in ghostPos;
                    if (ga is null || gb is null) continue;
                    ImVec2 pa, pb;
                    if (projectLocalPt(*ga, vpAim, pa) && projectLocalPt(*gb, vpAim, pb))
                        dl.AddLine(pa, pb, moveLoopCol, 2.0f);
                }
                foreach (vi, pos; ghostPos) {
                    ImVec2 gp;
                    if (projectLocalPt(pos, vpAim, gp))
                        dl.AddCircleFilled(gp, 4.0f, moveLoopCol, 16);
                }
            }
        }
    }

    // P11 (doc/topopen_p11_duploop_plan.md Phase 4): the Dup Loop
    // ghost — preview of the coincident-then-dragged duplicate ring +
    // bridge quads, recomputed every frame from the LIVE cursor
    // (`dupLoopCurX_`/`dupLoopCurY_`), mirroring the Move Loop ghost
    // immediately above (same `resnapToBackground`/`projectPt`
    // primitives, no mesh mutation, no extrude — pure preview).
    // Independent of `lastHit_`/CONS, drawn before the same
    // `!lastHit_.hit` early-return as every other gesture ghost.
    //
    // Task 0485: the SAME ghost for the Shift+LMB single-edge duplicate —
    // one edge instead of a loop, identical preview arithmetic.
    private void drawDupGhosts(ImDrawList* dl, const ref Viewport vp) {
        if (dupLoopArmed_ && meshSrc_ !is null) drawDupGhost(dl, vp, dupLoopEdges_,
            dupLoopCurX_ - dupLoopStartX_, dupLoopCurY_ - dupLoopStartY_);

        if (dupEdgeArmed_ && dupEdgeEdges_.length && meshSrc_ !is null)
            drawDupGhost(dl, vp, dupEdgeEdges_,
                         dupEdgeCurX_ - dupEdgeStartX_, dupEdgeCurY_ - dupEdgeStartY_);
    }

    // P12 (doc/topopen_p12_smoothloop_plan.md Phase 4): the Smooth+Loop
    // ghost — highlights the ARMED loop at its CURRENT (pre-relax)
    // vertex positions (no per-pass relaxation preview — deferred/
    // expensive, consistent with the whole-mesh Smooth ghost's own
    // restraint above), plus a P8-style cursor ring at the live drag
    // position (`smoothLoopCurX_`/`_Y_`). Independent of `lastHit_`/
    // CONS, drawn before the same `!lastHit_.hit` early-return as every
    // other gesture ghost above.
    private void drawSmoothLoopGhost(ImDrawList* dl, const ref Viewport vp) {
        if (smoothLoopArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && smoothLoopSeed_ >= 0 && smoothLoopSeed_ < cast(int)m.edges.length) {
                enum uint smoothLoopCol = IM_COL32(120, 255, 200, 220);   // smoothing green-blue (P8's own hue)
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());   // Pixel (§1.1), once (§3)
                foreach (ei; (*m).selectLoopEdges(cast(uint)smoothLoopSeed_)) {
                    if (ei < 0 || ei >= cast(int)m.edges.length) continue;
                    auto ringE = m.edges[ei];
                    ImVec2 ra, rb;
                    if (projectLocalPt(m.vertices[ringE[0]], vpAim, ra)
                     && projectLocalPt(m.vertices[ringE[1]], vpAim, rb))
                        dl.AddLine(ra, rb, smoothLoopCol, 2.5f);
                }
                ImVec2 cur = ImVec2(cast(float)smoothLoopCurX_, cast(float)smoothLoopCurY_);
                dl.AddCircle(cur, 14.0f, smoothLoopCol, 24, 2.5f);
                dl.AddCircleFilled(cur, 4.0f, smoothLoopCol, 16);
            }
        }
    }

    // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase
    // 4). MINOR-5: placed AFTER the LAST pre-`!lastHit_.hit`-return
    // ghost block above (P10 Move Loop, P11 Dup Loop, P12 Smooth+Loop)
    // rather than literally "after smooth" — Split (P9), Move Loop
    // (P10), Dup Loop (P11), and Smooth+Loop (P12) all now sit between
    // the whole-mesh Smooth ghost and this early-return too. Independent
    // of `lastHit_`/CONS
    // (over the PRIMARY, not the background), like every ghost above,
    // so a primary-only scene still shows it. Gated on
    // `!anyGestureArmed()` (mode ghosts win when armed — Pinned Decision
    // 5) AND `hoverOverMesh_` (the REV1 FIX-1 gate resolved in
    // `onMouseMotion`). Draw order — edge, then hatch, then square — so
    // the square reads on top and the hatch sits under the edge line.
    private void drawHoverHighlight(ImDrawList* dl, const ref Viewport vp) {
        if (!anyGestureArmed() && hoverOverMesh_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                // Pixel (§1.1), once for every branch below (§3). The
                // highlight is what the user aims BY, so it has to land on
                // the pixels the element is drawn at, not on where the layer
                // would sit at identity.
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());
                // ONE element — the one a press would grab (task 0484
                // follow-up), resolved by the press's own
                // `resolveGrabTarget`. This block used to paint the nearest
                // VERTEX and the nearest EDGE simultaneously, plus a hatch on
                // a boundary edge's face: three affordances answering "what
                // is near you". Now that a press grabs exactly one element,
                // showing more than that one misleads — the user aims by this
                // highlight, so it has to name what they will actually get.
                //
                // Switched on `hoverIndicatorElem()`, not on `hoverGrabElem_`:
                // that is the resolved target with the `showVertex`/`showEdge`
                // display toggles applied (task 0499). Both default ON, so the
                // painted result is unchanged unless the user turns one off.
                final switch (hoverIndicatorElem()) {
                case MoveElem.Vertex:
                    if (hoverGrabIndex_ >= 0 && hoverGrabIndex_ < cast(int)m.vertices.length) {
                        ImVec2 vc;
                        if (projectLocalPt(m.vertices[hoverGrabIndex_], vpAim, vc))
                            dl.AddRectFilled(
                                ImVec2(vc.x - kHoverVertSquareHalfPx, vc.y - kHoverVertSquareHalfPx),
                                ImVec2(vc.x + kHoverVertSquareHalfPx, vc.y + kHoverVertSquareHalfPx),
                                kHoverElemCol);
                    }
                    break;

                case MoveElem.Edge:
                    if (hoverGrabIndex_ >= 0 && hoverGrabIndex_ < cast(int)m.edges.length) {
                        auto he = m.edges[hoverGrabIndex_];
                        ImVec2 ea, eb;
                        if (projectLocalPt(m.vertices[he[0]], vpAim, ea)
                         && projectLocalPt(m.vertices[he[1]], vpAim, eb))
                            dl.AddLine(ea, eb, kHoverElemCol, kHoverEdgeWidthPx);
                    }
                    break;

                case MoveElem.Face:
                    // Cross-hatch + outline. ANY face under the cursor, not
                    // just a boundary edge's — the hatch used to be reachable
                    // only through `hoverBoundary_`, which is a fact about an
                    // EDGE, and left an interior polygon with no highlight at
                    // all even though a press there grabs it.
                    if (hoverGrabIndex_ >= 0 && hoverGrabIndex_ < cast(int)m.faces.length) {
                        ImVec2[] pts;
                        bool ok = true;
                        foreach (fvi; m.faces[hoverGrabIndex_]) {
                            ImVec2 p;
                            if (!projectLocalPt(m.vertices[fvi], vpAim, p)) { ok = false; break; }
                            pts ~= p;
                        }
                        if (ok && pts.length >= 3) {
                            hatchScreenPolygon(dl, pts, kHoverHatchCol,
                                              kHoverHatchSpacingPx, kHoverHatchWidthPx, vp);
                            foreach (i, pa; pts)
                                dl.AddLine(pa, pts[(i + 1) % pts.length],
                                           kHoverElemCol, kHoverEdgeWidthPx);
                        }
                    }
                    break;

                case MoveElem.None:
                    break;   // over the mesh but nothing resolved -> nothing to promise
                }
            }
        }
    }

    // Fill candidate-ring preview (MANDATORY opponent fix #2): its
    // OWN sibling gate — `penMode_ == Fill && fillRing_.length >= 3` —
    // deliberately NOT folded into the `hoverOverMesh_` block above.
    // Three corners as readily as four, because `quadOnly` off is a
    // measured build (task 0488).
    // `hoverOverMesh_` requires a pick within `topoPenPressPickPx`, which is
    // FALSE when hovering the center of an empty gap cell (the defining
    // Fill-mode case: no vertex/edge/face is anywhere near the
    // cursor) — nesting this there would make the preview never render
    // for that scenario. Still gated on `!anyGestureArmed()` (mode
    // ghosts win when armed, same precedent as every other ghost).
    private void drawFillRingPreview(ImDrawList* dl, const ref Viewport vp) {
        if (!anyGestureArmed() && penMode_ == PenMode.Fill
                                && fillRing_.length >= 3 && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                immutable size_t vlen2 = m.vertices.length;
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());   // Pixel (§1.1), once (§3)
                bool ok = true;
                ImVec2[] pts;
                pts.length = fillRing_.length;
                foreach (k, vi; fillRing_) {
                    if (vi >= vlen2 || !projectLocalPt(m.vertices[vi], vpAim, pts[k])) { ok = false; break; }
                }
                if (ok) {
                    hatchScreenPolygon(dl, pts, kFillPreviewCol,
                                      kHoverHatchSpacingPx, kHoverHatchWidthPx, vp);
                    foreach (k; 0 .. pts.length)
                        dl.AddLine(pts[k], pts[(k + 1) % pts.length],
                                   kFillPreviewCol, kHoverEdgeWidthPx);
                }
            }
        }
    }

    // Fill mode radius overlay (task 0477 continuation, the derived
    // radius law — full provenance in the PRIVATE toolcard,
    // toolcards/topology_pen/fill_radius_law_capture.md): a cosmetic
    // screen-space circle OUTLINE, centered on the LIVE cursor pixel,
    // sized to `fillRadiusPx_` (resolved in `onMouseMotion` above). Its
    // OWN sibling gate — `penMode_ == Fill && fillRadiusValid_` —
    // mirrors the candidate-cell preview immediately above and is,
    // for the identical reason, NOT folded into the `hoverOverMesh_`
    // block earlier in this function: it must still render while
    // hovering the open middle of a gap, where `hoverOverMesh_` is
    // false. Still gated on `!anyGestureArmed()` (mode ghosts win when
    // armed, same precedent as every other ghost). Re-polls the cursor
    // via `queryMouse` — the same draw()-time live-cursor idiom used
    // by this tool's own hover ghosts elsewhere in the codebase —
    // rather than any cached (e.x,e.y), so the circle keeps tracking
    // the cursor between motion events exactly like the derived law's
    // own "re-polled every redraw" cursor semantics. Draw-only: no
    // mesh read, no command, no undo interaction.
    private void drawFillRadiusOverlay(ImDrawList* dl) {
        if (!anyGestureArmed() && penMode_ == PenMode.Fill && fillRadiusValid_) {
            int qmx, qmy;
            queryMouse(qmx, qmy);
            dl.AddCircle(ImVec2(cast(float)qmx, cast(float)qmy), fillRadiusPx_,
                        kFillRadiusCol, kFillRadiusSegments, kFillRadiusThicknessPx);
        }
    }

    // The CONS-hit marker and the resolved snap-target highlight. Called
    // only when `lastHit_.hit` (the dispatcher early-returns otherwise).
    //
    // Re-resolve for THIS cell's camera — a multi-viewport draw may
    // run once per eligible cell, each with its own `vp`; the cached
    // `lastTarget_` (motion-time) stays what toolStateJson() reports.
    private void drawSnapTargetMarker(ImDrawList* dl, const ref Viewport vp) {
        auto ht = resolveHoverTarget(lastHit_, vp, topoPenPressPickPx(vp));

        enum uint markerCol = IM_COL32(255, 150, 0, 230);   // pen orange
        enum uint cyan      = IM_COL32(0, 220, 255, 230);   // snap highlight

        // Every point in this function is ALREADY WORLD — the CONS stage
        // publishes `lastHit_.point` / `.normal` / `.nearestVertPos` /
        // `.nearestEdgeA/B` through `ms.toWorldPoint` (0617,
        // toolpipe/stages/constrain.d:291-303, :375-387), and they are
        // anchored on the BACKGROUND layer, not on the primary. So this is
        // the canonical `projectWorldPt` block and it proves the
        // two-destination split is real rather than decorative.
        ImVec2 hitPt;
        bool   hitPtOk = projectWorldPt(lastHit_.point, vp, hitPt);
        if (hitPtOk) {
            // Hover marker: filled dot + ring ("free place-point" cursor).
            dl.AddCircleFilled(hitPt, 4.0f, markerCol, 16);
            dl.AddCircle(hitPt, 10.0f, markerCol, 24, 2.0f);

            // Normal pin — short line showing surface orientation.
            ImVec2 tip;
            if (projectWorldPt(lastHit_.point + lastHit_.normal * 0.15f, vp, tip))
                dl.AddLine(hitPt, tip, markerCol, 2.0f);
        }

        final switch (ht.kind) {
            case HoverTargetKind.Vertex: {
                ImVec2 vpt;
                if (projectWorldPt(lastHit_.nearestVertPos, vp, vpt))
                    dl.AddCircleFilled(vpt, 5.0f, cyan, 16);
                break;
            }
            case HoverTargetKind.Edge: {
                ImVec2 a, b;
                if (projectWorldPt(lastHit_.nearestEdgeA, vp, a)
                 && projectWorldPt(lastHit_.nearestEdgeB, vp, b))
                    dl.AddLine(a, b, cyan, 2.5f);
                break;
            }
            case HoverTargetKind.Face:
            case HoverTargetKind.None:
                break;   // marker only — no element to highlight
        }
    }

    // P3 (doc/topopen_p3_plan.md): ghost preview of an in-progress
    // drag-build — a line from the armed source A to the current
    // (CONS-snapped) release point, plus a line from whichever existing
    // neighbor(s) the classified case will auto-connect (Tri: N; Quad:
    // P and Q). No mesh mutation, no raycast — purely re-reads the
    // already-classified state and the packet-sourced `lastHit_`.
    private void drawBuildGhost(ImDrawList* dl, const ref Viewport vp) {
        // `hitPt` recomputed locally — pre-split it was shared with the
        // snap-target marker block above (`hitPtOk`).
        // TWO SPACES in one ghost, deliberately: `lastHit_.point` is the
        // CONS stage's WORLD hit on a BACKGROUND layer, while
        // `m.vertices[...]` are the PRIMARY layer's LOCAL coordinates. Each
        // end of the drawn line therefore takes a different projector, and
        // the type split is what makes that statable at all.
        ImVec2 hitPt;
        bool   hitPtOk = projectWorldPt(lastHit_.point, vp, hitPt);
        if (dragArmed_ && hitPtOk && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null && sourceVert_ >= 0 && sourceVert_ < cast(int)m.vertices.length) {
                enum uint ghostCol = IM_COL32(255, 210, 60, 220);
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());   // Pixel (§1.1)
                ImVec2 aPt;
                if (projectLocalPt(m.vertices[sourceVert_], vpAim, aPt))
                    dl.AddLine(aPt, hitPt, ghostCol, 2.0f);

                void ghostTo(int vi) {
                    if (vi < 0 || vi >= cast(int)m.vertices.length) return;
                    ImVec2 p;
                    if (projectLocalPt(m.vertices[vi], vpAim, p))
                        dl.AddLine(p, hitPt, ghostCol, 1.5f);
                }
                final switch (classifiedCase_) {
                    case BuildCase.Tri:  ghostTo(triN_);  break;
                    case BuildCase.Quad: ghostTo(quadP_); ghostTo(quadQ_); break;
                    case BuildCase.Edge:
                    case BuildCase.None: break;
                }
            }
        }
    }

    // Move drag affordance (P4's ghost, re-purposed by task 0484). P4
    // drew a line from the grabbed vertex's pre-commit position to the
    // live re-snap point, because the mesh did not move until release and
    // that line was the ONLY feedback. The drag is live now — the
    // geometry itself is the feedback — so the line would connect a point
    // to itself. What remains is a marker on the moving set, so the user
    // can still see WHICH element they grabbed once it is sitting under
    // the cursor: a small square per moving vertex, in the same green.
    private void drawMoveGhost(ImDrawList* dl, const ref Viewport vp) {
        if (moveArmed_ && meshSrc_ !is null) {
            auto m = mesh;
            if (m !is null) {
                enum uint  moveGhostCol = IM_COL32(80, 220, 120, 220);   // move green
                enum float halfPx       = 4.0f;
                const AimViewport vpAim = aimSpace(vp, primaryModelSpace());   // Pixel (§1.1), once (§3)
                foreach (vi; moveVerts_) {
                    if (vi >= m.vertices.length) continue;
                    ImVec2 p;
                    if (!projectLocalPt(m.vertices[vi], vpAim, p)) continue;
                    dl.AddRectFilled(ImVec2(p.x - halfPx, p.y - halfPx),
                                     ImVec2(p.x + halfPx, p.y + halfPx), moveGhostCol);
                }
            }
        }
    }

    // The duplicate ghost, shared by the Shift+RMB loop gesture and the
    // Shift+LMB single-edge one (task 0485): preview of the
    // coincident-then-dragged duplicate + its bridge quads, recomputed every
    // frame from the LIVE cursor delta. Mirrors the Move Loop ghost's
    // primitives (`resnapToBackground`/`projectPt`) — no mesh mutation, no
    // extrude, pure preview. Independent of `lastHit_`/CONS, drawn before the
    // same `!lastHit_.hit` early-return as every other gesture ghost.
    private void drawDupGhost(ImDrawList* dl, const ref Viewport vp,
                              const(int)[] edgeList, int dx, int dy) {
        auto m = mesh;
        if (m is null) return;
        enum uint dupCol = IM_COL32(60, 220, 140, 220);   // duplicate ghost green

        // Pixel (§1.1) for the source edge, once for the whole list (§3).
        const AimViewport vpAim = aimSpace(vp, primaryModelSpace());

        foreach (ei; edgeList) {
            if (ei < 0 || ei >= cast(int)m.edges.length) continue;
            auto edgeE = m.edges[ei];
            Vec3 a = m.vertices[edgeE[0]], b = m.vertices[edgeE[1]];

            // `aP`/`bP` were MIXED-SPACE for exactly the reason
            // `drawMoveLoopGhost`'s `ghostPos` was — a miss keeps the LOCAL
            // `a`/`b`, a hit took `resnapToBackground`'s then-WORLD answer.
            // Both branches are LOCAL now, so the predicted duplicate edge
            // and its bridge quad are drawn in one space.
            Vec3 aP = a, bP = b;   // default: miss (or off-screen) keeps coincident
            ImVec2 pa, pb;
            if (projectLocalPt(a, vpAim, pa)) {
                Vec3 hitA;
                if (resnapToBackground(a, cast(int)(pa.x + cast(float)dx),
                                       cast(int)(pa.y + cast(float)dy), vp, hitA)) aP = hitA;
            }
            if (projectLocalPt(b, vpAim, pb)) {
                Vec3 hitB;
                if (resnapToBackground(b, cast(int)(pb.x + cast(float)dx),
                                       cast(int)(pb.y + cast(float)dy), vp, hitB)) bP = hitB;
            }

            ImVec2 sa, sb, saP, sbP;
            bool ok = projectLocalPt(a, vpAim, sa) && projectLocalPt(b, vpAim, sb)
                   && projectLocalPt(aP, vpAim, saP) && projectLocalPt(bP, vpAim, sbP);
            if (!ok) continue;

            // The predicted bridge quad a-b-b'-a' + the new duplicate edge
            // a'-b' (heavier stroke), + a dot per predicted (dragged) vert.
            dl.AddLine(sa, sb,   dupCol, 1.5f);
            dl.AddLine(sb, sbP,  dupCol, 1.5f);
            dl.AddLine(sbP, saP, dupCol, 2.0f);
            dl.AddLine(saP, sa,  dupCol, 1.5f);

            dl.AddCircleFilled(saP, 4.0f, dupCol, 16);
            dl.AddCircleFilled(sbP, 4.0f, dupCol, 16);
        }
    }
}
