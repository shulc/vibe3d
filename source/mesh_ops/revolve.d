module mesh_ops.revolve;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshRevolveOps — Radial Sweep / Revolve kernel (revolveSweepClosed /
// revolveSweepClosedWithOffset / RevolveParams / revolveProfile /
// revolveProfileEx) PLUS the Path-follow extrude kernel (task 0323 "Sketch
// Extrude" port: PathExtrudeStep / maskVertexCentroid_ / extrudePathStep_ /
// extrudeAlongPath) — grouped as one family per the 0407 campaign queue even
// though the two are explicitly documented as sharing no code with each
// other (see the "Path-follow extrude kernel" banner below — ADDITIVE,
// unrelated to the revolve kernel above it). Mixed into struct Mesh
// (source/mesh.d) via `mixin MeshRevolveOps;`. extrudeAlongPath's own two
// unittest blocks were already MEMBER-style (nested directly in struct Mesh,
// not module-level) before this move — they stay that way here, nested
// inside this mixin template rather than pulled out after it, preserving
// their exact original character (verified: dub test still discovers and
// runs them from inside the template — see task 0417's Лог).
//
// Split out of mesh.d as part of the mesh.d decomposition campaign (0407
// §B.V2, task 0417 — continuation of the task-0412 plane-cut pilot and this
// same task's bridge/loop-slice/decimate extractions; see task 0412's doc
// for the architectural decision: mixin template over a package move or
// UFCS free-functions). Method bodies below are verbatim cut/paste from
// mesh.d (only the extraction boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshRevolveOps() {
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
    static bool revolveSweepClosed(float angle) pure nothrow @nogc @safe {
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
    static bool revolveSweepClosedWithOffset(float angle, float offset) pure nothrow @nogc @safe {
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
    size_t revolveProfile(const(uint)[] profile, bool profileClosed,
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
        return revolveProfileEx(profile, profileClosed, p);
    }

    /// Extended revolve/lathe kernel (task 0326) — additive superset of
    /// `revolveProfile` backing the interactive Radial Sweep tool
    /// (`tools/radial_sweep_tool.d`). Adds: a free 3D rotation axis (any
    /// direction, not just a world X/Y/Z unit vector), a Start Angle offset
    /// for ring 0, an axial spiral Offset per ring step, and optional
    /// Start/End caps.
    ///
    /// ⚠ SHARED KERNEL: this function (and `revolveProfile` above, which
    /// now forwards into it) also backs the task-0323 Sketch Extrude port.
    /// Extend via `RevolveParams` fields ONLY — never change either
    /// function's positional signature.
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
    size_t revolveProfileEx(const(uint)[] profile, bool profileClosed,
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
        const size_t origFaceCount = faces.length;

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
                Vec3 p  = vertices[vid];
                auto v4 = Vec4(p.x, p.y, p.z, 1.0f);
                auto r4 = mulMV(rotM, v4);
                Vec3 pos = Vec3(r4.x, r4.y, r4.z);
                if (hasOffset) pos = pos + axisVec * axialShift;
                ring[k] = addVertex(pos);
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
        size_t facesAdded = 0;
        immutable int lastBridge = sweepClosed ? params.count - 1 : params.count - 2;
        foreach (i; 0 .. lastBridge + 1) {
            int           nextIdx = sweepClosed ? (i + 1) % params.count : i + 1;
            const(uint)[] ringA   = rings[i];
            const(uint)[] ringB   = rings[nextIdx];

            if (profileClosed) {
                // bridgeLoopsPaired: M quads with closed wrap [A[i],A[i+1],B[i+1],B[i]].
                facesAdded += bridgeLoopsPaired(ringA, ringB);
            } else {
                // Open strip: M-1 quads, no wrap; same winding as bridgeLoopsPaired.
                const size_t M = profile.length;
                foreach (j; 0 .. M - 1) {
                    addFace([ringA[j], ringA[j + 1], ringB[j + 1], ringB[j]]);
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
                addFace(rev);
                ++facesAdded;
            }
            if (params.cap1) {
                addFace(rings[$ - 1].dup);
                ++facesAdded;
            }
        }

        if (facesAdded == 0) return 0;

        // Finalise: rebuild half-edge maps and grow selection arrays.
        buildLoops();
        syncSelection();

        // Deselect pre-existing faces; select only the newly swept faces.
        foreach (fi; 0 .. origFaceCount)
            deselectFace(cast(int)fi);
        faceSelectionOrderCounter = 0;
        foreach (fi; origFaceCount .. faces.length)
            selectFace(cast(int)fi);

        // Clear vertex and edge selection (mirrors radialArrayFaces :3807-3810).
        clearVertexSelection();
        clearEdgeSelection();

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
    private Vec3 maskVertexCentroid_(in bool[] mask) {
        Vec3   sum = Vec3(0, 0, 0);
        size_t n   = 0;
        bool[] seen;
        seen.length = vertices.length;
        foreach (fi; 0 .. faces.length) {
            if (fi >= mask.length || !mask[fi]) continue;
            foreach (vid; faces[fi]) {
                if (vid < seen.length) {
                    if (seen[vid]) continue;
                    seen[vid] = true;
                }
                sum = sum + vertices[vid];
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
    private PathExtrudeStep extrudePathStep_(in bool[] mask, Vec3 translate,
                                             const(float[16])* rotM) {
        import math : mulMV;

        PathExtrudeStep result;
        if (mask.length != faces.length) return result;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return result;

        auto edgeFaces = buildEdgeFaces();
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
            foreach (fi; 0 .. faces.length) {
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
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            int island = islandOf[fi];
            foreach (vid; faces[fi]) {
                ulong k = ivKey(island, vid);
                if (k !in vertNewPos)
                    vertNewPos[k] = newPos(vertices[vid]);
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
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            int island = islandOf[fi];
            foreach (vid; faces[fi]) {
                ulong k = ivKey(island, vid);
                if (k !in vertMap)
                    vertMap[k] = addVertex(vertNewPos[k]);
            }
        }

        size_t[] toCloneFace;
        foreach (fi; 0 .. faces.length) if (mask[fi]) toCloneFace ~= fi;

        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        bool[]   newSub;

        foreach (fi; 0 .. faces.length) {
            if (mask[fi]) continue;
            newFaces ~= faces[fi];
            newMat   ~= fi < faceMaterial.length       ? faceMaterial[fi]       : 0u;
            newPart  ~= fi < facePart.length           ? facePart[fi]           : 0u;
            newOrd   ~= fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0;
            newSub   ~= isFaceSubpatch(fi);
        }
        immutable size_t facesBefore = faces.length;
        immutable size_t capStart    = newFaces.length;

        foreach (fi; toCloneFace) {
            auto src = faces[fi];
            uint[] cloned;
            cloned.length = src.length;
            int island = islandOf[fi];
            foreach (k, vid; src) cloned[k] = vertMap[ivKey(island, vid)];
            newFaces ~= cloned;
            newMat   ~= fi < faceMaterial.length ? faceMaterial[fi] : 0u;
            newPart  ~= fi < facePart.length     ? facePart[fi]     : 0u;
            newOrd   ~= 0;
            newSub   ~= isFaceSubpatch(fi);
        }
        immutable size_t capCount = toCloneFace.length;

        foreach (ref be; bEdges) {
            uint a = be.va, b = be.vb;
            int island = islandOf[be.selFi];
            uint cloneA = vertMap[ivKey(island, a)], cloneB = vertMap[ivKey(island, b)];
            bool origAtoB = false;
            auto orig = faces[be.selFi];
            foreach (k; 0 .. orig.length) {
                uint u = orig[k], w = orig[(k + 1) % orig.length];
                if (u == a && w == b) { origAtoB = true;  break; }
                if (u == b && w == a) { origAtoB = false; break; }
            }
            if (origAtoB) newFaces ~= [cloneB, cloneA, a, b];
            else          newFaces ~= [cloneA, cloneB, b, a];
            newMat  ~= be.selFi < faceMaterial.length ? faceMaterial[be.selFi] : 0u;
            newPart ~= be.selFi < facePart.length     ? facePart[be.selFi]     : 0u;
            newOrd  ~= 0;
            // Task 0389: revolve wall quads inherit Subpatch from their source
            // profile edge's face, like extrudeFacesByMask — so revolving a
            // subdiv profile keeps the swept surface subdiv (bounds-guarded).
            newSub  ~= isFaceSubpatch(be.selFi);
        }

        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;

        // Rebuild faceMarks from scratch: resize+zero ALL bits, then set Subpatch.
        faceMarks.length = faces.length;
        faceMarks[]      = 0;
        foreach (fi, s; newSub)
            if (s) faceMarks[fi] |= Marks.Subpatch;

        // New selection = cap faces (chains a follow-up op off the top,
        // and lets the top-level extrudeAlongPath loop derive the next
        // band's mask from the selection state).
        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. capStart + capCount)
            selectFace(cast(int)fi);

        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        rebuildEdges();
        buildLoops();
        compactUnreferenced();   // drops orig verts no longer referenced (none here — walls keep them)
        buildLoops();

        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);

        result.facesAdded = faces.length - facesBefore;
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
    size_t extrudeAlongPath(in bool[] mask, const(Vec3)[] pathPoints, bool alignToPath = true) {
        import std.math : acos;

        if (mask.length != faces.length) return 0;
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
                        Vec3 pivot = maskVertexCentroid_(curMask);
                        rotM   = pivotRotationMatrix(pivot, axis, angle);
                        hasRot = true;
                    }
                }
            }
            prevTangent     = tangent;
            havePrevTangent = true;

            auto step = extrudePathStep_(curMask, translate, hasRot ? &rotM : null);
            if (step.facesAdded == 0) break;   // guard failure -- stop, keep prior bands
            totalAdded += step.facesAdded;

            curMask = new bool[faces.length];
            foreach (fi; step.capStart .. step.capStart + step.capCount) curMask[fi] = true;
        }
        return totalAdded;
    }

    unittest { // extrudeAlongPath (a): cube top face, straight vertical path, 16
               // spans — pins the KERNEL's topology for the captured span count
               // (task 0323 toolcard behavior_law_measured: cube top face,
               // default attrs, straight 180px screen drag → +64v/+64f, 16
               // bands). This test feeds the kernel a caller-resolved 16-point
               // WORLD-space path directly — it does NOT reproduce the
               // reference's screen-pixel→world camera-raycast mapping (that
               // lives at the tool layer — see StrokeExtrudeTool's doc comment)
               // nor the measured non-uniform per-band world spacing (a camera-
               // perspective effect, finding_1 — NOT a kernel-level law). The
               // exact screen-Precision→span-count formula is the toolcard's
               // own open follow-up (finding_3) and is intentionally NOT
               // guessed here or anywhere else in this port.
        import std.conv : to;
        import std.math : abs;

        auto m = makeCube();
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi])
                if (abs(m.vertices[vid].y - 0.5f) > 1e-4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        assert(topFi >= 0, "extrudeAlongPath: top face not found on test cube");

        bool[] mask;
        mask.length = m.faces.length;
        mask[]       = false;
        mask[topFi]  = true;

        Vec3[] path;
        path ~= Vec3(0, 0.5f, 0);   // anchor -- top face's own height
        foreach (k; 1 .. 17) path ~= Vec3(0, 0.5f + 0.1f * cast(float)k, 0);

        size_t added = m.extrudeAlongPath(mask, path, /*alignToPath*/true);
        assert(added == 64,
            "extrudeAlongPath: expected +64 net faces for the captured 16-span case, got "
            ~ added.to!string);
        assert(m.faces.length == 6 + 64,
            "extrudeAlongPath: expected 70 total faces (6 orig + 64 new), got "
            ~ m.faces.length.to!string);
        assert(m.vertices.length == 8 + 64,
            "extrudeAlongPath: expected 72 total verts (8 orig + 64 new), got "
            ~ m.vertices.length.to!string);

        // Manifold (task 0363 discipline): every undirected edge used by at
        // most 2 faces.
        int[ulong] edgeUse;
        foreach (ref face; m.faces) {
            size_t n = face.length;
            foreach (i; 0 .. n) {
                uint a = face[i], b = face[(i + 1) % n];
                ulong key = a < b ? ((cast(ulong)a << 32) | b) : ((cast(ulong)b << 32) | a);
                edgeUse[key] = edgeUse.get(key, 0) + 1;
            }
        }
        foreach (key, count; edgeUse)
            assert(count <= 2,
                "extrudeAlongPath: edge used by " ~ count.to!string ~ " faces -- non-manifold");
    }

    unittest { // extrudeAlongPath (b): guard rejections -- all must return 0,
               // mesh unchanged.
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
        Vec3[] path2 = [Vec3(0, 0, 0), Vec3(0, 1, 0)];

        // Mask length mismatch.
        bool[] badMask = [true, false];
        assert(m.extrudeAlongPath(badMask, path2) == 0,
            "extrudeAlongPath: mask-length mismatch must return 0");

        // No face selected.
        bool[] emptyMask; emptyMask.length = m.faces.length;
        assert(m.extrudeAlongPath(emptyMask, path2) == 0,
            "extrudeAlongPath: empty mask must return 0");

        // Fewer than 2 path points.
        assert(m.extrudeAlongPath(mask, [Vec3(0, 0, 0)]) == 0,
            "extrudeAlongPath: single-point path must return 0");
        assert(m.extrudeAlongPath(mask, cast(Vec3[])[]) == 0,
            "extrudeAlongPath: empty path must return 0");

        // Span-count DoS backstop: 4098 points => 4097 spans, one past the
        // internal 4096 cap => hard rejection. NOTE: deliberately NOT
        // testing the "exactly at the cap succeeds" boundary end-to-end
        // here — actually running 4096 real bands is O(bands × faces) and
        // would make `dub test` pathologically slow; the cap's ALLOW side
        // is already exercised cheaply by the 16-span case in test (a)
        // above, so this test only needs to prove the REJECT side, which
        // returns before any band runs (O(1), no mutation).
        Vec3[] overCap;
        overCap.length = 4098;
        foreach (k, ref p; overCap) p = Vec3(0, 0.5f + 0.001f * cast(float)k, 0);
        size_t facesBefore = m.faces.length;
        size_t vertsBefore = m.vertices.length;
        assert(m.extrudeAlongPath(mask, overCap) == 0,
            "extrudeAlongPath: over-cap span count must return 0 (DoS backstop)");
        assert(m.faces.length == facesBefore && m.vertices.length == vertsBefore,
            "extrudeAlongPath: over-cap rejection must leave the mesh unchanged");
    }
}

// ---------------------------------------------------------------------------
// Unit tests — co-located with the family they exercise (moved verbatim
// from mesh.d alongside the kernels above).
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// revolveProfile unittests
// ---------------------------------------------------------------------------

unittest { // revolveProfile (a): closed ring 360° — 16 quads, 16 verts, manifold, 0 boundary loops
    import std.math : PI;
    import std.conv : to;

    // Square closed cross-section at x=2 from the Y axis.
    // Closing edges complete the ring (needed for bridgeLoopsPaired topology but
    // not structurally required — revolveProfile only reads vertex positions via
    // the vertex index array, not edge topology).
    Mesh m;
    m.addVertex(Vec3(2, 0, 0));  // v0
    m.addVertex(Vec3(2, 1, 0));  // v1
    m.addVertex(Vec3(2, 1, 1));  // v2
    m.addVertex(Vec3(2, 0, 1));  // v3
    m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3); m.addEdge(3, 0);
    m.buildLoops();

    // Revolve 360°, 4 steps.
    // Closed sweep: 4 rings × 4 bridge steps × 4 quads/step = 16 faces.
    // Vertex count: ring[0]=4 original + rings[1..3]=3×4 = 4+12 = 16 (no seam dup).
    size_t added = m.revolveProfile([0u, 1u, 2u, 3u], /*profileClosed*/true,
                                    /*count*/4, 'Y', Vec3(0, 0, 0),
                                    cast(float)(2 * PI));
    assert(added == 16,
        "closed 360°: revolveProfile returned " ~ added.to!string ~ ", expected 16");
    assert(m.faces.length == 16,
        "closed 360°: faces.length == " ~ m.faces.length.to!string ~ ", expected 16");
    assert(m.vertices.length == 16,
        "closed 360°: vertices.length == " ~ m.vertices.length.to!string
        ~ " (expected 16, no seam dup)");

    // Manifold: every face-edge must appear exactly twice across all faces.
    int[ulong] edgeInc;
    foreach (fi; 0 .. m.faces.length) {
        const f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            uint a = f[k], b = f[(k + 1) % f.length];
            ulong key = a < b ? (cast(ulong)a << 32) | b
                              : (cast(ulong)b << 32) | a;
            edgeInc[key]++;
        }
    }
    foreach (key, cnt; edgeInc)
        assert(cnt == 2,
            "closed 360°: edge " ~ key.to!string ~ " has incidence " ~ cnt.to!string
            ~ " (expected exactly 2 — surface must be manifold)");

    // Watertight: zero boundary loops.
    auto bLoops = m.boundaryLoops();
    assert(bLoops.length == 0,
        "closed 360°: expected 0 boundary loops, got " ~ bLoops.length.to!string);
}

unittest { // revolveProfile (b): open strip, partial arc — 4 quads, 9 verts, 1 boundary loop
    import std.math : PI;
    import std.conv : to;

    // 3-vert polyline along the X axis; open-strip profile (profileClosed=false).
    // Verts in the y=0 plane: all rotated verts also remain in y=0 (Y-axis rotation
    // preserves y).  Face normals all point in +Y (verified analytically).
    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1
    m.addVertex(Vec3(3, 0, 0));  // v2
    m.addEdge(0, 1); m.addEdge(1, 2);
    m.buildLoops();

    // Open 90° arc, 3 copies.
    // stepAngle = (π/2)/(3-1) = π/4.
    // Bridges: (0→1), (1→2).  Each step: M-1 = 2 quads.  Total = 4 quads.
    // Vertex count: 3 original + 2 new rings × 3 = 9.
    size_t added = m.revolveProfile([0u, 1u, 2u], /*profileClosed*/false,
                                    /*count*/3, 'Y', Vec3(0, 0, 0),
                                    cast(float)(PI * 0.5));
    assert(added == 4,
        "open arc 90°: revolveProfile returned " ~ added.to!string ~ ", expected 4");
    assert(m.faces.length == 4,
        "open arc 90°: faces.length == " ~ m.faces.length.to!string ~ ", expected 4");
    assert(m.vertices.length == 9,
        "open arc 90°: vertices.length == " ~ m.vertices.length.to!string
        ~ ", expected 9");

    // All new faces must be quads with globally consistent winding.
    Vec3 refN = m.faceNormal(0);
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faces[fi].length == 4,
            "open arc 90°: face " ~ fi.to!string ~ " is not a quad");
        Vec3 fn = m.faceNormal(cast(uint)fi);
        float dt = fn.x * refN.x + fn.y * refN.y + fn.z * refN.z;
        assert(dt > 0.0f,
            "open arc 90°: face " ~ fi.to!string ~ " has inconsistent winding");
    }

    // Open partial arc: one boundary loop (the rectangular perimeter).
    auto bLoops = m.boundaryLoops();
    assert(bLoops.length == 1,
        "open arc 90°: expected 1 boundary loop (perimeter), got "
        ~ bLoops.length.to!string);
}

unittest { // revolveProfile (c): guard rejections — all must return 0, mesh unchanged
    import std.math : PI;
    import std.conv : to;

    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1
    m.addVertex(Vec3(3, 0, 0));  // v2

    immutable float tau = cast(float)(2 * PI);
    uint[] p3 = [0u, 1u, 2u];

    // count < 2
    assert(m.revolveProfile(p3, false, 1, 'Y', Vec3(0,0,0), tau) == 0,
        "guard count<2: expected 0");
    assert(m.faces.length == 0, "guard count<2: mesh must be unchanged");

    // bad axis character
    assert(m.revolveProfile(p3, false, 4, 'W', Vec3(0,0,0), tau) == 0,
        "guard bad axis: expected 0");
    assert(m.faces.length == 0, "guard bad axis: mesh must be unchanged");

    // zero angle
    assert(m.revolveProfile(p3, false, 4, 'Y', Vec3(0,0,0), 0.0f) == 0,
        "guard zero angle: expected 0");
    assert(m.faces.length == 0, "guard zero angle: mesh must be unchanged");

    // profile.length < 2
    assert(m.revolveProfile([0u], false, 4, 'Y', Vec3(0,0,0), tau) == 0,
        "guard profile<2: expected 0");
    assert(m.faces.length == 0, "guard profile<2: mesh must be unchanged");

    // closed profile with < 3 verts
    assert(m.revolveProfile([0u, 1u], true, 4, 'Y', Vec3(0,0,0), tau) == 0,
        "guard closed<3: expected 0");
    assert(m.faces.length == 0, "guard closed<3: mesh must be unchanged");

    // Vertex count must also be untouched: only the 3 verts we added.
    assert(m.vertices.length == 3,
        "guards: vertices.length must remain 3, got " ~ m.vertices.length.to!string);
}

unittest { // revolveProfileEx (d): spiral offset at a >=360deg angle span
           // must NOT wrap the last ring onto ring 0 (task 0326 review S1)
    import std.math : PI, abs;
    import std.conv : to;

    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1

    immutable float tau = cast(float)(2 * PI);

    Mesh.RevolveParams p;
    p.count  = 5;
    p.axis   = Vec3(0, 1, 0);
    p.center = Vec3(0, 0, 0);
    p.angle  = tau;      // angle-closed span on its own...
    p.offset = 0.5f;     // ...but a nonzero spiral offset must force OPEN.

    size_t vertsBefore = m.vertices.length;
    size_t facesBefore = m.faces.length;
    size_t inserted = m.revolveProfileEx([0u, 1u], false, p);

    // OPEN topology: count-1 bridges (4), NOT count (5) — a wrap bridge
    // would connect ring[4] (height 4*offset=2.0) back onto ring[0]
    // (height 0), a spurious self-intersecting closing band.
    assert(inserted == 4,
        "spiral offset at >=360deg: expected 4 faces (no wrap band), got "
        ~ inserted.to!string);
    assert(m.faces.length - facesBefore == 4,
        "spiral offset at >=360deg: expected +4 faces, got +"
        ~ (m.faces.length - facesBefore).to!string);
    // ring0 (reused, 0 new) + 4 new rings x 2 verts = 8 new verts.
    assert(m.vertices.length - vertsBefore == 8,
        "spiral offset at >=360deg: expected +8 verts, got +"
        ~ (m.vertices.length - vertsBefore).to!string);

    // Last ring (k=4) landed a full turn around (XZ back near the start)
    // but risen 4*offset=2.0 along Y — proves the sweep kept climbing
    // instead of folding back onto ring 0's height.
    Vec3 lastRingV0 = m.vertices[$ - 2];
    assert(abs(lastRingV0.y - 2.0f) < 1e-3f,
        "spiral offset: last ring expected y~2.0, got " ~ lastRingV0.y.to!string);
    assert(abs(lastRingV0.x - 1.0f) < 1e-2f && abs(lastRingV0.z) < 1e-2f,
        "spiral offset: last ring expected XZ~(1,0) after a full turn, got ("
        ~ lastRingV0.x.to!string ~ "," ~ lastRingV0.z.to!string ~ ")");
}
