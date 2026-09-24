module symmetry_pick;

import math    : Vec3, Viewport;
import mesh    : Mesh;
import editmode : EditMode;
import seltype  : SelType;
import toolpipe.packets       : SubjectPacket, SymmetryPacket;
import toolpipe.stages.symmetry : SymmetryStage, liveSymmetryStage;
import toolpipe.subject        : evaluateSubject, SubjectSource;
import symmetry               : mirrorElement;
import operator               : VectorStack;

// ---------------------------------------------------------------------------
// Symmetry-aware interactive pick helpers — the POINTER-gesture door of the
// selection law (task 7144, gap 315): a click, paint stroke or region pick
// selects the element AND its mirror partner (`symmetry.mirrorElement`);
// deselecting drops the partner too. Script and command doors do not come
// through here and never pair. These helpers do NOT touch the authoring side
// or the pair's base side (the handle and the pair weight are fixed at the +X
// member, gap 318).
//
// Returns silently when:
//   * toolpipe / SymmetryStage isn't registered (unit tests),
//   * symmetry is currently disabled,
//   * the pair table isn't yet built (first evaluate after enable).
// ---------------------------------------------------------------------------

/// Select (or deselect when `deselect == true`) vertex `vi` and its
/// symmetric counterpart.
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
    if (vi < 0 || vi >= cast(int)mesh.vertices.length) return;

    immutable uint mi = mirrorElement(*mesh, pkt, EditMode.Vertices, cast(uint)vi);
    if (mi != ~0u) {
        if (deselect) mesh.deselectVertex(cast(int)mi);
        else          mesh.selectVertex(cast(int)mi);
    }
}

/// Select (or deselect when `deselect == true`) edge `ei` and its
/// symmetric counterpart.
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

    immutable uint me = mirrorElement(*mesh, pkt, EditMode.Edges, cast(uint)ei);
    if (me != ~0u) {
        if (deselect) mesh.deselectEdge(cast(int)me);
        else          mesh.selectEdge(cast(int)me);
    }
}

/// Select (or deselect when `deselect == true`) face `fi` and its
/// symmetric counterpart.
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

    immutable uint mf = mirrorElement(*mesh, pkt, EditMode.Polygons, cast(uint)fi);
    if (mf != ~0u) {
        if (deselect) mesh.deselectFace(cast(int)mf);
        else          mesh.selectFace(cast(int)mf);
    }
}

// ---------------------------------------------------------------------------
// captureLiveSymmetry — fetch the live SymmetryPacket and SymmetryStage
// from the global toolpipe. Gated on the stage being registered AND
// enabled — pipeline.evaluate has cross-stage side effects (FalloffStage
// caches the upstream workplane normal on every fire), so we skip the
// call when symmetry is off.
//
// Task 1904 Stage 2: one shared capture for `MeshTransform` and the three
// pointer helpers above (the stage lookup is `liveSymmetryStage()`, task 7144).
// It only READS the packet — the gate on `enabled` is a reader's gate.
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
    stage = liveSymmetryStage();
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
