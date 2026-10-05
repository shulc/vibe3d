module commands.mesh.smooth;

import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport, AimViewport, aimSpace, cross, dot,
    triangulatePolygonEarClip;
import document : primaryModelSpace;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
import commands.mesh.vertex_position_result : VertexPositionResult,
    VertexPositionResultBuilder;
import toolpipe.packets : FalloffPacket, SubjectPacket;
import falloff : evaluateFalloff, IFalloffAware, FalloffInput,
    weightedLerp;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import tools.edit.smooth_relax : RelaxVec3, RelaxTopology, RelaxScratch,
    deriveBoundary, relaxable, relaxStep;

/// Preserve Volume re-projects at iteration `i` of `iters` iff i < 10, it is
/// the last iteration, or i % 100 == 0 (the 100 is fixed; captured K-F3k,
/// cell K3_ITER in tests/fixtures/smooth_kernel.json).
bool preserveProjectsAt(int i, int iters) pure nothrow @nogc @safe {
    return i < 10 || i == iters - 1 || i % 100 == 0;
}

/// Smooth: the shared relax kernel (`tools/edit/smooth_relax.d`) with the
/// boundary scale `c`, an ACTIVE mask and Preserve Volume's re-projection —
/// the captured law in tests/fixtures/smooth_kernel.json (task 9484).
///   * active = the operand selection's vertices (none selected = every
///     visible vertex) minus lockBound (a border-edge vertex), lockCorner
///     (used by exactly one polygon), lockSharp (an end of an edge whose face
///     normals dot below cos(sharpThreshold°)) and falloff weight 0; inactive
///     vertices are fixed neighbours; rings and border flags from the whole mesh;
///   * c = (mean |n_v·n_i|)² over the border ring of a border vertex with > 2
///     neighbours and >= 2 border neighbours, else 1; lockSharp forces c = 1;
///     n = unit(Σ first-corner polygon normals) of the ORIGINAL mesh, in float;
///   * positions stay double across iterations, written as float once;
///   * Preserve: at `preserveProjectsAt` iterations each active point moves
///     along −n onto the ORIGINAL surface (nearest hit on the line; no hit
///     keeps it); the falloff lerp from the original position comes last.
class MeshSmooth : Command, Operator, IFalloffAware,
                   VertexPositionResultBuilder {
    private float strn_       = 1.0f;   // `strn` — reference default 1.0
    private int   iter_       = 1;      // `iter`
    private bool  lockBound_  = false;  // `lockBound`
    private bool  lockCorner_ = false;  // `lockCorner`
    private bool  lockSharp_  = false;  // `lockSharp`
    private float sharpThresholdDeg_ = 60.0f; // `sharpThreshold`, DEGREES (K-F3s)
    private bool  preserve_   = false;  // `preserve` (Preserve Volume)
    // Optional falloff, set by XfrmSmoothTool from the toolpipe or by the HTTP
    // injector; weights are read at the ORIGINAL positions.
    mixin FalloffInput;
    // Recorded `Kind.SetPos` undo (task 1903 L0-d3). ONE entry, from the
    // builder result's explicit `before` image.
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing answers `true` from the BASE
        /// `Command.revert` (task 2500) and the mesh is already where the undo
        /// wants it, so every result-shaped assertion — the plane diff, the
        /// redo cell, the parity cell — is GREEN over a deleted recorder. Only
        /// reading the log itself is not.
        /// `version (unittest)`, so this is not a door in a shipped build; both
        /// gate lanes compile the sources with `-unittest`. `public` on the
        /// declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }

        /// Build the two mutation candidates without changing production
        /// state.  Tests vary the original-surface and sharp-normal coordinate
        /// images independently, which is what makes the two baseline laws
        /// separately falsifiable rather than one branch masking the other.
        public bool buildVertexPositionResultWithNormalSourcesForTest(
                const(Vec3)[] source,
                const(Vec3)[] surfaceSource,
                const(Vec3)[] sharpNormalSource,
                ref VectorStack vts,
                out VertexPositionResult result) {
            return buildVertexPositionResultImpl(source, surfaceSource,
                                                  sharpNormalSource, vts, result);
        }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.smooth"; }
    override string label() const { return "Smooth"; }

    // Row order matches the reference Smooth tool properties top-to-bottom.
    override Param[] params() {
        return [
            Param.float_("strn",       "Strength",         &strn_,          1.0f).min(0.0f).max(1.0f),
            // `.max(256).enforceBounds()` matches the local `MAX_SMOOTH_ITER`
            // apply-loop cap below — the Param bound alone is a UI-only
            // hint and does not clamp a raw HTTP write.
            Param.int_  ("iter",       "Iterations",       &iter_,          1).min(0).max(256).enforceBounds(),
            Param.bool_ ("lockBound",  "Lock Boundary",    &lockBound_,     false),
            Param.bool_ ("lockCorner", "Lock Corner",      &lockCorner_,    false),
            Param.bool_ ("preserve",   "Preserve Volume",  &preserve_,      false),
            Param.bool_ ("lockSharp",  "Lock Sharp Edges", &lockSharp_,     false),
            Param.float_("sharpThreshold", "Sharp Threshold", &sharpThresholdDeg_, 60.0f).min(0.0f).max(180.0f),
        ];
    }

    // The threshold is meaningful only while Lock Sharp Edges is on —
    // grey it out otherwise, matching the reference's disabled spinner.
    override bool paramEnabled(string name) const {
        if (name == "sharpThreshold") return lockSharp_;
        return true;
    }

    // Setters for XfrmSmoothTool's drag-modulates-attrs path.
    void setStrn(float v) { strn_ = v; }
    void setIter(int   v) { iter_ = v; }

    // Operator interface. Common stubs from the mixin; evaluate(vts)
    // publishes the optional FalloffPacket before invoking the deterministic
    // result builder.
    mixin OperatorActrCommon;
    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        captureFalloff(vts);

        // §2.4 — the guard is resolved BEFORE the batch is opened; a `return`
        // out of an open batch leaves `~MeshEditBatch` to pop the frame and
        // tick `changeBus.batchLeaks`, which the suite asserts is 0.
        //
        // It answers TRUE, and that is task 2110's ruling, not a shortcut:
        // `mesh.smooth {iter:0}` answers `ok` and records a history entry, so a
        // `false` from the matching `revert()` would make `CommandHistory.undo`
        // discard that entry AND the whole trailing suffix (regression 0099).
        // The entry it leaves is unarmed, and `revert()`'s legacy arm below
        // answers true for it.
        VertexPositionResult result;
        if (!buildVertexPositionResult(mesh.vertices, vts, result)) return false;
        if (result.empty) return true;  // command no-op remains success

        // REDO: re-run the kernel UNRECORDED and keep the first delta. The
        // relax, the preserve projection and the falloff blend are pure
        // functions of the params and the restored pre-op mesh.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            applyResult(ed, result);
            ed.close();
            return true;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        applyResult(ed, result);
        undo_.arm(this, ed.close());
        return true;
    }

    override bool buildVertexPositionResult(const(Vec3)[] source,
                                            ref VectorStack vts,
                                            out VertexPositionResult result) {
        return buildVertexPositionResultImpl(source, source, source, vts, result);
    }

    // `surfaceSource` is the ORIGINAL image the normals (c and the preserve
    // direction) and the preserve surface come from; `sharpNormalSource` the
    // image lockSharp classifies. Both are `source` in production; the test
    // seam varies them to prove neither reads the live preview.
    private bool buildVertexPositionResultImpl(
            const(Vec3)[] source,
            const(Vec3)[] surfaceSource,
            const(Vec3)[] sharpNormalSource,
            ref VectorStack vts,
            out VertexPositionResult result) {
        result.clear();
        auto subj = vts.get!SubjectPacket();
        if (subj is null || subj.mesh is null || subj.mesh !is mesh ||
            source.length != subj.mesh.vertices.length ||
            surfaceSource.length != source.length ||
            sharpNormalSource.length != source.length) return false;
        Mesh* subject = subj.mesh;
        const resultFalloff = inputFalloff(vts);

        // The command contract treats either zero control as a successful
        // no-op.  An empty builder value therefore means "nothing to apply",
        // never refusal (task 4560).
        if (iter_ <= 0 || strn_ <= 0.0f) return true;

        // DoS backstop (task 0365 P1): `iter` scales the pass count; Param
        // `.min()` hints are UI-only and do not clamp a scripted write.
        enum int MAX_SMOOTH_ITER = 256;
        const int iters = iter_ > MAX_SMOOTH_ITER ? MAX_SMOOTH_ITER : iter_;
        const size_t nV = source.length;

        // Active mask: the operand selection (L1 funnel, task 0613) minus
        // the locks and weight 0. Topology is the whole mesh's.
        bool[] active = subject.operandVertexMask(editMode);
        const RelaxTopology topo = relaxTopologyOf(subject);
        if (lockBound_)
            foreach (v; 0 .. nV) if (topo.boundary[v]) active[v] = false;
        if (lockCorner_) {
            auto uses = new int[](nV);
            foreach (f; subject.faces) if (f.length >= 3)
                foreach (vid; f) if (vid < nV) ++uses[vid];
            foreach (v; 0 .. nV) if (uses[v] == 1) active[v] = false;
        }
        if (lockSharp_) {
            foreach (ei, sharp; sharpEdgesAtPositions(
                    *subject, sharpThresholdDeg_, sharpNormalSource))
                if (sharp) foreach (vid; subject.edges[ei])
                    if (vid < nV) active[vid] = false;
        }
        float[] weight;
        if (resultFalloff.enabled) {
            // Screen/Lasso are evaluated in the actual subject viewport.
            const auto aim = aimSpace(subj.viewport, primaryModelSpace());
            weight.length = nV;
            foreach (v; 0 .. nV) if (active[v]) {
                weight[v] = evaluateFalloff(resultFalloff, source[v], cast(int)v, aim);
                if (!(weight[v] > 0.0f)) active[v] = false;
            }
        }

        const Vec3[] normal = vertexNormalsAtPositions(*subject, surfaceSource);
        const double[] cScale = lockSharp_ ? null : boundaryScale(topo, normal);
        const RelaxVec3[3][] surface =
            preserve_ ? surfaceTriangles(*subject, surfaceSource) : null;

        auto pos = new RelaxVec3[](nV);
        foreach (v; 0 .. nV) pos[v] = RelaxVec3(source[v].x, source[v].y, source[v].z);
        const double F = strn_ / 20.0;
        if (relaxable(pos, topo, F)) {
            auto work = RelaxScratch(nV, topo.nbrs.length);
            foreach (i; 0 .. iters) {
                relaxStep(pos, topo, F, active, cScale, work);
                if (preserve_ && preserveProjectsAt(i, iters))
                    foreach (v; 0 .. nV) if (active[v])
                        projectOntoSurface(pos[v], normal[v], surface);
            }
        }

        // ONE `SetPos` entry from the pre-op image (task 1903 §2.1); only
        // vertices whose final value differs from the baseline are carried.
        foreach (v; 0 .. nV) if (active[v]) {
            Vec3 p = Vec3(cast(float)pos[v].x, cast(float)pos[v].y,
                          cast(float)pos[v].z);
            if (weight.length) p = weightedLerp(source[v], p, weight[v]);
            if (p == source[v]) continue;
            result.indices ~= cast(uint)v;
            result.before ~= source[v];
            result.after ~= p;
        }
        return true;
    }

    private static void applyResult(ref MeshEditBatch ed,
                                    ref const VertexPositionResult result) {
        ed.setVertexPositions(result.indices, result.after);
        ed.commitChange(MeshEditScope.Position);
    }

    /// The relax topology of the whole mesh: CSR edge neighbours, each slot
    /// flagged OPEN when its edge has at most one face.
    private static RelaxTopology relaxTopologyOf(Mesh* m) {
        const(size_t)[] off;
        const(uint)[]   nbrs;
        m.vertexAdjacencyCSR(off, nbrs);
        auto openTo = new bool[](nbrs.length);
        foreach (v; 0 .. m.vertices.length)
            foreach (k; off[v] .. off[v + 1]) {
                const uint ei = m.edgeIndex(cast(uint)v, nbrs[k]);
                if (ei == uint.max) continue;
                size_t faces;
                foreach (fi; m.facesAroundEdge(ei)) ++faces;
                openTo[k] = faces <= 1;
            }
        return RelaxTopology(off, nbrs, openTo, deriveBoundary(off, openTo));
    }

    /// Vertex normals: unit(Σ unit FIRST-CORNER polygon normals
    /// (P1 − P0) × (P_last − P0)), computed in double, stored as float.
    private static Vec3[] vertexNormalsAtPositions(const ref Mesh m,
                                                   const(Vec3)[] pos) {
        auto sum = new RelaxVec3[](pos.length);
        foreach (f; m.faces) {
            if (f.length < 3) continue;
            const n = unitOrZero(crossD(d3(pos[f[1]]) - d3(pos[f[0]]),
                                        d3(pos[f[$ - 1]]) - d3(pos[f[0]])));
            foreach (vid; f) sum[vid] = sum[vid] + n;
        }
        auto normal = new Vec3[](pos.length);
        foreach (v, s; sum) {
            const u = unitOrZero(s);
            normal[v] = Vec3(cast(float)u.x, cast(float)u.y, cast(float)u.z);
        }
        return normal;
    }

    /// The boundary scale c per vertex (see the class comment).
    private static double[] boundaryScale(const ref RelaxTopology topo,
                                          const(Vec3)[] normal) {
        auto c = new double[](normal.length);
        foreach (v; 0 .. normal.length) {
            c[v] = 1.0;
            const size_t lo = topo.offset[v], hi = topo.offset[v + 1];
            if (!topo.boundary[v] || hi - lo <= 2) continue;
            const nv = d3(normal[v]);
            double sum = 0;
            size_t n;
            foreach (k; lo .. hi) if (topo.openTo[k]) {
                const d = nv.dot(d3(normal[topo.nbrs[k]]));
                sum += d < 0 ? -d : d;
                ++n;
            }
            if (n >= 2) c[v] = (sum / n) * (sum / n);
        }
        return c;
    }

    /// The original surface as triangles (ear clipping per polygon).
    private static RelaxVec3[3][] surfaceTriangles(const ref Mesh m,
                                                   const(Vec3)[] pos) {
        RelaxVec3[3][] tris;
        Vec3[] ring;
        foreach (f; m.faces) {
            ring.length = 0;
            foreach (vid; f) ring ~= pos[vid];
            foreach (t; triangulatePolygonEarClip(ring)) {
                RelaxVec3[3] tri = [d3(ring[t[0]]), d3(ring[t[1]]), d3(ring[t[2]])];
                tris ~= tri;
            }
        }
        return tris;
    }

    /// Move `p` along the line through it with direction −n to the nearest
    /// (smallest |t|) hit on `surface`; no hit keeps `p`.
    private static void projectOntoSurface(ref RelaxVec3 p, Vec3 n,
                                           const(RelaxVec3[3])[] surface) {
        const d = d3(n) * -1.0;
        double bestT = double.infinity;
        foreach (ref t; surface) {
            const e1 = t[1] - t[0], e2 = t[2] - t[0];
            const nt = crossD(e1, e2);
            const den = nt.dot(d);
            if (den == 0) continue;
            const tt = nt.dot(t[0] - p) / den;
            const q = p + d * tt;
            const tol = -1e-12 * nt.dot(nt);
            if (nt.dot(crossD(t[1] - t[0], q - t[0])) < tol ||
                nt.dot(crossD(t[2] - t[1], q - t[1])) < tol ||
                nt.dot(crossD(t[0] - t[2], q - t[2])) < tol) continue;
            if ((tt < 0 ? -tt : tt) < (bestT < 0 ? -bestT : bestT)) bestT = tt;
        }
        if (bestT != double.infinity) p = p + d * bestT;
    }

    private static RelaxVec3 d3(Vec3 v) { return RelaxVec3(v.x, v.y, v.z); }

    private static RelaxVec3 crossD(RelaxVec3 a, RelaxVec3 b) {
        return RelaxVec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
                         a.x * b.y - a.y * b.x);
    }

    private static RelaxVec3 unitOrZero(RelaxVec3 v) {
        const len = v.length();
        return len > 0 ? v * (1.0 / len) : RelaxVec3(0, 0, 0);
    }

    /// lockSharp's edge classification: an interior edge whose two face
    /// normals ((P1 − P0) × (P2 − P0)) dot below cos(threshold°), or any
    /// non-manifold edge with two or more faces.
    private static bool[] sharpEdgesAtPositions(const ref Mesh subject,
            float thresholdDeg, const(Vec3)[] positions) {
        import std.math : cos, PI;
        auto normals = new Vec3[](subject.faces.length);
        foreach (fi, f; subject.faces) {
            if (f.length < 3) { normals[fi] = Vec3(0, 1, 0); continue; }
            const Vec3 n = cross(positions[f[1]] - positions[f[0]],
                                 positions[f[2]] - positions[f[0]]);
            const float len = n.length;
            normals[fi] = len > 1e-9f ? n * (1.0f / len) : Vec3(0, 1, 0);
        }
        auto sharp = new bool[](subject.edges.length);
        const float cosThreshold = cos(thresholdDeg * (PI / 180.0f));
        foreach (li, ref loop; subject.loops) {
            if (loop.twin == uint.max || cast(uint)li > loop.twin ||
                li >= subject.loopEdge.length) continue;
            const uint ei = subject.loopEdge[li];
            if (ei < sharp.length && dot(normals[loop.face],
                    normals[subject.loops[loop.twin].face]) < cosThreshold)
                sharp[ei] = true;
        }
        foreach (ei; 0 .. sharp.length) {
            if (!subject.isEdgeNonManifold(cast(uint)ei)) continue;
            size_t faces;
            foreach (fi; subject.facesAroundEdge(cast(uint)ei)) ++faces;
            if (faces >= 2) sharp[ei] = true;
        }
        return sharp;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `RecordedUndo.arm` raises the flag
        // only for a NON-EMPTY delta, and `Command.revert` answers both the
        // empty-edit case and the never-applied case before this body runs. The
        // hand-rolled `setVertexPositions(touchedIdx, touchedPrev)` fallback that
        // used to sit under this line was reachable ONLY on `!armed()`, so it is
        // gone with the predicate that reached it.
        undo_.revert(*mesh);
    }
}
