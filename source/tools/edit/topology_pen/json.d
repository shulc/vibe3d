// PenStateJsonOps — the Topology Pen's test-introspection surface: the
// `toolStateJson()` override that answers `GET /api/tool/state`, and the
// `final switch` tag helpers that turn each internal enum into a stable wire
// token (`moveElemTag`, `penGestureTag`, `hoverTargetKindTag`,
// `buildCaseTag`, `slideDeclineTag`).
//
// Mixed into `TopologyPenTool` (`tools.edit.topology_pen.tool`) with
// `mixin PenStateJsonOps;`. Bodies are a verbatim cut/paste out of the class;
// only this wrapper is new, and no symbol was opened for the move -- a
// mixed-in member reads the class's `private` state exactly as before.
//
// The tag helpers live HERE, next to their only caller, rather than beside
// the enums they switch over: each is exhaustive on purpose, so adding a
// gesture or a decline reason is a compile error in this file instead of a
// silently unlabelled field on the wire. That contract is about the wire
// format, which is what this module is.
//
// Imports nothing deliberately -- a template mixin resolves identifiers in
// the scope it is mixed into, so `JSONValue`, `Vec3` and the enums come from
// tool.d; repeating them here would be inert.
module tools.edit.topology_pen.json;

mixin template PenStateJsonOps() {
    // `gestureOn_` as a stable wire token for `/api/tool/state` (task 0483).
    // A `final switch` (the `BuildCase`/`SlideDecline` precedent) rather than
    // an `IntEnumEntry` table: this is not a `Param`, nothing parses it back,
    // and the exhaustive switch makes a newly added action a COMPILE error
    // here instead of a silently unlabelled state field.
    // `moveElem_` as a stable wire token for `/api/tool/state` (task 0484),
    // same `final switch` discipline as `penGestureTag` below.
    private static string moveElemTag(MoveElem k) {
        final switch (k) {
        case MoveElem.None:   return "none";
        case MoveElem.Vertex: return "vertex";
        case MoveElem.Edge:   return "edge";
        case MoveElem.Face:   return "face";
        }
    }

    private static string penGestureTag(PenGesture a) {
        final switch (a) {
        case PenGesture.PlaceOrMove:    return "place_or_move";
        case PenGesture.Build:          return "build";
        case PenGesture.Slide:          return "slide";
        case PenGesture.Smooth:         return "smooth";
        case PenGesture.Split:          return "split";
        case PenGesture.AddLoop:        return "add_loop";
        case PenGesture.Remove:         return "remove";
        case PenGesture.MoveLoop:       return "move_loop";
        case PenGesture.DupLoop:        return "dup_loop";
        case PenGesture.SmoothLoop:     return "smooth_loop";
        }
    }

    // The remaining enum→token mappings `toolStateJson` needs, extracted
    // from its body under the same `final switch` discipline as
    // `moveElemTag`/`penGestureTag` above (see the comment at
    // `moveElemTag`): compile-time exhaustive, so a new enum member is a
    // compile error here instead of a silently unlabelled state field.
    private static string hoverTargetKindTag(HoverTargetKind k) {
        final switch (k) {
        case HoverTargetKind.None:   return "none";
        case HoverTargetKind.Vertex: return "vertex";
        case HoverTargetKind.Edge:   return "edge";
        case HoverTargetKind.Face:   return "face";
        }
    }

    private static string buildCaseTag(BuildCase c) {
        final switch (c) {
        case BuildCase.None: return "none";
        case BuildCase.Edge: return "edge";
        case BuildCase.Tri:  return "tri";
        case BuildCase.Quad: return "quad";
        }
    }

    private static string slideDeclineTag(SlideDecline d) {
        final switch (d) {
        case SlideDecline.None:           return "none";
        case SlideDecline.NoEdge:         return "no_edge";
        case SlideDecline.NoContinuation: return "no_continuation";
        }
    }

    // ----- Test-introspection (task 0234 pattern, GET /api/tool/state) ----
    // A Vec3 as a `[x, y, z]` JSON array — the shape every position/normal
    // field below reports in.
    private static JSONValue vec3Json(Vec3 v) {
        return JSONValue([cast(double)v.x, cast(double)v.y, cast(double)v.z]);
    }

    override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("mesh.topoPen");
        root["hit"]         = JSONValue(lastHit_.hit);
        root["point"]       = vec3Json(lastHit_.point);
        root["normal"]      = vec3Json(lastHit_.normal);
        root["layer"]       = JSONValue(lastHit_.layer);
        root["face"]        = JSONValue(lastHit_.face);
        root["nearestVert"] = JSONValue(lastHit_.nearestVert);
        root["nearestEdge"] = JSONValue(lastHit_.nearestEdge);

        // P1 (doc/topopen_p1_plan.md): the resolved hover snap-target,
        // nested so the P0 root fields above stay intact for the existing
        // Tier-C test.
        auto hv = JSONValue.emptyObject;
        hv["hit"]    = JSONValue(lastHit_.hit);
        hv["point"]  = vec3Json(lastHit_.point);
        hv["normal"] = vec3Json(lastHit_.normal);
        hv["targetKind"] = JSONValue(hoverTargetKindTag(lastTarget_.kind));
        hv["targetVert"] = JSONValue(lastTarget_.vert);
        hv["targetEdge"] = JSONValue(lastTarget_.edge);
        root["hover"] = hv;

        // P3 (doc/topopen_p3_plan.md): the armed drag-build state, for
        // Tier-C tests to assert the classified case (incl. a press on a
        // BARE-EDGE vertex -> "tri", the KILLER-1 regression guard) without
        // driving a full build.
        root["sourceVert"] = JSONValue(sourceVert_);
        root["dragArmed"]  = JSONValue(dragArmed_);
        root["case"] = JSONValue(buildCaseTag(classifiedCase_));

        // P4 (doc/topopen_p4_plan.md): the armed Move/Place disambiguation
        // state, for Tier-C tests to assert WHICH gesture a plain-LMB press
        // armed (and the grabbed vertex, for Move) without driving a full
        // release.
        root["placeArmed"]  = JSONValue(placeArmed_);
        root["moveArmed"]   = JSONValue(moveArmed_);
        // Which element the armed Move grabbed, and how many vertices it is
        // dragging (task 0484). `grabbedVert` alone cannot say: it is -1 for
        // BOTH "nothing armed" and "an edge/face is armed", which are
        // opposite states. `moveDirty` separates "armed but nothing has
        // actually moved yet" from "the live drag has already written the
        // mesh" — the difference between a press and a press+drag, invisible
        // from geometry alone until the release records its entry.
        root["moveElem"]      = JSONValue(moveElemTag(moveElem_));
        root["moveVertCount"] = JSONValue(cast(int)moveVerts_.length);
        root["moveDirty"]     = JSONValue(moveDirty_);
        root["grabbedVert"] = JSONValue(grabbedVert_);

        // P6 (doc/topopen_p6_addloop_plan.md Phase 5): the armed Add Loop
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and tracked ratio without driving a full release.
        root["addLoopArmed"] = JSONValue(addLoopArmed_);
        root["addLoopSeed"]  = JSONValue(addLoopSeed_);
        root["addLoopRatio"] = JSONValue(cast(double)addLoopRatio_);
        // "at the Middle" (doc/tasks/work/0480-topopen-addloop-middle.md):
        // the sticky option itself plus the EFFECTIVE fraction a release
        // would commit right now (`addLoopFrac(addLoopRatio_)`), so a Tier-C
        // test can observe the override without driving a full release.
        // `addLoopRatio` above stays the RAW cursor ratio — the two differ
        // exactly when the option is on.
        root["addLoopMiddle"] = JSONValue(addLoopMiddle_);
        root["addLoopFrac"]   = JSONValue(cast(double)addLoopFrac(addLoopRatio_));

        // P7 (doc/topopen_p7_slide_plan.md Phase 4): the armed Slide
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and the tracked scalar without driving a full release.
        // `slideDeltaK` replaces V1's `slideTA`/`slideTB` pair: the measured
        // law has ONE signed world-space scalar shared by both endpoints, and
        // no per-endpoint `[0,1]` fraction exists to report.
        root["slideArmed"]  = JSONValue(slideArmed_);
        root["slideSeed"]   = JSONValue(slideSeed_);
        root["slideDeltaK"] = JSONValue(cast(double)slideDeltaK_);
        root["slideNbrA"]   = JSONValue(slideNbrA_);
        root["slideNbrB"]   = JSONValue(slideNbrB_);

        // Why the most recent Slide press did not arm
        // (doc/tasks/work/0482-topopen-move-nonvertex.md item 3 follow-up).
        // Read-only; see `slideDecline_`'s own doc comment for the lifecycle.
        // The three fields above (`slideArmed`/`slideSeed`/`slideNbr*`) describe
        // an ARMED gesture and all read "nothing" on either decline — these two
        // are what separate the two declines:
        //   "none"            -> armed normally, or no Slide press yet/since a
        //                        reset (nothing to explain).
        //   "no_edge"         -> no primary edge within the snap radius: a real
        //                        pick miss. `slideDeclineSeed` is -1.
        //   "no_continuation" -> an edge WAS resolved (`slideDeclineSeed` names
        //                        it) but neither endpoint's rail resolves, so
        //                        the hold-fixed contract leaves nothing to
        //                        slide. A deliberate decline, NOT a miss —
        //                        do not score it as a pick failure.
        root["slideDeclineReason"] = JSONValue(slideDeclineTag(slideDecline_));
        root["slideDeclineSeed"]   = JSONValue(slideDeclineSeed_);

        // P8 (doc/topopen_p8_smooth_plan.md Phase 4): the armed Smooth
        // gesture's state, for Tier-C tests to assert click-vs-drag pass
        // counts without driving a full release. `smoothPassCount` goes
        // through the SAME law helper (`smoothPassesForDragDx`, fully
        // clamped) that `onMouseButtonUp`'s Smooth branch will apply if
        // released now — one function, so this readback cannot drift from
        // the committed count (NIT-3: reporting an unclamped value here
        // would make that "will apply" doc-comment false for an extreme
        // drag).
        root["smoothArmed"]     = JSONValue(smoothArmed_);
        root["smoothPassCount"] = JSONValue(smoothPassesForDragDx(smoothDragDx_));

        // P9 (doc/topopen_p9_split_plan.md Phase 4): the armed Split
        // gesture's state, for Tier-C tests to assert the picked source
        // vertex and tracked snap target without driving a full release.
        root["splitArmed"]      = JSONValue(splitArmed_);
        root["splitSourceVert"] = JSONValue(splitSourceVert_);
        root["splitTargetVert"] = JSONValue(splitTargetVert_);

        // P10 (doc/topopen_p10_moveloop_plan.md Phase 4): the armed Move
        // Loop gesture's state, for Tier-C tests to assert the picked seed
        // edge and gathered moving-set size without driving a full release.
        root["moveLoopArmed"]     = JSONValue(moveLoopArmed_);
        root["moveLoopSeed"]      = JSONValue(moveLoopSeed_);
        root["moveLoopVertCount"] = JSONValue(cast(int)moveLoopVerts_.length);

        // P11 (doc/topopen_p11_duploop_plan.md Phase 4): the armed Dup Loop
        // gesture's state, for Tier-C tests to assert the picked seed edge
        // and gathered loop-edge count without driving a full release.
        root["dupLoopArmed"]     = JSONValue(dupLoopArmed_);
        root["dupLoopSeed"]      = JSONValue(dupLoopSeed_);
        root["dupLoopEdgeCount"] = JSONValue(cast(int)dupLoopEdges_.length);

        // Task 0485: the Shift+LMB single-edge duplicate's own arm, kept
        // separate from the loop gesture's so a test (and a reader of the
        // state) can tell which of the two is in flight.
        root["dupEdgeArmed"]     = JSONValue(dupEdgeArmed_);
        root["dupEdgeSeed"]      = JSONValue(dupEdgeSeed_);
        root["dupEdgeEdgeCount"] = JSONValue(cast(int)dupEdgeEdges_.length);

        // P12 (doc/topopen_p12_smoothloop_plan.md Phase 4): the armed
        // Smooth+Loop gesture's state, for Tier-C tests to assert the
        // picked seed edge and gathered moving-set size without driving a
        // full release. NIT-3 parity with the whole-mesh Smooth's own
        // `smoothPassCount`: reports the CLAMPED value
        // `onMouseButtonUp`'s Smooth+Loop branch will actually apply if
        // released now. It is NOT the same LAW, though — this path keeps the
        // forked, unmeasured travel-based pacing (`kSmoothLoopPassStridePx`).
        root["smoothLoopArmed"]     = JSONValue(smoothLoopArmed_);
        root["smoothLoopSeed"]      = JSONValue(smoothLoopSeed_);
        root["smoothLoopVertCount"] = JSONValue(cast(int)smoothLoopVerts_.length);
        int smoothLoopPassCount = 1 + cast(int)(smoothLoopDragPx_ / kSmoothLoopPassStridePx);
        if (smoothLoopPassCount > MAX_TOPOPEN_SMOOTH_PASSES) smoothLoopPassCount = MAX_TOPOPEN_SMOOTH_PASSES;
        root["smoothLoopPassCount"] = JSONValue(smoothLoopPassCount);

        // The sticky Mode dropdown's CURRENT value, as its wire tag
        // ("move" / "duplicate" / ... / "smooth"), read straight out of
        // `penModeTable` via `wireTagForValue` so this can never drift from
        // the `Param.intEnum_` schema `params()` publishes or from the tag
        // `tool.attr mesh.topoPen mode <tag>` accepts. Read-only
        // observability: without it an automated run can SET the mode but
        // cannot verify the setting took, so a Fill-mode no-op and a
        // still-in-Move-mode press are indistinguishable from outside. Flat
        // root key (the `hover{}`/`hoverIndicator{}` nesting is for grouped
        // per-element state; this is one tool-wide scalar, like
        // `addLoopMiddle`).
        root["penMode"] = JSONValue(wireTagForValue(penModeTable, cast(int)penMode_));

        // The two dropdown-adjacent sticky flags, and the gesture the LAST
        // unmodified-LMB press actually resolved to under them (task 0483).
        // `lmbAction` is the router's own decision made visible: it is what
        // separates "Edge Loop was on, so the press armed a loop move" from
        // "Edge Loop was on but the press found no ring seed", which the arm
        // bools alone cannot tell apart from outside.
        root["edgeLoop"]  = JSONValue(edgeLoop_);
        root["edgeSlide"] = JSONValue(edgeSlide_);
        // The third sticky flag (task 0496): which CANDIDATE SET the pen's
        // snap target may resolve to — border-only when off, the interior
        // too when on.
        root["innerSnap"] = JSONValue(innerSnap_);
        // The ORIENTATION half of that same admission policy (task 0538):
        // whether a candidate whose own normal faces away from the viewer may
        // still be the pen's snap target. Published for the same reason
        // `innerSnap` is — the flag changes which element a drag lands on, so
        // an automated run has to be able to read back which branch it set.
        root["backFace"] = JSONValue(backFace_);
        // The fourth sticky flag (task 0494): whether a Remove-mode edge
        // dissolve KEEPS the vertices whose whole polygon fan it consumed.
        // Observability matters more here than for the others — the flag
        // changes what a click DESTROYS, so a run must be able to read back
        // which branch it is about to take.
        root["keepVertex"] = JSONValue(keepVertex_);
        root["lmbAction"] = JSONValue(penGestureTag(gestureOn_[InputButton.Left]));

        // Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md Phase
        // 6): a NEW nested object (deliberately NOT the existing `hover{}`
        // object above, which carries the P0/P1 CONS/background fields) so
        // Tier-C tests for that path stay intact.
        auto hi = JSONValue.emptyObject;
        hi["overMesh"]     = JSONValue(hoverOverMesh_);
        hi["nearestVert"]  = JSONValue(hoverNearestVert_);
        hi["nearestEdge"]  = JSONValue(hoverNearestEdge_);
        hi["isBoundary"]   = JSONValue(hoverBoundary_);
        hi["boundaryFace"] = JSONValue(hoverBoundaryFace_);
        // WHAT a press here would grab, and therefore the one element this
        // indicator draws (task 0484 follow-up). Distinct from `nearestVert`
        // /`nearestEdge` above, which are ∞-threshold "what is closest"
        // answers: this one is pick-range-limited and single, and it is the
        // only way an automated run can check that the highlight and the
        // press agree — they share `resolveGrabTarget`, and this field is
        // what proves it from outside.
        hi["grabElem"]  = JSONValue(moveElemTag(hoverGrabElem_));
        hi["grabIndex"] = JSONValue(hoverGrabIndex_);
        // What `draw()` actually PAINTS — `grabElem` filtered by the
        // `showVertex`/`showEdge` display toggles (task 0499). Reported
        // separately from `grabElem` above precisely because the toggles must
        // not change what a press grabs: an automated run can see the marker
        // disappear (`shownElem` = "none") while the grab target stays put.
        hi["shownElem"] = JSONValue(moveElemTag(hoverIndicatorElem()));
        hi["showVertex"] = JSONValue(showVertex_);
        hi["showEdge"]   = JSONValue(showEdge_);
        root["hoverIndicator"] = hi;

        return root;
    }
}
