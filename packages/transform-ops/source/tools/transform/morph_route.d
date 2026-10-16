module tools.transform.morph_route;

// One routed transform seam writes the selected morph map while preserving the
// base mesh; only its four desktop homes may name the route (task 1069/1073).
// The executable ownership census lives in tests/unit/morph_route_census_test.d.

import math    : Vec3;
import vibe3d.mesh.core.mesh    : Mesh, MeshMap, MapKind, isMorphKind;
import vibe3d.mesh.core.mesh_morph : morphApply, morphRoutedStore;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SymmetryPacket;
import symmetry : mirrorPosition, mirroredEdit, walkMirrorPairs,
                  applySymmetryMirror, applySymmetryMirrorDelta;

/// Everything the routed write needs, resolved once per apply.
///
/// **Both arrays are VERTEX-ID indexed and MESH-LENGTH.** That is stated here
/// because the kernel this feeds has TWO index spaces side by side and they
/// are not the same: `applyXformMatrix`'s `baseline` is ORDINAL-parallel to
/// `indices`, while its `weightVerts` is vertex-id indexed and mesh-length.
/// Handing one array to both silently mis-indexes — and the whole-mesh case
/// (an empty selection, where the two spaces coincide) accidentally works, so
/// the first test anyone writes is the one that hides it. Keep these two vid
/// indexed and gather the ordinal array at the one place that needs it.
struct MorphRoute {
    /// `.init` (`unclassified`) means NO ROUTING — the whole struct is inert
    /// and every routed entry point tail-calls its unrouted twin.
    MapKind kind = MapKind.unclassified;

    /// The target map's name. Resolved BY NAME on every apply, never cached
    /// as a `MeshMap*`: `Mesh.removeMeshMap` splices the registry array and
    /// invalidates every outstanding pointer (plan R3).
    string name;

    /// The TRUE base position of every vertex — `dragBaseline`, which the
    /// routed path never writes. This is what `morphRoutedStore` subtracts.
    const(Vec3)[] base;

    /// The DISPLAYED position of every vertex at RUN START: base + the map's
    /// value at that moment. This is what the kernel evaluates from, which is
    /// what law L7 (`edits_accumulate`) forces — a second gesture must build
    /// on the first, not replace it.
    ///
    /// It is deliberately NOT `dragBaseline`: writing the morphed position
    /// into `dragBaseline` would make `restoreBaseline()` put a morphed
    /// position where the true base belongs, and the NEXT gesture would
    /// re-capture that as its base and stack a second delta on top of the
    /// first. That is the single most damaging bug this design has to avoid,
    /// and `edits_accumulate` is the test that catches it.
    const(Vec3)[] runPos;

    bool active() const {
        return isMorphKind(kind);
    }

    /// Active AND correctly sized for a mesh of `n` vertices. Every consumer
    /// gates on THIS, not on `active()` alone — a short array would otherwise
    /// index out of range on the tail of the moving set.
    bool covers(size_t n) const {
        return active() && base.length == n && runPos.length == n;
    }
}

/// The vertex's CURRENT displayed position under routing: the true base with
/// the map's live stored value applied. Reads the map through the caller's
/// already-resolved pointer so a per-vertex loop does no name lookup.
Vec3 routedDisplayPos(const(MeshMap)* map, const ref MorphRoute route, size_t vi) {
    const Vec3 b = route.base[vi];
    if (map is null) return b;
    return morphApply(b, map.entryOr(vi, defaultStored(b, route.kind)), route.kind, 1.0f);
}

/// What an ABSENT entry stores, in the map's own units: the zero delta for
/// the relative kind, the vertex's own base position for the absolute kind
/// ("stay at the base"). Feeding this to `morphApply` returns the base for
/// both kinds, which is exactly what "no entry" should draw as.
Vec3 defaultStored(Vec3 base, MapKind kind) {
    return (kind == MapKind.morphRelative) ? Vec3(0, 0, 0) : base;
}

/// Write `moved` (a POSITION in world space) into the map as the routed
/// store for vertex `vi`. Returns false when the map refused the write.
bool storeRouted(MeshMap* map, const ref MorphRoute route, size_t vi, Vec3 moved) {
    if (map is null) return false;
    return map.setEntry(vi, morphRoutedStore(route.base[vi], moved, route.kind));
}

// ---------------------------------------------------------------------------
// Routed symmetry: the READS move too, not just the writes. Under routing
// `mesh.vertices[i] == base[i]`, so a walk reading `mesh.vertices` would mirror
// the driver's UNMOVED base (position: the partner's morph overwritten; delta:
// a zero edit) and project the base instead of the drawn point. Both walks read
// `routedDisplayPos`. "The partner's entry CHANGED" cannot see the failure
// (absent -> present-zero is a change): assert the stored value EQUALS the mirror.
// ---------------------------------------------------------------------------

/// Routed twin of `applySymmetryMirror` (absolute position-copy). Tail-calls
/// the unrouted original when no target is bound, so there is exactly ONE
/// behaviour for the no-target case and it is the existing code path.
void applySymmetryMirrorRouted(Mesh* mesh, const ref SymmetryPacket sp,
                               const(bool)[] selected, bool[] outAlsoTouched,
                               const ref MorphRoute route)
{
    if (!route.covers(mesh.vertices.length)) {
        applySymmetryMirror(mesh, sp, selected, outAlsoTouched);
        return;
    }
    auto map = mesh.morphMapForWrite(route.name);
    if (map is null) return;
    // The on-plane projection reads and stores the DRAWN point (never the base).
    bool wrote = false;
    walkMirrorPairs!(i => routedDisplayPos(map, route, i),
                     (i, p) { wrote |= storeRouted(map, route, i, p); },
                     (i, mi, p) => mirrorPosition(sp, p))(mesh, sp, selected, outAlsoTouched);
    // ONE note per pass, never per vertex — mid-drag version stability is
    // intentional (the symmetry / falloff / snap caches key on it).
    if (wrote) {
        import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditScope;
        mesh.noteChange(MeshEditScope.Maps);
    }
}

/// Routed twin of `applySymmetryMirrorDelta` (topological symmetry). The
/// partner's "pre-existing deformation" that the unrouted twin preserves via
/// `baseline[mi]` is, under routing, its RUN position — `route.runPos[mi]`.
void applySymmetryMirrorDeltaRouted(Mesh* mesh, const ref SymmetryPacket sp,
                                    const(Vec3)[] baseline,
                                    const(bool)[] selected, bool[] outAlsoTouched,
                                    const ref MorphRoute route)
{
    if (!route.covers(mesh.vertices.length)) {
        applySymmetryMirrorDelta(mesh, sp, baseline, selected, outAlsoTouched);
        return;
    }
    auto map = mesh.morphMapForWrite(route.name);
    if (map is null) return;
    // The driver's edit is measured on the DRAWN surface, from its run position.
    bool wrote = false;
    walkMirrorPairs!(i => routedDisplayPos(map, route, i),
                     (i, p) { wrote |= storeRouted(map, route, i, p); },
                     (i, mi, p) => mirroredEdit(sp, route.runPos, i, mi, p))(mesh, sp, selected, outAlsoTouched);
    if (wrote) {
        import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditScope;
        mesh.noteChange(MeshEditScope.Maps);
    }
}
