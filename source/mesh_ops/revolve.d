module mesh_ops.revolve;

// ---------------------------------------------------------------------------
// TWO kernel families that share a file and nothing else. The Radial Sweep /
// Revolve kernel (`revolveSweepClosed`, `revolveSweepClosedWithOffset`,
// `RevolveParams`, `revolveProfile`, `revolveProfileEx`) and the Path-follow
// extrude kernel (task 0323 "Sketch Extrude": `PathExtrudeStep`,
// `maskVertexCentroid_`, `extrudePathStep_`, `extrudeAlongPath`) were grouped
// as ONE family by the 0407 campaign queue even though they are explicitly
// documented as sharing no code — see the "Path-follow extrude kernel" banner
// below, which is ADDITIVE and unrelated to the revolve kernel above it.
// Split out of mesh.d as `mixin template MeshRevolveOps` by the mesh.d
// decomposition campaign (0407 §B.V2, task 0417).
//
// Converted to module-level FREE FUNCTIONS by task 1903 Stage E2
// (`doc/mesh_edit_seam_plan.md` §4, §5.2 row E2). Function BODIES are
// unchanged — every edit is an `ed.` / `m.` prefix — and the shapes C / D1 /
// D2 / D3 / E1 settled hold here verbatim: the receiver of a mutating kernel
// is the batch, the `mixin MeshRevolveOps;` line left `struct Mesh` in the
// SAME change, and the callers open an UNRECORDED batch at their own
// boundary. What E2 adds to that memo is below.
//
// E2 IS ALSO THE STAGE THAT PAYS OFF A NAMED DEBT. `revolveProfileEx` calls
// `bridgeLoopsPaired`, which Stage D3 had already converted — so from D3 until
// this commit the kernel opened a TRANSITIONAL `MeshEditBatch` of its OWN
// around its closed-profile ring loop (plan §4.4a's fourth cell: a converted
// kernel called from inside `struct Mesh`, where §4.1's "the boundary opens
// the batch" had nowhere to land). That block named E2 as its removing stage,
// carried a per-command `changeBus.nestedBatchOpens` delta assert in
// `tests/test_mesh_sweep.d` for the interim, and is GONE here: the batch
// arrives as `ed` and `bridgeLoopsPaired(ed, …)` takes it directly. The delta
// assert stays and now pins the finished shape — one batch for the whole
// sweep, opened by the caller, nesting nothing.
//
// TWO RECEIVERS, AND THE SPLIT IS THE MUTATION, NOT THE `const` (§4.1 cells
// one and two):
//
//   * `ref MeshEditBatch ed` — `revolveProfile`, `revolveProfileEx`,
//     `extrudePathStep_`, `extrudeAlongPath`. All four append vertices and
//     faces and stamp mark words.
//   * `ref const(Mesh) m` — `maskVertexCentroid_`, the align-to-path pivot.
//     It was NOT a `const` member before this commit (nothing in a mixin body
//     forces the keyword), and it only reads `faces`/`vertices` to average a
//     point — so the const receiver here is a widening of what the code
//     already did, and it is now ENFORCED at the seam rather than left to a
//     keyword nobody had to write.
//   * NO receiver at all — `revolveSweepClosed` /
//     `revolveSweepClosedWithOffset` were `static` members (they read no mesh
//     state, only an angle and an offset), so they become plain module
//     functions. Their `Mesh.` call-site spelling moved with this commit; the
//     bare name resolves through mesh.d's `public import mesh_ops.revolve;`.
//
// §4.1's THIRD cell (a query that touches a `mutationVersion`-keyed memo and
// therefore needs a plain `ref Mesh`) does not occur here: nothing in this
// file memoizes.
//
// `struct RevolveParams` MOVED TO MODULE SCOPE, and the call sites moved with
// it (§2.7: "the nested types move to module scope in their ops file … decide
// per type in its own stage; do not batch this decision"). The precedent is
// D3's `maxBridgeSpans`, which took the same route: a `public import` in
// mesh.d re-exports the MODULE's names, so a plain `import mesh;` resolves the
// BARE name `RevolveParams` at every call site — but it does NOT make
// `Mesh.RevolveParams` resolve, because that spelling asks for a MEMBER and
// there no longer is one. The alternative §2.7 offers (an
// `alias RevolveParams = mesh_ops.revolve.RevolveParams;` inside `Mesh`) was
// declined for the reason the tripwire at the foot of this file exists: an
// alias would put the name back on the struct, and then "is it still a member?"
// stops being answerable by `__traits(hasMember)`. The five call sites that
// spelled `Mesh.RevolveParams` / `Mesh.revolveSweepClosedWithOffset` are
// edited in this commit and named in tests/unit/commit_seam_census_test.d.
//
// THE WIDENINGS E2 OWES: **NONE**, measured the same way E1 measured its own
// none. §2.6 assigns each of its eleven `private` names of `mesh.d` to the
// stage that converts ITS caller, and none of the eleven is assigned to E2 —
// grepped, this file names none of them (`faceAttrOr`, `finalizeTopologyEdit`,
// `rebuildFaceWithVertexSubs`, `combineFaceMarksWords`, `edgeIndexOfVerts`,
// `orientFaceConsistent`, `registerNewFaceEdges`, `rebuildFacesWithChordSplits`,
// `insertEdgePoint`, `mesh.smoothstep01`, `editRecorder_`: 0 occurrences each).
// The proof is not that list: it is that this module now compiles as its own
// translation unit with no mixin instantiation scope behind it, so a missed
// widening is a `dub build` error rather than a silent pass.
//
// THE SELECTIVE-IMPORT SWEEP, which the compiler cannot do for us (E1's memo
// item 1). A `public import` is invisible through a SELECTIVE `import mesh : …`
// — measured at Stage C and written down at `mesh_ops/connected_mask.d` — so a
// name that moves out of `mesh` into a `mesh_ops` module silently stops
// resolving at any site that listed it selectively, and only in the
// configurations that compile that site. Swept for this family: the 260
// selective `import mesh : …` sites in `source/` ∪ `tests/` name none of
// `RevolveParams`, `revolveProfile`, `revolveProfileEx`, `extrudeAlongPath`,
// `revolveSweepClosed`, `revolveSweepClosedWithOffset`, `PathExtrudeStep` or
// `maskVertexCentroid_` — every consumer imports `mesh` whole. What DID have to
// move was the opposite half: `tests/unit/mesh_test.d` listed the TEMPLATE
// (`import mesh_ops.revolve : MeshRevolveOps;`), which no longer exists, and
// `dub build` cannot see it because `tests/unit/` compiles only under
// `--config=tests`.
//
// §4.4a IN THE OTHER DIRECTION, and it comes out empty. Before converting a
// family, grep its names inside `source/mesh.d` and the remaining
// `mesh_ops/*.d` — a still-mixin sibling calling a converted kernel is a
// caller the compiler names only after the fact. Done for this family: every
// hit on `revolveProfile`, `revolveProfileEx`, `extrudeAlongPath` and
// `RevolveParams` inside `source/mesh.d` and `source/mesh_ops/*.d` is inside a
// COMMENT (mesh.d's `MAX_SWEEP_SIDES` note, bridge.d's transitional-batch
// banner). No `Mesh` method and no sibling ops file CALLS this family, so E2
// opens no fourth-cell debt of its own.
// ---------------------------------------------------------------------------
import mesh;
import math;
// §4.3's per-file table, plus the two entries measuring the file found that
// the table missed. `MeshEditScope` for `extrudePathStep_`'s tail commit and
// for the family's declared scope below; `rewriteFaces` / `FaceSource` for
// `extrudePathStep_`'s single plane-carrying rewrite (task 1902 site 19) —
// both of those resolved through mesh.d's own imports while this was a mixin.
// `sqrt` is the same trap D2 hit in `decimate.d` and E1 hit in `cleanup.d`:
// `math` imports `std.math.sqrt` selectively and PRIVATELY, so the two
// `extrudeAlongPath` calls bound through `source/mesh.d`'s
// `import std.math : sqrt, isIdentical;` and not through this file's.
import mesh_edit_delta : MeshEditScope;
import mesh_planes : rewriteFaces, FaceSource;
import std.math : sqrt;

/// The change classes one revolve / path-extrude actually commits, for the
/// batch its callers open. It lives HERE, beside the kernels, and not spelled
/// out at each of the six call sites, for the reason Stage D2 gave for
/// `kReduceEditScope`: N copies is N chances to drift, and the one that drifts
/// is the one that stops matching the op-log's declared scope when track 2
/// turns this family's undo into a delta (`MeshEditTracker.declare` is what
/// ends up in `MeshEditDelta.scope_`).
///
/// `Points`   : every ring after ring 0 is `addVertex`'d, and
///              `extrudePathStep_` clones one vertex per (island, vertex).
/// `Polygons` : the ring bridge, the open-strip quads, the caps, the path
///              extrude's cap clones and wall quads — all `addFace` /
///              `rewriteFaces`.
/// `Marks`    : both kernels rewrite the selection to the newly created faces
///              (`deselectFace` / `selectFace` / `faceSelectionOrderCounter`),
///              and `extrudePathStep_` re-masks the carried `faceMarks` word.
///
/// NOT `Position`: neither kernel moves an EXISTING vertex. Every coordinate
/// they produce belongs to a vertex created in the same call — a `Points`
/// change that carries its position in the `AddVerts` entry. That is why this
/// family adds no `setVertexPos`/`setVertexPositions` call and why its §5.7
/// position-write count is 0 rather than a retired allow-entry.
enum uint kRevolveEditScope = MeshEditScope.Geometry | MeshEditScope.Marks;

/// True when a revolve `angle` span (radians) is treated as a CLOSED
/// 360° sweep by `revolveProfile`/`revolveProfileEx` (same rule the
/// kernel uses internally: |angle − 2π| < 1e-3 or angle >= 2π).
///
/// Exported (task 0326) so a caller translating a DIFFERENT "Count" UI
/// convention into this kernel's ring-count convention — e.g. the
/// interactive Radial Sweep tool, whose reference control means "number
/// of NEW bands" (ring count = Count+1) on an OPEN sweep but coincides
/// with "total rings" on a CLOSED 360° sweep — can determine which
/// translation applies using the exact same threshold the kernel itself
/// commits to, rather than duplicating (and risking drift from) the
/// constant.
bool revolveSweepClosed(float angle) pure nothrow @nogc @safe {
    import std.math : abs;
    immutable float tau = 6.283185307f;   // 2π
    return abs(angle - tau) < 1e-3f || angle >= tau;
}

/// True when a revolve is treated as a fully CLOSED, WRAPPING 360°
/// sweep — i.e. `revolveSweepClosed(angle)` AND no axial spiral
/// `offset`. A nonzero `offset` moves each successive ring along the
/// axis, so even an angle-closed (>=360°) sweep must NOT wrap its last
/// ring back onto ring 0 (they sit at different heights along the
/// axis) — doing so produced a spurious self-intersecting closing band
/// for any spiral/helix (task 0326 review finding S1: the advertised
/// spring/telephone-cord shape at End Angle > 360° + Offset > 0 was
/// broken). This is the single decision point `revolveProfileEx` uses
/// for BOTH the wrap-bridge/stepAngle choice and the cap-eligibility
/// gate, and the ONLY decision point the tool-layer Count-semantics
/// ring-count translation (`RadialSweepTool.toKernelParams`) should use
/// too — single source of truth so kernel and tool can never disagree
/// about what counts as "closed".
bool revolveSweepClosedWithOffset(float angle, float offset) pure nothrow @nogc @safe {
    import std.math : abs;
    return revolveSweepClosed(angle) && abs(offset) <= 1e-9f;
}

/// Extended parameter set for `revolveProfileEx` (task 0326, additive —
/// see that function's doc comment). Every field defaults to exactly
/// what the original `revolveProfile` always did, so `RevolveParams.init`
/// plus a real `count`/`axis`/`center`/`angle` reproduces the legacy
/// behaviour bit for bit.
struct RevolveParams {
    int   count      = 8;             // total ring count INCLUDING the
                                       // original — same meaning as the
                                       // legacy `revolveProfile.count`
                                       // param (NOT the reference tool's
                                       // "Count" UI convention; translate
                                       // at the call site via
                                       // `revolveSweepClosedWithOffset`).
    Vec3  axis       = Vec3(0, 1, 0); // free rotation axis DIRECTION —
                                       // need not be unit length (this
                                       // function normalises it); a
                                       // near-zero vector is a guard
                                       // failure.
    Vec3  center     = Vec3(0, 0, 0); // pivot point the axis line
                                       // passes through.
    float angle      = 6.2831853f;    // total sweep ANGLE SPAN in
                                       // radians (end − start).
    float startAngle = 0.0f;          // radians; rotational placement
                                       // of ring 0 (reference "Start
                                       // Angle" — vibe3d gap #3).
    float offset     = 0.0f;          // world units of axial
                                       // translation PER RING STEP
                                       // (spiral pitch; reference
                                       // "Offset" — vibe3d gap #4).
    bool  cap0       = false;         // close the start ring with an
                                       // n-gon (reference "Cap Start" —
                                       // vibe3d gap #7). Only takes
                                       // effect for a CLOSED profile
                                       // ring on a non-closed sweep —
                                       // see revolveProfileEx.
    bool  cap1       = false;         // close the end ring (reference
                                       // "Cap End").
}

/// Sweep a vertex chain (profile) around a principal axis to form a
/// surface of revolution.
///
/// `profile`       — ordered vertex indices in this mesh.
/// `profileClosed` — true: treat as a closed ring (M quads/step via
///                   `bridgeLoopsPaired`; profile.length >= 3 required);
///                   false: open strip (M-1 quads/step).
/// `count`         — total profile copies including the original (>= 2).
/// `axis`          — 'X', 'Y', or 'Z'.
/// `center`        — rotation pivot point.
/// `angle`         — total sweep angle in radians (nonzero).
///
/// `ed` — the caller's open edit batch (task 1903 Stage E2). Opening it is
/// the caller's job, never this kernel's (plan §4.1): a batch opened here
/// could not be the outermost one, which is precisely the debt E2 removed.
///
/// Thin, behaviour-preserving wrapper over `revolveProfileEx` (task
/// 0326) — resolves `axis` to a unit vector and leaves every new knob
/// (startAngle/offset/cap0/cap1) at its off default, so the output is
/// byte-identical to this function's pre-0326 standalone implementation.
/// Kept as a SEPARATE, unchanged-signature entry point (rather than
/// folding callers onto `revolveProfileEx` directly) because this kernel
/// is shared with the Sketch Extrude port (task 0323) — see
/// `revolveProfileEx`'s doc comment for the coordination note.
///
/// Returns faces added (> 0) on success, 0 on guard failure or no-op.
size_t revolveProfile(ref MeshEditBatch ed, const(uint)[] profile, bool profileClosed,
                      int count, char axis, Vec3 center, float angle) {
    Vec3 axisVec;
    if      (axis == 'X') axisVec = Vec3(1, 0, 0);
    else if (axis == 'Y') axisVec = Vec3(0, 1, 0);
    else if (axis == 'Z') axisVec = Vec3(0, 0, 1);
    else return 0;

    RevolveParams p;
    p.count  = count;
    p.axis   = axisVec;
    p.center = center;
    p.angle  = angle;
    // startAngle/offset/cap0/cap1 stay at RevolveParams.init's zero/off
    // defaults — this reproduces the pre-0326 behaviour exactly.
    return revolveProfileEx(ed, profile, profileClosed, p);
}

/// Extended revolve/lathe kernel (task 0326) — additive superset of
/// `revolveProfile` backing the interactive Radial Sweep tool
/// (`tools/alignment/radial_sweep_tool.d`). Adds: a free 3D rotation axis (any
/// direction, not just a world X/Y/Z unit vector), a Start Angle offset
/// for ring 0, an axial spiral Offset per ring step, and optional
/// Start/End caps.
///
/// ⚠ SHARED KERNEL: this function (and `revolveProfile` above, which
/// now forwards into it) also backs the task-0323 Sketch Extrude port.
/// Extend via `RevolveParams` fields ONLY — never change either
/// function's positional signature. Task 1903 Stage E2 added the
/// `ref MeshEditBatch ed` RECEIVER to both, which is the one edit that rule
/// does not cover: a receiver is not an operation parameter, it is where the
/// stamps go, and adding it is what let the transitional batch inside this
/// body be deleted. Everything after `ed` is untouched, and the rule still
/// binds it.
///
/// Ring construction: ring[k] (k = 0 .. params.count-1) is the profile
/// rotated by `params.startAngle + stepAngle*k` around the axis line
/// (through `params.center`, direction `params.axis`), then translated
/// `params.offset*k` along the (normalised) axis — the spiral pitch.
/// `stepAngle` follows `revolveProfile`'s original closed/open split
/// (see `revolveSweepClosedWithOffset` — a nonzero `offset` forces the
/// OPEN split even at a >=360° angle span, so a spiral never wraps its
/// last ring back onto ring 0). Ring 0 REUSES the original profile
/// vertex indices (no new vertices, no rotation applied) ONLY when
/// `startAngle` is exactly 0 — a nonzero Start Angle rotates ring 0 away
/// from the literal selection, so it can no longer reuse those indices.
/// This preserves `revolveProfile`'s original vertex-count contract for
/// every caller that never sets startAngle.
///
/// Caps: `cap0`/`cap1` each add ONE n-gon face at ring 0 / ring
/// (count-1), using the ring's own vertex loop. Capping requires a
/// CLOSED profile ring (`profileClosed == true`, length >= 3) — an open
/// vertex CHAIN has no single well-defined boundary n-gon to close (this
/// matches the measured reference behaviour on a degenerate 2-point
/// profile: capping added zero extra geometry, see
/// doc/tasks/*/radial_sweep toolcard findings §5). Capping is also a
/// no-op on a fully CLOSED, WRAPPING 360° sweep
/// (`revolveSweepClosedWithOffset(angle, offset)`) since there is no
/// exposed end to close — matches the reference help text ("Cap
/// options are only useful when the start/end angles do not result in
/// a complete rotation"). A nonzero `offset` (spiral) makes caps
/// available again even at a >=360° angle span, since the start/end
/// rings then sit at different heights and are genuinely exposed. Cap
/// winding direction (outward vs.
/// inward) is NOT verified against the reference (Invert-Polygons
/// winding parity was explicitly flagged un-captured in the toolcard) —
/// cap0 uses the ring's vertex order reversed, cap1 uses it as-is, a
/// plausible but unconfirmed convention.
///
/// Returns faces added (> 0) on success, 0 on guard failure or no-op.
size_t revolveProfileEx(ref MeshEditBatch ed, const(uint)[] profile, bool profileClosed,
                        RevolveParams params) {
    import math : mulMV, pivotRotationMatrix, normalize;
    import std.math : abs;

    // Guards.
    if (profile.length < 2) return 0;
    if (profileClosed && profile.length < 3) return 0;
    if (params.count < 2) return 0;
    // DoS backstop (task 0365 P1): `count` allocates one ring of
    // `profile.length` verts per step; Param `.min()/.max()` hints are
    // UI-only and do not clamp a direct/scripted caller reaching this
    // shared kernel. Clamp (not reject) — the `< 2` guard above is the
    // only documented reject sentinel for this param
    // (`test_mesh_sweep.d`'s count<2 contract).
    if (params.count > MAX_SWEEP_SIDES) params.count = MAX_SWEEP_SIDES;
    if (abs(params.angle) < 1e-6f) return 0;
    immutable float axisLenSq = params.axis.x * params.axis.x
                               + params.axis.y * params.axis.y
                               + params.axis.z * params.axis.z;
    if (axisLenSq < 1e-12f) return 0;
    const Vec3 axisVec = normalize(params.axis);

    // revolveSweepClosedWithOffset (NOT the bare angle-only
    // revolveSweepClosed) — a nonzero spiral offset must never wrap the
    // last ring back onto ring 0, even at a >=360° angle span (task
    // 0326 review finding S1). This one flag drives stepAngle, the
    // wrap-bridge decision below, AND the cap-eligibility gate.
    immutable bool  sweepClosed = revolveSweepClosedWithOffset(params.angle, params.offset);
    immutable float stepAngle   = sweepClosed
        ? params.angle / cast(float)params.count
        : params.angle / cast(float)(params.count - 1);
    immutable bool  hasStartAngle = abs(params.startAngle) > 1e-9f;
    immutable bool  hasOffset     = abs(params.offset) > 1e-9f;

    // Snapshot pre-mutation face count for selection finalise.
    const size_t origFaceCount = ed.faces.length;

    // Build per-step rings.
    // ring[0] = existing profile verts, reused verbatim (no copy) IFF
    // startAngle is exactly 0 (see doc comment above); otherwise a
    // rotated copy like every other ring.
    // ring[k] (k >= 1) = new rotated (+ optionally spiral-shifted)
    // copies appended to vertices[].
    uint[][] rings;
    rings.length = params.count;

    uint[] buildRing(float ang, float axialShift) {
        auto   rotM = pivotRotationMatrix(params.center, axisVec, ang);
        uint[] ring;
        ring.length = profile.length;
        foreach (k, vid; profile) {
            Vec3 p  = ed.vertices[vid];
            auto v4 = Vec4(p.x, p.y, p.z, 1.0f);
            auto r4 = mulMV(rotM, v4);
            Vec3 pos = Vec3(r4.x, r4.y, r4.z);
            if (hasOffset) pos = pos + axisVec * axialShift;
            ring[k] = ed.addVertex(pos);
        }
        return ring;
    }

    rings[0] = hasStartAngle ? buildRing(params.startAngle, 0.0f)
                              : profile.dup;

    foreach (step; 1 .. params.count) {
        float ang = params.startAngle + stepAngle * cast(float)step;
        rings[step] = buildRing(ang, params.offset * cast(float)step);
    }

    // Bridge consecutive rings into quad faces.
    //
    // NO BATCH IS OPENED HERE, and that is the whole content of Stage E2 for
    // this function. Until this commit the closed-profile arm below opened a
    // TRANSITIONAL `MeshEditBatch.unrecorded(this, kBridgeEditScope)` of its
    // own (task 1903 Stage D3, plan §4.4a's fourth cell) — the Bridge family
    // had become free functions over `ref MeshEditBatch` while this body was
    // still a `mixin` inside `struct Mesh`, so there was no caller-held batch
    // to take and the kernel had to open one, which §2.3 rule 2 forbids in the
    // finished design. That debt named E2 as its removing stage; this is it.
    // The batch now arrives as `ed`, opened by whoever called in — the
    // `mesh.sweep` command, `RadialSweepTool`'s three sites, a test — and
    // `bridgeLoopsPaired` takes it directly.
    //
    // WHAT THAT CHANGES, MEASURED, and it is the OPEN arm that moves. D3's
    // narrowing left the `else` arm below committing once per `addFace`,
    // because it calls no Bridge kernel and the conversion had not forced a
    // batch on it. Under a caller-held batch BOTH arms defer to one `close()`,
    // and the KERNEL's own contribution to `changeBus.unbatchedGeometryCommits`
    // is now 0 on both — measured over `/api/changes` on an instance of this
    // build, `mesh.sweep` with a closed EDGE-CYCLE profile (which runs the
    // closed arm and deletes no source face): +0, and with an open arc of 4
    // segments: +0. Pre-E2 the same open sweep was +49.
    //
    // What is NOT zero, and it is not this kernel: `mesh.sweep` in POLYGON mode
    // deletes the source profile face AFTER the kernel returns, outside the
    // batch by the caller's own choice, and that pair of commits still reads
    // +2. Traced at the tick site they are Polygons (`deleteFacesByMask`'s own
    // `rebuildEdges()`) then Geometry (its tail) — NOT `compactUnreferenced`,
    // which early-returns because `startAngle` is 0 there and ring 0 below
    // REUSES the profile's vertices, so the deletion orphans none of them. See
    // `commands/mesh/sweep.d` for whose obligation that is (**L10**), and for
    // the +4 the same deletion reads under a non-zero Start Angle.
    //
    // UNRECORDED IS THE CALLER'S CHOICE NOW, and every caller still makes it
    // (plan §9): `mesh.sweep` and `RadialSweepTool` both undo through a
    // whole-mesh `MeshSnapshot`, and the tool re-runs this kernel per drag
    // frame from `rebuildRadialSweepPreview`, so a RECORDING batch would build
    // and throw away a full op-log at 60 Hz. Track 2 flips that per COMMAND,
    // not per kernel: `sweep` is an L10 row (plan §5.5).
    size_t facesAdded = 0;
    immutable int lastBridge = sweepClosed ? params.count - 1 : params.count - 2;
    if (profileClosed) {
        foreach (i; 0 .. lastBridge + 1) {
            int nextIdx = sweepClosed ? (i + 1) % params.count : i + 1;
            // bridgeLoopsPaired: M quads with closed wrap [A[i],A[i+1],B[i+1],B[i]].
            facesAdded += bridgeLoopsPaired(ed, rings[i], rings[nextIdx]);
        }
    } else {
        // Open strip: M-1 quads, no wrap; same winding as bridgeLoopsPaired.
        const size_t M = profile.length;
        foreach (i; 0 .. lastBridge + 1) {
            int           nextIdx = sweepClosed ? (i + 1) % params.count : i + 1;
            const(uint)[] ringA   = rings[i];
            const(uint)[] ringB   = rings[nextIdx];
            foreach (j; 0 .. M - 1) {
                ed.addFace([ringA[j], ringA[j + 1], ringB[j + 1], ringB[j]]);
                ++facesAdded;
            }
        }
    }

    // Start/End caps (task 0326) — see doc comment for the
    // profileClosed + !sweepClosed gating rationale.
    if (profileClosed && !sweepClosed) {
        if (params.cap0) {
            uint[] rev; rev.length = rings[0].length;
            foreach (k, vid; rings[0]) rev[rings[0].length - 1 - k] = vid;
            ed.addFace(rev);
            ++facesAdded;
        }
        if (params.cap1) {
            ed.addFace(rings[$ - 1].dup);
            ++facesAdded;
        }
    }

    if (facesAdded == 0) return 0;

    // Stated loss (task 0830): a swept surface with no measured
    // parameterisation, the same family as the edge extrude.
    ed.dropCornerProvenance(CornerDrop.SweptSurfaceNoLaw);
    // Finalise: rebuild half-edge maps and grow selection arrays.
    ed.buildLoops();
    ed.syncSelection();

    // Deselect pre-existing faces; select only the newly swept faces.
    foreach (fi; 0 .. origFaceCount)
        ed.deselectFace(cast(int)fi);
    ed.faceSelectionOrderCounter = 0;
    foreach (fi; origFaceCount .. ed.faces.length)
        ed.selectFace(cast(int)fi);

    // Clear vertex and edge selection (mirrors radialArrayFaces :3807-3810).
    ed.clearVertexSelection();
    ed.clearEdgeSelection();

    return facesAdded;
}

// ---------------------------------------------------------------------------
// Path-follow extrude kernel (task 0323 "Sketch Extrude" port, basic/
// captured scope). ADDITIVE — shares no code with revolveProfile /
// revolveProfileEx above (the task-0326 Radial Sweep shared kernel): a
// fixed-axis revolve/lathe and a free camera-ray-cast path extrude are
// different operations (confirmed both statically and empirically by
// the task-0323 capture — see extrudeAlongPath's doc comment). Any
// future change here must NOT touch revolveProfile/revolveProfileEx,
// and `test_mesh_sweep` must stay green after any touch to this file.
// ---------------------------------------------------------------------------

/// Result of one band step of `extrudeAlongPath` — the newly created
/// "cap" faces (the ring at the moved end of the band) become the
/// running selection the NEXT band extrudes from.
private struct PathExtrudeStep {
    size_t facesAdded;   // net face-count delta for this band (0 == guard failure)
    size_t capStart;     // first index of the cap faces in the rebuilt faces[]
    size_t capCount;     // number of cap faces (== number of selected faces in)
}

/// Centroid of the (deduplicated) vertices used by the faces marked in
/// `mask`. Used by `extrudeAlongPath` as the pivot for its optional
/// align-to-path ring rotation. Returns the origin for an empty mask.
private Vec3 maskVertexCentroid_(ref const(Mesh) m, in bool[] mask) {
    Vec3   sum = Vec3(0, 0, 0);
    size_t n   = 0;
    bool[] seen;
    seen.length = m.vertices.length;
    foreach (fi; 0 .. m.faces.length) {
        if (fi >= mask.length || !mask[fi]) continue;
        foreach (vid; m.faces[fi]) {
            if (vid < seen.length) {
                if (seen[vid]) continue;
                seen[vid] = true;
            }
            sum = sum + m.vertices[vid];
            ++n;
        }
    }
    return n > 0 ? sum * (1.0f / cast(float)n) : Vec3(0, 0, 0);
}

/// Single-band worker for `extrudeAlongPath`: clones the boundary of
/// `mask`'s selected faces, offsets each clone to `translate` applied
/// after the optional rotation `rotM` (about the origin — callers pass
/// a matrix already built through the intended pivot, e.g. via
/// `pivotRotationMatrix`), and walls the gap between old and new
/// boundary with one quad per boundary edge.
///
/// Deliberately self-contained rather than refactored out of
/// `extrudeFacesByMask` (kept ADDITIVE/independent per the task-0323
/// shared-file discipline — see the section doc comment above) even
/// though the island-partition + boundary-wall-winding structure is
/// the same idea. Always "rigid" per-(island,vertex) offset (no
/// smooth-normal blend option — not part of the captured behaviour
/// for this tool). See `extrudeFacesByMask`'s doc comment for the
/// island / corner-vertex rationale (task 0312 fuzz find), reused
/// verbatim here.
private PathExtrudeStep extrudePathStep_(ref MeshEditBatch ed, in bool[] mask,
                                         Vec3 translate, const(float[16])* rotM) {
    import math : mulMV;

    PathExtrudeStep result;
    if (mask.length != ed.faces.length) return result;
    size_t selCount = 0;
    foreach (b; mask) if (b) ++selCount;
    if (selCount == 0) return result;

    auto edgeFaces = ed.buildEdgeFaces();
    int[size_t] islandOf;
    {
        size_t[][size_t] adj;
        foreach (key, fp; edgeFaces) {
            if (fp[0] < 0 || fp[1] < 0) continue;
            if (fp[0] >= cast(int)mask.length || fp[1] >= cast(int)mask.length) continue;
            if (!mask[fp[0]] || !mask[fp[1]]) continue;
            adj[cast(size_t)fp[0]] ~= cast(size_t)fp[1];
            adj[cast(size_t)fp[1]] ~= cast(size_t)fp[0];
        }
        int nextIsland = 0;
        foreach (fi; 0 .. ed.faces.length) {
            if (!mask[fi]) continue;
            if (fi in islandOf) continue;
            size_t[] stack = [fi];
            islandOf[fi] = nextIsland;
            while (stack.length) {
                size_t cur = stack[$ - 1];
                stack = stack[0 .. $ - 1];
                if (auto nbrs = cur in adj)
                    foreach (nb; *nbrs)
                        if (nb !in islandOf) {
                            islandOf[nb] = nextIsland;
                            stack ~= nb;
                        }
            }
            ++nextIsland;
        }
    }
    static ulong ivKey(int island, uint vid) {
        return (cast(ulong)cast(uint)island << 32) | vid;
    }

    Vec3 newPos(Vec3 p) {
        if (rotM is null) return p + translate;
        auto r4 = mulMV(*rotM, Vec4(p.x, p.y, p.z, 1.0f));
        return Vec3(r4.x, r4.y, r4.z) + translate;
    }

    // Per-(island,vertex) target position table, built BEFORE the
    // clone loop (same ordering rationale as extrudeFacesByMask's
    // vertOffset table — the clone loop only visits each (island,vid)
    // once, on first sight).
    Vec3[ulong] vertNewPos;
    foreach (fi; 0 .. ed.faces.length) {
        if (!mask[fi]) continue;
        int island = islandOf[fi];
        foreach (vid; ed.faces[fi]) {
            ulong k = ivKey(island, vid);
            if (k !in vertNewPos)
                vertNewPos[k] = newPos(ed.vertices[vid]);
        }
    }

    // Boundary edges: exactly one incident face is selected.
    struct BEdge { uint va, vb; int selFi; }
    BEdge[] bEdges;
    foreach (key, fp; edgeFaces) {
        bool s0 = fp[0] >= 0 && fp[0] < cast(int)mask.length && mask[fp[0]];
        bool s1 = fp[1] >= 0 && fp[1] < cast(int)mask.length && mask[fp[1]];
        if (s0 == s1) continue;   // both selected (internal) or neither
        uint va = cast(uint)(key >> 32);
        uint vb = cast(uint)(key & 0xffffffffUL);
        bEdges ~= BEdge(va, vb, s0 ? fp[0] : fp[1]);
    }
    if (bEdges.length == 0) return result;   // closed island -- no-op

    uint[ulong] vertMap;
    foreach (fi; 0 .. ed.faces.length) {
        if (!mask[fi]) continue;
        int island = islandOf[fi];
        foreach (vid; ed.faces[fi]) {
            ulong k = ivKey(island, vid);
            if (k !in vertMap)
                vertMap[k] = ed.addVertex(vertNewPos[k]);
        }
    }

    size_t[] toCloneFace;
    foreach (fi; 0 .. ed.faces.length) if (mask[fi]) toCloneFace ~= fi;

    uint[][] newFaces;
    uint[]   oldOfNew;   // newToOld correspondence — task 1902, mesh_planes.rewriteFaces

    foreach (fi; 0 .. ed.faces.length) {
        if (mask[fi]) continue;
        newFaces ~= ed.faces[fi];
        oldOfNew ~= cast(uint)fi;
    }
    immutable size_t facesBefore = ed.faces.length;
    immutable size_t capStart    = newFaces.length;

    foreach (fi; toCloneFace) {
        auto src = ed.faces[fi];
        uint[] cloned;
        cloned.length = src.length;
        int island = islandOf[fi];
        foreach (k, vid; src) cloned[k] = vertMap[ivKey(island, vid)];
        newFaces ~= cloned;
        oldOfNew ~= cast(uint)fi;
    }
    immutable size_t capCount = toCloneFace.length;

    foreach (ref be; bEdges) {
        uint a = be.va, b = be.vb;
        int island = islandOf[be.selFi];
        uint cloneA = vertMap[ivKey(island, a)], cloneB = vertMap[ivKey(island, b)];
        bool origAtoB = false;
        auto orig = ed.faces[be.selFi];
        foreach (k; 0 .. orig.length) {
            uint u = orig[k], w = orig[(k + 1) % orig.length];
            if (u == a && w == b) { origAtoB = true;  break; }
            if (u == b && w == a) { origAtoB = false; break; }
        }
        if (origAtoB) newFaces ~= [cloneB, cloneA, a, b];
        else          newFaces ~= [cloneA, cloneB, b, a];
        // Task 0389: revolve wall quads inherit Subpatch from their source
        // profile edge's face, like extrudeFacesByMask — so revolving a
        // subdiv profile keeps the swept surface subdiv (bounds-guarded).
        // Task 0613 §4.2: now the whole word, so Hide inherits too.
        // Carried by `rewriteFaces` below via `oldOfNew`.
        oldOfNew ~= cast(uint)be.selFi;
    }

    // faceSelectionOrder: cap clones and wall quads must both start
    // UNSELECTED (order 0), never inheriting whatever order stamp their
    // source face happened to carry (was `newOrd ~= 0;` for both
    // ranges, unlike material/part/setmask/marks, which DO inherit from
    // their source via `oldOfNew` above — plan §2.7a). Patched back
    // immediately after the call — the reselect loop below overwrites
    // the CAP portion of this range again (via selectFace); the wall
    // portion is what this line alone determines.
    rewriteFaces(ed, newFaces, FaceSource(oldOfNew));
    foreach (i; capStart .. ed.faces.length) ed.faceSelectionOrder[i] = 0;

    // Re-mask the just-carried word in place — src here IS faceMarks
    // (self-aliasing; see Mesh.setFaceMarksFrom's own doc comment for
    // why that is safe).
    ed.setFaceMarksFrom(ed.faceMarks, ~Mesh.Marks.Select);

    // New selection = cap faces (chains a follow-up op off the top,
    // and lets the top-level extrudeAlongPath loop derive the next
    // band's mask from the selection state).
    ed.faceSelectionOrderCounter = 0;
    foreach (fi; capStart .. capStart + capCount)
        ed.selectFace(cast(int)fi);

    ed.resizeVertexSelection();
    ed.clearVertexSelection();
    ed.clearEdgeSelectionResize();

    ed.dropCornerProvenance(CornerDrop.SweptSurfaceNoLaw);   // stated loss (task 0830)
    ed.rebuildEdges();
    ed.buildLoops();
    ed.compactUnreferenced();   // drops orig verts no longer referenced (none here — walls keep them)
    ed.buildLoops();

    ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);

    result.facesAdded = ed.faces.length - facesBefore;
    result.capStart   = capStart;
    result.capCount   = capCount;
    return result;
}

/// Extrude a selected set of polygons along an ordered WORLD-SPACE
/// path, producing one new "band" (a duplicated + connected ring) per
/// path segment.
///
/// `mask`        — bool[faces.length], the polygons to extrude (same
///                 convention as `extrudeFacesByMask`).
/// `pathPoints`  — world-space points, length >= 2. `pathPoints[0]` is
///                 the path ANCHOR (nominally the source polygons' own
///                 position when the stroke began — only consecutive
///                 DELTAS are used, so it need not exactly coincide
///                 with any vertex). `pathPoints.length - 1` new bands
///                 are created; band `i` translates the running ring
///                 by `pathPoints[i+1] - pathPoints[i]`. A
///                 near-zero-length segment (a duplicate/jittered
///                 sample point) is silently skipped rather than
///                 treated as a guard failure.
/// `alignToPath` — CAPTURED default true (reference "Align to Path"
///                 defaults ON — task-0323 toolcard spec.json
///                 `attributes[].align`). When true, each band's ring
///                 is additionally rotated, about its own running
///                 centroid, by the minimal rotation between the
///                 previous and current path-segment tangent before
///                 translating — a parallel-transport-style
///                 incremental tilt. TODO/UNVERIFIED: the one captured
///                 case (task-0323 toolcard behavior_law_measured) is
///                 a straight path, where every segment shares one
///                 tangent and this rotation is always identity;
///                 curved-path tilt is a documented default, not a
///                 captured law (finding_4 confirms align-to-path
///                 tilts rings on the reference, but the exact tilt
///                 formula for a CURVED path was not captured).
///
/// Non-goals carried over verbatim from the toolcard (open_todo, not
/// invented here): the exact screen-pixel Precision→span-count law
/// (finding_3 — this kernel takes an already-resolved point list, so
/// the law lives at the caller/tool layer, not here), Scale/Spin
/// per-band modulation, the Profile-browser width modulation, and the
/// 5 non-primary curve gestures (reset/constrained/branch/delete/
/// delete_branch).
///
/// Returns total NET faces added (> 0) on success, 0 on guard
/// failure / no-op (mesh left unchanged on a total failure of the
/// FIRST band; a later band's guard failure stops the loop early and
/// keeps whatever prior bands already committed — matching this
/// kernel's per-band commit granularity, one `commitChange` per band).
size_t extrudeAlongPath(ref MeshEditBatch ed, in bool[] mask,
                        const(Vec3)[] pathPoints, bool alignToPath = true) {
    import std.math : acos;

    if (mask.length != ed.faces.length) return 0;
    size_t selCount = 0;
    foreach (b; mask) if (b) ++selCount;
    if (selCount == 0) return 0;
    if (pathPoints.length < 2) return 0;
    immutable size_t spanCount = pathPoints.length - 1;
    // DoS backstop (defense-in-depth for the shared caller surface —
    // both the one-shot mesh.strokeExtrude command and the
    // interactive tool clamp the point list before calling in, this
    // is the kernel's own hard cap). Matches the project convention
    // for a generator kernel's own internal clamp (see
    // Mesh.radialArrayFaces's doc comment for the precedent).
    enum size_t maxSpans = 4096;
    if (spanCount > maxSpans) return 0;

    size_t totalAdded      = 0;
    bool[] curMask         = mask.dup;
    Vec3   prevTangent     = Vec3(0, 0, 0);
    bool   havePrevTangent = false;

    foreach (i; 0 .. spanCount) {
        Vec3 translate = pathPoints[i + 1] - pathPoints[i];
        immutable float segLenSq = translate.x * translate.x
                                  + translate.y * translate.y
                                  + translate.z * translate.z;
        if (segLenSq < 1e-12f) continue;   // degenerate sample -- skip, not a failure
        Vec3 tangent = translate * (1.0f / sqrt(segLenSq));

        float[16] rotM;
        bool hasRot = false;
        if (alignToPath && havePrevTangent) {
            immutable float c = dot(prevTangent, tangent);
            immutable float cClamped = c < -1.0f ? -1.0f : (c > 1.0f ? 1.0f : c);
            if (cClamped < 0.999999f) {   // measurable turn -- identity otherwise (straight path)
                Vec3 axis = cross(prevTangent, tangent);
                immutable float axisLenSq = axis.x * axis.x + axis.y * axis.y + axis.z * axis.z;
                if (axisLenSq > 1e-12f) {
                    axis = axis * (1.0f / sqrt(axisLenSq));
                    immutable float angle = acos(cClamped);
                    Vec3 pivot = maskVertexCentroid_(ed.mesh, curMask);
                    rotM   = pivotRotationMatrix(pivot, axis, angle);
                    hasRot = true;
                }
            }
        }
        prevTangent     = tangent;
        havePrevTangent = true;

        auto step = extrudePathStep_(ed, curMask, translate, hasRot ? &rotM : null);
        if (step.facesAdded == 0) break;   // guard failure -- stop, keep prior bands
        totalAdded += step.facesAdded;

        curMask = new bool[ed.faces.length];
        foreach (fi; step.capStart .. step.capStart + step.capCount) curMask[fi] = true;
    }
    return totalAdded;
}


// ===========================================================================
// Module unittests.
// ===========================================================================
// (None here — task 0706 moved both families' blocks to
// tests/unit/mesh_ops/revolve_test.d, and they stayed there through the E2
// conversion. The empty section headers this file used to carry for them are
// gone with the mixin template that framed them.)

// ---------------------------------------------------------------------------
// The gate that outlives the text census (task 1903 Stage C review, MAJOR-1 —
// compile-time, not a unittest). A member of `Mesh` BEATS a same-name UFCS free
// function silently — no ambiguity, no warning — so anything that puts one of
// these names back on the struct (`mixin MeshRevolveOps;`, `mixin ...!();`, a
// named mixin, a hand-written method with the old body, or an
// `alias RevolveParams = …;`) rebinds every call site to it and this module
// becomes dead code. The regex census in
// tests/unit/commit_seam_census_test.d sees only the literal `mixin Mesh*Ops;`
// spelling; this sees the fact, and at `dub build` time rather than only under
// --config=tests.
//
// It is ALSO the check that a mutating receiver did not quietly widen back: a
// `Mesh.revolveProfileEx` member could only exist by taking the mesh directly,
// i.e. by dropping the batch this stage exists to require — which is exactly
// the shape the transitional block this stage REMOVED had to use.
//
// EVERY family name is listed, including the private helpers, the injected
// parameter struct and the private result struct: the mixin put all of them
// into `Mesh` (plan §2.7), so a partial revert that reinstates only
// `RevolveParams` — the one an outside caller spells — is exactly the silent
// half this list is here to catch.
// ---------------------------------------------------------------------------
static foreach (n; ["revolveSweepClosed", "revolveSweepClosedWithOffset",
                    "RevolveParams", "revolveProfile", "revolveProfileEx",
                    "PathExtrudeStep", "maskVertexCentroid_",
                    "extrudePathStep_", "extrudeAlongPath"])
    static assert(!__traits(hasMember, Mesh, n),
        "`Mesh." ~ n ~ "` is a MEMBER again. A member BEATS a same-name UFCS free "
      ~ "function silently, so every call site binds back to it, the batch the "
      ~ "mutating kernels take as their receiver goes away with it, and task 1903 "
      ~ "Stage E2 means nothing — including the transitional batch E2 removed, "
      ~ "which only existed because this family had no caller-held batch. "
      ~ "Whatever re-added it — `mixin MeshRevolveOps;`, `mixin ...!();`, a named "
      ~ "mixin, an `alias`, or a hand-written method — must go.");
