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
/// SCOPE (task 0643 closed the gap this used to declare). Two kinds of item
/// are resolved: MESH items, through the BVH, and IMAGE PLANES, through a
/// ray-versus-quad test. A plane carries no geometry, so a BVH cannot reach it;
/// `image_plane.rayHitsPlaneQuad` owns both the intersection and the decision
/// about what counts as a hit inside a bare rectangle, and that decision is
/// documented there rather than here.
///
/// THE TWO KINDS ARE RANKED, NOT MERGED, and the rank is read off our own draw
/// order rather than invented. `drawImagePlane` disables the depth TEST, which
/// also suppresses depth WRITES, and it runs first — so "every later pass wins
/// regardless of world position" (its own words). Geometry is therefore painted
/// over a plane even when the plane is nearer the eye, and a picker that let the
/// nearer plane win would highlight an item the user cannot see at that pixel.
/// So: any mesh hit beats any plane hit; within a kind, nearest `t` wins.
module item_pick;

import bvh_pick   : BvhPick, SurfaceHit;
import document   : Document, Layer, kindInfo;
import image_plane : rayHitsPlaneQuad, resolvePlacementFor, ImagePlanePlacement;
import math       : Vec3, ModelSpace, Viewport, screenPointToRay;
import mesh       : Mesh;
import view       : ViewPreset;

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
    /// Skips hidden items — nothing invisible is hoverable — and, for planes,
    /// anything the SAME `drawn` predicate the draw pass reads says this cell
    /// does not show. `cellPreset` / `cellOrtho` are that predicate's other two
    /// inputs: a `front` backdrop is drawn in the front cell and not in the top
    /// one, so it must be pickable in exactly the cell it is visible in and no
    /// other. Passing the wrong cell's preset makes a plane hoverable where
    /// nothing is painted, which is why they are parameters and not a lookup.
    ItemHit pickItemAt(ref Document doc, int mx, int my, const ref Viewport vp,
                       ViewPreset cellPreset, bool cellOrtho) {
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
        // A mesh hit ENDS it — see the module comment's ranking note. Returning
        // here rather than folding the plane loop into the same `t` compare is
        // the whole implementation of "geometry paints over a backdrop", and
        // doing it as an early return means the rule cannot be lost to a later
        // edit of the compare.
        if (best.hit) return best;

        // Planes. The ray is built ONCE, with the same pixel-centre convention
        // `BvhPick.pickSurface` uses (`mx + 0.5`), so a plane and a mesh are
        // asked about the same line through space — and `dir` is left
        // unnormalised for the same reason it is there: `t` then means the same
        // thing on both sides.
        Vec3 org, dir;
        screenPointToRay(mx + 0.5f, my + 0.5f, vp, org, dir);
        foreach (i, lyr; doc.layers) {
            if (lyr is null || !lyr.hasImagePlane) continue;
            // `drawn` folds visibility, a usable image AND this cell's preset —
            // one predicate, shared with the draw pass, so "pickable" and
            // "painted" cannot drift apart.
            immutable ImagePlanePlacement pl =
                resolvePlacementFor(doc, lyr, cellPreset, cellOrtho);
            if (!pl.drawn) continue;

            float t;
            if (!rayHitsPlaneQuad(pl, org, dir, t)) continue;
            if (t >= best.t) continue;
            best.hit        = true;
            best.layerIndex = cast(int)i;
            best.t          = t;
        }
        return best;
    }
}
