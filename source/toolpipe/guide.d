module toolpipe.guide;

import math             : Vec3;
import toolpipe.packets : SnapType;

// ---------------------------------------------------------------------------
// The snapping guide — S4 of doc/toolpipe_architecture_plan.md.
//
// A guide is a CLIENT of the snap service that lives for exactly one gesture:
// a tool registers it when the gesture starts and removes it when the gesture
// ends. While it is registered, the service pushes the environment's pixel
// ranges INTO it and asks it, once per enumerated candidate, whether that
// candidate is eligible and how far away it counts as being. Several guides
// may be registered at once, which is what `priority` exists to settle.
//
// The guide is the LIFECYCLE WRAPPER above `snap.SnapAdmit`. The predicate is
// a per-call admission rule with no identity and no lifetime; the guide is an
// object that outlives the call, carries the ranges that were pushed into it,
// and can be arbitrated against its peers. Both seams answer the same
// ownership question — the enumeration is the service's, the admission is the
// client's — at two different scopes.
//
// ---------------------------------------------------------------------------
// PROVENANCE. The two halves of this file do NOT rest on the same evidence,
// and a later reader must not be able to mistake one for the other. Each
// declaration below repeats its own half; this is the summary.
//
//   MEASURED
//     * The LIFECYCLE — added when a gesture starts, removed when it ends.
//       This is an observed add/remove pair around a drag, not a convention we
//       chose. Our own code arrived at the same lifetime independently: the
//       topology pen's snapshot-at-press / drop-at-release already describes
//       itself as "the same lifetime a registered snapping guide has".
//     * The DIRECTION of the range push — the environment's ranges are pushed
//       IN to the guide; the guide does not source them for itself. Same
//       ownership the SNAP stage already implements for the one shared pair
//       `innerRangePx` / `outerRangePx`.
//
//   HEADER-DERIVED, NEVER OBSERVED ON A WIRE  (the plan marks this class U2)
//     * The METHOD SET below: that these four are the interface, that there
//       are not five, and that `proximity` takes this argument list.
//     * The `priority` return, and therefore the whole (priority, distance)
//       arbitration rule built on it.
//     * `GuideDrawState` and its three states.
//
// Phase (a) — this commit — wires none of it to a tool. No guide is ever
// registered, so the registry is empty, and the arbitration path in
// `snap.snapCursor` is unreachable. That is the entire neutrality argument
// (technique N4 of the plan): not "the new path agrees", but "the new path
// does not run". The unittest in `source/snap.d` proves the first anyway,
// because that equivalence is what makes phase (b) safe.
// ---------------------------------------------------------------------------

/// The value the environment puts in a guide's priority slot BEFORE it asks
/// for proximity, so a guide that ignores the parameter answers with this
/// rather than with zero or with whatever was there.
///
/// MEASURED, and it is one of three things about the arbitration that the
/// header does not carry. Its consequence is small and exact: "did not say"
/// and "said 0" are different answers, and only the seed makes them so. The
/// other two are recorded where they bite — the acceptance range in
/// `snap.snapCursor`'s `consider`, and the per-axis write mask in its
/// `arbitrate`, which we do not have because our guides never supply a
/// position for a mask to select from.
enum int kGuidePrioritySeed = 1;

/// How a registered guide should draw itself.
///
/// U2 — HEADER-DERIVED AND UNMEASURED, both the states and the fact that there
/// are three. Nothing calls `setDrawState` in phase (a): the draw protocol
/// needs a renderer-side consumer as well as a producer, and neither end has
/// been observed. Declared so the interface is the whole shape rather than the
/// part we happened to need first.
enum GuideDrawState : ubyte {
    Off     = 0,   /// not drawn
    Suggest = 1,   /// drawn as an available target
    Chosen  = 2,   /// drawn as the target the arbitration picked
}

/// A client-supplied snapping guide, alive for one gesture.
///
/// Registered on `SnapStage` (`addGuide` / `removeGuide`) by the tool that
/// owns the gesture. The stage pushes the environment's ranges in; the guide
/// answers proximity queries with its own admission rule.
interface SnapGuide {
    /// The environment's pixel ranges, pushed IN — the guide does not source
    /// them.
    ///
    /// MEASURED (the direction only). There is one pair of snap ranges in this
    /// tree, the SNAP stage owns it, and every client is told what it is
    /// rather than asking; a guide is one more client. What is OURS and not
    /// measured is *when* the push happens — we push at registration and again
    /// on every pipeline evaluation, so a mid-gesture range change reaches a
    /// guide that is already registered.
    void limits(float innerPx, float outerPx);

    /// Admission + distance for one enumerated candidate. Return false to
    /// REJECT it: a rejected candidate is treated as if the enumeration had
    /// never offered it — it cannot win, cannot highlight, and cannot lower
    /// the accumulator a later candidate has to beat.
    ///
    /// `distPx` is the distance the arbitration will RANK this candidate by,
    /// which need not be its screen distance from the cursor — that is the
    /// point of asking the guide rather than measuring. `priority` settles
    /// which of several guides answers for the candidate: higher wins
    /// OUTRIGHT, at any distance, and distance decides only between guides
    /// that named the same priority.
    ///
    /// `priority` is `ref`, not `out`, and that is load-bearing: the caller
    /// seeds it with `kGuidePrioritySeed` before every call, so a guide that
    /// does not assign it has said "the default", not "zero". The argument
    /// list is still header-derived; the arbitration rule built on `priority`
    /// no longer is.
    ///
    /// `candWorld` is the candidate's world position, `type` its discrete snap
    /// type, `idx` its source-local element index (-1 where the candidate is
    /// not a mesh element — Grid, Workplane and every constraint candidate)
    /// and `slot` its snap source (0 = active mesh, 1..N = background source),
    /// exactly as `SnapAdmit` sees them.
    ///
    /// Deliberately NOT `nothrow`, where the sibling seam `snap.SnapAdmit`
    /// is. The difference is not an oversight: an admission predicate answers
    /// from data it already has, while a guide's proximity is a PROJECTION,
    /// and the projection helper this tree ships (`math.projectToWindowFull`)
    /// carries no attributes — so `nothrow` here would push a `try`/`catch`
    /// into the body of every real guide. It is affordable because the
    /// candidate walk consults nothing while the grid mutex is held: every
    /// `synchronized` block in `snap.d` is closed before a candidate reaches
    /// `consider`, so an unwinding guide cannot strand the lock.
    bool proximity(Vec3 candWorld, SnapType type, int idx, int slot,
                   out float distPx, ref int priority);

    /// Off / Suggest / Chosen — the draw protocol.
    ///
    /// U2 — HEADER-DERIVED, and with no caller in phase (a). See
    /// `GuideDrawState`.
    void setDrawState(GuideDrawState s);

    /// A flag word describing the guide to the framework.
    ///
    /// U2 — HEADER-DERIVED, no bit of it decoded, and with no caller in phase
    /// (a). It is declared because one candidate meaning of one bit ("honour
    /// this guide even when the global snap enable is off") is a live owner
    /// fork about the topology pen's unconditional welding, and dropping the
    /// method from the interface would quietly foreclose that answer.
    uint flags() const;
}
