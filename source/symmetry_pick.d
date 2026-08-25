module symmetry_pick;

import math    : Vec3, Viewport;
import mesh    : Mesh;
import editmode : EditMode;
import seltype  : SelType;
import toolpipe.pipeline      : g_pipeCtx;
import toolpipe.packets       : SubjectPacket, SymmetryPacket;
import toolpipe.stage         : TaskCode;
import toolpipe.stages.symmetry : SymmetryStage;
import toolpipe.subject        : evaluateSubject, SubjectSource;
import symmetry               : mirrorEdge, mirrorFace;
import operator               : VectorStack;

// ---------------------------------------------------------------------------
// Symmetry-aware interactive pick helpers — phase 7.6c interactive flow.
//
// `MeshSelect` already wraps `/api/select` with symmetric auto-add + anchor
// baseSide. The interactive picking paths in `app.d` (lasso, click, etc.)
// call `mesh.selectVertex/Edge/Face` directly to stay tight; these helpers
// wrap each direct call so the editor's mouse-click picks behave the same
// as the headless HTTP path.
//
// Returns silently when:
//   * toolpipe / SymmetryStage isn't registered (unit tests),
//   * symmetry is currently disabled,
//   * the pair table isn't yet built (first evaluate after enable).
//
// For deselect, the mirror counterpart is also deselected so the
// click-twice-to-toggle UX is consistent across both sides.
// ---------------------------------------------------------------------------

/// Select (or deselect when `deselect == true`) vertex `vi` and its
/// symmetric counterpart. Anchors `baseSide` on the user-picked vertex
/// on select.
void symmetricSelectVertex(Mesh* mesh, Viewport vp, EditMode em,
                           int vi, bool deselect)
{
    // TASK 1906 STAGE 3 — THE INTERACTIVE PICK'S DELIVERY BOUNDARY, and it is
    // here because this module IS that boundary: `mesh.selectVertex/Edge/Face`
    // publish through `noteSelectionChange`, which accumulates and never
    // delivers, and the editor's click / paint / lasso paths reach them only
    // through these three helpers (`input_router.d`, `input_frame_state.d` and
    // `/api/pick` in `http_providers.d`). Measured, not assumed: with delivery
    // consuming the frame-drain words, `test_selection` / `test_lasso_select` /
    // `test_falloff_lasso_paint` / `test_element_pick_fresh_hover` left ~860
    // frames of `flags=Marks sel=Vertex|Edge|Face` for the drain, and a
    // per-call-site census of the six scalar setters named exactly one caller
    // at delivery depth 0: this file.
    //
    // ONE delivery per picked ELEMENT, covering the element and its mirror —
    // hence the batch: the counterpart write must not be a second delivery, and
    // a helper that returned early (symmetry off, pair table not built) must
    // still deliver the write it already made, which is what the `scope(exit)`
    // pair guarantees at all five return points.
    mesh.beginDeliveryBatch();
    scope(exit) { mesh.deliverAccumulated(); mesh.endDeliveryBatch(); }
    if (deselect) mesh.deselectVertex(vi);
    else          mesh.selectVertex(vi);

    SymmetryPacket pkt;
    SymmetryStage  sym;
    if (!captureLiveSymmetry(mesh, vp, em, pkt, sym)) return;
    if (pkt.pairOf.length != mesh.vertices.length) return;
    if (vi < 0 || vi >= cast(int)mesh.vertices.length) return;

    int mi = pkt.pairOf[vi];
    if (mi >= 0 && mi != vi) {
        if (deselect) mesh.deselectVertex(mi);
        else          mesh.selectVertex(mi);
    }
    if (!deselect)
        sym.anchorAt(mesh.vertices[vi]);
}

/// Select (or deselect when `deselect == true`) edge `ei` and its
/// symmetric counterpart, anchoring `baseSide` on the user-picked
/// edge's midpoint on select.
void symmetricSelectEdge(Mesh* mesh, Viewport vp, EditMode em,
                         int ei, bool deselect)
{
    // One delivery per picked element — see `symmetricSelectVertex`.
    mesh.beginDeliveryBatch();
    scope(exit) { mesh.deliverAccumulated(); mesh.endDeliveryBatch(); }
    if (deselect) mesh.deselectEdge(ei);
    else          mesh.selectEdge(ei);

    SymmetryPacket pkt;
    SymmetryStage  sym;
    if (!captureLiveSymmetry(mesh, vp, em, pkt, sym)) return;
    if (ei < 0 || ei >= cast(int)mesh.edges.length) return;

    uint me = mirrorEdge(*mesh, pkt, cast(uint)ei);
    if (me != ~0u && me != cast(uint)ei) {
        if (deselect) mesh.deselectEdge(cast(int)me);
        else          mesh.selectEdge(cast(int)me);
    }
    if (!deselect) {
        auto e = mesh.edges[ei];
        Vec3 anchor = (mesh.vertices[e[0]] + mesh.vertices[e[1]]) * 0.5f;
        sym.anchorAt(anchor);
    }
}

/// Select (or deselect when `deselect == true`) face `fi` and its
/// symmetric counterpart, anchoring `baseSide` on the user-picked
/// face's centroid on select.
void symmetricSelectFace(Mesh* mesh, Viewport vp, EditMode em,
                         int fi, bool deselect)
{
    // One delivery per picked element — see `symmetricSelectVertex`.
    mesh.beginDeliveryBatch();
    scope(exit) { mesh.deliverAccumulated(); mesh.endDeliveryBatch(); }
    if (deselect) mesh.deselectFace(fi);
    else          mesh.selectFace(fi);

    SymmetryPacket pkt;
    SymmetryStage  sym;
    if (!captureLiveSymmetry(mesh, vp, em, pkt, sym)) return;
    if (fi < 0 || fi >= cast(int)mesh.faces.length) return;

    uint mf = mirrorFace(*mesh, pkt, cast(uint)fi);
    if (mf != ~0u && mf != cast(uint)fi) {
        if (deselect) mesh.deselectFace(cast(int)mf);
        else          mesh.selectFace(cast(int)mf);
    }
    if (!deselect) {
        auto f = mesh.faces[fi];
        if (f.length == 0) return;
        Vec3 sum = Vec3(0, 0, 0);
        foreach (vi; f) sum = sum + mesh.vertices[vi];
        sym.anchorAt(sum * (1.0f / cast(float)f.length));
    }
}

// ---------------------------------------------------------------------------
// captureLiveSymmetry — fetch the live SymmetryPacket and SymmetryStage
// from the global toolpipe. Gated on the stage being registered AND
// enabled — pipeline.evaluate has cross-stage side effects (FalloffStage
// caches the upstream workplane normal on every fire), so we skip the
// call when symmetry is off.
//
// Task 1904 Stage 2: this used to be three copies of the same function —
// this one, `commands/mesh/select.d :: MeshSelect.captureSymmetryPacket`
// and the inline block in `commands/mesh/transform.d :: MeshTransform.
// evaluate` — same findByTask(TaskCode.Symm) + stage.enabled gate, same
// R3 comment, same "selType left at its default (Vertex)" note, same
// `get!SymmetryPacket` copy. Collapsed here (the widest signature — it
// hands back the stage too, which the interactive `symmetricSelectVertex`/
// `symmetricSelectEdge`/`symmetricSelectFace` helpers below need for
// `anchorAt`; `MeshSelect` ignores the returned stage and does its own
// `findByTask` lookup for `anchorAt` instead) and made non-private so both
// command sites call it instead of rebuilding it. Their only real
// difference was the viewport expression, so that stays a parameter.
//
// `vp` is `lazy`: callers build it from `effectiveViewport()`, which is
// cheap to call but not side-effect-free to call unconditionally — on a
// headless/direct-constructed command with no resolved-viewport provider
// it falls back to `view.viewportWith(...)`, which dereferences `view`
// (see command.d's `effectiveViewport()` doc). Before this function
// existed, each of the three call sites computed the viewport only
// *inside* its own `g_pipeCtx !is null` / `stage.enabled` guard;
// collapsing them here must not turn that conditional read into an
// unconditional one at the call site. `lazy` defers evaluation to the
// one read below, after both gates, so `mesh, effectiveViewport(), em`
// at a call site costs nothing when this function returns early.
public bool captureLiveSymmetry(Mesh* mesh, lazy Viewport vp, EditMode em,
                                out SymmetryPacket pkt, out SymmetryStage stage)
{
    if (g_pipeCtx is null) return false;
    stage = cast(SymmetryStage)
            g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
    if (stage is null || !stage.enabled) return false;

    // selType left at its default (Vertex): symmetry pairing is a
    // geometry-element operation (SYMM mirrors vertex pairs, see
    // doc/item_mode_transform_plan.md §Q2 — "not consumed" in item mode),
    // and none of this function's three callers has a SelType/SelTypeOrder
    // to read (plan §1.3 — one of the seven sites that freeze Vertex).
    SubjectPacket subj;
    VectorStack   vts;
    evaluateSubject(subj, vts, SubjectSource(mesh, em, SelType.Vertex, vp));
    if (auto p = vts.get!SymmetryPacket()) pkt = *p;
    return true;
}
