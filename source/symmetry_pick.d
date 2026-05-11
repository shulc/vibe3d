module symmetry_pick;

import math    : Vec3;
import mesh    : Mesh;
import view    : View;
import editmode : EditMode;
import toolpipe.pipeline      : g_pipeCtx;
import toolpipe.packets       : SubjectPacket, SymmetryPacket;
import toolpipe.stage         : TaskCode;
import toolpipe.stages.symmetry : SymmetryStage;
import symmetry               : mirrorEdge, mirrorFace;

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
void symmetricSelectVertex(Mesh* mesh, ref View view, EditMode em,
                           int vi, bool deselect)
{
    if (deselect) mesh.deselectVertex(vi);
    else          mesh.selectVertex(vi);

    SymmetryPacket pkt;
    SymmetryStage  sym;
    if (!captureLiveSymmetry(mesh, view, em, pkt, sym)) return;
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
void symmetricSelectEdge(Mesh* mesh, ref View view, EditMode em,
                         int ei, bool deselect)
{
    if (deselect) mesh.deselectEdge(ei);
    else          mesh.selectEdge(ei);

    SymmetryPacket pkt;
    SymmetryStage  sym;
    if (!captureLiveSymmetry(mesh, view, em, pkt, sym)) return;
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
void symmetricSelectFace(Mesh* mesh, ref View view, EditMode em,
                         int fi, bool deselect)
{
    if (deselect) mesh.deselectFace(fi);
    else          mesh.selectFace(fi);

    SymmetryPacket pkt;
    SymmetryStage  sym;
    if (!captureLiveSymmetry(mesh, view, em, pkt, sym)) return;
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
// ---------------------------------------------------------------------------
private bool captureLiveSymmetry(Mesh* mesh, ref View view, EditMode em,
                                 out SymmetryPacket pkt, out SymmetryStage stage)
{
    if (g_pipeCtx is null) return false;
    stage = cast(SymmetryStage)
            g_pipeCtx.pipeline.findByTask(TaskCode.Symm);
    if (stage is null || !stage.enabled) return false;

    SubjectPacket subj;
    subj.mesh             = mesh;
    subj.editMode         = em;
    subj.selectedVertices = mesh.selectedVertices.dup;
    subj.selectedEdges    = mesh.selectedEdges.dup;
    subj.selectedFaces    = mesh.selectedFaces.dup;
    auto vp = view.viewport();
    auto state = g_pipeCtx.pipeline.evaluate(subj, vp);
    pkt = state.symmetry;
    return true;
}
