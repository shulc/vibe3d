/// Which ITEM the camera ray strikes — the item-level counterpart of the
/// element pickers in `gpu_select.d` / `bvh_pick.d` (task 0647).
///
/// WHY A SEPARATE MODULE, and not another branch inside the element pickers.
/// Those answer "which vertex / edge / polygon OF THE PRIMARY LAYER", and they
/// are structurally tied to that: the GPU ID buffer is rendered from the
/// primary's VBO and `BvhPick` caches one mesh at a time. The question here is
/// a different one — "which of the document's items" — over a set that
/// deliberately INCLUDES the primary and every visible background layer, each
/// under its own item transform. Answering it inside the element path would
/// mean either re-rendering the ID buffer per layer or teaching the primary
/// picker about a layer array it has no business knowing.
///
/// The nearest-hit rule is MEASURED, not assumed: with two items along one ray
/// the reference highlights exactly one, the front-most, and its own click
/// picker returns that same item for that pixel. So this keeps a single global
/// `t` across all sources rather than a per-source answer the caller ranks.
///
/// SCOPE, stated because the gap is real and must not be discovered later.
/// This resolves MESH items only. An item with no geometry — the reference
/// image plane — is skipped here and is NOT hovered, because a plane's hit
/// test is a ray-versus-quad question plus a decision about what counts as a
/// hit (the whole rectangle, or only its opaque pixels) that task 0643 owns.
/// The reference DOES highlight a plane, by the same law and the same three
/// colours, so this module is knowingly incomplete on that axis — see
/// `pickItemAt`'s doc comment for what a caller may and may not conclude from
/// a miss.
module item_pick;

import bvh_pick : BvhPick, SurfaceHit;
import document : Document, Layer, kindInfo;
import math     : Vec3, ModelSpace, Viewport;
import mesh     : Mesh;

/// What the item ray found.
///
/// `layerIndex` is an index into `Document.layers`, which is the identity every
/// item-level command already takes (`layer.select index:N`), so a caller can
/// act on it without a second lookup. -1 with `hit == false` is a miss, and a
/// miss is a measurement: the reference paints zero pixels over empty space.
struct ItemHit {
    bool  hit;
    int   layerIndex = -1;
    float t          = float.infinity;   ///< ray parameter, world units
}

/// Per-mesh BVH cache for the item ray.
///
/// One `BvhPick` per mesh ADDRESS, exactly like the background-surface raycast
/// in the constrain stage: `BvhPick` holds a single mesh's tree and rebuilds it
/// whenever the mesh address or mutation version it was built from changes, so
/// sharing one instance across N layers would rebuild N trees every call. The
/// address is a stable key because `Layer` is a class and its interior `Mesh`
/// never moves (see `document.d`'s note on why `Layer` is not a struct).
///
/// Entries for meshes that are no longer reachable are pruned on each call, so
/// deleting or hiding a layer frees its tree without anyone having to
/// remember to say so.
final class ItemRayPicker {
    private BvhPick[size_t] _bvh;

    /// The visible item whose surface the ray through window pixel (mx, my)
    /// strikes FIRST.
    ///
    /// Skips: hidden items (nothing invisible is hoverable), and items that
    /// carry no geometry. The second skip is the scope gap named in the module
    /// comment — a miss therefore means "no MESH item is under the cursor",
    /// which is not the same statement as "no item is under the cursor" on a
    /// document containing an image plane. Callers must not report the stronger
    /// one.
    ItemHit pickItemAt(ref Document doc, int mx, int my, const ref Viewport vp) {
        // Prune first, so a long-lived picker over a document that keeps
        // replacing its layers does not accumulate trees for dead meshes. Done
        // per call rather than on a change signal: the cost is one pass over a
        // map with as many entries as there are visible mesh layers, and a
        // signal is one more thing that can be forgotten at a new mutation site.
        bool[size_t] live;
        foreach (lyr; doc.layers) {
            if (lyr is null || !lyr.hasMesh) continue;
            live[cast(size_t)lyr.meshOrNull()] = true;
        }
        size_t[] stale;
        foreach (addr, _; _bvh)
            if ((addr in live) is null) stale ~= addr;
        foreach (addr; stale) _bvh.remove(addr);

        ItemHit best;
        foreach (i, lyr; doc.layers) {
            if (lyr is null || !lyr.visible) continue;
            // `drawsGeometry`, not `hasMesh`: the set that can be hovered is
            // the set that is DRAWN as geometry. They agree today (the table
            // proves `drawsGeometry` implies `hasMesh` at compile time) and
            // the draw-side gate in the highlight pass reads the same bit, so
            // picking and painting cannot select different items.
            if (!kindInfo(lyr.kind).drawsGeometry) continue;

            const(Mesh)* m = lyr.meshOrNull();
            if (m is null || m.faces.length == 0) continue;

            immutable size_t addr = cast(size_t)m;
            auto pp = addr in _bvh;
            BvhPick bp;
            if (pp is null) {
                bp = new BvhPick();
                _bvh[addr] = bp;
            } else {
                bp = *pp;
            }

            SurfaceHit sh;
            // Each mesh through its OWN ModelSpace — a transformed item is
            // picked where it is DRAWN, not at its identity pose (task 0617's
            // rule, and the reason `pickSurface` takes the space rather than
            // assuming identity).
            if (!bp.pickSurface(mx, my, vp, *m, lyr.xform.modelSpace(), sh))
                continue;
            if (sh.t >= best.t) continue;
            best.hit        = true;
            best.layerIndex = cast(int)i;
            best.t          = sh.t;
        }
        return best;
    }
}
