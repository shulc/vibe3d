module tools.slice.slice_tool;

import bindbc.sdl;
import bindbc.opengl;
import std.json : JSONValue;
import std.math : sqrt, sin, cos, PI;
import ImGui = d_imgui;
import d_imgui.imgui_h;   // ImDrawList / ImVec2 / IM_COL32 for the RMB gap HUD (task 0288)

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import operator : VectorStack;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, FullCircleHandler, ToolHandles, gizmoSize, getGizmoPixels, drawWorldSegment, drawWorldQuad;
import viewport_scheme : schemeColor, SchemeColor;
import document : primaryModelSpace;
import tools.create.create_common : currentWorkplaneFrame, pickWorkplaneFrame, WorkplaneFrame;
// Reuse MoveTool's dominant-axis selector for the Ctrl axis-constraint (task
// 0286): the SAME screen-direction → world-axis math the Move gizmo's Ctrl lock
// uses, so Slice's Ctrl constraint is byte-consistent with Move's, not reinvented.
import tools.transform.move : chooseConstraintAxis;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind;
import prepared_slice_activation : PreparedSliceActivationOwner;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_slice_deactivate : PreparedSliceDeactivateOwner;
import command_history : PreparedHistoryKind;
import document : Layer;
import mesh_edit_delta : MeshEditScope;

struct PreparedSliceActivationImage {
    MeshSnapshot before;
    MeshCacheKey armedKey;
    uint[] restrictFaces;
    bool valid;
    void clear() nothrow @nogc {
        before = MeshSnapshot.init; armedKey = MeshCacheKey.init;
        restrictFaces = null; valid = false;
    }
}

struct PreparedSliceDeactivateImage {
    bool valid, expectedActive, expectedPreviewLive, expectedHaveBefore;
    int expectedDragPart, expectedCtrlAxis;
    bool expectedHaveRaw, expectedSnapTempInvert, expectedHaveFrozen;
    bool expectedPendingAxisClassify, expectedHasLine, expectedDrawGesture;
    bool expectedCtrlPending, expectedGapDrag;
    size_t expectedArmedAddr; ulong expectedArmedMutVer;
    MeshSnapshot expectedLive, expectedBefore;
    bool commitEligible;
    void clear() nothrow @nogc {
        expectedLive = MeshSnapshot.init; expectedBefore = MeshSnapshot.init;
        valid = commitEligible = false;
    }
}

// ---------------------------------------------------------------------------
// SliceAxis (task 0269, S3; owner-revised task 0284) — the OVERRIDE that sets the
// cut plane's EXTRUSION DIRECTION to a world axis (`X`/`Y`/`Z`) or the user-supplied
// `vector` (`Custom`). The `axis` is NOT the normal: the slice plane is the drawn
// line EXTRUDED along the axis direction (n = normalize(cross(lineDir, axisDir))),
// so it ALWAYS contains BOTH drawn points — the axis just swaps the extrusion
// direction for a world axis / custom vector. There is NO `Free` value: the
// reference Slice's Axis control offers only {X, Y, Z, Custom} (owner-confirmed).
// The DEFAULT plane orientation is NOT an enum value at all — it is the FROZEN
// drag-defined plane (the drawn line extruded along the work-plane normal captured
// once at the gesture that drew the line; see `frozenNormal_` / `axisLocked_`). The
// override is engaged only once the user writes the `axis` attribute (`axisLocked_`
// — set in onParamChanged, cleared on tool activation and on a fresh line redraw),
// so a plain drag with no axis change reproduces the drawn-line plane exactly (the
// S0 `slice.json` golden).
//
// The integer VALUES stay 1..4 (unchanged from the S3 enum) so the pure
// math.planeForSlice law is untouched: it still reads 1=X, 2=Y, 3=Z, 4=Custom,
// and its internal `default` (mode 0) is the "extrude along the work plane normal"
// construction the tool passes when NO override is locked. Mode 0 is therefore
// the runtime "no override" wire value; it is simply not offered as a
// user-selectable SliceAxis.
enum SliceAxis : int { X = 1, Y = 2, Z = 3, Custom = 4 }

// The planeForSlice `axisMode` the tool passes when NO axis override is locked:
// the "drawn line ⟂ (frozen) work plane" construction (planeForSlice's default).
enum int SLICE_AXIS_DRAG = 0;

static immutable IntEnumEntry[4] sliceAxisTable = [
    IntEnumEntry(cast(int)SliceAxis.X,      "x",      "X"),
    IntEnumEntry(cast(int)SliceAxis.Y,      "y",      "Y"),
    IntEnumEntry(cast(int)SliceAxis.Z,      "z",      "Z"),
    IntEnumEntry(cast(int)SliceAxis.Custom, "custom", "Custom"),
];

// classifyPlaneAxis (owner fix 1, task 0284; owner-revised for the extrusion-
// direction model) — map a drag plane's EXTRUSION DIRECTION (the frozen work-plane
// normal the line was extruded along) to the SliceAxis that reproduces the SAME
// plane, so the Tool-Properties dropdown reflects it. Since the axis is the
// EXTRUSION direction (not the cut normal), classifying this direction and feeding
// it back through planeForSlice's cross(lineDir, axisDir) rebuilds the identical
// plane. If the (unit) direction is aligned with a world axis to within `tol`
// (|dir·axis| ≥ tol, sign-agnostic — the extrusion sign does not change the cut),
// it classifies to that axis (X/Y/Z), for which planeForSlice uses the same world
// axis ⇒ the same plane. Otherwise it classifies to Custom and hands back
// `vector` = normalize(dir); planeForSlice's Custom mode then extrudes along
// EXACTLY that direction, so the cut is byte-identical. `vector` is always set to
// normalize(dir) (only consulted by the caller for the Custom result). Pure —
// unit-tested without a GL context.
SliceAxis classifyPlaneAxis(Vec3 dir, out Vec3 vector, float tol = 0.999f) {
    import std.math : fabs;
    Vec3 nn = normalize(dir);
    vector = nn;
    if (fabs(nn.x) >= tol) return SliceAxis.X;
    if (fabs(nn.y) >= tol) return SliceAxis.Y;
    if (fabs(nn.z) >= tol) return SliceAxis.Z;
    return SliceAxis.Custom;
}

// ---------------------------------------------------------------------------
// SliceGapSide (task 0275, S9) — the reference "Offset Side": where the Gap
// band sits relative to the cut plane. The integer VALUES are the wire contract
// the kernel (mesh_ops.cut.cutByPlaneEx → splitAlongCutLoop) reads directly, so keep
// them 0/1/2 in lockstep with the switch there.
//   Center   — symmetric: both shells recede ±gap/2 from the plane.
//   Positive — the +n-side shell takes the full gap along +n; the other stays.
//   Negative — the −n-side shell takes the full gap along −n; the other stays.
// (Total shell separation is always exactly `gap` for all three.)
enum SliceGapSide : int { Center = 0, Positive = 1, Negative = 2 }

static immutable IntEnumEntry[3] sliceGapSideTable = [
    IntEnumEntry(cast(int)SliceGapSide.Center,   "center",   "Center"),
    IntEnumEntry(cast(int)SliceGapSide.Positive, "positive", "Positive"),
    IntEnumEntry(cast(int)SliceGapSide.Negative, "negative", "Negative"),
];

// ---------------------------------------------------------------------------
// sliceSplitGap (task 0291) — the ONE shared helper for Split + Caps + Gap,
// called identically from BOTH split-gap call sites (`sliceFromBaseline` below
// and `SliceTool.applyHeadless`) so they cannot drift. Routes through
// `mesh_ops.cut.cutByPlaneSplitGap` — TWO REAL parallel plane cuts at
// `center ± offset·n` with the slab between them deleted, so every seam sits
// on a real edge∩plane intersection and each remaining shell's cap is always
// planar + simple. This replaces the single-cut + fixed along-edge slide
// (`cutByPlaneEx`'s own gap block), which overshoots at a graze vertex on
// dense/curved oblique geometry and produces a self-intersecting cap (the
// reported bug; see doc/slice_gap_two_cut_plan.md).
//
// When the two cuts do NOT fully separate the mesh (`separated == false` — a
// short clipped line that doesn't span the whole shape), silently dropping
// the gap would be a REGRESSION versus today's slide (which does open a gap
// for such partial cuts on simple meshes). Instead, roll the two cuts back
// via the snapshot already taken and fall back to the legacy single-cut+gap
// slide, preserving today's partial-cut behaviour exactly.
// ---------------------------------------------------------------------------
size_t sliceSplitGap(ref Mesh mesh, Vec3 p, Vec3 n, bool clipped, Vec3 s, Vec3 e,
                     bool caps, float gap, int gapSide, const uint[] restrict) {
    MeshSnapshot snap = MeshSnapshot.capture(mesh);
    bool separated;
    // TWO batches, not one, and the reason is the rollback between them (task
    // 1903 Stage E3). `snap.restore` replaces the whole `Mesh` value and stamps
    // through `commitRestored`, which by design never consults the batch frame
    // — so it must not run inside an open one. Each batch therefore spans
    // exactly its own kernel call, which is also E2's settled shape for a
    // caller. UNRECORDED: this path's undo is the caller's whole-mesh snapshot
    // until Stage L4 (commands) / Stage M (the tool's session-edit pair).
    size_t nc;
    {
        auto ed = MeshEditBatch.unrecorded(mesh, kCutEditScope);
        nc = ed.cutByPlaneSplitGap(p, n, clipped, s, e, caps, gap, gapSide,
                                   separated, restrict);
        ed.close();
    }
    if (separated) return nc;
    // PARTIAL cut: the two planes did not disconnect the mesh ⇒ no band to
    // remove ⇒ NO gap would open. Roll back and reproduce today's behaviour.
    snap.restore(mesh);
    PlaneCutLoops loops;
    size_t nLegacy;
    {
        auto ed = MeshEditBatch.unrecorded(mesh, kCutEditScope);
        nLegacy = ed.cutByPlaneEx(p, n, clipped, s, e, /*split*/true, caps, loops,
                                  1e-5f, restrict, gap, gapSide);
        ed.close();
    }
    return nLegacy;
}

// ---------------------------------------------------------------------------
// sliceFromBaseline — the shared cut kernel wrapper (the single point that
// turns a Start→End line into a plane cut). RESTORES `baseline` onto `mesh`
// FIRST, then cuts with the plane through the line perpendicular to
// `wpNormal`, returning the number of faces split (0 = the line missed every
// face). The mandatory restore is what makes the live preview NON-CUMULATIVE:
// dragging the line through many positions never stacks cut upon cut — every
// call reproduces exactly the single cut that the final line would make from
// the pristine pre-gesture mesh. The interactive preview (onMouseMotion), the
// commit (onMouseButtonUp), and the `fast`-deferred commit all funnel through
// here, so they can never diverge in result. Pure data (no GPU / GL) so it is
// unit-testable under `dub test`.
size_t sliceFromBaseline(ref Mesh mesh, const ref MeshSnapshot baseline,
                         Vec3 start, Vec3 end, Vec3 wpNormal,
                         int axisMode = SLICE_AXIS_DRAG,
                         Vec3 vector = Vec3(0, 1, 0),
                         bool infinite = false,
                         bool split = false,
                         bool caps = false,
                         const uint[] restrictFaces = null,
                         float gap = 0.0f,
                         int gapSide = cast(int)SliceGapSide.Center)
{
    if (baseline.filled) baseline.restore(mesh);
    Vec3 p, n;
    if (!planeForSlice(start, end, wpNormal, axisMode, vector, p, n))
        return 0;
    // `infinite` (task 0270): ON extends the line indefinitely, so the plane
    // slices the WHOLE mesh (mesh_ops.cut.cutByPlane — the S0 behavior). OFF (the
    // reference factory default) CLIPS the cut to the drawn Start→End span, so
    // only faces under the drawn line are cut (mesh_ops.cut.cutByPlaneClipped). On a
    // mesh whose cross-section fits within the line the two agree.
    //
    // `split` (task S7): OFF is the connected single cut above — byte-for-byte
    // the S0/S4 path (the non-split kernel is called directly). ON routes the
    // SAME plane cut through mesh_ops.cut.cutByPlaneEx, which duplicates the cut loop
    // into two coincident boundary loops (the Loop Slice lo/hi seam model),
    // splitting the surface into two disconnected sections along the cut.
    // `caps` (task S8): with `split` on, seal each split section's boundary loop
    // with one cap polygon (mesh_ops.cut.cutByPlaneEx forwards it to splitAlongCutLoop →
    // mesh_ops.loop_slice.capShellCycles, the SAME cap geometry as Loop Slice
    // Cap Sections). A no-op
    // when `split` is off (the non-split kernels never duplicate a loop).
    // `restrictFaces` (task 0279): when non-empty, the cut is confined to those
    // faces — the reference Slice cuts ONLY the selected polygons (the whole
    // layer when nothing is selected, i.e. an empty set here). Threaded into
    // every cut variant so the preview, the commit, and applyHeadless all
    // restrict identically.
    if (!split) {
        // A single connected plane cut through point `pp`, honoring infinite vs
        // clipped + restrictFaces (the S0/S4 path). Nested so the Gap-without-
        // split path can fire it twice for the two parallel cuts.
        // Takes the batch rather than opening one (task 1903 Stage E3): the
        // Gap-without-split path fires it TWICE, and both cuts belong to one
        // edit — one stamp, one derive, one delivery at the caller's `close()`.
        size_t cutAt(ref MeshEditBatch ed, Vec3 pp) {
            if (infinite)
                return restrictFaces.length > 0
                     ? ed.cutByPlaneRestricted(pp, n, restrictFaces)
                     : ed.cutByPlane(pp, n);
            return ed.cutByPlaneClipped(pp, n, start, end, 1e-5f, restrictFaces);
        }
        // Gap WITHOUT Split (task 0288). The reference Slice's `gap` works even
        // with Split OFF: it opens the single cut into TWO PARALLEL cuts `gap`
        // apart along the plane normal (offset per `gapSide`), leaving the strip
        // between them as COPLANAR band faces — the mesh stays CONNECTED (a
        // channel notched into the surface), NOT the disconnected two-shell Split.
        // Captured on a cube (axis-aligned cut, center): 12v/10f → 16v/14f with
        // the two loops at ±gap/2 (the captured reference geometry, task 0288).
        // Reproduced EXACTLY by two sequential parallel plane cuts through
        // p + n·loAmt and p − n·hiAmt (loAmt/hiAmt from `gapSide`, summing to
        // `gap` — the SAME sign policy as the Split gap kernel: center gap/2·gap/2,
        // positive gap·0, negative 0·gap). `gap == 0` collapses both planes onto
        // `p`, so the second cut is a no-op and this stays byte-for-byte the single
        // connected cut. Only the axis-aligned center case is reference-captured;
        // positive/negative + sheared cuts are analytic extensions.
        if (gap != 0.0f) {
            float loAmt, hiAmt;
            switch (gapSide) {
                case cast(int)SliceGapSide.Positive: loAmt = gap;        hiAmt = 0.0f;       break;
                case cast(int)SliceGapSide.Negative: loAmt = 0.0f;       hiAmt = gap;        break;
                default:                              loAmt = gap * 0.5f; hiAmt = gap * 0.5f; break;
            }
            size_t nCut;
            {
                auto ed = MeshEditBatch.unrecorded(mesh, kCutEditScope);
                nCut  = cutAt(ed, p + n * loAmt);
                nCut += cutAt(ed, p - n * hiAmt);
                ed.close();
            }
            return nCut;
        }
        size_t nOne;
        {
            auto ed = MeshEditBatch.unrecorded(mesh, kCutEditScope);
            nOne = cutAt(ed, p);
            ed.close();
        }
        return nOne;
    }
    // `gap`/`gapSide` (S9): with split on, separate the two boundary loops along
    // the cut-plane normal `n` by `gap`, offset per `gapSide` (mesh_ops.cut.cutByPlaneEx
    // → splitAlongCutLoop). gap=0 leaves the pairs coincident (byte-for-byte S7/S8).
    //
    // Task 0291: an UNRESTRICTED gap route through `sliceSplitGap` — TWO real
    // parallel plane cuts + band delete — instead of the single-cut + fixed
    // along-edge slide, which self-intersects its cap on dense/curved oblique
    // cuts (see sliceSplitGap's doc comment). Restricted split-gap keeps the
    // single-cut path unchanged (the two cuts would shift face indices between
    // calls, making a second restrict stale — no reference/golden for it).
    if (gap != 0.0f && restrictFaces.length == 0)
        return sliceSplitGap(mesh, p, n, /*clipped*/!infinite, start, end,
                             caps, gap, gapSide, restrictFaces);
    PlaneCutLoops loops;
    size_t nSplitCut;
    {
        auto ed = MeshEditBatch.unrecorded(mesh, kCutEditScope);
        nSplitCut = ed.cutByPlaneEx(p, n, /*clipped*/!infinite, start, end,
                                    /*split*/true, caps, loops, 1e-5f, restrictFaces,
                                    gap, gapSide);
        ed.close();
    }
    return nSplitCut;
}

// The face set the cut is restricted to = the current POLYGON selection. Empty
// (null) when no polygon is selected ⇒ whole-mesh cut. This mirrors the
// reference Slice, which cuts ONLY the selected polygons and the whole layer
// when nothing is selected (task 0279 capture: 2 of 6 faces selected → only
// those 2 split, unselected crossed neighbours absorb the cut verts as n-gons;
// nothing / all selected → whole cut). Keyed on the polygon selection like Loop
// Slice's Slice Selected; a pure vertex/edge selection does not restrict.
uint[] sliceRestrictFaces(ref Mesh mesh) {
    if (mesh.countSelectedFaces() == 0) return null;
    uint[] r;
    foreach (fi; 0 .. mesh.faces.length)
        if (mesh.isFaceSelected(fi)) r ~= cast(uint)fi;
    return r;
}

// ---------------------------------------------------------------------------
// Cut-plane overlay geometry (task 0284). Pure world-space helpers for the
// translucent quad SliceTool.draw() lays IN the cut plane — factored out of the
// GL draw so they are unit-testable without a context. The quad ALWAYS lies in
// the plane (through `p`, normal `n`): its two axes are the IN-PLANE line
// direction and its in-plane perpendicular, so every corner satisfies
// dot(corner - p, n) == 0.
// ---------------------------------------------------------------------------

// The quad's in-plane orthonormal basis. `dir` = the component of the drawn
// line (end-start) that lies IN the plane, normalized — this equals
// normalize(end-start) whenever the segment lies in the plane (always so in the
// no-override drag mode, and whenever the locked/custom normal is ⟂ the line,
// e.g. a Z-line with axis=X). `perp` = normalize(cross(n, dir)), across
// the line. Returns false when the line is degenerate or runs parallel to `n`
// (no well-defined in-plane direction) so the caller can skip the overlay.
bool sliceOverlayBasis(Vec3 start, Vec3 end, Vec3 n, out Vec3 dir, out Vec3 perp,
                       float eps = 1e-6f)
{
    Vec3 nn  = normalize(n);
    Vec3 seg = end - start;
    Vec3 inPlane = seg - nn * dot(seg, nn);     // drop the out-of-plane part
    if (inPlane.length < eps) return false;      // line ⟂ plane / zero-length
    dir  = normalize(inPlane);
    Vec3 pv = cross(nn, dir);
    if (pv.length < eps) return false;
    perp = normalize(pv);
    return true;
}

// The four world-space corners (CCW in the dir→perp frame) of the overlay
// rectangle, anchored at the in-plane point `p`. The extents are measured from
// `p`: [aMin,aMax] along `dir`, [bMin,bMax] along `perp`. All four corners lie
// in the plane through `p` spanned by dir/perp (both ⟂ the normal).
Vec3[4] sliceOverlayQuad(Vec3 p, Vec3 dir, Vec3 perp,
                         float aMin, float aMax, float bMin, float bMax)
{
    return [
        p + dir * aMin + perp * bMin,
        p + dir * aMax + perp * bMin,
        p + dir * aMax + perp * bMax,
        p + dir * aMin + perp * bMax,
    ];
}

// Size the overlay so it (a) spans EXACTLY the Start→End segment along the line
// (never past the endpoint handles — task 0284 owner fix 1), and (b) covers the
// active mesh's projection ACROSS the line AND biases that cross span markedly
// LARGER than the along span (owner fix 2) so the plane reads as a plane
// extending AWAY from the handles, not a thin ribbon between them. BOUNDED.
// Extents are along `dir` / across `perp`, measured from `p`.
//
// KEY (owner fix 1): the ALONG-`dir` extent is the drawn segment ONLY — no mesh
// union, no along-line pad — so the translucent plane starts at one handle and
// ends at the other, never extending across the viewport as a guide.
// KEY (owner fix 2): `perp` is the NO-HANDLE axis (the handles sit at the line's
// two ends, along `dir`), so the CROSS-`perp` extent is deliberately biased
// larger: it unions the mesh, then guarantees a half-span of a full along-extent
// on each side (⇒ cross span ≥ 2× along) plus a generous overhang, netting a
// cross span ≥ 3× along > along. `p` is the plane through-point (= start).
//
// `ms` (task 0619, §1.2) is the LAYER TRANSFORM of the mesh being scanned.
// `p`/`dir`/`perp`/`start`/`end` are WORLD constructs (the drawn line and the
// workplane), but `m.vertices` are LAYER-LOCAL — so the union below has to be
// taken over where those vertices are DRAWN, `M*v`, not over the raw array.
// Rather than transform V vertices, carry the PLANE into local space, which
// is one point and one direction: with `pL = M^-1 p` and `perpL = M^T perp`,
//
//     dot(v - pL, perpL) == dot(M*v - p, perp)     EXACTLY, any invertible M
//
// so the extent that comes out is still measured in WORLD units along the
// WORLD `perp` — which is what `sliceOverlayQuad` needs, since it rebuilds
// the quad from the world `p`/`dir`/`perp`. Note `toLocalNormal` (`M^T`) and
// NOT `toLocalDir` (`M^-1`): the two agree only when `M` has no non-uniform
// scale, and the identity above is false for the latter.
void sliceOverlayExtent(const ref Mesh m, const ModelSpace ms,
                        Vec3 p, Vec3 dir, Vec3 perp,
                        Vec3 start, Vec3 end,
                        out float aMin, out float aMax,
                        out float bMin, out float bMax)
{
    import std.algorithm : min, max;
    // Along the line: bound EXACTLY to the drawn segment (start↔end).
    float a0 = dot(start - p, dir), a1 = dot(end - p, dir);
    aMin = min(a0, a1); aMax = max(a0, a1);
    // Across the line: seed with the segment, then union the mesh projection so
    // the plane spans the depth of the region being cut.
    float b0 = dot(start - p, perp), b1 = dot(end - p, perp);
    bMin = min(b0, b1); bMax = max(b0, b1);
    const Vec3 pLocal    = ms.toLocalPoint(p);
    const Vec3 perpLocal = ms.toLocalNormal(perp);
    foreach (v; m.vertices) {
        float b = dot(v - pLocal, perpLocal);
        bMin = min(bMin, b); bMax = max(bMax, b);
    }
    float along = max(1e-3f, aMax - aMin);
    // PERPENDICULAR-to-line (`perp`) is the NO-HANDLE axis (owner fix 2, 0284):
    // bias the quad markedly LARGER across the line than along it, so the plane
    // reads as extending AWAY from the endpoint handles (which sit along `dir`),
    // not as a thin ribbon strung between them. Guarantee a half-span of a FULL
    // along-extent on each side (⇒ cross span ≥ 2× along, even on a flat/empty
    // mesh) plus a generous 0.5× along overhang past the mesh — net cross span
    // ≥ 3× along > along, always. The ALONG-`dir` extent is untouched (flush with
    // the drawn segment).
    float minHalf = 1.0f * along;
    bMax = max(bMax,  minHalf);
    bMin = min(bMin, -minHalf);
    // Generous cross-line overhang (owner fix 2 widened it from 0.1× to 0.5×
    // along) — NOT along the line, which stays flush with the endpoint handles.
    float pad = 0.5f * along;
    bMin -= pad; bMax += pad;
}

// ---------------------------------------------------------------------------
// DEGENERATE-plane overlay basis + extent (task 0284; owner-revised for the
// extrusion-direction model). Under the extrusion model EVERY axis-locked plane
// CONTAINS the drawn line (n ⟂ line by construction), so the line-derived basis
// above applies to X/Y/Z/Custom too — the draw() path uses it for both drag and
// locked modes. These two helpers are the FALLBACK for the ONE case the line-based
// basis cannot handle: the TRUE degenerate where the drawn line is (near-)parallel
// to the extrusion axis (cross ≈ 0), where planeForSlice itself returns false and
// no line-derived in-plane direction exists. Then the basis comes from the NORMAL
// itself (a deterministic in-plane perpendicular pair, independent of the line) and
// the extent COVERS THE ACTIVE MESH in that plane, so the overlay stays a valid
// in-plane rectangle. The normal (drag or locked) always yields a line-based basis
// otherwise, so this path is rarely reached.
// ---------------------------------------------------------------------------

// A STABLE in-plane orthonormal basis derived from the normal `n` alone — a
// canonical/deterministic perpendicular pair, NOT the drawn line. `dir` =
// normalize(cross(n, worldUp)); when `n ∥ worldUp` (no well-defined cross) it
// falls back to cross(n, worldX). `perp` = cross(n, dir). Both are unit and ⟂ n
// (and ⟂ each other), so every quad corner lies in the plane. Returns false only
// for a zero-length normal (never for a valid unit axis / custom vector).
bool sliceOverlayBasisLocked(Vec3 n, out Vec3 dir, out Vec3 perp, float eps = 1e-6f)
{
    Vec3 nn = normalize(n);
    if (nn.length < eps) return false;
    Vec3 pv = cross(nn, Vec3(0, 1, 0));          // worldUp
    if (pv.length < eps) pv = cross(nn, Vec3(1, 0, 0));   // n ∥ worldUp → fall back to worldX
    if (pv.length < eps) return false;
    dir  = normalize(pv);
    perp = normalize(cross(nn, dir));
    return true;
}

// Size the LOCKED overlay to COVER THE ACTIVE MESH in the plane: union the mesh
// vertices' projections onto (dir, perp) anchored at `p` (the plane through-
// point = start_), plus a min-band (so a flat/empty mesh still shows a real
// rectangle) and a ~10% overhang on every edge. Extents are measured
// from `p` along `dir` / across `perp`. Unlike the unlocked extent the drawn
// line does NOT bound the quad here (the line no longer lies in the plane).
// `ms` — the same task-0619 §1.2 carry as `sliceOverlayExtent` above, for the
// same reason and with the same exactness: the union must be over the DRAWN
// vertices, and moving the plane costs one point plus two directions instead
// of transforming V vertices. This variant projects on BOTH axes, so `dir`
// crosses over too.
void sliceOverlayExtentLocked(const ref Mesh m, const ModelSpace ms,
                              Vec3 p, Vec3 dir, Vec3 perp,
                              out float aMin, out float aMax,
                              out float bMin, out float bMax)
{
    import std.algorithm : min, max;
    aMin = aMax = bMin = bMax = 0.0f;
    bool any = false;
    const Vec3 pLocal    = ms.toLocalPoint(p);
    const Vec3 dirLocal  = ms.toLocalNormal(dir);
    const Vec3 perpLocal = ms.toLocalNormal(perp);
    foreach (v; m.vertices) {
        float a = dot(v - pLocal, dirLocal), b = dot(v - pLocal, perpLocal);
        if (!any) { aMin = aMax = a; bMin = bMax = b; any = true; }
        else {
            aMin = min(aMin, a); aMax = max(aMax, a);
            bMin = min(bMin, b); bMax = max(bMax, b);
        }
    }
    // Reference length for the pad + min-band: the larger mesh span (or a small
    // floor for a flat/empty mesh), so the overhang and non-degeneracy guard
    // scale with the region being cut.
    float refLen = max(max(aMax - aMin, bMax - bMin), 1e-3f);
    float pad    = 0.1f * refLen;
    aMin -= pad; aMax += pad;
    bMin -= pad; bMax += pad;
    // Guarantee a visible, non-degenerate rectangle even for a flat/empty mesh
    // (all verts project to one line along dir or perp): open the collapsed axis
    // to at least half the reference length on each side.
    float half = 0.5f * refLen;
    if (aMax - aMin < 1e-3f) { aMax += half; aMin -= half; }
    if (bMax - bMin < 1e-3f) { bMax += half; bMin -= half; }
}

// ---------------------------------------------------------------------------
// Custom-axis rotate gizmo math (task 0287). PURE, unit-testable without a GL
// context. When axis == Custom the cut plane's EXTRUSION direction is `vector`
// and its normal is normalize(cross(lineDir, vector)) (planeForSlice's Custom
// mode). ROTATING THE PLANE ABOUT THE DRAWN LINE is therefore rotating `vector`
// about the (unit) line direction: because the line direction IS the rotation
// axis, R(cross(lineDir, vector)) == cross(lineDir, R(vector)), so tilting
// `vector` by θ tilts the plane normal by the SAME θ about the line — while BOTH
// endpoints stay in the plane (cross(lineDir, ·) is always ⟂ lineDir, so the line
// remains contained). The two drawn points never move; only the tilt changes.
// ---------------------------------------------------------------------------

// Rodrigues rotation of a DIRECTION vector `v` about a unit `axis` by `angle`
// (radians), pivot at the origin (direction only — no translation). Preserves
// |v|. This is the whole rotate-gizmo kernel: new vector = rotate the frozen
// gesture-start vector about the line by the drag angle.
Vec3 rotateVectorAboutAxis(Vec3 v, Vec3 axis, float angle) {
    // The formula itself lives in math.d (`rotateAboutAxis`, unit-axis
    // contract); what this wrapper adds — and what its callers rely on — is
    // the `normalize` at the boundary.
    return rotateAboutAxis(v, normalize(axis), angle);
}

// Signed angle (radians, in [-π, π]) FROM `from` TO `to` measured about the unit
// `axis` (right-handed): atan2((from×to)·axis, from·to). `from`/`to` need not be
// unit. Used to turn the gizmo's grab-direction-vs-cursor-direction into a
// rotation sense about the line.
float signedAngleAboutAxis(Vec3 from, Vec3 to, Vec3 axis) {
    import std.math : atan2;
    Vec3 a = normalize(axis);
    return atan2(dot(cross(from, to), a), dot(from, to));
}

// A deterministic orthonormal pair spanning the plane ⟂ `axis` (the plane the
// rotate ring lies in). `right` = normalize(cross(axis, worldUp)) with a worldX
// fallback when axis ∥ worldUp; `up` = cross(axis, right). Basis choice does not
// affect the ring (a full circle is basis-independent) nor the rotate angle
// (measured from a world grab direction), only the ring's point parameterization.
void sliceRingPlaneBasis(Vec3 axis, out Vec3 right, out Vec3 up) {
    Vec3 a = normalize(axis);
    Vec3 r = cross(a, Vec3(0, 1, 0));
    if (r.length < 1e-6f) r = cross(a, Vec3(1, 0, 0));
    right = normalize(r);
    up    = normalize(cross(a, right));
}

// ---------------------------------------------------------------------------
// SliceTool — interactive plane/line slice (factory id `mesh.sliceTool`).
//
// Draws a Start→End line and cuts the mesh with the plane through that line
// that is PERPENDICULAR TO THE WORK PLANE (owner decision — see
// math.planeFromLineAndWorkplane). This is deliberately NOT the camera-eye
// plane that the one-shot `mesh.screenSlice` command builds
// (source/commands/mesh/screen_slice.d, untouched): a horizontal drag in a
// front view makes a clean axis-aligned cut regardless of camera pitch. The
// cut itself reuses the existing `mesh_ops.cut.cutByPlane` kernel (index-shared
// crossing verts, chord-split faces, all-quad on a cube — 8v/6f → 12v/10f for
// a mid-plane cut); this tool does not reimplement it.
//
// S1 scope (this class), on top of S0's activation + line-draw + plane + cut
// + one-`MeshSnapshot`-per-commit undo + `applyHeadless()`:
//   • DRAW: the Start→End line + two draggable endpoint handles (BoxHandler),
//     rendered through the shared gizmo palette + hover arbiter (ToolHandles).
//   • GESTURES: drag an endpoint to move it; drag the line body to translate
//     the whole line; middle-click to relocate the line to the cursor;
//     Shift+drag to reset/redraw a fresh line; RMB CANCELS an in-flight LMB
//     gesture, else RMB drags the `gap` (task 0288, dashed-circle + value HUD).
//   • LIVE PREVIEW: while dragging, the resulting cut is previewed on the real
//     mesh WITHOUT committing — non-cumulative (each update restores the
//     ACTIVATION baseline then re-cuts, via `sliceFromBaseline`), mirroring
//     LoopSliceTool's mutate/revert armed preview. The slice stays LIVE for the
//     whole tool session; nothing is baked on mouse-up.
//   • `fast` (bool, default off): the preview gate. OFF ⇒ the cut recomputes
//     live on every motion. ON ⇒ the cut is DEFERRED to mouse-up (only the
//     line/handles move during the drag — no live cut on dense meshes). Both
//     paths materialise the identical final geometry (`sliceFromBaseline` is
//     the one cut kernel).
//
// S3 (task 0269; owner-revised 0284) adds the `axis` (X/Y/Z/Custom) OVERRIDE +
// `vectorX/Y/Z`: with NO override the plane is the drawn line ⟂ the FROZEN work
// plane (the default — see frozenNormal_/axisLocked_); X/Y/Z lock the normal to
// a world axis; Custom uses the `vector` normal. The plane law lives in the
// unit-tested math.planeForSlice helper (mode 0 = the no-override drag plane);
// the Vector gang is greyed unless axis == Custom (paramEnabled).
//
// S4 (task 0270) adds `infinite` (bool): OFF (the reference factory default)
// CLIPS the cut to the drawn Start→End span — only faces under the line get
// cut (mesh_ops.cut.cutByPlaneClipped); ON extends the line indefinitely so the plane
// slices the whole mesh (mesh_ops.cut.cutByPlane, the S0 behavior). It threads through
// the preview + commit (sliceFromBaseline) and applyHeadless.
//
// S7 (task 0273) adds `split` (bool, default off): OFF is the S0 connected cut;
// ON duplicates the plane-cut loop into two coincident boundary loops so the
// surface splits into two disconnected sections along the cut, reusing the Loop
// Slice lo/hi seam-pair split machinery (mesh_ops.cut.cutByPlaneEx → splitAlongCutLoop).
// It threads through the preview + commit (sliceFromBaseline) and applyHeadless.
// The seam-pair data it produces is what Cap Sections (S8) / Gap (S9) build on.
//
// S8 (task 0274) adds `caps` (Cap Sections, bool, default ON, dep Split): with
// `split` on, each split section's boundary loop is sealed by one cap polygon in
// the loop plane — the SAME geometry as Loop Slice Cap Sections (the shared
// mesh_ops.loop_slice.capShellCycles helper, via cutByPlaneEx →
// splitAlongCutLoop). A no-op
// while `split` is off (greyed by paramEnabled); the seam-pair data survives for
// Gap (S9). Threads through the preview + commit (sliceFromBaseline) and
// applyHeadless.
//
// S9 (task 0275) adds `gap` (distance, default 0, dep Split) + `gapSide` (Offset
// Side: center/positive/negative, default center). With `split` on and `gap != 0`
// the two split boundary loops are pushed APART by `gap` along the CUT-PLANE
// NORMAL `n` (the flat-cut analogue of the Loop Slice rail-direction gap),
// offset per `gapSide`; with `caps` on the caps become real walls (nonzero
// area). gap=0 is byte-for-byte S7/S8. Threads through sliceFromBaseline
// (preview + commit) and applyHeadless. This completes the Slice program (S0–S9).
//
// Params: `startX/Y/Z`, `endX/Y/Z`, `fast`, `snap`, `snapAngle`, `split`,
// `caps`, `gap`, `gapSide`, `infinite`, `axis`, `vectorX/Y/Z`.
//
// Undo model (task 0278 — mirrors LoopSliceTool's arm-then-commit lifecycle):
// `before_` is the ACTIVATION baseline, snapshotted ONCE in `activate()` — NOT
// per gesture. Every endpoint/line drag re-cuts NON-CUMULATIVELY from that one
// baseline (restore baseline → `cutByPlane` once), so the mesh always shows
// EXACTLY ONE slice at the current line — dragging endpoints refines the SAME
// slice, it never spawns another. The cut is baked into ONE
// MeshSessionEdit(before, after) history entry when the tool is DEACTIVATED /
// dropped (see `deactivate` → `commitCurrentSlice`), never on mouse-up. A
// session whose final line touches no face (or was never drawn) commits
// nothing. `armedKey_` guards the deferred commit against a mesh swapped out
// from under us (scene reset / layer switch) between the last preview and the
// drop — a mismatch drops the preview instead of baking a bogus entry.
// ---------------------------------------------------------------------------
final class SliceTool : Tool {
private:
    Mesh* delegate() nothrow @nogc meshSrc_;
    @property Mesh* mesh() const nothrow @nogc { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;


    // The slice line, in world space. Bound to the startX..endZ params. The
    // defaults are neutral round numbers (a unit line on X through the origin);
    // headless tests always set them explicitly, so the exact idle defaults are
    // not load-bearing.
    Vec3 start_ = Vec3(-1, 0, 0);
    Vec3 end_   = Vec3( 1, 0, 0);

    // Fast Slice (S6, introduced here as the preview gate): OFF ⇒ recompute the
    // cut live during the drag; ON ⇒ defer the cut to mouse-up. Sticky param
    // (not reset on activate) — matches the reference's sticky tool options.
    bool fast_ = false;

    // Slice axis OVERRIDE (S3; owner-revised 0284). `axis_` names the world axis
    // (X/Y/Z) or Custom-vector the cut plane's EXTRUSION DIRECTION locks to (the
    // line is extruded along it ⇒ n = cross(lineDir, axisDir); the plane always
    // contains the line); `vector_` is the Custom extrusion direction, meaningful
    // only when axis_ == Custom (the panel greys it
    // otherwise — see paramEnabled). The override is active ONLY while
    // `axisLocked_` is set (see below). Its default VALUE is X, but that value is
    // ignored until the user engages the lock — the default plane orientation is
    // the frozen drag plane, NOT any axis (see SliceAxis doc).
    SliceAxis axis_   = SliceAxis.X;
    Vec3      vector_ = Vec3(0, 1, 0);

    // Axis-override engagement (owner fix 4, task 0284). FALSE = no override: the
    // cut plane uses the FROZEN drag normal (drawn line ⟂ frozen work plane),
    // reproducing the S0 drawn-line plane. TRUE = the `axis_` override is locked
    // (world X/Y/Z or Custom vector), independent of the drawn line. Set in
    // onParamChanged whenever the `axis` attribute is written (panel dropdown or
    // headless tool.attr); reset to FALSE on activation and on a fresh line
    // redraw (Shift+drag / new line), which are the paths back to the drag plane.
    bool axisLocked_ = false;

    // Pending axis classification (owner fix 1, task 0284). Set when a FRESH line
    // is started (beginFreshLinePlane) and consumed at that gesture's mouse-UP,
    // where the drawn line's direction is finally known: the drag-mode plane
    // normal is classified to a concrete Axis (X/Y/Z if aligned, else Custom) so
    // the Tool-Properties dropdown reflects the drawn plane. Deferred to mouse-UP
    // because at the fresh-line DOWN the line is still degenerate (start==end, no
    // direction, no plane). Endpoint-refine / line-translate / relocate gestures
    // do NOT set it — they preserve the axis the draw established (reclassifying
    // them would clobber a locked axis with a stale line-derived one).
    bool pendingAxisClassify_ = false;

    // Frozen cut-plane normal (owner fix 3, task 0284). The work-plane normal is
    // captured ONCE, at the gesture that DRAWS the line (fresh line / relocate /
    // the first endpoint or line-body drag of the session), and reused for BOTH
    // the cut (updatePreview / sliceFromBaseline) AND the overlay draw. This
    // decouples the slice plane from the live camera: orbiting after the line is
    // drawn leaves the plane (and its overlay) exactly in place, so the drawn cut
    // and the committed cut never diverge. Only a fresh Shift+drag / redraw / a
    // new tool session re-captures it. `p` (the through-point = start_) stays
    // live so the plane still follows the LINE's position under handle drags —
    // it is only the ORIENTATION that freezes.
    Vec3 frozenNormal_;
    bool haveFrozen_;

    // Infinite (S4, task 0270). OFF (the reference factory default) CLIPS the
    // cut to the drawn Start→End span — only faces under the line get cut. ON
    // extends the line indefinitely so the plane slices the whole mesh (the S0
    // behavior). Threaded into sliceFromBaseline (preview + commit) and
    // applyHeadless. Sticky (not reset on activate), like the other tool
    // options. DEFAULT DECISION: the reference live-capture reads infinite=off
    // as a GUARANTEED factory default (spec.json "default": false, authoritative
    // from cmdhelptools.cfg — unlike the sticky-flagged axis/snap values). The
    // S0/S3/session goldens all draw lines that span the cube's cross-section,
    // so every crossing stays in-band and the clipped default reproduces them
    // unchanged; the infinite/clipped divergence only shows on a line shorter
    // than the mesh (see test_fixture_slice_infinite).
    bool infinite_ = false;

    // Split (S7, task 0273; default OFF per the reference spec). OFF is the S0
    // connected cut (byte-for-byte). ON duplicates the plane-cut loop into two
    // coincident boundary loops — the surface splits into two disconnected
    // sections along the cut, reusing the Loop Slice lo/hi seam-pair machinery
    // (mesh_ops.cut.cutByPlaneEx → splitAlongCutLoop). Threads through the preview +
    // commit (sliceFromBaseline) and applyHeadless. Sticky (not reset on
    // activate), like the other tool options. The seam-pair data it produces is
    // the foundation the later Cap Sections (S8) / Gap (S9) options act on.
    bool split_ = false;

    // Cap Sections (S8, task 0274; default ON per the reference spec — spec.json
    // "caps" default true, dep Split). A no-op while `split_` is off (the
    // non-split cut never duplicates a loop, so there is no open boundary to
    // cap); the panel greys it out then (paramEnabled). With `split_` on, each
    // split section's boundary loop is sealed by one cap polygon — the SAME
    // geometry as Loop Slice Cap Sections
    // (mesh_ops.loop_slice.capShellCycles). Threads through
    // the preview + commit (sliceFromBaseline) and applyHeadless. Sticky (not
    // reset on activate), like the other tool options. DEFAULT DECISION: the
    // reference live-capture reads caps=on but flags it "may be sticky"; the
    // spec's authoritative default is ON and the vibe3d Loop Slice Cap Sections
    // default is likewise ON, so ON is the self-consistent reference-faithful
    // default. It changes nothing while Split is off (the S0/S4/S7 goldens, all
    // Split-off, stay byte-for-byte).
    bool caps_ = true;

    // Gap + Offset Side (S9, task 0275; gap default 0, gapSide default Center).
    // Only meaningful with `split_` on (the panel greys both while Split is off —
    // paramEnabled). `gap_ == 0` (default) leaves the two duplicated boundary
    // loops COINCIDENT, byte-for-byte the S7/S8 result. Non-zero pushes the two
    // split shells APART along the CUT-PLANE NORMAL `n` by exactly `gap_`,
    // opening a real band (a thickened cut); `gapSide_` biases which shell moves
    // (Center = symmetric ±gap/2; Positive/Negative = one shell takes the full
    // gap). KEY DIVERGENCE from the Loop Slice gap: that one displaces along the
    // on-surface RAIL (perpendicular to the edge loop); a FLAT plane cut has no
    // rail, so the two shells separate along the plane normal instead — the
    // natural "open the cut" direction. Threaded into sliceFromBaseline (preview
    // + commit) and applyHeadless. Sticky (not reset on activate). With `caps_`
    // on the cap polygons gain real (nonzero) area — the band becomes solid walls.
    float        gap_     = 0.0f;
    SliceGapSide gapSide_ = SliceGapSide.Center;

    // RMB gap-adjust drag (task 0288). The reference exposes `gap` as an RMB
    // click+drag gizmo with a dashed-circle + value HUD. RMB with NO active LMB
    // gesture begins a gap drag: the horizontal travel maps px→gap. `gapDrag_` is
    // the live flag; `gapDragStartGap_`/`gapDragStartM*_` latch the gap + mouse
    // pixel it began at so the delta is ABSOLUTE (no per-frame accumulation drift,
    // like the transform rings). Since gap now applies WITHOUT Split (opens a
    // channel), the drag re-previews live.
    bool  gapDrag_;
    float gapDragStartGap_;
    int   gapDragStartMX_, gapDragStartMY_;
    // Screen px → world gap scale for the RMB drag (~200 px ≈ 1 world unit). The
    // dashed HUD circle's pixel radius is gap_/GAP_DRAG_PX_TO_WORLD (+ a floor),
    // so the ring grows in lockstep with the cursor's horizontal travel.
    enum float GAP_DRAG_PX_TO_WORLD = 0.005f;

    // Angle Snap (S5, task 0271). When ON, the drawn line's ANGLE in the work
    // plane is quantized to the nearest multiple of `snapAngle_` before the cut
    // plane is built, so an endpoint drag snaps the line to clean angles
    // (0°/45°/90°/… for the default 45°). `snapAngle_` is greyed while `snap_`
    // is off (paramEnabled). Threaded through the interactive drag (onMouseMotion
    // / applyAngleSnapFromRaw) AND the headless apply (applyHeadless) via the pure
    // math.snapLineEndpointToAngle helper, so the snapped line is identical either
    // way. Sticky (not reset on activate), like the other tool options.
    //
    // DEFAULT DECISION: the reference live-capture reads snap=ON but its own spec
    // flags that value "may be sticky from seeded prefs, NOT a guaranteed fresh
    // factory default" (same caveat as the `axis` reading, which this file
    // resolves to the no-override drag plane default). A snap=ON factory default
    // would silently rotate
    // EVERY existing slice golden's line to a 45° multiple (e.g. the slice_axis
    // 81°→90° line), so ON is neither self-consistent with the drawn-line
    // semantics nor golden-safe. The reference-faithful, goldens-green reading is
    // therefore snap=OFF as the factory default; the S5 golden turns it ON
    // explicitly. `snapAngle_` = 45° matches the spec's authoritative default.
    //
    // CAPTURE CAVEAT (task 0279): the reference `snap` attribute raises a MODAL
    // dialog that blocks the command port, so its geometry can't be captured
    // headlessly. This is a straightforward ANALYTIC feature (quantize the line
    // angle in the work plane) and is verified analytically (unit tests +
    // slice_snap.json golden) — no reference capture is attempted through the modal.
    bool  snap_      = false;
    float snapAngle_ = 45.0f;

    // X-key TEMPORARY snap toggle (S5): while X is held, the effective snap state
    // is INVERTED (the reference's "press X in-viewport to temporarily toggle
    // snapping"). Set on X-down, cleared on X-up (onKeyDown/onKeyUp). The
    // effective state = snap_ ^ snapTempInvert_.
    bool snapTempInvert_ = false;

    // The RAW (unsnapped) drag endpoints from the last motion, so the X toggle
    // can re-derive the snapped line mid-drag WITHOUT a fresh mouse move (the
    // snap is otherwise lossy — start_/end_ already hold the snapped result).
    Vec3 rawStart_, rawEnd_;
    bool haveRaw_;

    // Which part of the gizmo this gesture drags.
    enum DragNone   = -1;
    enum DragStart  = 0;    // the Start endpoint handle
    enum DragEnd    = 1;    // the End endpoint handle
    enum DragLine   = 2;    // the whole line body (translate)
    enum DragRotate = 3;    // the custom-axis rotate ring (tilt the plane about the line)

    // Session state. `before_` is the session baseline captured ONCE at
    // activation (task 0278); `previewLive_` is true whenever a real cut sits
    // on the mesh (the thing `deactivate` commits). `armedKey_` stamps the
    // mesh identity+version we last left the preview at, so the deferred
    // commit can detect an external mesh swap and drop rather than corrupt it.
    bool     active;
    int      dragPart_ = DragNone;

    // Task 0286 — reference-faithful interactive input model. `hasLine_` gates ALL
    // drawing AND the first/second-drag dispatch: at bare tool activation NOTHING
    // is shown (no overlay, no line, no handles) and no line exists — the viewport
    // stays clean until the FIRST LMB drag lays a line. Set true the instant that
    // first fresh line begins (so it renders as it is drawn); reset to false on
    // activation / teardown (dropPreview).
    bool     hasLine_;
    // True for the duration of a DRAW gesture — the first LMB drag that lays a
    // fresh line (or a Shift+drag redraw) — as opposed to a whole-line TRANSLATE
    // (DragLine). Distinguishes the two so a held Ctrl locks the line DIRECTION on
    // a draw but the TRANSLATION axis on a move (owner observations 4 vs 5).
    bool     drawGesture_;
    // Ctrl axis-constraint (task 0286), reusing MoveTool.chooseConstraintAxis.
    // `ctrlPending_` = Ctrl was held at gesture start but the locked axis is not
    // yet resolved — we WAIT for enough initial movement (the MoveTool wait-gate)
    // so the drag direction is unambiguous. `ctrlAxis_` = the resolved world axis
    // (0=X / 1=Y / 2=Z), -1 while unresolved or no lock. `ctrlStartM*_` = the
    // pixel the gesture began at (the movement origin the axis is chosen from).
    bool     ctrlPending_;
    int      ctrlAxis_ = -1;
    int      ctrlStartMX_, ctrlStartMY_;

    bool     previewLive_;       // a preview cut currently sits on the mesh
    MeshSnapshot before_;        // session baseline captured at activation
    bool     haveBefore_;
    // The polygon-selection face set the cut is restricted to (task 0279),
    // snapshotted ONCE at activation. Every non-cumulative preview restores the
    // baseline (reverting face indices), so these activation-time indices stay
    // valid across the whole session. Empty ⇒ whole-mesh cut.
    uint[]   restrictFaces_;
    // recorded remainder (1906 §3.6): `mutationVersion` owns this key and
    // KEEPS it. This is not a cache — it is an IDENTITY guard, asked between
    // mouse events: "is the baseline I armed still the mesh I armed it on, at
    // the state I armed it in?". A bus class answers a different question
    // ("did anything change"), and the guard's correct response to any change
    // at all is the same one — drop the armed preview. Replacing an equality
    // on a monotone counter with a subscription would also make the answer
    // depend on when the bus last delivered, which replay determinism forbids.
    // Plan §3.4 row 18.
    MeshCacheKey armedKey_;      // mesh identity+version guard for the deferred commit
    // The WORLD-space viewport `draw()` was handed (task 0619 rename). Every
    // one of its uses was re-read and every one is genuinely WORLD: the
    // Ctrl-axis election, the workplane ray, the Start/End handle and line
    // picks, and the rotate ring all address `start_`/`end_` and the
    // workplane — constructs with no mesh read on the aim side (task 0619
    // §Out of scope, "tool params placed by a camera-plane ray"). The one
    // mesh-derived aim in this file is `sliceOverlayExtent`'s vertex scan,
    // which takes no viewport at all — it takes a `ModelSpace`.
    Viewport vpWorld_;

    // Line-body translate bookkeeping: the endpoints + the work-plane anchor at
    // the moment the drag began, so motion translates by (hit - anchor).
    Vec3 dragStart0_, dragEnd0_, dragAnchor_;

    // The line endpoints as they stood at the START of the current gesture, so
    // RMB-cancel can revert this drag (only) and re-preview, leaving the
    // session baseline untouched. `gVector0_` latches the Custom vector too, so
    // RMB-cancel of a rotate gesture restores the pre-drag tilt.
    Vec3 gStart0_, gEnd0_, gVector0_;

    // Rotate-gesture (DragRotate, task 0287) frozen reference: the line axis
    // (rotation axis), the ring centre, the in-plane grab direction, and the
    // Custom vector — all latched at gesture start. Each motion recomputes
    // vector_ = rotate(rotVector0_ about rotAxis0_) by the SIGNED angle from
    // rotRefDir0_ to the live cursor direction, so the drag is ABSOLUTE (measured
    // from the frozen grab, no per-frame accumulation) — robust across the
    // ray/plane grazing frame the same way the transform ring's absolute angle is.
    Vec3 rotAxis0_, rotCenter0_, rotRefDir0_, rotVector0_;

    // Endpoint handle visuals (lazily built inside a live GL context, since
    // BoxHandler uploads a VAO). Purely for drawing + hover highlight; the
    // actual grab hit-test is the projection-based `pickHandle` (no GL needed,
    // so the event path works even before the first draw).
    BoxHandler  startH_, endH_;
    // Custom-axis rotate gizmo (task 0287): a ring around the Start→End line
    // (its plane ⟂ the line), shown ONLY when axis_ == Custom. Reuses handler.d's
    // FullCircleHandler — the SAME ring hit-test/draw the transform RotateHandler's
    // view-ring uses — so it hover-highlights through the shared ToolHandles
    // arbiter exactly like the endpoint squares. Lazily built in a live GL context
    // (draw()), like startH_/endH_; the grab hit-test (`pickRotateRing`) is pure
    // projection so the event path works before the first draw.
    FullCircleHandler rotRing_;
    ToolHandles toolHandles_;

    // Endpoint handle visual size + grab radius (task 0278). The reference
    // Slice draws small cyan endpoint squares ~10 px across (0277 handler
    // capture), so the visible half-extent is HANDLE_HALF_PX ≈ 5 px (the old
    // `gizmoSize()*0.5` was ~45 px half — a ~90 px square, far too big). The
    // grab radius is tied to the visual: HANDLE_PICK_PX covers the whole
    // square (its 5·√2 ≈ 7 px corner) plus a small margin, so a click on the
    // visible square reliably grabs the endpoint. A hit-test SMALLER than the
    // visual was part of why endpoint drags "missed" and fell through to
    // drawing a fresh line.
    enum float HANDLE_HALF_PX = 5.0f;    // visible endpoint square half-extent (~10 px square)
    enum float HANDLE_PICK_PX = 9.0f;    // grab radius — matched to (slightly > ) the visual
    enum float LINE_PICK_PX   = 8.0f;

    // Custom-axis rotate ring (task 0287): screen-constant radius (px) + grab
    // tolerance. The ring reads clearly larger than the ~10 px endpoint squares
    // (and sits at the line MIDPOINT, away from the endpoints) so it never
    // competes with them for a click.
    enum float RING_RADIUS_PX = 46.0f;
    enum float RING_PICK_PX   = 8.0f;

    // Gizmo palette, resolved from the viewport scheme (`viewport_scheme.d`)
    // rather than held as literals here: endpoint handles in the path blue,
    // the line in a light neutral. The engaged tint is applied by the handle
    // itself — see `viewport_scheme.handleColor`.
    enum Vec3 HANDLE_COLOR = schemeColor(SchemeColor.toolPath);
    enum Vec3 LINE_COLOR   = schemeColor(SchemeColor.toolPathLine);
    // Rotate-ring colour: a light teal in the vibe3d gizmo palette (NOT a
    // reference colour), distinct from the endpoint blue so the two read apart.
    enum Vec3 RING_COLOR   = schemeColor(SchemeColor.toolPathRing);

    // Cut-plane overlay (task 0284): a subtle translucent fill in the same blue
    // family as the endpoint handles (vibe3d gizmo palette — NOT reference
    // colours), at a low alpha so the mesh, cut preview, and handles all read
    // through it.
    enum Vec3  PLANE_COLOR = schemeColor(SchemeColor.toolPath);
    enum float PLANE_ALPHA = 0.18f;

public:
    this(Mesh* delegate() nothrow @nogc meshSrc, GpuMesh* gpu,
            EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
    }

    override string name() const { return "Slice"; }

    // A mesh op — offered in every geometry mode (like the screen/axis slice
    // commands, which are mode-agnostic).
    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    override Param[] params() {
        return [
            // Start/End: the drawn cut line — per-gesture geometry, not a
            // remembered setting (reference auto-reset equivalent). Excluded from
            // sticky-tool-defaults capture via .transient().
            Param.float_("startX", "Start X", &start_.x, -1.0f).transient(),
            Param.float_("startY", "Start Y", &start_.y,  0.0f).transient(),
            Param.float_("startZ", "Start Z", &start_.z,  0.0f).transient(),
            Param.float_("endX",   "End X",   &end_.x,    1.0f).transient(),
            Param.float_("endY",   "End Y",   &end_.y,    0.0f).transient(),
            Param.float_("endZ",   "End Z",   &end_.z,    0.0f).transient(),
            Param.bool_( "fast",   "Fast Slice", &fast_,  false),
            // Infinite (S4): OFF clips the cut to the drawn line's span (the
            // reference factory default); ON slices the whole mesh (S0).
            Param.bool_( "infinite", "Infinite", &infinite_, false),
            // Split (S7): OFF connected single cut (default); ON duplicates the
            // cut loop into two disconnected boundary loops.
            Param.bool_( "split",  "Split", &split_, false),
            // Cap Sections (S8): with Split on, seal each split section's
            // boundary loop with a cap polygon. Default ON; greyed while Split
            // off (paramEnabled) — a no-op there.
            Param.bool_( "caps",   "Cap Sections", &caps_, true),
            // Gap (S9 / task 0288): open a band of this width at the cut. With
            // Split ON the two shells separate (0290); with Split OFF it opens a
            // connected channel (two parallel cuts, task 0288). Default 0. NOT
            // greyed by Split (applies either way); also driven by an RMB drag.
            Param.float_("gap",    "Gap", &gap_, 0.0f),
            // Offset Side (S9): where the Gap band sits vs the plane
            // (center/positive/negative). Applies with Split on or off (task 0288).
            Param.intEnum_("gapSide", "Offset Side", cast(int*)&gapSide_,
                           sliceGapSideTable[], cast(int)SliceGapSide.Center),
            // Angle Snap (S5): OFF (goldens-green factory default — see field
            // doc) draws the raw line; ON quantizes the line's work-plane angle
            // to the nearest `snapAngle` multiple before the plane is built.
            Param.bool_( "snap",   "Angle Snap", &snap_, false),
            // Angle (S5): the snap step in degrees. Greyed while Angle Snap is
            // off (paramEnabled). Default 45° per the reference spec.
            Param.float_("snapAngle", "Angle", &snapAngle_, 45.0f),
            // Axis (S3; owner-revised 0284): X / Y / Z (world-axis normal) /
            // Custom (vector normal) OVERRIDE. No Free value — the default plane
            // is the frozen drag plane (axisLocked_ false); writing this attr
            // engages the override. Default VALUE X (ignored until locked).
            Param.intEnum_("axis", "Axis", cast(int*)&axis_, sliceAxisTable[],
                           cast(int)SliceAxis.X),
            // Custom normal — greyed unless Axis == Custom (paramEnabled).
            Param.float_("vectorX", "Vector X", &vector_.x, 0.0f),
            Param.float_("vectorY", "Vector Y", &vector_.y, 1.0f),
            Param.float_("vectorZ", "Vector Z", &vector_.z, 0.0f),
        ];
    }

    // Grey the Vector gang unless a Custom axis is active — the custom normal is
    // only consulted when axis_ == Custom (reference: the Vector X/Y/Z rows are
    // enabled only for Axis = Custom).
    override bool paramEnabled(string name) const {
        if (name == "vectorX" || name == "vectorY" || name == "vectorZ")
            return axis_ == SliceAxis.Custom;
        // Cap Sections (S8) only acts once Split has duplicated the loop — grey
        // it while Split is off (it is a no-op there), mirroring the reference.
        if (name == "caps")
            return split_;
        // Gap + Offset Side (S9 / task 0288): ALWAYS enabled. Gap now applies
        // WITHOUT Split too — with Split off it opens a connected channel (two
        // parallel cuts), with Split on it separates the two shells (0290). So
        // both rows stay live regardless of Split (the captured reference is not
        // split-gated for gap; task 0288).
        // Angle (snapAngle) only matters when Angle Snap is on — grey it while
        // snap is off (a no-op there), mirroring the reference.
        if (name == "snapAngle")
            return snap_;
        return true;
    }

    // Test-introspection (GET /api/tool/state): echo the line + `fast` + a
    // neutral tool tag so a headless test can assert the driven start/end and
    // preview gate without a screenshot. Mirrors LoopSliceTool.toolStateJson
    // (data, not pixels).
    override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]   = JSONValue("slice");
        // Task 0286: whether a line has been drawn yet (false at bare activation —
        // nothing is shown / cut until the first drag). Lets a headless test assert
        // the clean-until-first-drag invariant without a screenshot.
        root["lineDrawn"] = JSONValue(hasLine_);
        root["startX"] = JSONValue(start_.x);
        root["startY"] = JSONValue(start_.y);
        root["startZ"] = JSONValue(start_.z);
        root["endX"]   = JSONValue(end_.x);
        root["endY"]   = JSONValue(end_.y);
        root["endZ"]   = JSONValue(end_.z);
        root["fast"]   = JSONValue(fast_);
        root["infinite"] = JSONValue(infinite_);
        root["split"]  = JSONValue(split_);
        root["caps"]   = JSONValue(caps_);
        root["gap"]     = JSONValue(gap_);
        root["gapSide"] = JSONValue(wireTagForValue(sliceGapSideTable[], cast(int)gapSide_));
        // Task 0288: whether an RMB gap-adjust drag is currently live (lets a
        // headless test observe the gap gizmo state without a screenshot).
        root["gapDragging"] = JSONValue(gapDrag_);
        root["snap"]      = JSONValue(snap_);
        // Task 0709 — the X chord's TEMPORARY inversion, and the state the
        // tool actually snaps by. `snap_` alone is the panel value and says
        // nothing about whether X is currently held, so a headless test could
        // observe neither the latch nor its release. These two make the chord
        // a data assertion instead of a screenshot.
        root["snapTempInvert"] = JSONValue(snapTempInvert_);
        root["effectiveSnap"]  = JSONValue(effectiveSnap());
        root["snapAngle"] = JSONValue(snapAngle_);
        root["axis"]    = JSONValue(wireTagForValue(sliceAxisTable[], cast(int)axis_));
        root["vectorX"] = JSONValue(vector_.x);
        root["vectorY"] = JSONValue(vector_.y);
        root["vectorZ"] = JSONValue(vector_.z);
        return root;
    }

    // Test-introspection (GET /api/tool/handles, task 0234): the registered
    // handle parts (DragStart=0, DragEnd=1, and — ONLY for axis == Custom — the
    // rotate ring DragRotate=3), so a headless test can assert the ring is
    // Custom-only without a screenshot. Reflects the last draw()'s registration;
    // null before the first draw / when no handles exist.
    override JSONValue toolHandlesJson() const {
        if (toolHandles_ is null) return JSONValue(null);
        return toolHandles_.toJson(vpWorld_);
    }

    override void activate() {
        active = true;
        dropPreview();
        // Snapshot the SESSION baseline once, now, at tool activation. Every
        // drag re-cuts non-cumulatively from this (never per-gesture), and the
        // deferred commit records before_ → the final cut as ONE undo entry.
        before_     = MeshSnapshot.capture(*mesh);
        haveBefore_ = true;
        // Freeze the restrict set (current polygon selection) for the session —
        // valid across previews because each restores the baseline face indexing.
        restrictFaces_ = sliceRestrictFaces(*mesh);
        armedKey_.stamp(*mesh);
        // Owner fix 4 (0284): a fresh tool session DEFAULTS to the drag plane
        // (no axis override), whatever the sticky `axis_` value shows. The user
        // re-engages the override by writing the `axis` attr (onParamChanged).
        axisLocked_ = false;
    }

    final PreparedSliceActivationImage buildPreparedActivation(out Mesh* source) {
        PreparedSliceActivationImage image;
        source = mesh;
        if (source is null) return image;
        image.before = MeshSnapshot.capture(*source);
        image.restrictFaces = sliceRestrictFaces(*source);
        image.armedKey.stamp(*source);
        image.valid = true;
        return image;
    }
    final void installPreparedActivation(ref PreparedSliceActivationImage image)
            nothrow @nogc {
        if (!image.valid) return;
        active = true; dragPart_ = DragNone; previewLive_ = false;
        haveBefore_ = true; haveRaw_ = false; snapTempInvert_ = false;
        haveFrozen_ = false; pendingAxisClassify_ = false;
        hasLine_ = false; drawGesture_ = false; ctrlPending_ = false;
        ctrlAxis_ = -1; gapDrag_ = false; axisLocked_ = false;
        image.before.moveInto(before_);
        restrictFaces_ = image.restrictFaces; image.restrictFaces = null;
        armedKey_ = image.armedKey;
        image.clear();
    }
    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.Slice, false);
        scope(failure) context.discard();
        auto owner = PreparedSliceActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareSliceActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.Slice, ok);
    }

    override void deactivate() {
        // Bake the live slice into ONE undo entry on tool-drop (task 0278) —
        // this is the ONLY commit point (never mouse-up). If no cut is live
        // (off-mesh / never-drawn line, or a headless applyHeadless already
        // ran its own ToolDoApplyCommand-wrapped cut), leave the mesh exactly
        // as it is and record nothing.
        if (active) commitCurrentSlice();
        active = false;
        dropPreview();
    }

    final bool ownsPreparedLayer(Layer layer) const {
        return layer !is null && &layer.meshRef() is mesh;
    }
    final PreparedSliceDeactivateImage buildPreparedDeactivateState(
            ref Mesh live) {
        PreparedSliceDeactivateImage image;
        image.valid = true; image.expectedActive = active;
        image.expectedPreviewLive = previewLive_;
        image.expectedHaveBefore = haveBefore_;
        image.expectedDragPart = dragPart_; image.expectedCtrlAxis = ctrlAxis_;
        image.expectedHaveRaw = haveRaw_;
        image.expectedSnapTempInvert = snapTempInvert_;
        image.expectedHaveFrozen = haveFrozen_;
        image.expectedPendingAxisClassify = pendingAxisClassify_;
        image.expectedHasLine = hasLine_;
        image.expectedDrawGesture = drawGesture_;
        image.expectedCtrlPending = ctrlPending_;
        image.expectedGapDrag = gapDrag_;
        image.expectedArmedAddr = armedKey_.addr;
        image.expectedArmedMutVer = armedKey_.mutVer;
        image.expectedLive = MeshSnapshot.capture(live);
        image.expectedBefore = before_;
        image.commitEligible = active && previewLive_ && haveBefore_ &&
            before_.filled && armedKey_.matches(live);
        return image;
    }
    final bool preparedDeactivateStateMatches(
            in PreparedSliceDeactivateImage image, ref const Mesh live) const
            nothrow @nogc {
        return image.valid && active == image.expectedActive &&
            previewLive_ == image.expectedPreviewLive &&
            haveBefore_ == image.expectedHaveBefore &&
            dragPart_ == image.expectedDragPart && ctrlAxis_ == image.expectedCtrlAxis &&
            haveRaw_ == image.expectedHaveRaw &&
            snapTempInvert_ == image.expectedSnapTempInvert &&
            haveFrozen_ == image.expectedHaveFrozen &&
            pendingAxisClassify_ == image.expectedPendingAxisClassify &&
            hasLine_ == image.expectedHasLine &&
            drawGesture_ == image.expectedDrawGesture &&
            ctrlPending_ == image.expectedCtrlPending &&
            gapDrag_ == image.expectedGapDrag &&
            armedKey_.addr == image.expectedArmedAddr &&
            armedKey_.mutVer == image.expectedArmedMutVer &&
            image.expectedLive.matches(live) &&
            image.expectedBefore.matches(before_);
    }
    final void installPreparedDeactivateState(
            ref PreparedSliceDeactivateImage image) nothrow @nogc {
        if (!image.valid) return;
        active = false; dragPart_ = DragNone; previewLive_ = false;
        haveBefore_ = false; haveRaw_ = false; snapTempInvert_ = false;
        haveFrozen_ = false; pendingAxisClassify_ = false;
        hasLine_ = false; drawGesture_ = false; ctrlPending_ = false;
        ctrlAxis_ = -1; gapDrag_ = false;
        armedKey_.addr = size_t.max; armedKey_.mutVer = ulong.max;
        image.clear();
    }
    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context,
            Layer layer) {
        if (context is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.Slice, false, false);
        scope(failure) context.discard();
        auto stateOwner = PreparedSliceDeactivateOwner.prepare(this, layer);
        bool ok = stateOwner !is null;
        bool historyPrepared;
        if (ok && stateOwner.commitEligible && history !is null &&
                gestureFactory !is null) {
            auto cmd = cast(MeshSessionEdit)gestureFactory();
            if (cmd !is null) {
                cmd.setSnapshots(before_, MeshSnapshot.capture(layer.meshRef()),
                    "Slice");
                historyPrepared = context.prepare(cmd,
                    PreparedHistoryKind.Plain).accepted;
                ok = historyPrepared;
            } else ok = context.prepareGestureCarrierMismatch();
        }
        if (ok) ok = historyPrepared ? context.markHistoryInstall()
                                     : context.markNoHistoryInstall();
        if (ok) ok = context.prepareSliceDeactivate(stateOwner);
        if (!ok) context.discard();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Slice, historyPrepared, ok);
    }

    version(unittest) final void seedPreparedDeactivateForTest(ref Mesh live) {
        active = true; previewLive_ = true; haveBefore_ = true;
        before_ = MeshSnapshot.capture(live);
        live.vertices[0].x += 0.25f;
        live.commitChange(MeshEditScope.Position);
        armedKey_.stamp(live); dragPart_ = DragRotate; haveRaw_ = true;
        snapTempInvert_ = haveFrozen_ = pendingAxisClassify_ = true;
        hasLine_ = drawGesture_ = ctrlPending_ = gapDrag_ = true;
        ctrlAxis_ = 2;
    }
    version(unittest) final bool preparedDeactivateInstalledForTest() const
            nothrow @nogc {
        return !active && dragPart_ == DragNone && !previewLive_ &&
            !haveBefore_ && !haveRaw_ && !snapTempInvert_ && !haveFrozen_ &&
            !pendingAxisClassify_ && !hasLine_ && !drawGesture_ &&
            !ctrlPending_ && ctrlAxis_ == -1 && !gapDrag_ &&
            armedKey_.addr == size_t.max && armedKey_.mutVer == ulong.max;
    }
    version(unittest) final void mutatePreparedDeactivateForTest()
            nothrow @nogc { gapDrag_ = false; }

    // Clear per-session preview/drag state WITHOUT touching the mesh or
    // history — the safe teardown for a mesh swapped out from under us.
    private void dropPreview() {
        dragPart_       = DragNone;
        previewLive_    = false;
        haveBefore_     = false;
        haveRaw_        = false;
        snapTempInvert_ = false;
        haveFrozen_     = false;   // owner fix 3 (0284): re-capture on the next gesture
        pendingAxisClassify_ = false;   // owner fix 1 (0284): no draw in flight to classify
        // Task 0286: a fresh session (activate → dropPreview) starts with NO line
        // and no in-flight Ctrl lock, so the viewport is clean until the first drag.
        hasLine_        = false;
        drawGesture_    = false;
        ctrlPending_    = false;
        ctrlAxis_       = -1;
        gapDrag_        = false;   // task 0288: no RMB gap drag in flight
        armedKey_.invalidate();
    }

    // No standing preview persists across frames outside a drag, so there is
    // never an uncommitted edit to coordinate with history navigation.
    override void evaluate() {}

    // Tool Properties param edit (task 0283). A panel edit of any CUT-AFFECTING
    // param must re-apply to the CURRENT live slice immediately — not wait for
    // the next drag. The field was already written by injectParamsInto BEFORE
    // this fires (commands/tool/attr.d, and PropertyPanel), so for startX..endZ
    // the new value already sits in start_/end_ (params() binds the field
    // pointers) and re-previewing simply picks it up. We re-cut the CURRENT line
    // from the activation baseline via updatePreview() — the same
    // non-cumulative kernel the drag path uses.
    //
    // FAST DECISION: `fast_` gates the LIVE DRAG recompute (onMouseMotion), so
    // dense meshes don't re-cut on every motion event. A panel edit is a single
    // DELIBERATE action, not a drag, so it re-previews REGARDLESS of `fast_` —
    // the user expects the value they just typed to take effect at once. `fast`
    // itself is NOT a cut-affecting param, so editing it is a no-op here (falls
    // through the switch's default) and never spuriously toggles geometry.
    override void onParamChanged(string pname) {
        switch (pname) {
            // The line endpoints + every plane/cut option. Anything else
            // (notably `fast`) is intentionally excluded — no live rebuild.
            case "startX": case "startY": case "startZ":
            case "endX":   case "endY":   case "endZ":
            case "split":  case "caps":   case "gap":   case "gapSide":
            case "axis":   case "vectorX": case "vectorY": case "vectorZ":
            case "infinite": case "snap": case "snapAngle":
                break;
            default:
                return;
        }
        // Owner fix 4 (0284): writing the `axis` attribute ENGAGES the axis
        // override (world X/Y/Z or Custom vector). This runs BEFORE the
        // re-preview guards below so the lock latches even when no live cut yet
        // sits on the mesh (the headless fixture path: activate → tool.attr axis
        // <x|z|custom> → tool.doApply, where previewLive_ is false). Until this
        // fires the plane uses the frozen drag normal (SLICE_AXIS_DRAG).
        if (pname == "axis") axisLocked_ = true;
        // Guard: only re-preview a slice that ALREADY has a live cut on the
        // mesh, while the tool is active and NOT mid-drag (during a drag the
        // motion path owns the preview and this edit would fight it).
        //
        // `previewLive_` is the authoritative "a slice currently sits on the
        // mesh" signal: an interactive drag (even in `fast` mode, which
        // materialises the cut on mouse-up — onMouseButtonUp → updatePreview)
        // sets it true, and updatePreview() clears it whenever the line misses
        // every face. We deliberately do NOT also fire on the looser
        // `start_ != end_` "a line is placed" test: the HEADLESS apply path
        // (fixtures / HTTP tool.doApply) ACTIVATES the tool with the idle
        // default line already non-degenerate and then configures params via
        // tool.attr BEFORE doApply — under a `start_ != end_` guard each of
        // those config writes would leave a preview cut on the mesh that
        // applyHeadless (which never restores the baseline) would then cut a
        // SECOND time (double slice). Gating on `previewLive_` keeps the
        // headless path a single clean cut while still re-previewing every
        // interactive panel edit (a real drawn slice always has previewLive_).
        if (!active || dragPart_ != DragNone) return;
        if (!previewLive_) return;
        updatePreview();
    }

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply / HTTP). Builds the plane from the current
    // start/end + the DEFAULT construction plane's normal (world XZ ⇒ +Y in
    // `--test`, deterministic — the camera-facing auto pick has no headless
    // equivalent, see create_common.currentWorkplaneFrame) and cuts. Must NOT
    // snapshot itself — ToolDoApplyCommand wraps this with its own snapshot
    // pair and IS the undo entry. A single clean cut (no baseline restore —
    // headless never leaves a preview on the mesh), byte-for-byte the S0 path.
    // -------------------------------------------------------------------
    override bool applyHeadless() {
        // Angle Snap (S5): quantize the line's work-plane angle before the plane
        // (and the clip span) is built. Headless has no drag context, so the
        // snap pivots about Start and rotates End — the deterministic convention.
        // A local copy leaves the driven start_/end_ params untouched.
        WorkplaneFrame wf = currentWorkplaneFrame();
        Vec3 sStart = start_, sEnd = end_;
        if (snap_)
            sEnd = snapLineEndpointToAngle(sStart, sEnd, wf.axis1, wf.axis2, snapAngle_);
        // Owner fixes 3 + 4 (0284): use the FROZEN drag normal when the tool
        // captured one (interactive session), else the deterministic headless
        // work-plane normal; and pass the axis OVERRIDE mode only when locked
        // (SLICE_AXIS_DRAG = the drawn-line ⟂ work-plane plane otherwise).
        Vec3 nrm = haveFrozen_ ? frozenNormal_ : wf.normal;
        Vec3 p, n;
        if (!planeForSlice(sStart, sEnd, nrm, effectiveAxisMode(), vector_, p, n))
            return false;
        // Restrict the cut to the current polygon selection (task 0279): the
        // reference Slice cuts ONLY the selected polygons, the whole layer when
        // nothing is selected (empty set ⇒ whole cut).
        uint[] restrict = sliceRestrictFaces(*mesh);
        // infinite ⇒ whole-mesh plane cut; else clip to the drawn Start→End span.
        // split ⇒ route the same cut through cutByPlaneEx so the loop is
        // duplicated into two disconnected boundary loops (S7); caps ⇒ seal each
        // section with a cap polygon (S8, forwarded to splitAlongCutLoop).
        size_t nSplit;
        if (split_) {
            // gap/gapSide (S9): separate the two split shells along the plane
            // normal by gap_, offset per gapSide_ (no-op at gap_ == 0).
            //
            // Task 0291: an UNRESTRICTED gap routes through `sliceSplitGap`
            // (two real parallel plane cuts + band delete) instead of the
            // single-cut + fixed along-edge slide — MUST stay in lockstep with
            // sliceFromBaseline's split+gap branch (see its doc comment).
            if (gap_ != 0.0f && restrict.length == 0) {
                nSplit = sliceSplitGap(*mesh, p, n, /*clipped*/!infinite_, sStart, sEnd,
                                       caps_, gap_, cast(int)gapSide_, restrict);
            } else {
                PlaneCutLoops loops;
                auto ed = MeshEditBatch.unrecorded(*mesh, kCutEditScope);
                nSplit = ed.cutByPlaneEx(p, n, /*clipped*/!infinite_, sStart, sEnd,
                                         /*split*/true, caps_, loops, 1e-5f, restrict,
                                         gap_, cast(int)gapSide_);
                ed.close();
            }
        } else {
            // A single connected plane cut through `pp` (infinite/clipped +
            // restrict). Nested so the Gap-without-split path fires it twice.
            // MUST stay in lockstep with sliceFromBaseline's non-split branch.
            // Takes the batch, does not open one — the twin of
            // `sliceFromBaseline`'s `cutAt` (task 1903 Stage E3).
            size_t cutAt(ref MeshEditBatch ed, Vec3 pp) {
                if (restrict.length > 0)
                    return infinite_ ? ed.cutByPlaneRestricted(pp, n, restrict)
                                     : ed.cutByPlaneClipped(pp, n, sStart, sEnd, 1e-5f, restrict);
                return infinite_ ? ed.cutByPlane(pp, n)
                                 : ed.cutByPlaneClipped(pp, n, sStart, sEnd);
            }
            // Gap WITHOUT Split (task 0288): two parallel cuts `gap` apart open a
            // CONNECTED channel — the captured reference geometry (see
            // sliceFromBaseline; task 0288). gap_ == 0 ⇒ one cut (byte-for-byte
            // the S0/S4 path).
            if (gap_ != 0.0f) {
                float loAmt, hiAmt;
                switch (cast(int)gapSide_) {
                    case cast(int)SliceGapSide.Positive: loAmt = gap_;        hiAmt = 0.0f;        break;
                    case cast(int)SliceGapSide.Negative: loAmt = 0.0f;        hiAmt = gap_;        break;
                    default:                              loAmt = gap_ * 0.5f; hiAmt = gap_ * 0.5f; break;
                }
                auto ed = MeshEditBatch.unrecorded(*mesh, kCutEditScope);
                nSplit = cutAt(ed, p + n * loAmt) + cutAt(ed, p - n * hiAmt);
                ed.close();
            } else {
                auto ed = MeshEditBatch.unrecorded(*mesh, kCutEditScope);
                nSplit = cutAt(ed, p);
                ed.close();
            }
        }
        if (nSplit == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;

        // RMB: with an LMB gesture IN FLIGHT → cancel it (revert to baseline, no
        // undo entry). Otherwise (task 0288) RMB begins a GAP-adjust drag — drag
        // left/right to change `gap`, with a dashed-circle + value HUD (draw()).
        // Needs a drawn line to gap around; falls through (returns false) when no
        // line exists yet so the app's RMB paths still work at bare activation.
        if (e.button == SDL_BUTTON_RIGHT) {
            if (dragPart_ != DragNone) { cancelGesture(); return true; }
            if (hasLine_) { beginGapDrag(e.x, e.y); return true; }
            return false;
        }

        SDL_Keymod mods = SDL_GetModState();
        if (mods & KMOD_ALT) return false;   // reserved for camera nav (orbit/pan/zoom)
        bool shift = (mods & KMOD_SHIFT) != 0;
        bool ctrl  = (mods & KMOD_CTRL)  != 0;   // task 0286: axis-constrain the gesture

        // Latch the line as it stands NOW so RMB can cancel just this gesture
        // (the session baseline is never per-gesture — see the class comment).
        gStart0_  = start_;
        gEnd0_    = end_;
        gVector0_ = vector_;   // task 0287: rotate-gesture RMB-cancel restores the tilt

        // Middle-click relocates the whole line to the cursor: translate so the
        // line midpoint lands on the work-plane hit, then drag it as a line
        // translate.
        if (e.button == SDL_BUTTON_MIDDLE) {
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            Vec3 mid   = (start_ + end_) * 0.5f;
            Vec3 delta = hit - mid;
            start_ = start_ + delta;
            end_   = end_   + delta;
            // Relocate is a translate — keep the existing frozen plane
            // orientation (capture one if this is the first gesture).
            ensureFrozenNormal();
            beginLineDrag(hit);
            hasLine_     = true;   // a line now exists (task 0286)
            drawGesture_ = false;  // relocate is a translate, not a draw
            kickPreview();
            return true;
        }

        if (e.button != SDL_BUTTON_LEFT) return false;

        if (shift) {
            // Shift+drag resets/redraws: start a fresh line from the cursor
            // regardless of what the click landed near — a fresh line RE-CAPTURES
            // the plane orientation from the current work plane and returns to the
            // drag plane (clears any axis override — owner fixes 3 + 4, 0284).
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            start_ = hit;
            end_   = hit;
            beginFreshLinePlane();
            dragPart_    = DragEnd;
            hasLine_     = true;    // the redraw lays a line (task 0286)
            drawGesture_ = true;    // Shift+drag DRAWS — Ctrl locks the direction
            armCtrl(ctrl, e.x, e.y);
            kickPreview();
            return true;
        }

        // Plain LMB — task 0286 input model:
        //   • No line yet → FIRST drag: down = Start, the drag defines the End
        //     (draws a fresh line). Ctrl locks the drawn DIRECTION to a world axis.
        //   • Line exists + click ON an endpoint handle → refine that endpoint
        //     (kept as a bonus gesture; the primary second-drag is a translate).
        //   • Line exists + click elsewhere → SECOND drag: translate the WHOLE
        //     line (both points). Ctrl locks the TRANSLATION to a world axis
        //     (the same single-axis constraint MoveTool applies).
        int grabbed = hasLine_ ? pickHandle(cast(float)e.x, cast(float)e.y) : -1;
        if (grabbed >= 0) {
            // Endpoint drag refines the EXISTING line — keep the frozen plane.
            ensureFrozenNormal();
            dragPart_    = grabbed;
            drawGesture_ = false;
        } else if (hasLine_ && axis_ == SliceAxis.Custom &&
                   beginRotateIfRingHit(cast(float)e.x, cast(float)e.y)) {
            // Custom-axis rotate ring grabbed (task 0287): beginRotateIfRingHit
            // latched the DragRotate gesture — nothing else to set up here.
        } else if (!hasLine_) {
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            start_ = hit;
            end_   = hit;
            beginFreshLinePlane();   // fresh line → re-capture normal, drop override
            dragPart_    = DragEnd;   // the drag defines the End of the new line
            hasLine_     = true;
            drawGesture_ = true;
            armCtrl(ctrl, e.x, e.y);   // Ctrl on the FIRST drag → axis-locked line
        } else {
            Vec3 hit;
            if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return false;
            ensureFrozenNormal();   // whole-line translate — keep the frozen plane
            beginLineDrag(hit);
            drawGesture_ = false;
            armCtrl(ctrl, e.x, e.y);   // Ctrl on the SECOND drag → axis-locked move
        }
        kickPreview();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active) return false;

        // RMB gap-adjust drag (task 0288): the horizontal travel from the grab
        // pixel maps to an ABSOLUTE gap. gap now applies even without Split (it
        // opens a channel), so re-preview live unless `fast` defers the cut. This
        // runs BEFORE the dragPart_ gate — the gap drag owns no line handle.
        if (gapDrag_) {
            float g = gapDragStartGap_ + (e.x - gapDragStartMX_) * GAP_DRAG_PX_TO_WORLD;
            if (g < 0.0f) g = 0.0f;   // gap is a non-negative distance
            gap_ = g;
            if (!fast_) updatePreview();
            return true;
        }

        if (dragPart_ == DragNone) return false;

        // Custom-axis rotate ring (task 0287): tilt the Custom vector — and thus
        // the cut plane — about the drawn line. The endpoints DO NOT move (this
        // gesture never touches start_/end_). Absolute angle from the frozen grab.
        if (dragPart_ == DragRotate) {
            Vec3 hit;
            if (ringPlaneHit(cast(float)e.x, cast(float)e.y, rotCenter0_, rotAxis0_, hit)) {
                Vec3 cur = hit - rotCenter0_;           // in the ring plane ⟂ axis
                if (cur.length > 1e-6f) {
                    float ang = signedAngleAboutAxis(rotRefDir0_, cur, rotAxis0_);
                    vector_ = rotateVectorAboutAxis(rotVector0_, rotAxis0_, ang);
                    if (!fast_) updatePreview();
                }
            }
            return true;
        }

        // Ctrl axis-lock (task 0286): once the drag has moved far enough for a
        // clear direction (the MoveTool wait-gate), resolve the locked world axis
        // via the shared chooseConstraintAxis. Until then, swallow the motion.
        if (ctrlPending_) {
            int tdx = e.x - ctrlStartMX_, tdy = e.y - ctrlStartMY_;
            if (tdx * tdx + tdy * tdy < 25) return true;
            ctrlAxis_    = resolveCtrlAxis(tdx, tdy);
            ctrlPending_ = false;
        }

        Vec3 hit;
        if (!workplaneHit(cast(float)e.x, cast(float)e.y, hit)) return true;

        bool ctrlLocked = ctrlAxis_ >= 0;
        if (ctrlLocked && drawGesture_ && dragPart_ == DragEnd) {
            // FIRST drag under Ctrl: draw the line ALONG the locked world axis —
            // the End slides only along that axis from the fixed Start. Angle Snap
            // is bypassed (the two constraints are mutually-exclusive gestures).
            Vec3 ax = worldAxisVec(ctrlAxis_);
            rawStart_ = start_;                       // Start fixed
            rawEnd_   = start_ + ax * dot(hit - start_, ax);
            end_      = rawEnd_;
            haveRaw_  = true;
        } else if (ctrlLocked && dragPart_ == DragLine) {
            // SECOND drag under Ctrl: translate BOTH points along the locked axis
            // (the same single-axis constraint MoveTool applies to a free move).
            Vec3 ax    = worldAxisVec(ctrlAxis_);
            Vec3 delta = ax * dot(hit - dragAnchor_, ax);
            rawStart_ = dragStart0_ + delta;
            rawEnd_   = dragEnd0_   + delta;
            start_    = rawStart_;
            end_      = rawEnd_;
            haveRaw_  = true;
        } else {
            // Unconstrained: record the RAW (unsnapped) endpoints, then let Angle
            // Snap (S5) derive the actual start_/end_. Keeping the raw pair lets
            // the X-key toggle re-snap mid-drag without a fresh mouse move.
            final switch (dragPart_) {
                case DragStart: rawStart_ = hit;    rawEnd_ = end_;  break;
                case DragEnd:   rawStart_ = start_; rawEnd_ = hit;   break;
                case DragLine:
                    Vec3 delta = hit - dragAnchor_;
                    rawStart_ = dragStart0_ + delta;
                    rawEnd_   = dragEnd0_   + delta;
                    break;
            }
            haveRaw_ = true;
            applyAngleSnapFromRaw();
        }

        // Live preview unless `fast` defers the cut to mouse-up.
        if (!fast_) updatePreview();
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        // End an RMB gap-adjust drag (task 0288): materialise the final gap into
        // the preview so it holds after release. Handled before the dragPart_ gate
        // (the gap drag owns no line handle).
        if (gapDrag_ && e.button == SDL_BUTTON_RIGHT) {
            gapDrag_ = false;
            updatePreview();
            return true;
        }
        if (dragPart_ == DragNone) return false;
        if (e.button != SDL_BUTTON_LEFT && e.button != SDL_BUTTON_MIDDLE) return false;
        dragPart_ = DragNone;
        // Task 0286: the Ctrl lock is per-gesture — clear it so the next gesture
        // re-decides (a following non-Ctrl drag is unconstrained).
        ctrlPending_ = false;
        ctrlAxis_    = -1;
        // Mouse-up does NOT commit (task 0278) — the slice stays LIVE for the
        // rest of the session; the single undo entry is baked at tool-drop.
        // Materialise the final cut here so `fast` mode (which suppresses the
        // live cut during the drag) shows/holds the result, and so the
        // non-fast path lands exactly on the release line.
        updatePreview();
        // Owner fix 1 (0284): a fresh line is now drawn OUT — its direction is
        // known, so classify the drawn plane's normal to a concrete Axis and lock
        // it (the panel then reflects the drawn plane). The classified axis
        // reproduces the SAME plane, so this never moves the just-cut geometry.
        if (pendingAxisClassify_) {
            pendingAxisClassify_ = false;
            classifyDrawnPlaneAxis();
        }
        return true;
    }

    // X-key TEMPORARY snap toggle (S5): while X is held the effective snap state
    // is inverted (reference: "press X in-viewport to temporarily toggle
    // snapping"). Consumes X so the global snap.toggle does not also fire while
    // the Slice tool is active. Re-derives the line from the raw endpoints and
    // re-previews so the flip is visible immediately, without a fresh mouse move.
    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        if (!active || e.keysym.sym != SDLK_x) return false;
        if (!e.repeat && !snapTempInvert_) { snapTempInvert_ = true; retrySnapPreview(); }
        return true;
    }

    override bool onKeyUp(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        if (!active || e.keysym.sym != SDLK_x) return false;
        if (snapTempInvert_) { snapTempInvert_ = false; retrySnapPreview(); }
        return true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        // Cache the viewport for the endpoint ray casts / handle picks in the
        // event handlers.
        if (!visualOnly) vpWorld_ = vp;
        if (!active) return;
        // Task 0286: NOTHING is shown at bare activation — no overlay, no line, no
        // endpoint handles — until the FIRST LMB drag has laid a line. (vpWorld_ is
        // cached ABOVE this gate so the event handlers still have a viewport for
        // their ray casts before the first draw.)
        if (!hasLine_) return;

        // Lazily build the endpoint handle geometry (needs a live GL context).
        if (startH_ is null) {
            startH_      = new BoxHandler(start_, HANDLE_COLOR);
            endH_        = new BoxHandler(end_,   HANDLE_COLOR);
            // Rotate ring (task 0287) — placeholder geometry; re-positioned each
            // frame below when axis_ == Custom.
            rotRing_     = new FullCircleHandler(Vec3(0, 0, 0), Vec3(0, 0, 1), 1.0f, RING_COLOR);
            // WINDOW PIXELS — halved from 2.5f with task 0600's geometry-shader
            // unit fix (see shader.thickLineGeomSrc). Renders the same 1.25 px.
            rotRing_.lineWidth = 1.25f;
            toolHandles_ = new ToolHandles();
        }
        // Screen-constant handle size (~10 px cyan square, reference-matched),
        // re-positioned on the live endpoints. gizmoSize()'s half-extent maps
        // to getGizmoPixels() px, so scale it to HANDLE_HALF_PX px.
        immutable float handleScale = HANDLE_HALF_PX / getGizmoPixels();
        startH_.pos = start_; startH_.size = gizmoSize(start_, vp, handleScale);
        endH_.pos   = end_;   endH_.size   = gizmoSize(end_,   vp, handleScale);

        // Translucent CUT-PLANE overlay (task 0284): a rectangle lying IN the
        // cut plane, spanning EXACTLY the drawn line along it (owner fix 1 — never
        // past the endpoint handles) and extending across it to cover the region
        // being cut. Built from the SAME plane the cut uses: the
        // FROZEN drag normal + the axis-override mode (owner fixes 3 + 4), so it
        // tracks drags / panel edits AND stays put under camera orbit — exactly
        // where the committed cut is. Drawn FIRST (before the line + handles) so
        // those stay visible on top.
        //
        // DEPTH (owner fix 2): the plane is depth-TESTED so the mesh occludes the
        // part behind it and the plane visibly CUTS THROUGH the geometry (not a
        // float-on-top overlay). Depth WRITES are off (translucent — it must not
        // occlude the line/mesh behind it) and back-face culling is disabled so
        // the plane shows from either side. Alpha-blended (the grid alpha
        // precedent, app.d). drawWorldQuad's caller-owns-state contract means we
        // set + restore GL_BLEND / depth mask / cull here.
        {
            Vec3 pp, nn;
            if (planeForSlice(start_, end_, effectiveNormal(),
                              effectiveAxisMode(), vector_, pp, nn)) {
                // Branch on the GEOMETRY, not the lock flag (owner fixes 1 + 2,
                // 0284; extrusion-direction model). Under the extrusion model the
                // drawn line LIES IN the cut plane for EVERY axis mode (n ⟂ line by
                // construction: drag, X/Y/Z, and Custom all extrude the line) — so
                // the LINE-based basis applies throughout: along-`dir` bounded to
                // the drawn segment, across-`perp` biased LARGER to read past the
                // handles (owner fix 2). The only exception is the TRUE degenerate
                // where the line runs (near-)parallel to the extrusion axis (cross
                // ≈ 0, planeForSlice already returned false so we do not get here) —
                // any residual near-degenerate case falls back to the NORMAL-derived,
                // mesh-covering basis so the quad is still a valid in-plane rect.
                Vec3 dir, perp;
                bool haveBasis;
                float aMin, aMax, bMin, bMax;
                if (sliceOverlayBasis(start_, end_, nn, dir, perp)) {
                    haveBasis = true;
                    sliceOverlayExtent(*mesh, primaryModelSpace(),
                                       pp, dir, perp, start_, end_,
                                       aMin, aMax, bMin, bMax);
                } else if (sliceOverlayBasisLocked(nn, dir, perp)) {
                    haveBasis = true;
                    sliceOverlayExtentLocked(*mesh, primaryModelSpace(),
                                             pp, dir, perp,
                                             aMin, aMax, bMin, bMax);
                } else {
                    haveBasis = false;
                }
                if (haveBasis) {
                    Vec3[4] quad = sliceOverlayQuad(pp, dir, perp,
                                                    aMin, aMax, bMin, bMax);
                    GLboolean wasCull = glIsEnabled(GL_CULL_FACE);
                    glEnable(GL_BLEND);
                    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                    glEnable(GL_DEPTH_TEST);   // mesh occludes the plane behind it
                    glDepthMask(GL_FALSE);     // ...but the translucent plane writes no depth
                    glDisable(GL_CULL_FACE);   // show the plane from both sides
                    drawWorldQuad(quad, vp, PLANE_COLOR, PLANE_ALPHA, shader.program);
                    glDepthMask(GL_TRUE);
                    glDisable(GL_BLEND);
                    if (wasCull) glEnable(GL_CULL_FACE);
                }
            }
        }

        // The Start→End line, drawn over the mesh (depth-test off, like the
        // other gizmos) so it stays visible against the surface being cut.
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identityMatrix.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glDisable(GL_DEPTH_TEST);
        // 1.25f is WINDOW PIXELS — halved from 2.5f with task 0600's
        // geometry-shader unit fix (see shader.thickLineGeomSrc). Same ink.
        drawWorldSegment(start_, end_, vp, LINE_COLOR, 1.25f, shader.program);
        glEnable(GL_DEPTH_TEST);

        // Custom-axis rotate gizmo (task 0287): position the ring around the
        // Start→End line — centred at the line midpoint, its plane ⟂ the line
        // (normal = the line direction), a screen-constant radius. Shown ONLY for
        // axis_ == Custom and a non-degenerate line; dragging it tilts the plane
        // about the line (the endpoints stay). The overlay + cut above already
        // follow `vector_` via effectiveNormal()/planeForSlice.
        Vec3 seg      = end_ - start_;
        bool showRing = axis_ == SliceAxis.Custom && seg.length > 1e-6f;
        if (showRing) {
            Vec3 center     = (start_ + end_) * 0.5f;
            rotRing_.center = center;
            rotRing_.normal = normalize(seg);
            rotRing_.radius = ringRadiusWorld(center, vp);
        }

        // Hover / capture highlight through the single-source arbiter: the
        // dragged handle stays hot for the whole gesture; otherwise the hovered
        // handle lights up. The ring joins the same pool when Custom is active.
        toolHandles_.begin();
        toolHandles_.add(startH_, DragStart);
        toolHandles_.add(endH_,   DragEnd);
        if (showRing) toolHandles_.add(rotRing_, DragRotate);
        if      (dragPart_ == DragStart)  toolHandles_.setHaul(DragStart);
        else if (dragPart_ == DragEnd)    toolHandles_.setHaul(DragEnd);
        else if (dragPart_ == DragRotate) toolHandles_.setHaul(DragRotate);
        else                              toolHandles_.setHaul(-1);
        int mx, my;
        queryMouse(mx, my);
        toolHandles_.update(mx, my, vp);

        if (showRing) rotRing_.draw(shader, vp);
        startH_.draw(shader, vp);
        endH_.draw(shader, vp);

        // RMB gap-adjust dashed-circle + value HUD (task 0288), only while an RMB
        // gap drag is live. Screen-space overlay drawn last, on top of everything.
        if (gapDrag_) drawGapHud(vp);
    }

private:
    // Kick the live preview at the start of a gesture (unless `fast` defers the
    // cut to mouse-up). Does NOT snapshot — the session baseline was captured
    // once at activation.
    void kickPreview() {
        if (!fast_) updatePreview();
    }

    // Latch the line-translate reference state from the current endpoints.
    void beginLineDrag(Vec3 anchor) {
        dragPart_   = DragLine;
        dragStart0_ = start_;
        dragEnd0_   = end_;
        dragAnchor_ = anchor;
    }

    // Start an RMB gap-adjust drag (task 0288): latch the current gap + the mouse
    // pixel so onMouseMotion computes an ABSOLUTE gap from the horizontal travel.
    void beginGapDrag(int mx, int my) {
        gapDrag_         = true;
        gapDragStartGap_ = gap_;
        gapDragStartMX_  = mx;
        gapDragStartMY_  = my;
    }

    // RMB gap-adjust HUD (task 0288): a DASHED CIRCLE whose pixel radius grows
    // with `gap` (via the SAME px↔world scale the drag uses, so the ring tracks
    // the cursor's horizontal travel) + the gap VALUE as text, centred at the
    // projected line midpoint. Drawn in SCREEN space through the ImGui foreground
    // draw list (a UI affordance, not baked geometry — the reference draws the
    // same dashed ring + value while RMB-dragging gap). The dash is N short arc
    // segments with every other one skipped (GL-core has no line stipple).
    void drawGapHud(const ref Viewport vp) {
        Vec3 mid = (start_ + end_) * 0.5f;
        float cx, cy, ndcZ;
        if (!projectToWindowFull(mid, vp, cx, cy, ndcZ)) return;
        ImDrawList* dl = ImGui.GetForegroundDrawList();
        float rPx = 8.0f + gap_ / GAP_DRAG_PX_TO_WORLD;   // floor + grows with gap
        enum int N = 48;
        immutable uint ringCol = IM_COL32(90, 220, 220, 230);   // teal (gizmo-ring family)
        for (int i = 0; i < N; i += 2) {
            float a0 = (2.0f * PI) * i       / N;
            float a1 = (2.0f * PI) * (i + 1) / N;
            dl.AddLine(ImVec2(cx + cos(a0) * rPx, cy + sin(a0) * rPx),
                       ImVec2(cx + cos(a1) * rPx, cy + sin(a1) * rPx), ringCol, 1.5f);
        }
        import std.format : format;
        string label = format("gap %.3f", gap_);
        dl.AddText(ImVec2(cx + rPx + 6.0f, cy - 8.0f),
                   IM_COL32(255, 255, 255, 235), label);
    }

    // --- Ctrl axis-constraint (task 0286), reusing MoveTool.chooseConstraintAxis -

    // Arm the per-gesture Ctrl lock: when `ctrl` is held, the locked axis is
    // resolved LAZILY on the first sufficient movement (onMouseMotion), from the
    // pixel the gesture began at. A no-Ctrl gesture clears any prior lock.
    void armCtrl(bool ctrl, int mx, int my) {
        ctrlPending_ = ctrl;
        ctrlAxis_    = -1;
        ctrlStartMX_ = mx;
        ctrlStartMY_ = my;
    }

    // Resolve the dominant world axis for the Ctrl lock from the drag's pixel
    // delta, via the SAME selector MoveTool's Ctrl lock uses (chooseConstraintAxis
    // — screen-projected world axis best aligned with the mouse movement). The
    // gesture center is the fixed Start for a draw (the line pivots about it) or
    // the line midpoint for a translate; axis-end probes sit one unit along each
    // world axis from that center so their screen directions are well-defined.
    int resolveCtrlAxis(int tdx, int tdy) {
        if (vpWorld_.width <= 0) return -1;
        Vec3 camBack = Vec3(vpWorld_.view[2], vpWorld_.view[6], vpWorld_.view[10]);
        Vec3 center  = drawGesture_ ? start_ : (start_ + end_) * 0.5f;
        Vec3 ex = center + Vec3(1, 0, 0);
        Vec3 ey = center + Vec3(0, 1, 0);
        Vec3 ez = center + Vec3(0, 0, 1);
        return chooseConstraintAxis(camBack,
            Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
            ex, ey, ez, center, vpWorld_, tdx, tdy);
    }

    // The world axis vector for a resolved Ctrl-lock index (0=X / 1=Y / 2=Z).
    static Vec3 worldAxisVec(int a) {
        if (a == 0) return Vec3(1, 0, 0);
        if (a == 1) return Vec3(0, 1, 0);
        return Vec3(0, 0, 1);
    }

    // Refresh the non-cumulative preview: restore the SESSION baseline, re-cut
    // with the current line, stamp the mesh guard, and push to the GPU. Leaves
    // the mesh AT the baseline (previewLive_ = false) when the line misses
    // every face, so an off-mesh drag never shows a stale cut — and the
    // deferred commit then records nothing.
    void updatePreview() {
        if (!haveBefore_) return;
        // Owner fixes 3 + 4 (0284): cut with the FROZEN drag normal + the
        // axis-override mode (SLICE_AXIS_DRAG when no override is locked), so the
        // preview matches the overlay AND does not shift under camera orbit.
        size_t nSplit = sliceFromBaseline(*mesh, before_, start_, end_,
                                          effectiveNormal(), effectiveAxisMode(), vector_,
                                          infinite_, split_, caps_, restrictFaces_,
                                          gap_, cast(int)gapSide_);
        previewLive_ = nSplit > 0;
        // Stamp AFTER the cut, BEFORE refreshDisplay (which does not bump
        // mutationVersion): the guard now reflects the mesh state WE produced,
        // so deactivate() can tell whether anything external has since touched
        // it (mirrors LoopSliceTool.rebuildCut).
        armedKey_.stamp(*mesh);
        refreshDisplay(mesh, gpu);
    }

    // RMB cancel: revert ONLY the current gesture (restore the line to where it
    // stood when this drag began) and re-preview from the session baseline. The
    // session stays alive — the baseline is not dropped.
    void cancelGesture() {
        dragPart_    = DragNone;
        ctrlPending_ = false;   // task 0286: cancel drops any in-flight Ctrl lock
        ctrlAxis_    = -1;
        start_    = gStart0_;
        end_      = gEnd0_;
        vector_   = gVector0_;   // task 0287: restore the pre-drag Custom tilt
        updatePreview();
    }

    // Bake the live slice into ONE undo entry (called from deactivate). The
    // mesh already holds the non-cumulative preview cut for the current line
    // (mutate/revert keeps exactly one cut on it), so this just records
    // before_ → the current mesh. No-ops when nothing is live to commit
    // (off-mesh / never-drawn line, or a headless applyHeadless path), and
    // drops silently if the mesh was swapped out from under us since the last
    // preview (armedKey_ mismatch) rather than baking a bogus entry.
    void commitCurrentSlice() {
        if (!previewLive_ || !haveBefore_ || !before_.filled) return;
        // recorded remainder (1906 §3.6): `mutationVersion` — an IDENTITY guard, not a cache; see the `armedKey_` field note.
        if (!armedKey_.matches(*mesh)) return;   // mesh swapped since last preview — drop
        if (history is null || gestureFactory is null) return;
        auto cmd = cast(MeshSessionEdit) gestureFactory();
        if (cmd is null) { noteGestureCarrierMismatch(); return; }
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before_, post, "Slice");
        recordGestureEdit(cmd, GestureRecordMode.Plain);
    }

    // The work-plane normal the interactive path builds the cut plane from.
    // Uses the live workplane frame (respects a user-set non-auto workplane);
    // pickWorkplaneFrame needs a viewport, so fall back to the pipe default
    // (currentWorkplaneFrame) when none was cached yet.
    Vec3 cachedWorkplaneNormal() {
        if (vpWorld_.width > 0) return pickWorkplaneFrame(vpWorld_).normal;
        return currentWorkplaneFrame().normal;
    }

    // --- Frozen cut-plane orientation (owner fixes 3 + 4, task 0284) ---------

    // Capture the work-plane normal NOW and freeze it for the rest of the line's
    // life. Called at the gesture that DRAWS/relocates the line, so subsequent
    // camera orbits leave the plane orientation untouched.
    void captureFrozenNormal() {
        frozenNormal_ = cachedWorkplaneNormal();
        haveFrozen_   = true;
    }

    // Capture a frozen normal only if none is held yet (endpoint / line-body /
    // relocate gestures reuse the plane the line was drawn with).
    void ensureFrozenNormal() { if (!haveFrozen_) captureFrozenNormal(); }

    // A fresh line (Shift+drag / new line) re-captures the plane orientation and
    // returns to the drag plane, dropping any axis override. Owner fix 1 (0284):
    // arm the axis classification — once this fresh line is drawn OUT (mouse-up),
    // its plane normal is classified to a concrete Axis so the panel reflects it.
    void beginFreshLinePlane() {
        axisLocked_ = false;
        pendingAxisClassify_ = true;
        captureFrozenNormal();
    }

    // Owner fix 1 (0284; owner-revised for the extrusion-direction model). Classify
    // the DRAWN plane's EXTRUSION direction to a concrete Axis so the panel reflects
    // it. The drag plane is the line extruded along the FROZEN work-plane normal
    // (effectiveNormal()) — so THAT extrusion direction, not the cut normal, is what
    // planeForSlice's axis modes consume. Classify it to the aligned world axis
    // (|dir·axis| ≥ tol ⇒ X/Y/Z) or Custom (vector_ = the extrusion direction).
    // Either reproduces the SAME plane byte-identically: planeForSlice(classifiedAxis)
    // = cross(lineDir, axisDir) = the original drag normal (Custom's vector IS the
    // extrusion dir). So the drawn cut is unchanged; only the displayed param + the
    // subsequent re-orientation model change. No-op for a degenerate line (a click
    // with no drag ⇒ no plane ⇒ nothing to reflect).
    void classifyDrawnPlaneAxis() {
        Vec3 pp, nn;
        if (!planeForSlice(start_, end_, effectiveNormal(),
                           SLICE_AXIS_DRAG, vector_, pp, nn))
            return;
        Vec3 ext = effectiveNormal();   // the frozen extrusion direction (work-plane normal)
        Vec3 v;
        SliceAxis a = classifyPlaneAxis(ext, v);
        axis_ = a;
        if (a == SliceAxis.Custom) vector_ = v;
        axisLocked_ = true;
    }

    // The cut-plane normal the interactive cut + overlay both use: the FROZEN
    // drag normal once a gesture has drawn the line, else the live work-plane
    // normal (before the first drag of the session).
    Vec3 effectiveNormal() {
        return haveFrozen_ ? frozenNormal_ : cachedWorkplaneNormal();
    }

    // The planeForSlice `axisMode`: the axis OVERRIDE (X/Y/Z/Custom) only while
    // locked, else SLICE_AXIS_DRAG (the drawn line ⟂ frozen work plane).
    int effectiveAxisMode() const {
        return axisLocked_ ? cast(int)axis_ : SLICE_AXIS_DRAG;
    }

    // The work-plane in-plane basis for the angle-snap projection (same frame
    // source as cachedWorkplaneNormal).
    void cachedWorkplaneAxes(out Vec3 a1, out Vec3 a2) {
        WorkplaneFrame wf = vpWorld_.width > 0 ? pickWorkplaneFrame(vpWorld_)
                                               : currentWorkplaneFrame();
        a1 = wf.axis1;
        a2 = wf.axis2;
    }

    // Effective Angle Snap state: the sticky `snap_` param XOR the momentary
    // X-key inversion.
    bool effectiveSnap() const { return snap_ ^ snapTempInvert_; }

    // Derive start_/end_ from the RAW drag endpoints, applying Angle Snap (S5)
    // when effective. A line-body drag (DragLine) is a pure translation — the
    // angle is unchanged, so it never snaps. The dragged endpoint rotates about
    // the fixed one so the line keeps its length and lands on a clean angle.
    void applyAngleSnapFromRaw() {
        start_ = rawStart_;
        end_   = rawEnd_;
        if (!effectiveSnap() || dragPart_ == DragLine) return;
        Vec3 a1, a2;
        cachedWorkplaneAxes(a1, a2);
        if (dragPart_ == DragStart)
            start_ = snapLineEndpointToAngle(rawEnd_, rawStart_, a1, a2, snapAngle_);
        else   // DragEnd (and the fresh-line / shift-redraw paths, all DragEnd)
            end_   = snapLineEndpointToAngle(rawStart_, rawEnd_, a1, a2, snapAngle_);
    }

    // Re-apply Angle Snap after an X-key flip and refresh the preview, so the
    // toggle is visible mid-drag without needing a fresh mouse move. No-op when
    // no raw drag is in flight (nothing to re-snap).
    void retrySnapPreview() {
        if (!haveRaw_ || dragPart_ == DragNone) return;
        applyAngleSnapFromRaw();
        if (!fast_) updatePreview();
    }

    // Intersect the cursor ray with the current work plane; the dragged
    // endpoint slides on that plane so the whole line stays in the work plane
    // (which keeps the perpendicular cut plane well-defined).
    bool workplaneHit(float sx, float sy, out Vec3 hit) {
        if (vpWorld_.width <= 0) return false;
        WorkplaneFrame wp = pickWorkplaneFrame(vpWorld_);
        Vec3 origin, dir;
        screenPointToRay(sx, sy, vpWorld_, origin, dir);
        return rayPlaneIntersect(origin, dir, wp.origin, wp.normal, hit);
    }

    // Return DragStart if the cursor is within HANDLE_PICK_PX of the Start
    // projection, DragEnd if within range of End (nearest wins), else -1.
    int pickHandle(float sx, float sy) {
        if (vpWorld_.width <= 0) return -1;
        float bestD2 = HANDLE_PICK_PX * HANDLE_PICK_PX;
        int best = -1;
        foreach (i, pt; [start_, end_]) {
            float px, py, z;
            if (!projectToWindowFull(pt, vpWorld_, px, py, z)) continue;
            float d2 = (px - sx) * (px - sx) + (py - sy) * (py - sy);
            if (d2 <= bestD2) { bestD2 = d2; best = cast(int)i; }
        }
        return best;
    }

    // True if the cursor is within LINE_PICK_PX of the Start→End line's screen
    // projection (endpoints already handled by pickHandle, which is tried
    // first). A degenerate (zero-length) line has no body.
    bool pickLineBody(float sx, float sy) {
        if (vpWorld_.width <= 0) return false;
        float ax, ay, az, bx, by, bz;
        if (!projectToWindowFull(start_, vpWorld_, ax, ay, az)) return false;
        if (!projectToWindowFull(end_,   vpWorld_, bx, by, bz)) return false;
        float dx = bx - ax, dy = by - ay;
        if (dx * dx + dy * dy < 1.0f) return false;   // no visible body
        float t;
        float d = closestOnSegment2D(sx, sy, ax, ay, bx, by, t);
        return d <= LINE_PICK_PX;
    }

    // --- Custom-axis rotate ring (task 0287) -------------------------------

    // World radius that projects to RING_RADIUS_PX px at `center` — screen-
    // constant, the SAME gizmoSize mapping the endpoint squares use (scale =
    // RING_RADIUS_PX / getGizmoPixels()).
    float ringRadiusWorld(Vec3 center, const ref Viewport vp) {
        return gizmoSize(center, vp, RING_RADIUS_PX / getGizmoPixels());
    }

    // Intersect the cursor ray with the ROTATE RING's plane (through `center`,
    // normal = `axis` = the line direction), giving the world grab point the
    // rotate angle is measured from. False when no viewport is cached or the ray
    // runs parallel to the plane (edge-on ring).
    bool ringPlaneHit(float sx, float sy, Vec3 center, Vec3 axis, out Vec3 hit) {
        if (vpWorld_.width <= 0) return false;
        Vec3 origin, dir;
        screenPointToRay(sx, sy, vpWorld_, origin, dir);
        return rayPlaneIntersect(origin, dir, center, axis, hit);
    }

    // True if the cursor is within RING_PICK_PX of the rotate ring's screen
    // projection. PURE projection (no GL object needed) so the event path works
    // before the first draw — mirrors pickHandle / FullCircleHandler.aiScreenDistance.
    // Only meaningful for a Custom axis with a non-degenerate line.
    bool pickRotateRing(float sx, float sy) {
        if (vpWorld_.width <= 0 || axis_ != SliceAxis.Custom) return false;
        Vec3 seg = end_ - start_;
        if (seg.length < 1e-6f) return false;
        Vec3 axis   = normalize(seg);
        Vec3 center = (start_ + end_) * 0.5f;
        float radius = ringRadiusWorld(center, vpWorld_);
        if (radius <= 0.0f) return false;
        Vec3 right, up;
        sliceRingPlaneBasis(axis, right, up);
        enum int SEGS = 48;
        float best = float.infinity;
        float prevX = 0, prevY = 0; bool prevValid = false;
        foreach (i; 0 .. SEGS + 1) {
            float a = cast(float)i * 2.0f * PI / SEGS;
            Vec3 w = center + right * (cos(a) * radius) + up * (sin(a) * radius);
            float wx, wy, wz;
            bool ok = projectToWindowFull(w, vpWorld_, wx, wy, wz);
            if (prevValid && ok) {
                float t;
                float d = closestOnSegment2D(sx, sy, prevX, prevY, wx, wy, t);
                if (d < best) best = d;
            }
            prevValid = ok; prevX = wx; prevY = wy;
        }
        return best <= RING_PICK_PX;
    }

    // Start a rotate gesture if the cursor grabbed the ring: latch the rotation
    // axis (the line), the ring centre, the in-plane grab direction, and the
    // Custom vector, all frozen for the drag. False (no gesture) if the ring
    // wasn't hit or the grab point is degenerate.
    bool beginRotateIfRingHit(float sx, float sy) {
        if (!pickRotateRing(sx, sy)) return false;
        Vec3 seg = end_ - start_;
        if (seg.length < 1e-6f) return false;
        Vec3 axis   = normalize(seg);
        Vec3 center = (start_ + end_) * 0.5f;
        Vec3 hit;
        if (!ringPlaneHit(sx, sy, center, axis, hit)) return false;
        Vec3 grab = hit - center;              // in the ring plane ⟂ axis
        if (grab.length < 1e-6f) return false;
        ensureFrozenNormal();                  // keep the frozen extrusion basis
        dragPart_    = DragRotate;
        drawGesture_ = false;
        rotAxis0_    = axis;
        rotCenter0_  = center;
        rotRefDir0_  = normalize(grab);
        rotVector0_  = vector_;
        return true;
    }

public:
    final Mesh* preparedActivationMesh() const nothrow @nogc { return mesh; }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    version(unittest) final void seedPreparedActivationForTest() {
        mesh.syncSelection(); mesh.selectFace(0); mesh.selectFace(2);
        active = false; dragPart_ = DragRotate; previewLive_ = true;
        haveBefore_ = false; haveRaw_ = true; snapTempInvert_ = true;
        haveFrozen_ = true; pendingAxisClassify_ = true;
        hasLine_ = true; drawGesture_ = true; ctrlPending_ = true;
        ctrlAxis_ = 2; gapDrag_ = true; axisLocked_ = true;
        restrictFaces_ = [4,5]; armedKey_.stamp(*mesh);
        before_ = MeshSnapshot.capture(*mesh);
        fast_ = true; axis_ = SliceAxis.Custom; vector_ = Vec3(1,2,3);
        infinite_ = true; split_ = true; caps_ = false; gap_ = 0.7f;
        gapSide_ = SliceGapSide.Positive; snap_ = true; snapAngle_ = 30;
        start_ = Vec3(4,5,6); end_ = Vec3(7,8,9);
        rawStart_ = Vec3(10,11,12); rawEnd_ = Vec3(13,14,15);
        frozenNormal_ = Vec3(0,0,1); vpWorld_.view[0] = 9;
    }
    version(unittest) final bool preparedActivationDirtyForTest() const {
        return !active && dragPart_ == DragRotate && previewLive_ && !haveBefore_ &&
            haveRaw_ && snapTempInvert_ && haveFrozen_ && pendingAxisClassify_ &&
            hasLine_ && drawGesture_ && ctrlPending_ && ctrlAxis_ == 2 && gapDrag_ &&
            axisLocked_ && restrictFaces_ == [4,5] && armedKey_.matches(*mesh) &&
            before_.filled && fast_ && axis_ == SliceAxis.Custom &&
            vector_ == Vec3(1,2,3) && infinite_ && split_ && !caps_ && gap_ == 0.7f &&
            gapSide_ == SliceGapSide.Positive && snap_ && snapAngle_ == 30 &&
            start_ == Vec3(4,5,6) && end_ == Vec3(7,8,9) &&
            rawStart_ == Vec3(10,11,12) && rawEnd_ == Vec3(13,14,15) &&
            frozenNormal_ == Vec3(0,0,1) && vpWorld_.view[0] == 9;
    }
    version(unittest) final bool preparedActivationForTest(bool restricted) const {
        bool restrictOk = restricted ? restrictFaces_ == [0u,2u] :
            restrictFaces_.length == 0 && restrictFaces_.ptr is null;
        return active && dragPart_ == DragNone && !previewLive_ && haveBefore_ &&
            !haveRaw_ && !snapTempInvert_ && !haveFrozen_ && !pendingAxisClassify_ &&
            !hasLine_ && !drawGesture_ && !ctrlPending_ && ctrlAxis_ == -1 &&
            !gapDrag_ && !axisLocked_ && restrictOk &&
            armedKey_.matches(*mesh) && before_.filled && before_.matches(*mesh) &&
            fast_ && axis_ == SliceAxis.Custom && vector_ == Vec3(1,2,3) &&
            infinite_ && split_ && !caps_ && gap_ == 0.7f &&
            gapSide_ == SliceGapSide.Positive && snap_ && snapAngle_ == 30 &&
            start_ == Vec3(4,5,6) && end_ == Vec3(7,8,9) &&
            rawStart_ == Vec3(10,11,12) && rawEnd_ == Vec3(13,14,15) &&
            frozenNormal_ == Vec3(0,0,1) && vpWorld_.view[0] == 9;
    }
    version(unittest) final void clearFaceSelectionForTest() {
        foreach (fi; 0 .. mesh.faces.length) mesh.deselectFace(cast(int)fi);
    }
}
