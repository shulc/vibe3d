module tools.edit.preview_rebuild;

import mesh : Mesh;
import snapshot : MeshSnapshot;

// ---------------------------------------------------------------------------
// PreviewRebuild — the shared seam for "restore the clean cage and re-run the
// kernel", used by the interactive topology-creating tools (task 1620).
//
// THE DEFECT THIS EXISTS TO REMOVE. Those tools rebuild their live preview by
//
//     before.restore(*mesh);            // tear the created topology down
//     mesh.<kernel>(mask, params...);   // create it again
//
// on EVERY frame of a drag. On the frames where only a POSITION parameter
// moved, the topology that comes back is structurally the same one that was
// just torn down — the same operand elements, the same created vertices, the
// same created faces — so the work buys nothing. It is not free, though: both
// halves publish a Geometry-class change, so `Mesh.topologyVersion` advances
// twice per frame, and `topologyVersion` is the key the subpatch preview uses
// to decide whether its INDEX SPACE still holds. A moved key makes
// `SubpatchPreview.dispatchBuild` drop `active` (deliberately, and documented
// there: while a build is in flight the CAGE must be what is drawn AND what is
// picked, so a click in that window answers in cage indices). Frame in —
// subpatch; frame out — cage. That is the flicker the owner found dragging an
// extend handle on a subdiv mesh, measured on the live editor as: plain
// move/rotate/scale do NOT flicker (position-only, no dispatch by
// construction), while extend / extrude / bevel do.
//
// THE SPLIT. A rebuild is separated into the two cases by a TOPOLOGY KEY:
//
//   * key unchanged  — the created topology is the same one already standing.
//     Re-run the kernel against a PRIVATE clean-cage copy, and transplant the
//     resulting vertex POSITIONS onto the live mesh. The live mesh's topology
//     is never torn down, so `topologyVersion` does not move, so no dispatch
//     happens and the preview keeps its index space.
//   * key changed    — the topology really is different. Do exactly what the
//     tools did before: restore the live mesh and re-run the kernel on it.
//     One dispatch here is CORRECT.
//
// WHAT BELONGS IN THE KEY, and why each tool declares its own rather than a
// central helper inferring it. The key is not "the parameters that are not
// being dragged" — it is **whatever the kernel consults to decide how many
// elements exist**, INCLUDING its own degenerate branches. Both bevels carry
//
//     if (width_ == 0.0f)                    { ... }   // edge_bevel
//     if (inset_ == 0.0f && shift_ == 0.0f)  { ... }   // poly_bevel
//
// and crossing zero makes the bevel geometry appear and disappear. A key of
// (mask, roundLevel) alone is therefore WRONG: drag the width down through
// zero and back and the key never moves while the topology moves twice. So
// `degenerate` is a field of the key, on the same footing as the counts. A
// central guess at "the topology parameters" is exactly what would miss it.
//
// A WRONG KEY COSTS PERFORMANCE, NEVER CORRECTNESS. The placement path does
// not trust the key: it hashes the topology the kernel just produced on the
// scratch and compares it against the topology hash recorded at the last full
// rebuild. A mismatch falls back to the full path (and counts itself in
// `keyMisses`), so a tool that under-declares its key degrades to the old
// behaviour instead of transplanting a position array onto a topology it does
// not belong to. `keyMisses` is what a test asserts to pin the key ITSELF;
// the dispatch count alone cannot, precisely because this guard rescues it.
//
// COST. The placement path pays one snapshot restore + one kernel run (the
// same two the old code paid) + one topology hash + one position copy, and it
// SAVES the live mesh's full GPU re-upload and the subpatch preview's rebuild
// — which is the dominant cost on the meshes where the flicker was visible.
// The key-changed path pays one EXTRA restore (into the scratch, to read the
// operand mask off the clean cage before the key is known). That frame is
// doing a full topology rebuild anyway, and key changes are rare by
// construction.
// ---------------------------------------------------------------------------

/// What a tool declares its preview TOPOLOGY to depend on.
///
/// `degenerate` is the kernel's own "build nothing" branch — see the header:
/// it is part of the key, not a special case beside it. `operand` is a digest
/// of the operand mask (WHICH elements are built from). `counts` carries the
/// tool's topology scalars (segments / round level / grouping / …); unused
/// slots stay 0.
struct PreviewTopologyKey {
    bool    degenerate;
    ulong   operand;
    long[4] counts;

    /// Build a key. `operandMask` is the mask the kernel would run on, read
    /// off the CLEAN CAGE (which is what `PreviewRebuild.run` hands the
    /// declaring delegate).
    static PreviewTopologyKey make(in bool[] operandMask, bool degenerate,
                                   long c0 = 0, long c1 = 0,
                                   long c2 = 0, long c3 = 0) {
        PreviewTopologyKey k;
        k.degenerate = degenerate;
        k.operand    = operandDigest(operandMask);
        k.counts     = [c0, c1, c2, c3];
        return k;
    }
}

/// FNV-1a over the SET indices of a mask (plus its length), so both "a
/// different element" and "a different element count" move the digest.
ulong operandDigest(in bool[] mask) {
    ulong h = 0xcbf29ce484222325UL;
    static void mix(ref ulong h, ulong x) {
        h ^= x;
        h *= 0x100000001b3UL;
    }
    mix(h, mask.length);
    foreach (i, on; mask)
        if (on) mix(h, i);
    return h;
}

/// FNV-1a over a mesh's element COUNTS + face rings + edge tuples. Positions
/// are deliberately absent: this is the quantity the placement path must find
/// unchanged, and it changes only when the topology does.
ulong topologyDigest(ref const Mesh m) {
    ulong h = 0x9e3779b97f4a7c15UL;
    static void mix(ref ulong h, ulong x) {
        h ^= x;
        h *= 0x100000001b3UL;
    }
    mix(h, m.vertices.length);
    mix(h, m.faces.length);
    mix(h, m.edges.length);
    foreach (ref f; m.faces) {
        mix(h, f.length);
        foreach (vi; f) mix(h, vi);
    }
    foreach (ref e; m.edges) {
        mix(h, e[0]);
        mix(h, e[1]);
    }
    return h;
}

/// The three diagnostic counters, copyable out of a tool without dragging its
/// clean-cage scratch along. See `PreviewRebuild` for what each one means.
struct PreviewRebuildCounts {
    ulong fullRebuilds;
    ulong placements;
    ulong keyMisses;
}

/// The rebuild seam itself. A tool holds one of these and calls `run` where it
/// used to write `before.restore(*mesh); mesh.<kernel>(...)`.
struct PreviewRebuild {
    /// Diagnostics — read by tests (and cheap enough to keep unconditionally).
    /// `fullRebuilds` counts the restore-and-rebuild frames (each of which is
    /// a legitimate topology change), `placements` the position-only frames,
    /// and `keyMisses` the frames where the declared key said "same topology"
    /// but the produced topology disagreed. A correctly-declared key never
    /// misses; see the header for why that is the assertion which pins it.
    ulong fullRebuilds;
    ulong placements;
    ulong keyMisses;

    /// Copy the counters out (the struct itself owns a whole Mesh, so it must
    /// not be copied wholesale just to read three numbers).
    PreviewRebuildCounts counts() const {
        return PreviewRebuildCounts(fullRebuilds, placements, keyMisses);
    }

    private bool               hasLast_;
    private PreviewTopologyKey last_;
    private ulong              lastTopology_;
    /// Private clean-cage scratch. Never the mesh on screen, never uploaded,
    /// never picked — the kernel runs on it so the LIVE mesh's topology can
    /// stay standing. Dropped by `reset()` so an inactive tool holds no copy.
    private Mesh               cage_;

    /// Forget the last key + release the scratch. Call from the tool's
    /// session (re)init, deactivate and live-edit cancel: any of those can
    /// leave the live mesh holding topology this seam did not build.
    void reset() {
        hasLast_      = false;
        last_         = PreviewTopologyKey.init;
        lastTopology_ = 0;
        cage_         = Mesh.init;
    }

    /// One preview rebuild.
    ///
    /// `keyOf`   — given the CLEAN CAGE, return the topology key for the
    ///             parameters as they now stand.
    /// `kernel`  — given a mesh that IS the clean cage, apply the tool's
    ///             kernel to it and return the kernel's own count (0 = built
    ///             nothing, which is also what a degenerate branch returns).
    ///             It must not restore anything itself.
    ///
    /// Returns the kernel's count, so the caller's `built = (n != 0)` reads
    /// exactly as it did before.
    size_t run(ref Mesh live, ref const MeshSnapshot before,
               scope PreviewTopologyKey delegate(ref Mesh cage) keyOf,
               scope size_t delegate(ref Mesh target) kernel) {
        if (!before.filled) return 0;

        before.restore(cage_);
        const key = keyOf(cage_);

        if (!hasLast_ || key != last_)
            return fullRebuild(live, before, key, kernel);

        const size_t n = kernel(cage_);

        // The key is a CLAIM; this is the check. See the header — a
        // mismatch is a mis-declared key, and it costs a doubled kernel run
        // rather than a corrupted mesh.
        if (cage_.vertices.length != live.vertices.length
            || topologyDigest(cage_) != lastTopology_) {
            ++keyMisses;
            return fullRebuild(live, before, key, kernel);
        }

        live.adoptVertexPositions(cage_.vertices);
        ++placements;
        return n;
    }

    private size_t fullRebuild(ref Mesh live, ref const MeshSnapshot before,
                               ref const PreviewTopologyKey key,
                               scope size_t delegate(ref Mesh target) kernel) {
        before.restore(live);
        const size_t n = kernel(live);
        last_         = key;
        hasLast_      = true;
        lastTopology_ = topologyDigest(live);
        ++fullRebuilds;
        return n;
    }
}
