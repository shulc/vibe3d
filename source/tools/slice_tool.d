module tools.slice_tool;

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
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import operator : VectorStack;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, FullCircleHandler, ToolHandles, gizmoSize, getGizmoPixels, drawWorldSegment, drawWorldQuad;
import tools.create_common : currentWorkplaneFrame, pickWorkplaneFrame, WorkplaneFrame;
// Reuse MoveTool's dominant-axis selector for the Ctrl axis-constraint (task
// 0286): the SAME screen-direction → world-axis math the Move gizmo's Ctrl lock
// uses, so Slice's Ctrl constraint is byte-consistent with Move's, not reinvented.
import tools.move : chooseConstraintAxis;

// The interactive Slice commit reuses the generic before/after snapshot edit
// command (the same MeshSessionEdit the mirror / tack / primitive tools reuse for
// their one-shot snapshot undo), labelled "Slice".
alias SliceEditFactory = MeshSessionEdit delegate();

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
// the kernel (Mesh.cutByPlaneEx → splitAlongCutLoop) reads directly, so keep
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
// `Mesh.cutByPlaneSplitGap` — TWO REAL parallel plane cuts at
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
    size_t nc = mesh.cutByPlaneSplitGap(p, n, clipped, s, e, caps, gap, gapSide,
                                        separated, restrict);
    if (separated) return nc;
    // PARTIAL cut: the two planes did not disconnect the mesh ⇒ no band to
    // remove ⇒ NO gap would open. Roll back and reproduce today's behaviour.
    snap.restore(mesh);
    Mesh.PlaneCutLoops loops;
    return mesh.cutByPlaneEx(p, n, clipped, s, e, /*split*/true, caps, loops,
                             1e-5f, restrict, gap, gapSide);
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
    // slices the WHOLE mesh (Mesh.cutByPlane — the S0 behavior). OFF (the
    // reference factory default) CLIPS the cut to the drawn Start→End span, so
    // only faces under the drawn line are cut (Mesh.cutByPlaneClipped). On a
    // mesh whose cross-section fits within the line the two agree.
    //
    // `split` (task S7): OFF is the connected single cut above — byte-for-byte
    // the S0/S4 path (the non-split kernel is called directly). ON routes the
    // SAME plane cut through Mesh.cutByPlaneEx, which duplicates the cut loop
    // into two coincident boundary loops (the Loop Slice lo/hi seam model),
    // splitting the surface into two disconnected sections along the cut.
    // `caps` (task S8): with `split` on, seal each split section's boundary loop
    // with one cap polygon (Mesh.cutByPlaneEx forwards it to splitAlongCutLoop →
    // capShellCycles, the SAME cap geometry as Loop Slice Cap Sections). A no-op
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
        size_t cutAt(Vec3 pp) {
            if (infinite)
                return restrictFaces.length > 0
                     ? mesh.cutByPlaneRestricted(pp, n, restrictFaces)
                     : mesh.cutByPlane(pp, n);
            return mesh.cutByPlaneClipped(pp, n, start, end, 1e-5f, restrictFaces);
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
            size_t nCut = cutAt(p + n * loAmt);
            nCut       += cutAt(p - n * hiAmt);
            return nCut;
        }
        return cutAt(p);
    }
    // `gap`/`gapSide` (S9): with split on, separate the two boundary loops along
    // the cut-plane normal `n` by `gap`, offset per `gapSide` (Mesh.cutByPlaneEx
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
    Mesh.PlaneCutLoops loops;
    return mesh.cutByPlaneEx(p, n, /*clipped*/!infinite, start, end,
                             /*split*/true, caps, loops, 1e-5f, restrictFaces,
                             gap, gapSide);
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
void sliceOverlayExtent(const ref Mesh m, Vec3 p, Vec3 dir, Vec3 perp,
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
    foreach (v; m.vertices) {
        float b = dot(v - p, perp);
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
void sliceOverlayExtentLocked(const ref Mesh m, Vec3 p, Vec3 dir, Vec3 perp,
                              out float aMin, out float aMax,
                              out float bMin, out float bMax)
{
    import std.algorithm : min, max;
    aMin = aMax = bMin = bMax = 0.0f;
    bool any = false;
    foreach (v; m.vertices) {
        float a = dot(v - p, dir), b = dot(v - p, perp);
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
    Vec3 a = normalize(axis);
    float c = cos(angle), s = sin(angle);
    return v * c + cross(a, v) * s + a * (dot(a, v) * (1.0f - c));
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
// cut itself reuses the existing `Mesh.cutByPlane` kernel (index-shared
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
// cut (Mesh.cutByPlaneClipped); ON extends the line indefinitely so the plane
// slices the whole mesh (Mesh.cutByPlane, the S0 behavior). It threads through
// the preview + commit (sliceFromBaseline) and applyHeadless.
//
// S7 (task 0273) adds `split` (bool, default off): OFF is the S0 connected cut;
// ON duplicates the plane-cut loop into two coincident boundary loops so the
// surface splits into two disconnected sections along the cut, reusing the Loop
// Slice lo/hi seam-pair split machinery (Mesh.cutByPlaneEx → splitAlongCutLoop).
// It threads through the preview + commit (sliceFromBaseline) and applyHeadless.
// The seam-pair data it produces is what Cap Sections (S8) / Gap (S9) build on.
//
// S8 (task 0274) adds `caps` (Cap Sections, bool, default ON, dep Split): with
// `split` on, each split section's boundary loop is sealed by one cap polygon in
// the loop plane — the SAME geometry as Loop Slice Cap Sections (the shared
// Mesh.capShellCycles helper, via cutByPlaneEx → splitAlongCutLoop). A no-op
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
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory   history;
    SliceEditFactory factory;

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
    // (Mesh.cutByPlaneEx → splitAlongCutLoop). Threads through the preview +
    // commit (sliceFromBaseline) and applyHeadless. Sticky (not reset on
    // activate), like the other tool options. The seam-pair data it produces is
    // the foundation the later Cap Sections (S8) / Gap (S9) options act on.
    bool split_ = false;

    // Cap Sections (S8, task 0274; default ON per the reference spec — spec.json
    // "caps" default true, dep Split). A no-op while `split_` is off (the
    // non-split cut never duplicates a loop, so there is no open boundary to
    // cap); the panel greys it out then (paramEnabled). With `split_` on, each
    // split section's boundary loop is sealed by one cap polygon — the SAME
    // geometry as Loop Slice Cap Sections (Mesh.capShellCycles). Threads through
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
    MeshCacheKey armedKey_;      // mesh identity+version guard for the deferred commit
    Viewport cachedVp;

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

    // Gizmo palette (codebase handle colours — NOT reference colours): endpoint
    // handles in the blue used by Create-tool handles, the line in a light
    // neutral. Rollover/selected tints come from handler.handleStateColor.
    enum Vec3 HANDLE_COLOR = Vec3(0.30f, 0.60f, 1.00f);
    enum Vec3 LINE_COLOR   = Vec3(0.90f, 0.92f, 0.98f);
    // Rotate-ring colour: a light teal in the vibe3d gizmo palette (NOT a
    // reference colour), distinct from the endpoint blue so the two read apart.
    enum Vec3 RING_COLOR   = Vec3(0.35f, 0.85f, 0.85f);

    // Cut-plane overlay (task 0284): a subtle translucent fill in the same blue
    // family as the endpoint handles (vibe3d gizmo palette — NOT reference
    // colours), at a low alpha so the mesh, cut preview, and handles all read
    // through it.
    enum Vec3  PLANE_COLOR = Vec3(0.30f, 0.60f, 1.00f);
    enum float PLANE_ALPHA = 0.18f;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, SliceEditFactory f) {
        this.history = h;
        this.factory = f;
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
        return toolHandles_.toJson(cachedVp);
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
                Mesh.PlaneCutLoops loops;
                nSplit = mesh.cutByPlaneEx(p, n, /*clipped*/!infinite_, sStart, sEnd,
                                           /*split*/true, caps_, loops, 1e-5f, restrict,
                                           gap_, cast(int)gapSide_);
            }
        } else {
            // A single connected plane cut through `pp` (infinite/clipped +
            // restrict). Nested so the Gap-without-split path fires it twice.
            // MUST stay in lockstep with sliceFromBaseline's non-split branch.
            size_t cutAt(Vec3 pp) {
                if (restrict.length > 0)
                    return infinite_ ? mesh.cutByPlaneRestricted(pp, n, restrict)
                                     : mesh.cutByPlaneClipped(pp, n, sStart, sEnd, 1e-5f, restrict);
                return infinite_ ? mesh.cutByPlane(pp, n)
                                 : mesh.cutByPlaneClipped(pp, n, sStart, sEnd);
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
                nSplit = cutAt(p + n * loAmt) + cutAt(p - n * hiAmt);
            } else {
                nSplit = cutAt(p);
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
        if (!visualOnly) cachedVp = vp;
        if (!active) return;
        // Task 0286: NOTHING is shown at bare activation — no overlay, no line, no
        // endpoint handles — until the FIRST LMB drag has laid a line. (cachedVp is
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
            rotRing_.lineWidth = 2.5f;
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
                    sliceOverlayExtent(*mesh, pp, dir, perp, start_, end_,
                                       aMin, aMax, bMin, bMax);
                } else if (sliceOverlayBasisLocked(nn, dir, perp)) {
                    haveBasis = true;
                    sliceOverlayExtentLocked(*mesh, pp, dir, perp,
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
        drawWorldSegment(start_, end_, vp, LINE_COLOR, 2.5f, shader.program);
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
        if (cachedVp.width <= 0) return -1;
        Vec3 camBack = Vec3(cachedVp.view[2], cachedVp.view[6], cachedVp.view[10]);
        Vec3 center  = drawGesture_ ? start_ : (start_ + end_) * 0.5f;
        Vec3 ex = center + Vec3(1, 0, 0);
        Vec3 ey = center + Vec3(0, 1, 0);
        Vec3 ez = center + Vec3(0, 0, 1);
        return chooseConstraintAxis(camBack,
            Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
            ex, ey, ez, center, cachedVp, tdx, tdy);
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
        refreshDisplay(mesh, gpu, vc, ec, fc);
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
        if (!armedKey_.matches(*mesh)) return;   // mesh swapped since last preview — drop
        if (history is null || factory is null) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before_, post, "Slice");
        history.record(cmd);
    }

    // The work-plane normal the interactive path builds the cut plane from.
    // Uses the live workplane frame (respects a user-set non-auto workplane);
    // pickWorkplaneFrame needs a viewport, so fall back to the pipe default
    // (currentWorkplaneFrame) when none was cached yet.
    Vec3 cachedWorkplaneNormal() {
        if (cachedVp.width > 0) return pickWorkplaneFrame(cachedVp).normal;
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
        WorkplaneFrame wf = cachedVp.width > 0 ? pickWorkplaneFrame(cachedVp)
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
        if (cachedVp.width <= 0) return false;
        WorkplaneFrame wp = pickWorkplaneFrame(cachedVp);
        Vec3 origin, dir;
        screenPointToRay(sx, sy, cachedVp, origin, dir);
        return rayPlaneIntersect(origin, dir, wp.origin, wp.normal, hit);
    }

    // Return DragStart if the cursor is within HANDLE_PICK_PX of the Start
    // projection, DragEnd if within range of End (nearest wins), else -1.
    int pickHandle(float sx, float sy) {
        if (cachedVp.width <= 0) return -1;
        float bestD2 = HANDLE_PICK_PX * HANDLE_PICK_PX;
        int best = -1;
        foreach (i, pt; [start_, end_]) {
            float px, py, z;
            if (!projectToWindowFull(pt, cachedVp, px, py, z)) continue;
            float d2 = (px - sx) * (px - sx) + (py - sy) * (py - sy);
            if (d2 <= bestD2) { bestD2 = d2; best = cast(int)i; }
        }
        return best;
    }

    // True if the cursor is within LINE_PICK_PX of the Start→End line's screen
    // projection (endpoints already handled by pickHandle, which is tried
    // first). A degenerate (zero-length) line has no body.
    bool pickLineBody(float sx, float sy) {
        if (cachedVp.width <= 0) return false;
        float ax, ay, az, bx, by, bz;
        if (!projectToWindowFull(start_, cachedVp, ax, ay, az)) return false;
        if (!projectToWindowFull(end_,   cachedVp, bx, by, bz)) return false;
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
        if (cachedVp.width <= 0) return false;
        Vec3 origin, dir;
        screenPointToRay(sx, sy, cachedVp, origin, dir);
        return rayPlaneIntersect(origin, dir, center, axis, hit);
    }

    // True if the cursor is within RING_PICK_PX of the rotate ring's screen
    // projection. PURE projection (no GL object needed) so the event path works
    // before the first draw — mirrors pickHandle / FullCircleHandler.aiScreenDistance.
    // Only meaningful for a Custom axis with a non-degenerate line.
    bool pickRotateRing(float sx, float sy) {
        if (cachedVp.width <= 0 || axis_ != SliceAxis.Custom) return false;
        Vec3 seg = end_ - start_;
        if (seg.length < 1e-6f) return false;
        Vec3 axis   = normalize(seg);
        Vec3 center = (start_ + end_) * 0.5f;
        float radius = ringRadiusWorld(center, cachedVp);
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
            bool ok = projectToWindowFull(w, cachedVp, wx, wy, wz);
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
}

// ---------------------------------------------------------------------------
// Non-cumulative preview + fast-gate parity (dub test). Proves the two S1
// invariants at the cut-kernel level without a GL context:
//   1. Dragging the line through many preview positions never accumulates —
//      each `sliceFromBaseline` reproduces a single clean cut of the pristine
//      baseline (a mid-plane cube cut is always 12v/10f, never 16v+).
//   2. The `fast`-deferred commit (one call at the final line) yields the
//      identical geometry to the live-preview path (N previews then a final
//      commit-position call).
// Runs on the `infinite` path (infinite=true): these positions vary the line
// LENGTH, and the point here is length-INDEPENDENT non-accumulation, so the
// whole-mesh plane cut is the right invariant. The clipped-default divergence
// (line length changes what is cut) is covered by cutByPlaneClipped's mesh.d
// unittests + test_fixture_slice_infinite.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // A drag of the End endpoint through several positions, all producing a
    // vertical (X-normal, through X=0) cut of the unit cube: the line lies
    // along Z (perpendicular to +Y work plane), start fixed at (0,0,-1).
    Vec3[] endPositions = [
        Vec3(0, 0, 0.4f), Vec3(0, 0, 0.7f), Vec3(0, 0, 1.0f), Vec3(0, 0, 1.3f),
    ];
    Vec3 start = Vec3(0, 0, -1);
    Vec3 wpN   = Vec3(0, 1, 0);   // default world-XZ work plane normal
    enum bool INF = true;         // whole-mesh plane — length-independent cut

    // --- Path A: live preview drag, then commit at the final line ---
    Mesh live = makeCube();
    auto baseline = MeshSnapshot.capture(live);
    assert(live.vertices.length == 8 && live.faces.length == 6);

    foreach (ep; endPositions) {
        size_t n = sliceFromBaseline(live, baseline, start, ep, wpN,
                                     SLICE_AXIS_DRAG, Vec3(0, 1, 0), INF);
        assert(n > 0, "each mid-plane preview must split faces");
        // NON-CUMULATIVE: always the single-cut topology, never accumulated.
        assert(live.vertices.length == 12, "preview must not accumulate verts");
        assert(live.faces.length == 10,    "preview must not accumulate faces");
    }
    // Commit at the final line (revert baseline + cut once — the same
    // non-cumulative kernel the deferred deactivate-commit records).
    size_t nCommit = sliceFromBaseline(live, baseline, start, endPositions[$-1], wpN,
                                       SLICE_AXIS_DRAG, Vec3(0, 1, 0), INF);
    assert(nCommit > 0);
    assert(live.vertices.length == 12 && live.faces.length == 10);

    // --- Path B: fast — no live preview, a single deferred commit ---
    Mesh fast = makeCube();
    auto fastBaseline = MeshSnapshot.capture(fast);
    size_t nFast = sliceFromBaseline(fast, fastBaseline, start, endPositions[$-1], wpN,
                                     SLICE_AXIS_DRAG, Vec3(0, 1, 0), INF);
    assert(nFast == nCommit);
    assert(fast.vertices.length == live.vertices.length);
    assert(fast.faces.length    == live.faces.length);

    // Byte-for-byte geometry parity between the fast-deferred and live-preview
    // commits (both are one cut of the pristine baseline at the same line).
    foreach (i; 0 .. live.vertices.length) {
        assert(abs(live.vertices[i].x - fast.vertices[i].x) < 1e-6f);
        assert(abs(live.vertices[i].y - fast.vertices[i].y) < 1e-6f);
        assert(abs(live.vertices[i].z - fast.vertices[i].z) < 1e-6f);
    }

    // --- Clip default: the SAME short line (end z=0.4) cuts LESS than infinite.
    // Its far crossing (z=+0.5) projects past the drawn span, so only the near
    // (z=−0.5) side splits cleanly — a countable proof the default clips. The
    // line ENDS inside the top & bottom faces (z=0.4 < 0.5), so those receive a
    // keyhole interior vertex (task 0289) instead of a clean split; the clip thus
    // still splits FEWER faces than the infinite belt (7 vs 10 total faces).
    Mesh clip = makeCube();
    auto clipBase = MeshSnapshot.capture(clip);
    size_t nClip = sliceFromBaseline(clip, clipBase, start, Vec3(0, 0, 0.4f), wpN);
    assert(nClip < 4, "clipped short line must split fewer faces than infinite (4)");
    assert(clip.faces.length < 10,
           "clipped short line splits fewer faces than the full belt (infinite=10)");
}

// ---------------------------------------------------------------------------
// sliceSplitGap unittests (task 0291) — the partial-cut fallback (objection 2)
// and the caps==false routing note (DQ4).
// ---------------------------------------------------------------------------
unittest { // sliceSplitGap: a PARTIAL cut — one of the two offset planes never
    // finds any geometry within the clip span — does NOT fully separate the
    // mesh, so `cutByPlaneSplitGap` reports `separated == false`. Silently
    // dropping the gap here would be a REGRESSION (today's slide DOES open one
    // for the equivalent single center-plane cut), so `sliceSplitGap` must
    // roll back both offset cuts and reproduce the legacy single-cut+slide
    // (at the CENTER plane, not either offset) EXACTLY.
    //
    // Construction: a cube mid-plane cut (x=0, gap 0.4 center ⇒ offsets at
    // x=+0.2 and x=-0.2), CLIPPED to a segment lying ALONG the cut normal
    // itself (x from -0.25 to +0.1) rather than across it. `cutByPlaneClipped`
    // only tests a crossing's projection onto the segment's OWN direction —
    // it need not lie IN the cut plane — so this is a legal, if extreme,
    // clip. Every crossing at x=+0.2 (the `+offset` plane) projects to
    // s≈1.29 (past the segment's end) ⇒ OUT of band ⇒ that whole cut is a
    // no-op; every crossing at x=-0.2 (the `-offset` plane) projects to
    // s≈0.14 ⇒ IN band ⇒ that cut proceeds normally. With only ONE of the
    // two boundary planes actually cutting anything, there is no bounded
    // [-hiAmt,+loAmt] slab anywhere in the result — `deleteComponentsInSlab`
    // finds nothing (both resulting shells extend to the cube's far corners,
    // well past either offset), so `separated == false`. Crucially, the
    // crossing at x=0 (the CENTER plane the legacy path actually cuts at)
    // projects to s≈0.71 — IN band — so the legacy single-cut+slide at the
    // center plane, using this SAME clip segment, still opens a real gap.
    import std.math : abs;

    Mesh viaHelper = makeCube();
    viaHelper.buildLoops();
    viaHelper.resetSelection();
    Mesh viaLegacy = makeCube();
    viaLegacy.buildLoops();
    viaLegacy.resetSelection();

    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);
    Vec3 segStart = Vec3(-0.25f, 0, 0), segEnd = Vec3(0.1f, 0, 0);
    enum float G = 0.4f;

    size_t nHelper = sliceSplitGap(viaHelper, P, N, /*clipped*/true, segStart, segEnd,
                                   /*caps*/true, G, /*gapSide*/0, null);

    Mesh.PlaneCutLoops loops;
    size_t nLegacy = viaLegacy.cutByPlaneEx(P, N, /*clipped*/true, segStart, segEnd,
                                            /*split*/true, /*caps*/true, loops,
                                            1e-5f, null, G, 0);

    assert(nHelper > 0, "the clipped segment must still cut some faces");
    assert(nHelper == nLegacy,
           "partial cut: the fallback must cut exactly as many faces as the legacy slide");
    assert(viaHelper.vertices.length == viaLegacy.vertices.length,
           "partial cut: fallback must reproduce the legacy slide's vertex count");
    assert(viaHelper.faces.length == viaLegacy.faces.length,
           "partial cut: fallback must reproduce the legacy slide's face count");
    foreach (i; 0 .. viaHelper.vertices.length) {
        Vec3 a = viaHelper.vertices[i], b = viaLegacy.vertices[i];
        assert(abs(a.x - b.x) < 1e-6f && abs(a.y - b.y) < 1e-6f && abs(a.z - b.z) < 1e-6f,
               "partial cut: fallback vertex must match the legacy slide exactly");
    }
    // Sanity: the fallback really opened a gap (grew past the pristine
    // cube's 8 verts), it did not silently no-op.
    assert(viaHelper.vertices.length > 8,
           "partial cut: the fallback must still open a gap, not drop it");
    // And it must NOT have taken the two-cut path silently: confirm the
    // TWO-CUT attempt on an independent copy really does report
    // separated==false for this exact scenario (the discriminator this test
    // exercises), rather than the byte-parity above passing by coincidence.
    {
        Mesh probe = makeCube();
        probe.buildLoops();
        probe.resetSelection();
        bool separated;
        probe.cutByPlaneSplitGap(P, N, /*clipped*/true, segStart, segEnd,
                                 /*caps*/true, G, /*gapSide*/0, separated, null);
        assert(!separated,
               "partial cut: the two offset cuts must NOT report separated==true "
               ~ "(one plane's crossings project entirely out of the clip band)");
    }
}

unittest { // sliceSplitGap: caps==false + split + gap routes to the two-cut
    // path and still deletes the band (task 0291, DQ4) — the `gap != 0` gate
    // ignores `caps`, so an uncapped split+gap is NOT silently forced through
    // the legacy slide. A full mid-plane cut of a cube (gap 0.2 center,
    // caps=false): the band is still a bounded connected component (4 side
    // sub-quads forming a closed ring, no caps needed for DSU connectivity)
    // and gets removed exactly as in the capped case; only the 2 cap FACES
    // are absent, so each remaining shell's boundary loop is OPEN.
    static size_t boundaryEdgeCount(ref Mesh m) {
        size_t n = 0;
        foreach (ei; 0 .. m.edges.length) {
            size_t nf = 0;
            foreach (fi; m.facesAroundEdge(cast(uint)ei)) ++nf;
            if (nf == 1) ++n;
        }
        return n;
    }
    static size_t componentCount(ref Mesh m) {
        auto nf = m.faces.length;
        if (nf == 0) return 0;
        auto parent = new size_t[](nf);
        foreach (i; 0 .. nf) parent[i] = i;
        size_t find(size_t x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void uni(size_t a, size_t b) { parent[find(a)] = find(b); }
        uint[][uint] vFaces;
        foreach (fi, f; m.faces) foreach (v; f) vFaces[v] ~= cast(uint)fi;
        foreach (v, fs; vFaces) foreach (k; 1 .. fs.length) uni(fs[0], fs[k]);
        bool[size_t] roots;
        foreach (i; 0 .. nf) roots[find(i)] = true;
        return roots.length;
    }

    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();

    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);
    enum float G = 0.2f;

    size_t n = sliceSplitGap(m, P, N, /*clipped*/false, P, P,
                            /*caps*/false, G, /*gapSide*/0, null);
    assert(n > 0, "the mid-plane must cut faces");
    assert(componentCount(m) == 2, "band removed: exactly 2 shells left, even uncapped");
    assert(m.vertices.length == 16, "caps add no verts — same 16v as the capped case");
    assert(m.faces.length == 10,
           "caps==false: 2 shells x (4 side + 1 original), no cap faces (12-2)");
    assert(boundaryEdgeCount(m) > 0,
           "caps==false must leave each shell's boundary loop OPEN (not sealed)");
}

// ---------------------------------------------------------------------------
// Cut-plane overlay geometry (task 0284). Proves, WITHOUT a GL context, that
// the translucent quad SliceTool.draw() renders:
//   1. lies IN the cut plane — every corner satisfies dot(corner - p, n) ≈ 0;
//   2. CONTAINS the Start→End segment (both endpoints project inside the
//      corner extents);
//   3. TRACKS the live state — changing `axis` (⇒ a different plane normal) and
//      moving an endpoint move the corners and keep them in the NEW plane.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // Assert all four corners lie in the plane (p, n) and contain the segment.
    static void checkQuad(Vec3 start, Vec3 end, Vec3 wpN, int axis, Vec3 vector) {
        Vec3 p, n;
        assert(planeForSlice(start, end, wpN, axis, vector, p, n),
               "test lines are chosen so the plane is well-defined");
        Vec3 dir, perp;
        assert(sliceOverlayBasis(start, end, n, dir, perp),
               "in-plane line ⇒ a valid overlay basis");

        // In-plane basis: both axes ⟂ the normal.
        assert(abs(dot(dir,  n)) < 1e-5f, "dir must be in-plane");
        assert(abs(dot(perp, n)) < 1e-5f, "perp must be in-plane");
        assert(abs(dot(dir, perp)) < 1e-5f, "dir ⟂ perp");

        // Size to a unit cube (the region being cut) + the segment.
        Mesh cube = makeCube();
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtent(cube, p, dir, perp, start, end, aMin, aMax, bMin, bMax);
        Vec3[4] q = sliceOverlayQuad(p, dir, perp, aMin, aMax, bMin, bMax);

        // (1) every corner lies in the cut plane.
        foreach (c; q)
            assert(abs(dot(c - p, n)) < 1e-4f,
                   "quad corner must lie in the cut plane");

        // (2) the quad contains the segment: start/end project inside [aMin,aMax]
        //     along dir and [bMin,bMax] across perp.
        foreach (pt; [start, end]) {
            float a = dot(pt - p, dir), b = dot(pt - p, perp);
            assert(a >= aMin - 1e-4f && a <= aMax + 1e-4f, "segment within along-extent");
            assert(b >= bMin - 1e-4f && b <= bMax + 1e-4f, "segment within cross-extent");
        }
        // The extents are non-degenerate (a real rectangle).
        assert(aMax - aMin > 1e-3f && bMax - bMin > 1e-3f);
    }

    // Drag plane (no override): a Z-line ⇒ an X-normal plane; corners in-plane,
    // contain line.
    checkQuad(Vec3(0, 0, -1), Vec3(0, 0, 1), Vec3(0, 1, 0),
              SLICE_AXIS_DRAG, Vec3(0, 1, 0));

    // OWNER FIX 1 (0284): the overlay spans EXACTLY the segment along the line —
    // its along-`dir` extent never runs past the endpoint handles, no matter how
    // large the mesh is. A short Z-line on the unit cube must keep aMin/aMax at
    // the segment's own projection (here [0, 1]), NOT stretched to the cube's
    // ±0.5 along the line (which the pre-fix mesh-union extent would have done).
    {
        Vec3 s = Vec3(0, 0, -0.5f), e = Vec3(0, 0, 0.5f);   // a Z-line, length 1
        Vec3 p, n, dir, perp;
        assert(planeForSlice(s, e, Vec3(0,1,0), SLICE_AXIS_DRAG, Vec3(0,1,0), p, n));
        assert(sliceOverlayBasis(s, e, n, dir, perp));
        Mesh cube = makeCube();
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtent(cube, p, dir, perp, s, e, aMin, aMax, bMin, bMax);
        // Along the line: exactly the segment [0, 1] (p == start, dir == +Z).
        assert(abs(aMin - 0.0f) < 1e-5f, "along-min flush with the Start handle");
        assert(abs(aMax - 1.0f) < 1e-5f, "along-max flush with the End handle (no overhang)");
        // Across the line the plane DOES cover the cube (≥ its ±0.5 depth) so the
        // cut reads through the geometry (owner fix 2 shows it, this sizes it).
        assert(bMax >= 0.5f - 1e-5f && bMin <= -0.5f + 1e-5f,
               "cross-line extent must still span the mesh depth");
    }

    // TRACKING — axis change (extrusion-direction model): the SAME X-line extruded
    // along Z vs along Y gives DIFFERENT planes, and the drawn line lies IN both.
    {
        Vec3 s = Vec3(-0.5f, 0, 0), e = Vec3(0.5f, 0, 0);  // an X-line
        // axis=Z ⇒ extrude the X-line along Z ⇒ Y-normal plane (n = cross(X,Z)).
        // The X-line still lies IN it (n ⟂ line by construction).
        Vec3 pZ, nZ, dirZ, perpZ;
        assert(planeForSlice(s, e, Vec3(0,1,0), cast(int)SliceAxis.Z, Vec3(0,1,0), pZ, nZ));
        assert(abs(dot(s - pZ, nZ)) < 1e-5f && abs(dot(e - pZ, nZ)) < 1e-5f,
               "both endpoints lie in the axis=Z plane");
        assert(sliceOverlayBasis(s, e, nZ, dirZ, perpZ));
        checkQuad(s, e, Vec3(0, 1, 0), cast(int)SliceAxis.Z, Vec3(0, 1, 0));
        // axis=Y ⇒ extrude along Y ⇒ Z-normal plane; the X-line still lies in it,
        // but the plane (and hence perp) differs from axis=Z — the overlay tracked it.
        Vec3 pY, nY, dirY, perpY;
        assert(planeForSlice(s, e, Vec3(0,1,0), cast(int)SliceAxis.Y, Vec3(0,1,0), pY, nY));
        assert(abs(dot(s - pY, nY)) < 1e-5f && abs(dot(e - pY, nY)) < 1e-5f,
               "both endpoints lie in the axis=Y plane");
        assert(sliceOverlayBasis(s, e, nY, dirY, perpY));
        assert(abs(dot(nZ, nY)) < 1.0f - 1e-4f,
               "a different extrusion axis yields a different plane normal");
        checkQuad(s, e, Vec3(0, 1, 0), cast(int)SliceAxis.Y, Vec3(0, 1, 0));
    }

    // TRACKING — endpoint move: extending End along the line grows the along-
    // extent (the quad spans the longer segment). Anchor p = start.
    {
        Vec3 s = Vec3(0, 0, -0.5f);
        Mesh cube = makeCube();
        Vec3 pS, nS, dir, perp;
        assert(planeForSlice(s, Vec3(0,0,0.5f), Vec3(0,1,0),
                             SLICE_AXIS_DRAG, Vec3(0,1,0), pS, nS));
        assert(sliceOverlayBasis(s, Vec3(0,0,0.5f), nS, dir, perp));
        float a0min, a0max, b0min, b0max;
        sliceOverlayExtent(cube, pS, dir, perp, s, Vec3(0,0,0.5f), a0min, a0max, b0min, b0max);
        float a1min, a1max, b1min, b1max;
        sliceOverlayExtent(cube, pS, dir, perp, s, Vec3(0,0,3.0f), a1min, a1max, b1min, b1max);
        assert(a1max > a0max + 1e-4f,
               "moving End further out must grow the overlay's along-extent");
    }

    // Degenerate: a line parallel to the plane normal has no in-plane direction.
    {
        Vec3 dir, perp;
        assert(!sliceOverlayBasis(Vec3(0,0,0), Vec3(0,1,0), Vec3(0,1,0), dir, perp),
               "a line ∥ the normal yields no overlay basis");
    }

    // OWNER BUG FIX (0284): when the axis is LOCKED to a world axis, the cut
    // plane's normal is that axis and the plane NO LONGER contains the drawn
    // line. The unlocked line-based basis then goes thin/degenerate when the
    // normal runs near-parallel to the line — so the locked path must derive its
    // basis from the NORMAL (not the line) and cover the mesh. Verify for
    // axis = X / Y / Z, each with a line drawn ALONG that same axis (i.e. the
    // line is PARALLEL to the locked normal — the worst case the unlocked basis
    // cannot handle): a valid, non-degenerate, mesh-spanning, in-plane quad.
    static void checkLocked(Vec3 n, Vec3 start, Vec3 end) {
        import std.math : abs;
        // The unlocked basis is degenerate for this line (∥ the normal)...
        Vec3 ud, up;
        assert(!sliceOverlayBasis(start, end, n, ud, up),
               "line ∥ locked normal ⇒ no unlocked (line-based) basis");
        // ...but the locked (normal-derived) basis is well-defined.
        Vec3 dir, perp;
        assert(sliceOverlayBasisLocked(n, dir, perp),
               "a valid unit normal always yields a locked basis");
        Vec3 nn = normalize(n);
        assert(abs(dot(dir,  nn)) < 1e-5f, "locked dir must be in-plane");
        assert(abs(dot(perp, nn)) < 1e-5f, "locked perp must be in-plane");
        assert(abs(dot(dir, perp)) < 1e-5f, "locked dir ⟂ perp");
        assert(abs(dir.length  - 1.0f) < 1e-5f, "locked dir is unit");
        assert(abs(perp.length - 1.0f) < 1e-5f, "locked perp is unit");

        // Extent covers the unit cube (the region being cut), anchored at p = start.
        Mesh cube = makeCube();
        Vec3 p = start;   // planeForSlice always sets p = start
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtentLocked(cube, p, dir, perp, aMin, aMax, bMin, bMax);
        Vec3[4] q = sliceOverlayQuad(p, dir, perp, aMin, aMax, bMin, bMax);

        // (1) every corner lies in the cut plane.
        foreach (c; q)
            assert(abs(dot(c - p, nn)) < 1e-4f, "locked quad corner in the cut plane");
        // (2) the quad SPANS the mesh (not collapsed to the line): the unit cube
        //     measures 1.0 across each in-plane axis, so both extents clear ~0.9.
        assert(aMax - aMin > 0.9f, "locked quad spans the mesh along dir");
        assert(bMax - bMin > 0.9f, "locked quad spans the mesh along perp");
    }
    checkLocked(Vec3(1, 0, 0), Vec3(-0.5f, 0, 0), Vec3(0.5f, 0, 0));   // axis X, X-line
    checkLocked(Vec3(0, 1, 0), Vec3(0, -0.5f, 0), Vec3(0, 0.5f, 0));   // axis Y, Y-line
    checkLocked(Vec3(0, 0, 1), Vec3(0, 0, -0.5f), Vec3(0, 0, 0.5f));   // axis Z, Z-line

    // The UNLOCKED path is unchanged: an in-plane line still bounds the along-
    // extent to the drawn segment (never mesh-spanning along the line).
    {
        Vec3 s = Vec3(0, 0, -0.5f), e = Vec3(0, 0, 0.5f);   // a Z-line
        Vec3 p, n, dir, perp;
        assert(planeForSlice(s, e, Vec3(0,1,0), SLICE_AXIS_DRAG, Vec3(0,1,0), p, n));
        assert(sliceOverlayBasis(s, e, n, dir, perp));
        Mesh cube = makeCube();
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtent(cube, p, dir, perp, s, e, aMin, aMax, bMin, bMax);
        assert(abs(aMin - 0.0f) < 1e-5f && abs(aMax - 1.0f) < 1e-5f,
               "unlocked along-extent stays flush with the drawn segment");
    }
}

// ---------------------------------------------------------------------------
// OWNER FIX 3 (0284) — FROZEN cut-plane normal. Both the cut (sliceFromBaseline)
// and the overlay (draw) build their plane from the tool's effectiveNormal(),
// which is the normal FROZEN at the gesture that drew the line. This proves,
// analytically, that once frozen the plane is decoupled from the work-plane
// normal: feeding a DIFFERENT (post-orbit) work-plane normal does NOT move the
// plane, while the tool keeps using the frozen one — so the drawn cut and the
// committed cut cannot diverge under camera orbit. (Guarding against the OLD
// bug where draw()/updatePreview recomputed cachedWorkplaneNormal() live.)
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // A Z-line; the drag normal captured at gesture start is +Y (world-XZ work
    // plane). After the user orbits, the LIVE work-plane normal would tilt.
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0, 0, 1);
    Vec3 frozenN  = Vec3(0, 1, 0);
    Vec3 orbitedN = normalize(Vec3(0.35f, 1.0f, 0.25f));   // camera moved

    // The plane the cut/overlay use is fully determined by the PASSED normal.
    Vec3 pFrozen, nFrozen;
    assert(planeForSlice(s, e, frozenN, SLICE_AXIS_DRAG, Vec3(0,1,0), pFrozen, nFrozen));

    // If the tool (wrongly) used the LIVE normal after an orbit, the plane would
    // move: prove the live normal yields a DIFFERENT plane normal.
    Vec3 pLive, nLive;
    assert(planeForSlice(s, e, orbitedN, SLICE_AXIS_DRAG, Vec3(0,1,0), pLive, nLive));
    assert(abs(dot(nFrozen, nLive)) < 1.0f - 1e-3f,
           "a changed work-plane normal WOULD move the drag plane (so freezing matters)");

    // The tool keeps passing the FROZEN normal, so the plane is unchanged after
    // the orbit — identical normal, identical through-point.
    Vec3 pStill, nStill;
    assert(planeForSlice(s, e, frozenN, SLICE_AXIS_DRAG, Vec3(0,1,0), pStill, nStill));
    assert(abs(nStill.x - nFrozen.x) < 1e-6f &&
           abs(nStill.y - nFrozen.y) < 1e-6f &&
           abs(nStill.z - nFrozen.z) < 1e-6f,
           "frozen normal ⇒ the cut/overlay plane stays put across camera orbit");

    // And the ACTUAL cut geometry is frozen too: cutting the cube with the frozen
    // normal is byte-for-byte identical regardless of the later live normal,
    // while the live normal would have produced a measurably different cut.
    Mesh a = makeCube(); auto ba = MeshSnapshot.capture(a);
    Mesh b = makeCube(); auto bb = MeshSnapshot.capture(b);
    Mesh c = makeCube(); auto bc = MeshSnapshot.capture(c);
    // `a`, `b`: cut with the FROZEN normal (the tool's behavior before + after orbit).
    sliceFromBaseline(a, ba, s, e, frozenN,  SLICE_AXIS_DRAG, Vec3(0,1,0), true);
    sliceFromBaseline(b, bb, s, e, frozenN,  SLICE_AXIS_DRAG, Vec3(0,1,0), true);
    // `c`: cut with the ORBITED normal (what the buggy live path would have done).
    sliceFromBaseline(c, bc, s, e, orbitedN, SLICE_AXIS_DRAG, Vec3(0,1,0), true);
    assert(a.vertices.length == b.vertices.length);
    bool frozenStable = true, liveDiffers = false;
    foreach (i; 0 .. a.vertices.length) {
        if (abs(a.vertices[i].x - b.vertices[i].x) > 1e-6f ||
            abs(a.vertices[i].y - b.vertices[i].y) > 1e-6f ||
            abs(a.vertices[i].z - b.vertices[i].z) > 1e-6f) frozenStable = false;
    }
    if (c.vertices.length == a.vertices.length) {
        foreach (i; 0 .. a.vertices.length)
            if (abs(a.vertices[i].x - c.vertices[i].x) > 1e-4f ||
                abs(a.vertices[i].y - c.vertices[i].y) > 1e-4f ||
                abs(a.vertices[i].z - c.vertices[i].z) > 1e-4f) liveDiffers = true;
    } else liveDiffers = true;
    assert(frozenStable, "frozen-normal cut is identical before/after orbit");
    assert(liveDiffers,  "the live-normal cut WOULD differ — so the freeze is load-bearing");
}

// ---------------------------------------------------------------------------
// OWNER FIX 4 (0284; extrusion-direction model) — the axis model has NO `Free`.
// SliceAxis offers only the {X, Y, Z, Custom} OVERRIDE; "no override" is the
// runtime SLICE_AXIS_DRAG mode (the frozen drag plane), which is the DEFAULT. This
// asserts the enum/table shape, that SLICE_AXIS_DRAG reproduces the drawn-line
// plane, and that every override mode extrudes the line along its axis so the
// plane CONTAINS BOTH endpoints (n ⟂ line) — the core owner-bug invariant.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // No `Free` member survives, and the values are the unchanged 1..4.
    static assert(!__traits(hasMember, SliceAxis, "Free"),
                  "SliceAxis must not expose a Free value (owner fix 4)");
    static assert(cast(int)SliceAxis.X == 1 && cast(int)SliceAxis.Y == 2 &&
                  cast(int)SliceAxis.Z == 3 && cast(int)SliceAxis.Custom == 4);
    static assert(SLICE_AXIS_DRAG == 0, "the no-override wire mode is 0 (planeForSlice default)");

    // The user-selectable table is exactly {x, y, z, custom} — no "free" tag.
    assert(sliceAxisTable.length == 4);
    foreach (entry; sliceAxisTable)
        assert(entry.wireTag != "free", "no 'free' entry in the Axis dropdown");
    assert(sliceAxisTable[0].wireTag == "x" && sliceAxisTable[1].wireTag == "y" &&
           sliceAxisTable[2].wireTag == "z" && sliceAxisTable[3].wireTag == "custom");

    // DEFAULT = the frozen drag plane: mode SLICE_AXIS_DRAG reproduces the
    // drawn-line ⟂ work-plane plane exactly (== planeFromLineAndWorkplane).
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0.3f, 0, 1), wpN = Vec3(0, 1, 0);
    Vec3 pD, nD, pR, nR;
    assert(planeForSlice(s, e, wpN, SLICE_AXIS_DRAG, Vec3(0,1,0), pD, nD));
    assert(planeFromLineAndWorkplane(s, e, wpN, pR, nR));
    assert(abs(nD.x - nR.x) < 1e-6f && abs(nD.y - nR.y) < 1e-6f && abs(nD.z - nR.z) < 1e-6f,
           "the no-override default is the drawn-line drag plane");

    // OVERRIDE X/Y/Z/Custom: the line is EXTRUDED along the axis, so the plane
    // CONTAINS BOTH drawn endpoints (n ⟂ line) and n ⟂ the extrusion axis. This is
    // the owner-bug invariant: the axis-locked plane still passes through both
    // points, unlike the old normal=world-axis model (which passed through Start
    // only). Verify for each axis with the slanted line above.
    Vec3 p, n;
    static void checkExtrude(Vec3 s, Vec3 e, int mode, Vec3 axisDir, Vec3 vec) {
        Vec3 pp, nn;
        assert(planeForSlice(s, e, Vec3(0,1,0), mode, vec, pp, nn),
               "a line not parallel to the axis has a well-defined plane");
        assert(abs(nn.length - 1.0f) < 1e-5f, "unit normal");
        assert(abs(dot(s - pp, nn)) < 1e-5f, "Start lies in the extruded plane");
        assert(abs(dot(e - pp, nn)) < 1e-5f, "End lies in the extruded plane");
        assert(abs(dot(nn, normalize(axisDir))) < 1e-5f, "n ⟂ the extrusion axis");
    }
    checkExtrude(s, e, cast(int)SliceAxis.X, Vec3(1,0,0), Vec3(0,1,0));
    checkExtrude(s, e, cast(int)SliceAxis.Y, Vec3(0,1,0), Vec3(0,1,0));
    checkExtrude(s, e, cast(int)SliceAxis.Z, Vec3(0,0,1), Vec3(0,1,0));
    checkExtrude(s, e, cast(int)SliceAxis.Custom, Vec3(2,0,0), Vec3(2,0,0));

    // The override plane can DIFFER from the drag-plane normal for this line
    // (axis=Z vs. the drag plane) — proving lock ≠ default.
    assert(planeForSlice(s, e, wpN, cast(int)SliceAxis.Z, Vec3(0,1,0), p, n));
    assert(abs(dot(n, nD)) < 1.0f - 1e-4f,
           "an axis override yields a different plane than the drag default");

    // DEGENERATE GUARD: a line drawn ALONG the extrusion axis has no unique plane.
    assert(!planeForSlice(Vec3(-1,0,0), Vec3(1,0,0), wpN,
                          cast(int)SliceAxis.X, Vec3(0,1,0), p, n),
           "line ∥ extrusion axis X ⇒ planeForSlice returns false");
}

// ---------------------------------------------------------------------------
// OWNER FIX 1 (0284; extrusion-direction model) — the drag plane's EXTRUSION
// DIRECTION classifies to a concrete Axis so the Tool-Properties dropdown reflects
// the drawn cut. Proves, WITHOUT a GL context: (a) an axis-aligned extrusion dir →
// X/Y/Z; (b) a slanted extrusion dir → Custom with vector == the direction; (c) the
// classification ROUND-TRIPS the plane (drag plane → classify the extrusion dir →
// planeForSlice(classifiedAxis) reproduces the SAME plane); (d) the cut is
// BYTE-IDENTICAL whether cut in drag mode (SLICE_AXIS_DRAG) or via the classified
// axis — so reflecting the panel never moves the geometry.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // Each world axis (both signs) classifies to its axis — the extrusion dir is
    // the frozen work-plane normal, classified sign-agnostically (|dir·axis| ≥ tol).
    {
        Vec3 v;
        assert(classifyPlaneAxis(Vec3( 1,0,0), v) == SliceAxis.X);
        assert(classifyPlaneAxis(Vec3(-1,0,0), v) == SliceAxis.X);
        assert(classifyPlaneAxis(Vec3(0, 1,0), v) == SliceAxis.Y);
        assert(classifyPlaneAxis(Vec3(0,-1,0), v) == SliceAxis.Y);
        assert(classifyPlaneAxis(Vec3(0,0, 1), v) == SliceAxis.Z);
        assert(classifyPlaneAxis(Vec3(0,0,-1), v) == SliceAxis.Z);
    }
    // (a) The default +Y work plane (the headless drag extrusion direction)
    //     classifies to axis Y.
    {
        Vec3 v;
        assert(classifyPlaneAxis(Vec3(0,1,0), v) == SliceAxis.Y,
               "the +Y work-plane extrusion direction classifies to axis Y");
    }
    // (b) A slanted extrusion direction ⇒ Custom, vector == normalize(direction).
    {
        Vec3 d = normalize(Vec3(0.3f, 1.0f, 0.0f));   // off every world axis
        Vec3 v;
        assert(classifyPlaneAxis(d, v) == SliceAxis.Custom,
               "an off-axis extrusion direction classifies to Custom");
        assert(abs(v.x - d.x) < 1e-6f && abs(v.y - d.y) < 1e-6f && abs(v.z - d.z) < 1e-6f,
               "Custom vector == the extrusion direction");
    }

    // (c) ROUND-TRIP + (d) BYTE-IDENTICAL cut: build the drag plane, classify its
    //     extrusion direction (the work-plane normal), rebuild via the classified
    //     axis, and assert BOTH the plane (n, p) and the resulting cube cut match.
    static void assertRoundTrip(Vec3 s, Vec3 e, Vec3 wpN) {
        // Drag plane (extrude the line along wpN).
        Vec3 pD, nD;
        assert(planeForSlice(s, e, wpN, SLICE_AXIS_DRAG, Vec3(0,1,0), pD, nD));
        // Classify the EXTRUSION direction (the work-plane normal), NOT the cut normal.
        Vec3 v;
        SliceAxis a = classifyPlaneAxis(wpN, v);
        // Rebuild via the classified axis and assert the SAME plane.
        Vec3 pC, nC;
        assert(planeForSlice(s, e, wpN, cast(int)a, v, pC, nC));
        assert(abs(nC.x - nD.x) < 1e-5f && abs(nC.y - nD.y) < 1e-5f && abs(nC.z - nD.z) < 1e-5f,
               "classified-axis plane normal == the drag plane normal");
        assert(abs(pC.x - pD.x) < 1e-6f && abs(pC.y - pD.y) < 1e-6f && abs(pC.z - pD.z) < 1e-6f,
               "classified-axis through-point == the drag through-point");
        // ...and the actual cube cut is byte-identical either way.
        Mesh md = makeCube(); auto bd = MeshSnapshot.capture(md);
        sliceFromBaseline(md, bd, s, e, wpN, SLICE_AXIS_DRAG, Vec3(0,1,0), true);
        Mesh mc = makeCube(); auto bc = MeshSnapshot.capture(mc);
        sliceFromBaseline(mc, bc, s, e, wpN, cast(int)a, v, true);
        assert(md.vertices.length == mc.vertices.length,
               "classified-axis cut has the same vert count as the drag-mode cut");
        foreach (i; 0 .. md.vertices.length)
            assert(abs(md.vertices[i].x - mc.vertices[i].x) < 1e-6f &&
                   abs(md.vertices[i].y - mc.vertices[i].y) < 1e-6f &&
                   abs(md.vertices[i].z - mc.vertices[i].z) < 1e-6f,
                   "classified-axis cut is byte-identical to the drag-mode cut");
    }
    // Axis-aligned extrusion direction (+Y work plane ⇒ axis Y).
    assertRoundTrip(Vec3(0,0,-1), Vec3(0,0,1), Vec3(0,1,0));
    // Slanted extrusion direction ⇒ Custom; the Custom vector rebuilds it exactly.
    assertRoundTrip(Vec3(0,0,-1), Vec3(0,0,1), normalize(Vec3(0.4f, 1.0f, 0.0f)));
}

// ---------------------------------------------------------------------------
// OWNER FIX 2 (0284) — the overlay is a RECTANGLE biased LARGER across the line
// (the no-handle `perp` axis) than along it (the handle axis). For an in-plane
// line the perpendicular extent is STRICTLY greater than the along extent, while
// the along extent still equals the drawn segment exactly.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    Vec3 s = Vec3(0,0,-0.5f), e = Vec3(0,0,0.5f);   // a unit Z-line (length 1)
    Vec3 p, n, dir, perp;
    assert(planeForSlice(s, e, Vec3(0,1,0), SLICE_AXIS_DRAG, Vec3(0,1,0), p, n));
    assert(sliceOverlayBasis(s, e, n, dir, perp));
    Mesh cube = makeCube();
    float aMin, aMax, bMin, bMax;
    sliceOverlayExtent(cube, p, dir, perp, s, e, aMin, aMax, bMin, bMax);
    float along = aMax - aMin, across = bMax - bMin;
    // ALONG-line = the drawn segment exactly ([0,1]) — handles at its ends.
    assert(abs(aMin - 0.0f) < 1e-5f && abs(aMax - 1.0f) < 1e-5f,
           "along-line extent stays flush with the drawn segment");
    // PERPENDICULAR (no-handle) is STRICTLY larger — the plane extends past the
    // handles rather than reading as a thin square between them.
    assert(across > along + 1e-4f,
           "perpendicular-to-line extent must be strictly greater than along-line");
    // ...and still spans the mesh depth (±0.5) with room to spare.
    assert(bMax >= 0.5f && bMin <= -0.5f, "cross extent still spans the mesh");
}

// ---------------------------------------------------------------------------
// CUSTOM-AXIS ROTATE GIZMO (task 0287) — the rotate-math kernel + the geometric
// invariants the ring drag must uphold: rotating the Custom `vector` about the
// drawn line by θ tilts the cut-plane normal by the SAME θ about the line, while
// BOTH endpoints stay in the plane and the line stays contained (n ⟂ line). The
// two drawn points never move. Pure — no GL context.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs, fabs, PI, cos, sin;

    // (a) Rodrigues basics: +Y about +X by +90° → +Z (right-handed).
    {
        Vec3 r = rotateVectorAboutAxis(Vec3(0,1,0), Vec3(1,0,0), cast(float)(PI/2));
        assert(fabs(r.x) < 1e-5f && fabs(r.y) < 1e-5f && fabs(r.z - 1.0f) < 1e-5f,
               "rotate +Y about +X by +90° = +Z");
    }
    // (a2) The axis component of a vector is preserved; length is preserved.
    {
        Vec3 v = Vec3(0.3f, 1.0f, 0.4f);
        Vec3 axis = normalize(Vec3(0.2f, 0.1f, 1.0f));
        Vec3 r = rotateVectorAboutAxis(v, axis, 0.7f);
        assert(fabs(r.length - v.length) < 1e-5f, "rotation preserves |v|");
        assert(fabs(dot(r, axis) - dot(v, axis)) < 1e-5f, "axis component preserved");
    }
    // (b) signedAngleAboutAxis round-trips against a known rotation.
    {
        Vec3 axis = normalize(Vec3(0.1f, 0.2f, 1.0f));
        Vec3 from = Vec3(1, 0, 0);
        // Make `from` ⟂ axis so the in-plane angle is exactly the applied one.
        from = normalize(from - axis * dot(from, axis));
        float theta = 0.6f;
        Vec3 to = rotateVectorAboutAxis(from, axis, theta);
        assert(fabs(signedAngleAboutAxis(from, to, axis) - theta) < 1e-5f,
               "signed angle recovers the applied rotation");
        assert(fabs(signedAngleAboutAxis(to, from, axis) + theta) < 1e-5f,
               "signed angle is antisymmetric");
    }

    // (c) THE LOAD-BEARING INVARIANT. A drawn line (start,end), a Custom vector
    //     not parallel to it, and the extrusion model normal = cross(lineDir,vec).
    //     Rotating `vec` about lineDir by θ must rotate the NORMAL by θ about
    //     lineDir, keep both endpoints in the plane, and keep n ⟂ line — for a
    //     sweep of angles — and planeForSlice(Custom, vec') must agree.
    static void checkTilt(Vec3 start, Vec3 end, Vec3 vec0, float theta) {
        Vec3 lineDir = normalize(end - start);
        // Baseline plane from the frozen vector.
        Vec3 p0, n0;
        assert(planeForSlice(start, end, Vec3(0,1,0), cast(int)SliceAxis.Custom, vec0, p0, n0),
               "baseline Custom plane is well-defined (vec not ∥ line)");
        // Tilt the vector about the line, exactly what the gizmo drag does.
        Vec3 vec1 = rotateVectorAboutAxis(vec0, lineDir, theta);
        Vec3 p1, n1;
        assert(planeForSlice(start, end, Vec3(0,1,0), cast(int)SliceAxis.Custom, vec1, p1, n1),
               "tilted Custom plane is well-defined");
        // n ⟂ line, and BOTH endpoints lie in the tilted plane (the line stays).
        assert(fabs(dot(n1, lineDir)) < 1e-5f, "tilted normal ⟂ the line");
        assert(fabs(dot(start - p1, n1)) < 1e-5f, "Start stays in the tilted plane");
        assert(fabs(dot(end   - p1, n1)) < 1e-5f, "End stays in the tilted plane");
        // The through-point p is start for both (the endpoints never move).
        assert(fabs((p1 - p0).length) < 1e-6f, "through-point (= Start) unchanged");
        // The NORMAL rotated by EXACTLY θ about the line: signed angle n0→n1 = θ
        // (both n0, n1 are ⟂ lineDir, so the in-plane signed angle is exact).
        float measured = signedAngleAboutAxis(n0, n1, lineDir);
        // Compare on the circle (fold to (-π,π]); a straight diff handles the
        // moderate angles swept here.
        assert(fabs(measured - theta) < 1e-4f,
               "plane normal tilts by exactly the applied angle about the line");
    }
    // A slanted line + an oblique Custom vector, swept across several angles.
    Vec3 s = Vec3(-0.7f, -0.4f, 0.3f), e = Vec3(0.7f, 0.4f, -0.3f);
    Vec3 vec0 = Vec3(0.3f, 1.0f, 0.4f);
    foreach (k; 0 .. 7) {
        float theta = -0.9f + 0.3f * k;   // −0.9 … +0.9 rad
        checkTilt(s, e, vec0, theta);
    }
    // An axis-aligned line too (X-line, vector with a Y/Z tilt).
    checkTilt(Vec3(-1,0,0), Vec3(1,0,0), Vec3(0, 1, 0.5f), 0.5f);
    checkTilt(Vec3(-1,0,0), Vec3(1,0,0), Vec3(0, 1, 0.5f), -0.8f);
}
