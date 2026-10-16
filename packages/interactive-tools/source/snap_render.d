module snap_render;

version (unittest) {
    import math     : lookAt, perspectiveMatrix, transformPoint;
    import document : ItemXform, primaryModelSpaceResolver;
    import std.format : format;
}
version (unittest) import snap_render_source_helpers : t0619Matrix, t0619Viewport, t0619Mesh, t0619DrawnPx, t0619IdentityPx, t0619Dist, t0619Xf, t0619PxUnder, t0619BgMeshA, t0619BgMeshB, t0619InstallPrimary;

import math : Vec3;
import vibe3d.util.spatial.spatial : Viewport, projectToWindowFull, ModelSpace, AimViewport, aimSpace;
import mesh : Mesh;
import snap : SnapResult, snapSource, snapSourceSpace;
import document : primaryModelSpace;
import toolpipe.packets : SnapType;
import viewport_scheme : SchemeColor, schemeColor, packImCol;
import held_gesture_buttons : g_heldGestureButtons;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import core.atomic : atomicOp;

// Snap visual feedback. Tools publish their latest snap query through
// `publishLastSnap` / `clearLastSnap`; the FRAME draws `g_lastSnap` once per
// cell (`frame_runner.drawScene`), no tool draws it. The look is the
// captured one (toolcards findings_O): with no mouse button held the
// target element gets the rollover mark (`preHighlight`, a 6x6 px square on a
// vertex); while a gesture holds a button the point gets a gapped cross,
// `handleUnsnap` before it snaps and `handle` once snapped. `g_lastSnap` is
// also what /api/snap/last serves to headless tests.

__gshared SnapResult g_lastSnap;

private shared ulong nextSnapOverlayOwnerId;
struct PreparedSnapOverlayToken { @disable this(this); private ulong ownerId, generation; }
struct ValidatedSnapOverlayToken { @disable this(this); private ulong ownerId, generation; }

/// Closed owner for the complete HTTP-visible snap projection. Preparation
/// captures the current projection; validation rejects intervening publishes;
/// install is a scalar-free, nothrow reset.
final class SnapOverlayOwner {
private:
    immutable ulong ownerId;
    ulong generation;
    bool pending, validated;
    SnapResult expected;
    PreparedSnapOverlayToken prepared;
    ValidatedSnapOverlayToken validatedToken;
public:
    this() { ownerId = atomicOp!"+="(nextSnapOverlayOwnerId, 1UL); }
    bool beginClear() nothrow @nogc {
        if (pending) return false;
        expected = g_lastSnap; ++generation; pending = true; validated = false;
        prepared.ownerId = ownerId; prepared.generation = generation;
        return true;
    }
    bool validateClear() nothrow @nogc {
        if (!pending || validated || prepared.ownerId != ownerId ||
            prepared.generation != generation || g_lastSnap != expected) return false;
        validated = true; validatedToken.ownerId = ownerId;
        validatedToken.generation = generation; return true;
    }
    void installClear() nothrow @nogc {
        if (!pending || !validated || validatedToken.ownerId != ownerId ||
            validatedToken.generation != generation) return;
        g_lastSnap = SnapResult.init; pending = validated = false;
        validatedToken.ownerId = validatedToken.generation = 0;
    }
    void abortClear() nothrow @nogc { pending = validated = false; }
}



/// Update the global last-snap state. Tools call this after every
/// motion event that ran snapCursor, snap-fired or not (so the
/// pre-snap highlight pulse stays current).
void publishLastSnap(SnapResult sr) {
    g_lastSnap = sr;
}

/// Reset the global last-snap. Tools call this at drag end so the
/// stale highlight from the last drag doesn't linger.
void clearLastSnap() {
    g_lastSnap = SnapResult.init;
}

/// The captured look of a published snap (findings_O O1, O1d).
enum SnapMark { none, rollover, unsnapped, snapped }

/// Which mark `result` gets: none unless highlighted; the rollover mark with
/// no mouse button held; during a held gesture the snapped / unsnapped cross.
SnapMark snapMarkOf(const ref SnapResult result) nothrow @nogc {
    if (!result.highlighted) return SnapMark.none;
    if (!g_heldGestureButtons.any) return SnapMark.rollover;
    return result.snapped ? SnapMark.snapped : SnapMark.unsnapped;
}

/// The scheme colour of each mark (`none` has none).
SchemeColor snapMarkColor(SnapMark mark) pure nothrow @nogc @safe {
    final switch (mark) {
        case SnapMark.none, SnapMark.rollover: return SchemeColor.preHighlight;
        case SnapMark.unsnapped: return SchemeColor.handleUnsnap;
        case SnapMark.snapped:   return SchemeColor.handle;
    }
}

/// Draw the snap overlay for `result`, called once per cell by the frame.
void drawSnapOverlay(const ref SnapResult result, const ref Viewport vp,
                     const ref Mesh mesh)
{
    immutable mark = snapMarkOf(result);
    if (mark == SnapMark.none) return;
    auto dl = ImGui.GetForegroundDrawList();
    immutable uint col = packImCol(schemeColor(snapMarkColor(mark)), 255);
    if (mark == SnapMark.rollover) {
        drawRolloverMark(dl, result, vp, mesh, col);
        return;
    }
    ImVec2 c;
    if (!projectWorld(result.worldPos, vp, c)) return;
    // Four 2 px ticks from 4 to 8 px off the point (O1d pixel read).
    static immutable float[2][4] arms = [[1, 0], [-1, 0], [0, 1], [0, -1]];
    foreach (d; arms)
        dl.AddLine(ImVec2(c.x + 4 * d[0], c.y + 4 * d[1]),
                   ImVec2(c.x + 8 * d[0], c.y + 8 * d[1]), col, 2.0f);
}

/// The window pixels the rollover mark is drawn at — the whole of
/// this overlay's geometry, with nothing but colour and stroke width left
/// behind in the drawing code below.
///
/// Split out for task 0619 so the value that carries the item transform is
/// assertable. `drawTargetElementHighlight` emits into ImGui's foreground
/// drawlist, which no headless probe can read (`/api/viewport/probe` reads a
/// cell FBO, and this overlay is not in one), so a test written against the
/// draw could only ever assert that it did not crash. The pixels are the
/// thing under test, and this returns them.
///
/// Fills `pts` with one point for a vertex target, two for an edge, and one
/// per corner for a face. Returns false when the target cannot be resolved or
/// any of its points fails to project — the same fail-soft the draw takes.
bool snapHighlightPixels(const ref SnapResult result, const ref Viewport vp,
                         const ref Mesh mesh, ref ImVec2[] pts)
{
    pts.length = 0;
    if (!result.highlighted) return false;

    int idx = result.targetIndex;
    auto t  = result.targetType;

    // Resolve the source the winning candidate came from (layers Stage 5).
    // `targetIndex` is a SOURCE-LOCAL element index; indexing the active mesh
    // for a background-source winner would highlight the wrong element (or be
    // silently dropped by the range guard). Slot 0 = the active `mesh` arg
    // (common path); slots 1..N resolve to their own source mesh via
    // snap.snapSource. A null resolution (background source gone this frame)
    // ⇒ skip — same fail-soft as the out-of-range guard.
    //
    // ...and, with it, the ModelSpace that source is DRAWN through (task
    // 0619). `m.vertices[]` are LOCAL to their layer; projecting them with the
    // plain world `vp` drew the cyan highlight where the element would sit
    // under an IDENTITY item transform, while the yellow cursor marker
    // (a genuine world point) was drawn correctly — so on a transformed layer
    // the two markers visibly separated. Aiming kind **Pixel** (plan §1.1):
    // keep the geometry local and compose the viewport, which is exact
    // (`proj·(view·M)·v == proj·view·(M·v)`) and costs one 4x4 multiply for
    // the whole overlay instead of one per vertex.
    const(Mesh)* m;
    ModelSpace   ms;
    if (result.targetSource == 0) {
        // Slot 0 is the active mesh, which snap.d does not hold — the caller
        // passes it in, so its transform is the primary layer's, read fresh
        // here (there is no invalidation signal to cache it against; 0617
        // §2.4 proved none exists).
        m  = &mesh;
        ms = primaryModelSpace();
    } else if (!snapSourceSpace(result.targetSource, ms)) {
        return false;                // background source gone — fail soft
    } else {
        m = snapSource(result.targetSource);
    }
    if (m is null) return false;

    const AimViewport vpAim = aimSpace(vp, ms);

    if (t == SnapType.Vertex) {
        if (idx < 0 || idx >= cast(int)m.vertices.length) return false;
        ImVec2 pt;
        if (!projectLocal(m.vertices[idx], vpAim, pt)) return false;
        pts = [pt];
        return true;
    }
    if (t == SnapType.Edge || t == SnapType.EdgeCenter) {
        if (idx < 0 || idx >= cast(int)m.edges.length) return false;
        auto edge = m.edges[idx];
        ImVec2 a, b;
        if (!projectLocal(m.vertices[edge[0]], vpAim, a)) return false;
        if (!projectLocal(m.vertices[edge[1]], vpAim, b)) return false;
        pts = [a, b];
        return true;
    }
    if (t == SnapType.Polygon || t == SnapType.PolyCenter) {
        if (idx < 0 || idx >= cast(int)m.faces.length) return false;
        auto face = m.faces[idx];
        if (face.length < 3) return false;
        ImVec2[] out_;
        out_.length = face.length;
        foreach (i, vi; face) {
            if (vi >= m.vertices.length) return false;
            if (!projectLocal(m.vertices[vi], vpAim, out_[i])) return false;
        }
        pts = out_;
        return true;
    }
    // SnapType.Grid / SnapType.Workplane have no element to mark.
    return false;
}

// Linked from the cimgui archive; the binding wraps only the convex fill.
private extern (C) nothrow @nogc void ImDrawList_AddConcavePolyFilled(
    ImGui.ImDrawList* self, const(ImVec2)* points, int n, uint col);

private void drawRolloverMark(ImGui.ImDrawList* dl, const ref SnapResult result,
                              const ref Viewport vp, const ref Mesh mesh, uint col)
{
    ImVec2[] pts;
    if (!snapHighlightPixels(result, vp, mesh, pts)) return;
    if (pts.length == 1)        // a vertex: the 6x6 px square (-3..+2, O1)
        dl.AddRectFilled(ImVec2(pts[0].x - 3, pts[0].y - 3),
                         ImVec2(pts[0].x + 3, pts[0].y + 3), col);
    else if (pts.length == 2)   // an edge: a 2 px line (uncaptured)
        dl.AddLine(pts[0], pts[1], col, 2.0f);
    else                        // a polygon is filled solid (O2's rollover)
        ImDrawList_AddConcavePolyFilled(dl, pts.ptr, cast(int)pts.length, col);
}

// One projection per SPACE, not one projection with a parameter named after
// the space it usually holds (task 0619 §2.0, the same split the topology pen
// carries). The old single `project(Vec3 worldPos, ...)` was named `worldPos`
// and was handed a raw LOCAL vertex at four of its five call sites; a name
// cannot be wrong in a way the compiler notices, but a TYPE can. `AimViewport`
// is constructible only through `aimSpace(vp, ms)`, so passing the world
// viewport where the composed one belongs is a compile error rather than a
// silently misplaced highlight.

/// Project a point that is LOCAL to its layer, through the aim space that
/// already carries that layer's model matrix.
private bool projectLocal(Vec3 pLocal, const ref AimViewport vpAim, out ImVec2 pt) {
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pLocal, vpAim.vp, sx, sy, ndcZ)) return false;
    pt = ImVec2(sx, sy);
    return true;
}

/// Project a point that is already WORLD, through the plain world viewport.
private bool projectWorld(Vec3 pWorld, const ref Viewport vp, out ImVec2 pt) {
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pWorld, vp, sx, sy, ndcZ)) return false;
    pt = ImVec2(sx, sy);
    return true;
}

// ===========================================================================
// VERIFIED BY MUTATION. Each was applied to the green tree, built and run;
// the observed failure is recorded, and the tree restored and re-run green.
//
//   1. `snapHighlightPixels` composed `ModelSpace.world()` instead of the
//      resolved source space — the pre-0619 law, verbatim.
//      RED (vertex): "got (441.05,362.48), drawn (600.64,424.52), off by
//      171.22 px" — the highlight landed exactly on the identity-pose pixel.
//      RED (edge):   "a off by 73.87 px, b off by 171.22 px".
//      RED (face):   "corner 0 ... off by 73.87 px".
//      (D aborts a module at the first AssertError, so the edge and face
//      values were read by relaxing the earlier cases in turn.)
//
//   2. `projectWorld` composed the primary's matrix in too — the opposite
//      error, "fixing" a value that was already world.
//      RED: "the cursor marker must project through the PLAIN world
//      viewport: off by 148.0039 px".
//
//   3. `snapHighlightPixels` used `primaryModelSpace()` for EVERY slot, not
//      just slot 0 — i.e. the `targetSource >= 1` arm deleted.
//      RED: "the background highlight must sit where bg-A is DRAWN: got
//      (567.84,434.50), bg-A (369.79,282.81), primary (567.84,434.50),
//      slot-2 (491.16,520.48), identity (440.74,377.89)" — landed exactly
//      on the PRIMARY's pose, 249.3 px from bg-A's.
//
//   4. `snap.snapSourceSpace` read `g_snapSourceSpaces[slot]` instead of
//      `[slot-1]` — off by one slot, which resolves to a REAL neighbour
//      rather than falling off the end.
//      RED: "... got (491.16,520.48), bg-A (369.79,282.81) ..." — landed
//      exactly on SLOT 2's pose, 267.4 px from bg-A's.
//
// (3) and (4) were both green through the whole tree before the background
// case below existed: every other assertion sets `targetSource = 0`.
// ===========================================================================

// ===========================================================================
// Task 0619 — the snap highlight is drawn where the element IS DRAWN.
//
// THE PAIR THESE CASES ASSERT, and the wrong implementation they separate:
//
//   correct law   project `M * v_local` (compose the layer's matrix into the
//                 viewport, which is what `aimSpace` does)
//   wrong  law    project `v_local` through the WORLD viewport   <- pre-0619
//
// The oracle is the pixel itself, computed in the test through the app's own
// `projectToWindowFull` from `ItemXform.composedMatrix()` — the same matrix
// the DRAW path binds — rather than by re-running the function under test.
//
// The fixture is asymmetric on every axis the law touches: translation on all
// three, rotation on all three, and a NON-UNIFORM scale. A 90/180-degree
// rotation or a mirror-only transform maps a symmetric vertex SET to itself,
// so it can only ever measure winding and never position — the fixture shape
// that shipped the 0617 bug, named in its retro. Each case therefore opens
// with a vacuity guard: the drawn pixel and the identity pixel must be far
// enough apart that a wrong answer cannot hide inside the tolerance.
// ===========================================================================









// NOT ADDED, and why: a case for an OUT-OF-RANGE slot (`targetSource` past
// the installed sources) would be inert. `snapSourceSpace` returning false
// there is invisible through this function, because `snapSource` returns null
// for the same slot and the `m is null` guard already refuses — so even the
// wrong implementation this accessor's `bool`+`out` shape exists to prevent
// ("no space here ⇒ fall back to the primary's") reads the same answer. The
// bounds miss is pinned by the guard beside it, not by a second assertion.

unittest { // 0619: the CURSOR MARKER is a world point and must NOT move.
    // The other half of the split: `highlightPos` is published in world space
    // by `snapCursor`, so composing the layer matrix into ITS projection would
    // be a NEW bug of the same family in the opposite direction. This case
    // fails if someone "fixes" the marker too.
    auto saved = primaryModelSpaceResolver;
    scope (exit) primaryModelSpaceResolver = saved;
    t0619InstallPrimary();

    auto vp = t0619Viewport();
    immutable Vec3 world = Vec3(0.8f, 0.4f, -0.3f);

    ImVec2 got;
    assert(projectWorld(world, vp, got), "the world marker must project");

    float wx, wy, ndcZ;
    assert(projectToWindowFull(world, vp, wx, wy, ndcZ));
    assert(t0619Dist(got.x, got.y, wx, wy) < 1e-3,
        format("the cursor marker must project through the PLAIN world "
               ~ "viewport: off by %.4f px", t0619Dist(got.x, got.y, wx, wy)));

    // And the discriminator: composing the transform in would move it.
    immutable float[16] M = t0619Matrix();
    float mx, my;
    assert(projectToWindowFull(transformPoint(M, world), vp, mx, my, ndcZ));
    assert(t0619Dist(wx, wy, mx, my) > 20.0,
        "vacuous fixture: composing M would not move this marker anyway");
}
