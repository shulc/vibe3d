module tools.transform.morph_route;

/// The morph ROUTING seam's one home (task 1069).
///
/// "Routing" is the measured law L2: with a morph map selected, the SAME
/// transform that would move the base writes into the map instead and leaves
/// `mesh.vertices` completely alone.
///
/// ─── WHY THE SEAM IS HERE AND NOT ON `Mesh` (plan R2) ──────────────────────
///
/// The obvious place is a hook on the vertex write. It is the wrong place.
/// `mesh.vertices` is written from ~55 statements across ~25 files, and the
/// transform path in particular writes it for THREE different reasons: an
/// edit, a RESTORE of the run baseline (`restoreBaselinePrefix`, run every
/// single apply), and a session CANCEL. A mesh-level hook would have to tell
/// those apart, and getting that wrong turns a restore into a morph write.
///
/// Placing the seam at the kernel's write instead means the restore, the
/// cancel, `snapshot.d` and `command_wrapper.d` are all untouched and CANNOT
/// be misread as edits — they keep writing the base, which under routing is
/// exactly what they should do. Do not "simplify" this into a mesh-level hook.
///
/// ─── WHY THE SEAM IS ON THE CALLER, NOT INSIDE `symmetry.d` ────────────────
///
/// `applySymmetryMirror` / `applySymmetryMirrorDelta` have SEVEN production
/// callers across three unrelated subsystems, and most of them do NOT route
/// their own primary write: `PushTool`, `BendTool`, `LinearAlignTool` and
/// `RadialAlignTool` all reach the mirror through
/// `TransformTool.applySymmetryToDrag`, and `commands/mesh/transform.d` and
/// `commands/mesh/symmetrize.d` call it outside any tool at all.
///
/// A `MorphRoute` parameter INSIDE those functions would therefore make one
/// user gesture write the primary vertex to the base and its mirrored partner
/// to the map — corrupting BOTH surfaces from a single action. So `symmetry.d`
/// is not modified at all; the routed forms live here as separate overloads
/// that only the one routed tool ever calls, and the completeness gate is
/// mechanical:
///
///     grep -rl 'MorphRoute' source/ | sort
///
/// must print exactly this file plus `xform_kernels.d`, `xfrm_apply.d`,
/// `xfrm_transform.d`, `transform.d` and `commands/mesh/morph_edit.d`.
/// Anything else in that output is an unreviewed second routing site.

import math    : Vec3;
import mesh    : Mesh, MeshMap, MapKind, isMorphKind;
import mesh_morph : morphApply, morphRoutedStore;
import toolpipe.packets : SymmetryPacket;
import symmetry : mirrorPosition, mirrorDirection, projectOnPlane,
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
// Routed symmetry.
//
// **The reads move too, not just the writes.** Both unrouted twins compute
// their mirror from a READ of `mesh.vertices[i]` — the driver's post-fold
// position. Under routing `mesh.vertices[i] == base[i]` for EVERY vertex (that
// is the entire point of the design), so a naive "copy of the twin with the
// write substituted" would:
//
//   * in the position twin, mirror the driver's UNMOVED base onto the
//     partner — and, worse, OVERWRITE any morph the partner already had with
//     that unmoved value;
//   * in the delta twin, compute `delta == 0` and write the partner back to
//     its own run position — a mirror that does nothing at all.
//
// Both failures are invisible to an assertion of the form "the partner's entry
// CHANGED", because absent -> present-zero is a change. The test must assert
// the partner's stored value EQUALS the mirrored delta.
//
// The ON-PLANE branch needs the same treatment for a different reason: it
// writes the DRIVER's own position (`mesh.vertices[i] = projectOnPlane(...)`).
// Left unrouted it would be the one place a routed gesture still moves the
// base; substituted naively it would project the base rather than the drawn
// point and silently break the "centre stays on the plane" contract.
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
    if (!sp.enabled) return;
    if (sp.pairOf.length != mesh.vertices.length) return;
    auto map = mesh.morphMapForWrite(route.name);
    if (map is null) return;

    bool wrote = false;
    foreach (i; 0 .. mesh.vertices.length) {
        if (i >= selected.length || !selected[i]) continue;
        if (sp.onPlane[i]) {
            // Project the DRAWN point and store the projection — never touch
            // mesh.vertices, and never project the base.
            wrote |= storeRouted(map, route, i,
                                 projectOnPlane(sp, routedDisplayPos(map, route, i)));
            continue;
        }
        int mi = sp.pairOf[i];
        if (mi < 0 || mi == cast(int) i) continue;
        if (mesh.isVertexHidden(mi)) continue;   // R3 (task 0613), same placement
        bool mirrorAlsoSelected =
            (mi < cast(int) selected.length) && selected[mi];
        if (mirrorAlsoSelected) {
            int iSign = (i < sp.vertSign.length) ? sp.vertSign[i] : 0;
            if (iSign != sp.baseSide) continue;
        }
        wrote |= storeRouted(map, route, mi,
                             mirrorPosition(sp, routedDisplayPos(map, route, i)));
        if (mi < cast(int) outAlsoTouched.length)
            outAlsoTouched[mi] = true;
    }
    // ONE note per pass, never per vertex — mid-drag version stability is
    // intentional (the symmetry / falloff / snap caches key on it).
    if (wrote) {
        import mesh_edit_delta : MeshEditScope;
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
    if (!sp.enabled) return;
    if (sp.pairOf.length != mesh.vertices.length) return;
    auto map = mesh.morphMapForWrite(route.name);
    if (map is null) return;

    bool wrote = false;
    foreach (i; 0 .. mesh.vertices.length) {
        if (i >= selected.length || !selected[i]) continue;
        if (sp.onPlane[i]) {
            wrote |= storeRouted(map, route, i,
                                 projectOnPlane(sp, routedDisplayPos(map, route, i)));
            continue;
        }
        int mi = sp.pairOf[i];
        if (mi < 0 || mi == cast(int) i) continue;
        if (mesh.isVertexHidden(mi)) continue;
        bool mirrorAlsoSelected =
            (mi < cast(int) selected.length) && selected[mi];
        if (mirrorAlsoSelected) {
            int iSign = (i < sp.vertSign.length) ? sp.vertSign[i] : 0;
            if (iSign != sp.baseSide) continue;
        }
        // The driver's edit displacement, measured on the DRAWN surface:
        // routed position now, minus where it sat at run start.
        const Vec3 delta = routedDisplayPos(map, route, i) - route.runPos[i];
        wrote |= storeRouted(map, route, mi,
                             route.runPos[mi] + mirrorDirection(sp, delta));
        if (mi < cast(int) outAlsoTouched.length)
            outAlsoTouched[mi] = true;
    }
    if (wrote) {
        import mesh_edit_delta : MeshEditScope;
        mesh.noteChange(MeshEditScope.Maps);
    }
}
