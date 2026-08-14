// Border classification and the snap guide it exists for.
//
// `isEdgeInterior` / `isVertexInterior` answer "is this element on the mesh
// border", and `PenSnapGuide` is the `SnapGuide` the Topology Pen registers
// for the duration of a gesture -- whose admission rule is that question.
// They are one family: the predicates have no other caller, in this package or
// outside it, and the guide has no other rule.
//
// Split out of the tool module by task 0718, verbatim apart from one indent
// level and the `static` storage class, which class members needed and module
// members do not. The guide was already `static` and back-pointer-free ("a
// guide answers from what it was told"), which is what made it liftable at
// all; the dependency runs one way, tool.d -> here.
module tools.edit.topology_pen.snap_guide;

import std.math          : hypot;

import mesh              : Mesh, MeshCacheKey;
import math              : Vec3, Viewport, dot, screenPointToRay, projectToWindowFull;
import document          : primaryModelSpace;
import toolpipe.guide    : SnapGuide, GuideDrawState, kGuidePrioritySeed;
import toolpipe.packets  : SnapType;

/// True if edge `ei` is INTERIOR — shared by two or more polygons.
///
/// Counted off `faces[]` via `Mesh.edgePolygonCounts`, NOT through
/// `facesAroundEdge` (task 0502): the half-edge rings have no
/// representation for a non-manifold fan and report ONE face for three
/// quads sharing an edge, so the ring walk classified a NON-MANIFOLD edge
/// as a BORDER edge — and this predicate is the border-only snap-candidate
/// filter, so such an edge silently became a snap target. `>= 2` is
/// unchanged; only the counter under it is now truthful.
package bool isEdgeInterior(in int[] polyCount, uint ei) {
    return ei < polyCount.length && polyCount[ei] >= 2;
}

/// One-off convenience — RECOUNTS THE WHOLE MESH per call. Any loop over
/// edges or vertices must hoist `Mesh.edgePolygonCounts()` once and use the
/// array overload; the two `borderOnly` scans below do exactly that.
package bool isEdgeInterior(Mesh* m, uint ei) {
    return isEdgeInterior(m.edgePolygonCounts(), ei);
}

/// True if vertex `vi` is INTERIOR — it has incident edges and EVERY one
/// of them is interior, i.e. it touches no border and no wire edge.
private bool isVertexInterior(Mesh* m, in int[] polyCount, uint vi) {
    bool any = false;
    foreach (ei; m.edgesAroundVertex(vi)) {
        any = true;
        if (!isEdgeInterior(polyCount, ei)) return false;
    }
    return any;
}

/// One-off convenience — see the `isEdgeInterior` overload above.
package bool isVertexInterior(Mesh* m, uint vi) {
    return isVertexInterior(m, m.edgePolygonCounts(), vi);
}

// -----------------------------------------------------------------------
// The pen's SNAPPING GUIDE — S6 of doc/toolpipe_architecture_plan.md.
//
// The pen has no snapping of its own to own. It is a CLIENT of the one
// snapping service in this tree, and the only thing about that service
// that is the pen's is the ADMISSION RULE: which enumerated candidate the
// pen is willing to land on. That rule used to be a `bool borderOnly`
// parameter threaded through the tool's own vertex scan — a policy with no
// owner, invisible to the service and unusable by anything else. It lives
// here now, in one object, with the lifetime of one gesture.
//
// MEASURED — the LIFECYCLE. The reference's pen registers a guide object
// on the shared event-translation packet when its drag starts and removes
// it on mouse-up; the environment's pixel ranges are pushed INTO the guide
// by the framework, which is why `limits` is a setter and not a getter.
// Our `SnapStage` is the same service: `addGuide` on the press,
// `removeGuide` on the release (`TopologyPenTool.onMouseButtonDown` /
// `onMouseButtonUp` / `deactivate`), and the stage pushes the ranges in.
//
// MEASURED — the PRIORITY. `kPriority` below is read out of the reference,
// not chosen: its pen guide declares 2 where its element-snap guide
// declares 3, and both are live for the whole of a pen drag. The framework
// pre-seeds the priority slot to 1 before every proximity call, so 1 is
// what a guide that ignores the parameter reports — 2 is a deliberate
// value, one step above the default and one below the element snap's.
//
// MEASURED — `flags`. The reference's pen guide installs NO flags accessor
// at all (the vtable slot is NULL, and it is one of exactly three
// tool-owned guides that leave it so). `0` is the faithful stand-in for
// "declares nothing": no bit is set, and in particular the pen does NOT
// claim the "run even when the global snap enable is off" bit — which is
// the whole of why the weld below is gated. Do not put a bit here without
// a measurement.
//
// OURS, and unmeasured: the AIM (`aimAt`). The interface pushes the
// environment's RANGES in but not its CURSOR, and a guide cannot answer
// "how far away is this candidate" without one. So whoever is about to run
// a query aims the guide first, exactly as it would push a range. The
// reference's guide carries a view and a host pointer in its own context
// and is likewise aimed by its owner, so the direction is right; the
// spelling is ours.
// -----------------------------------------------------------------------
final class PenSnapGuide : SnapGuide {
    /// The priority this guide answers proximity queries with. MEASURED —
    /// see the block comment above. Higher wins outright; distance only
    /// breaks ties WITHIN one priority.
    enum int kPriority = 2;

    // The mesh the admission rule is evaluated against, and the border
    // classification of its edges. The counts are a CACHE, keyed on
    // (address, mutationVersion) so a gesture that edits the mesh under
    // the guide — Move writes on every motion event — re-derives them
    // instead of admitting against a stale topology. The pen's own scan
    // used to recompute them once per call, so this is never more work
    // and usually less.
    private Mesh*        mesh_;
    private int[]        polyCount_;
    private MeshCacheKey polyKey_;

    /// `innerSnap`: when set, the interior opens up and every vertex is a
    /// candidate. The pen attribute, mirrored here rather than read
    /// through a back-pointer — a guide answers from what it was told.
    private bool interiorOk_;

    /// `backFace`: when set, the ORIENTATION test below is skipped and a
    /// back-facing candidate is admitted. Mirrored here for the same
    /// reason `interiorOk_` is. MEASURED, including the polarity: the
    /// reference reads its flag in the same candidate-filter callbacks it
    /// reads the border rule in, and a non-zero value is what makes the
    /// filter accept without testing.
    private bool backFaceOk_;

    // The aim. `aimed_` is deliberately NOT defaulted true: a guide that
    // has never been aimed must reject rather than answer against a
    // zero viewport, because a wrong distance is a wrong winner and would
    // be indistinguishable from a near miss.
    //
    // `aimDir_` is the world-space ray through the aimed pixel, computed
    // once per aim and shared by every candidate — which is the measured
    // shape of the orientation test, not an optimisation: the reference
    // writes ONE screen ray into the tool before it runs the candidate
    // search and every filter call dots against that one direction. A
    // per-candidate eye→candidate direction would be a different test at
    // wide FOV.
    private Viewport aimVp_;
    private int      aimX_, aimY_;
    package Vec3     aimDir_ = Vec3(0, 0, 0);
    // The same ray direction in the PRIMARY layer's LOCAL space (task
    // 0619 §1.4), written beside `aimDir_` in `aimAt`. Deliberately NOT
    // renormalized — only its SIGN against a local normal is read.
    private Vec3     aimDirLocal_ = Vec3(0, 0, 0);
    private bool     aimed_;

    // What the service pushed in. Recorded, not consumed: the pen's own
    // resolver takes the acceptance radius off the packet it snapshotted
    // at press (one gesture, one set of ranges), and the service applies
    // its own gather cutoff before a candidate ever reaches `proximity`.
    // They are held so a reader — and the package's unittest module — can
    // see that the push arrived.
    private float innerPx_ = -1.0f, outerPx_ = -1.0f;
    private GuideDrawState draw_ = GuideDrawState.Off;

    /// Point the guide at the mesh and the admission policy of the gesture
    /// that is starting.
    ///
    /// `interiorOk` is `innerSnap`, in the SAME polarity — not the
    /// `borderOnly` negation the scan parameter used to carry. Stated
    /// because the flip is one character and the two spellings coexisted
    /// during this move; the 0496 Split cases below are what catch it.
    ///
    /// `backFaceOk` is `backFace`, likewise in the SAME polarity: TRUE
    /// opens back-facing candidates. It defaults to the MEASURED default
    /// (OFF, i.e. the orientation test runs) so a caller that forgets it
    /// gets the reference's behaviour rather than the permissive one.
    void retarget(Mesh* m, bool interiorOk, bool backFaceOk = false) {
        mesh_       = m;
        interiorOk_ = interiorOk;
        backFaceOk_ = backFaceOk;
        polyKey_.invalidate();
    }

    /// Aim the guide at the query that is about to run. See the block
    /// comment: OURS, because the interface pushes ranges but not a cursor.
    ///
    /// Also derives this query's one screen ray (`aimDir_`), which the
    /// orientation test in `admits` dots every candidate normal against.
    /// `screenPointToRay` rather than `screenRay` so an ORTHOGRAPHIC
    /// viewport answers with its view forward instead of an inverted
    /// perspective matrix it does not have.
    void aimAt(const ref Viewport vp, int mx, int my) {
        aimVp_ = vp;
        aimX_  = mx;
        aimY_  = my;
        Vec3 org;
        screenPointToRay(cast(float)mx, cast(float)my, vp, org, aimDir_);
        // Task 0619 §1.4: the primary layer's LOCAL copy of this same
        // ray direction, resolved ONCE per aim. `orientationAdmits`
        // dots it against local face normals, so this replaces an
        // O(faces) normal transform with one O(1) direction transform.
        // `aimVp_`/`aimDir_` stay WORLD: `proximity` receives world
        // candidate positions from the snapping service and must keep
        // measuring its pixel distance in the world viewport.
        aimDirLocal_ = primaryModelSpace().toLocalDir(aimDir_);
        aimed_ = true;
    }

    /// THE PEN'S ADMISSION RULE, and the only copy of it.
    ///
    /// Shaped as `snap.SnapAdmit` so the pen's own resolver can hand it
    /// straight to a candidate walk, and called by `proximity` below so
    /// the service's walk applies the identical rule. One predicate, two
    /// channels — which is the reference's own arrangement: its pen
    /// carries an admission callback on its own snap call AND registers a
    /// guide for the framework's, and both enforce the same border rule.
    ///
    /// * VERTICES only. The pen's snap target is a vertex by definition
    ///   (a landing on an edge mid-span is a no-op, not a weld), so every
    ///   other enumerated type is refused rather than silently outranked.
    /// * The ACTIVE mesh only (`slot == 0`). A background layer is a
    ///   snapping source for placement, never a weld target — the pen
    ///   cannot edit it.
    /// * BORDER vertices only, unless `innerSnap` opens the interior. A
    ///   vertex with no incident edges at all is NOT interior and stays a
    ///   candidate, exactly as the scan this replaces had it.
    /// * FRONT-FACING vertices only, unless `backFace` opens the other
    ///   side. See `orientationAdmits` for the test and its provenance.
    ///
    /// `nothrow` by the `SnapAdmit` contract. The count refresh allocates
    /// and is therefore not `nothrow` itself; a failure REJECTS, which is
    /// that contract's own stated answer for a predicate that cannot
    /// decide ("a predicate that needs to fail should reject").
    bool admits(SnapType type, int idx, int slot) nothrow {
        if (type != SnapType.Vertex) return false;
        if (slot != 0)               return false;
        if (mesh_ is null || idx < 0) return false;
        if (idx >= cast(int)mesh_.vertices.length) return false;
        try {
            if (!interiorOk_) {
                if (!polyKey_.matches(*mesh_)) {
                    polyCount_ = mesh_.edgePolygonCounts();
                    polyKey_.stamp(*mesh_);
                }
                if (isVertexInterior(mesh_, polyCount_, cast(uint)idx))
                    return false;
            }
            return orientationAdmits(cast(uint)idx);
        } catch (Exception) {
            return false;
        }
    }

    /// The ORIENTATION half of the admission rule — `backFace`, task 0538.
    ///
    /// MEASURED, law and polarity both. At `backFace` OFF the reference
    /// takes the CANDIDATE'S OWN normal, brings it into the space of the
    /// screen ray, and dots the two: a positive dot — the normal pointing
    /// the same way the ray travels, i.e. away from the viewer — REJECTS.
    /// At `backFace` ON the test is skipped and the candidate is accepted
    /// unconditionally. A ZERO normal is never rejected (its dot is 0, and
    /// the reject is strict `> 0`); that clause is the reference's own,
    /// not a robustness flourish of ours.
    ///
    /// The normal is the UNIFORM (unweighted) average of the incident face
    /// normals — the reference's own default vertex-normal convention,
    /// documented as such and separately confirmed against it on a
    /// deform-tool fixture. `Mesh.faceNormal` returns a UNIT vector, so
    /// summing it is that average and not the area-weighted one a raw
    /// Newell sum would give. A vertex with no incident faces sums to zero
    /// and is therefore admitted, which is the same answer the border half
    /// gives face-less geometry.
    ///
    /// THE SPACES — task 0619 §1.4, and the comment this replaces was
    /// WRONG about them. It said "ours are both in world space
    /// (`Document` has no per-layer transform yet)". `Document` has had
    /// one since 0617, and `mesh_.faceNormal` was never a world normal
    /// in the first place: it is built from `mesh_.vertices[]`, i.e.
    /// LOCAL coordinates. Only `aimDir_` was world. The test therefore
    /// dotted a local normal against a world ray, which is wrong for any
    /// non-identity `M` — including under a pure rotation, where the
    /// numbers stay plausible and the SIGN can still flip near grazing.
    ///
    /// The fix is one direction transform on the RAY, not one normal
    /// transform per face, and its sign correction is **σ = +1** — no
    /// `ms.mirrored`, no `det(M)`:
    ///
    ///     dot(n_local, ms.toLocalDir(d_world))
    ///       == dot(ms.toWorldNormal(n_local), d_world)     EXACTLY,
    ///
    /// for any invertible `M`, mirrored or not, because
    /// `dot((M^-1)^T n, M v) == dot(n, v)` is an identity. Four in-tree
    /// citations, none of them this comment's own opinion:
    ///   * `math.d:428-454` — `ModelSpace.mirrored`'s doc: a front-facing
    ///     test done ENTIRELY in local space needs NO correction,
    ///     mirrored or not; names the three sites that had it backwards
    ///     and says not to reintroduce the flip;
    ///   * `math.d:666-721` — the unittest that checks the local test
    ///     against the true geometric world test (world normal via the
    ///     inverse-transpose) across four `M`s, mirrored and not, and
    ///     whose own comment records that its PREVIOUS version measured
    ///     a winding artefact and could not fail. (The plan cites this
    ///     as `math.d:570-592`; that range is the `toLocalPoint`
    ///     round-trip and `toLocalDir` non-normalisation blocks — the
    ///     line numbers moved, the argument did not.);
    ///   * `math.d:495-512` — `toWorldNormal`'s doc: do NOT "fix" a
    ///     mirror-flipped normal by cross-producting world points;
    ///   * app.d's RMB-lasso `frontFacing` closure, `Mesh.visibleVertices`'
    ///     inline cull, and snap.d's `faceVisible` — the three sites 0617
    ///     converted to exactly this law, each carrying its reason inline.
    ///     (Cited by SYMBOL on purpose: this comment previously carried
    ///     four line numbers and all four had rotted. Re-derivable by
    ///     searching for `ms.mirrored`, which is still read nowhere in
    ///     production.)
    ///
    /// Two laws that are NOT this one, rejected on purpose:
    ///   * the world WINDING normal (`sign(det M)` times this) — a true
    ///     statement about `cross(Mu, Mv)`, and not the facing truth;
    ///   * `mat3(M) * n`, what the lit vertex shader shades with
    ///     (`shader.d:136`). That is the classic wrong normal transform
    ///     under non-uniform scale — a pre-existing shading defect, not
    ///     a definition of facing. Adopting it would import a renderer
    ///     bug into a picking predicate.
    ///
    /// OURS, and unmeasured — the UN-AIMED case. The reference has no such
    /// state: it writes its screen ray immediately before the candidate
    /// search, so the ray is always there when the filter runs. Ours can
    /// be asked before an aim (`admits` is a public seam), and there the
    /// orientation test is SKIPPED rather than inverted into a rejection.
    /// Skipping is what the measured predicate itself does with a
    /// degenerate operand — a zero normal is admitted — while rejecting
    /// would be a policy no measurement carries. The one production caller
    /// (`resolveSnapTargetVert`) aims before it asks.
    ///
    /// NOT cached, deliberately. A per-vertex normal array keyed on
    /// `MeshCacheKey` would go stale under a position-only edit, because
    /// that key is a mutation COUNTER and this tree has transform paths
    /// that move vertices without bumping it — and a stale normal is a
    /// silently wrong admission. Recomputing costs one walk of the
    /// candidate's own face fan, which the border half's
    /// `edgePolygonCounts()` already dwarfs.
    private bool orientationAdmits(uint vi) {
        if (backFaceOk_) return true;   // the test is not run at all
        if (!aimed_)     return true;   // no ray to test against — see above
        Vec3 n = Vec3(0, 0, 0);
        foreach (fi; mesh_.facesAroundVertex(vi))
            n = n + mesh_.faceNormal(cast(uint)fi);
        // `n` is LOCAL (a sum of local winding normals, and the sum is
        // linear so it transports exactly the same way one of them
        // does); `aimDirLocal_` is the aim ray carried into that same
        // space. See this function's doc comment for why the sign needs
        // no correction.
        return !(dot(n, aimDirLocal_) > 0.0f);
    }

    // ---- SnapGuide ----------------------------------------------------

    void limits(float innerPx, float outerPx) {
        innerPx_ = innerPx;
        outerPx_ = outerPx;
    }

    bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                   out float distPx, ref int priority)
    {
        if (!admits(type, idx, slot)) return false;
        if (!aimed_) return false;
        float qx, qy, qz;
        if (!projectToWindowFull(candWorld, aimVp_, qx, qy, qz)) return false;
        immutable float dx = qx - cast(float)aimX_;
        immutable float dy = qy - cast(float)aimY_;
        distPx   = hypot(dx, dy);
        priority = kPriority;
        return true;
    }

    void setDrawState(GuideDrawState s) { draw_ = s; }

    uint flags() const { return 0; }

    // ---- readback, for the tests and for a reader ---------------------
    float innerPushedPx() const { return innerPx_; }
    float outerPushedPx() const { return outerPx_; }
    GuideDrawState drawState() const { return draw_; }
    bool  isAimed() const { return aimed_; }
}
