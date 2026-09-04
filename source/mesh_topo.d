module mesh_topo;

// ---------------------------------------------------------------------------
// The half-edge dart type and the six topology ranges built on it:
// VertexDartRange, FaceEdgeRange, VertexFaceRange, VertexNeighborRange,
// VertexEdgeRange, EdgeFaceRange and AdjacentFaceRange, plus FaceEdge and the
// two helpers they share (the one-shot walk-overrun warning and the CSR
// dedup-append).
//
// Split out of mesh.d (task 0717, audit 0678 §2B-M3 item 3, which asked for
// exactly this and asked for it NOT as a mixin — these are free-standing
// types, not Mesh members). `Loop` comes with them: every one of these ranges
// holds nothing but a `const(Loop)[]` slice, and moving the type is what lets
// this module stand alone instead of importing mesh.d back.
//
// mesh.d re-exports this module (`public import mesh_topo;`), the same way it
// re-exports mesh_gpu, so `import mesh : Loop;` / `mesh.VertexEdgeRange` and
// every other existing spelling resolves unchanged.
//
// The only import back into mesh.d is `version (unittest)`: the two blocks at
// the bottom (EdgeFaceRange's other-endpoint retry on a corrupted fan) build
// a Mesh to reproduce the corruption, and they must live in THIS module
// because they read EdgeFaceRange's private `_tryFrom`. Production code here
// depends on nothing but the language.
// ---------------------------------------------------------------------------

version (unittest) import mesh;
version (unittest) import math : Vec3;

/// Canonical UNDIRECTED edge key: the two vertex indices packed (min, max)
/// into one ulong, min in the high word — so `key >> 32` is the smaller index
/// and `key & 0xFFFF_FFFF` the larger (`Mesh.rebuildEdgesFromFaces` decodes
/// it that way). This is the ONE definition in the tree: task 4066 folded five named
/// bodies, five nested/static ones and seven inline packs into it. mesh.d
/// re-exports this module, so `import mesh` and `import mesh : edgeKey` both
/// reach it.
///
/// The `(vertex, face)`, `(island, vertex)` and `(from, toward)` keys
/// elsewhere in the tree are ORDERED pairs packed the same way and are NOT
/// this function — folding one of those in here would silently canonicalise
/// a direction that its owner depends on.
ulong edgeKey(uint a, uint b) pure nothrow @nogc @safe {
    return a < b ? (cast(ulong)a << 32 | cast(ulong)b)
                 : (cast(ulong)b << 32 | cast(ulong)a);
}

/// Half-edge dart: represents the directed edge vert → next(vert) inside one face.
struct Loop {
    uint vert;   // start vertex of this dart
    uint face;   // face this loop belongs to
    uint next;   // index of the next loop in the same face (CCW)
    uint prev;   // index of the previous loop in the same face

    /// Dart in the adjacent face (reverse direction).
    ///
    /// `~0u` IS OVERLOADED AND MEANS TWO DIFFERENT THINGS. Read this before
    /// using it as a rim test — "no twin" is NOT "open boundary":
    ///
    ///   1. an OPEN BOUNDARY edge  — exactly ONE incident face, and
    ///   2. a NON-MANIFOLD edge    — THREE OR MORE incident faces.
    ///
    /// `buildLoops` puts case 2 here deliberately ("treatment A"): a 3-face
    /// edge has no unique partner to name, so it clears BOTH slots and every
    /// dart on that edge comes out carrying the boundary sentinel. The two
    /// cases are byte-identical here and cannot be told apart from this field.
    ///
    /// Every consumer that asked "is there a twin?" and concluded "border"
    /// therefore answered a 3-face edge WRONG, and there were six of them
    /// (task 1290): the ring walk yielded one face of three, `isEdgeBorder`
    /// said border, the vertex fan walks truncated mid-fan,
    /// `computeEdgeSharpness` called the edge never-sharp,
    /// `computeOrientationFlipMask` treated it as a hard component wall, and
    /// `uv_relax` pinned it as a mesh rim. One conflation, six wrong answers.
    ///
    /// **Ask `Mesh.isEdgeNonManifold(ei)` to separate the two cases.** A
    /// genuine rim test is `twin == ~0u && !isEdgeNonManifold(ei)`; a genuine
    /// count is `edgePolygonCounts` / `edgeFaceUseCounts`, which read off
    /// `faces[]` and cannot undercount. Reaching for a bare `~0u` re-creates
    /// the bug.
    uint twin;
}

// ---------------------------------------------------------------------------
// VertexDartRange
// ---------------------------------------------------------------------------

/// Input range (and forward range via .save) over all half-edge dart indices
/// incident to a given vertex.  Each element is a uint loop index `li` such
/// that `loops[li].vert` equals the start vertex.
///
/// Traversal rule: from the current dart `li`, the next dart around the vertex
/// is `twin(prev(li))`.  The range stops when:
///   - `twin == ~0u`  (boundary edge reached), or
///   - the dart wraps back to the starting dart (full circle), or
///   - the internal safety counter exceeds 1024 (degenerate mesh guard).
///
/// The range holds only a slice of `Loop[]`, not a reference to the whole
/// Mesh, so it is a lightweight value type with no cyclic dependency.
struct VertexDartRange {
    private const(Loop)[] _loops;
    private uint  _start;   // first dart (also the stop sentinel for cycles)
    private uint  _cur;     // current dart
    private bool  _done;
    private uint  _steps;

    private enum uint MAX_STEPS = 1024;

    /// Construct from a loops slice and a starting dart index.
    /// If `startLi == ~0u` the range is immediately empty (isolated vertex).
    this(const(Loop)[] loops, uint startLi) {
        _loops = loops;
        _start = startLi;
        _cur   = startLi;
        _done  = (startLi == ~0u);
        _steps = 0;
    }

    /// True when the range has been exhausted.
    @property bool empty() const { return _done; }

    /// The current dart index.
    @property uint front() const
    in (!_done)
    { return _cur; }

    /// Advance to the next dart around the vertex.
    void popFront()
    in (!_done)
    {
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _done = true; return; }
        // Task 0447 (KEEP-TWIN): a same-direction ("meaning-3") twin shares
        // the tail of `prevLi` instead of reversing it — following it would
        // yield a dart based at the OTHER endpoint (a foreign element). Stop
        // as at a boundary. On a consistently-wound mesh the twin is always
        // antiparallel, so this never fires and the walk is byte-identical.
        if (_loops[twinPrev].vert == _loops[prevLi].vert) { _done = true; return; }
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexDartRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start)
            _done = true;
    }

    /// Save a copy so the range can be used as a ForwardRange.
    @property VertexDartRange save() const { return this; }
}

/// One-time-per-session stderr warning shared by the three half-edge
/// vertex-walk ranges (Dart / Neighbor / Edge). Triggered when a walk
/// fails to return to its starting dart inside MAX_STEPS — typically
/// non-manifold edges in an imported mesh (LWO files commonly share
/// an edge across 3+ faces, which breaks the unique-twin invariant
/// the walk relies on).
///
/// Old behaviour was `debug assert(false, …)`, which crashed debug
/// builds on every degenerate walk; release builds were already
/// gracefully truncating via `_done = true`. The assert was hiding
/// the fact that the underlying topology problem deserves a fix at
/// build-loops time (treat non-manifold edges as boundaries so twins
/// stay well-defined) — log once so the issue stays visible without
/// being a hard stop.
private void warnMaxStepsExceeded(string rangeName) nothrow {
    import log : logWarnOnce;
    import std.format : format;
    try {
        logWarnOnce("mesh", "maxSteps", format(
            "%s: MAX_STEPS exceeded — non-manifold cage edges " ~
            "(walk truncated; selection / loop ops may be incomplete).",
            rangeName));
    } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// FaceEdgeRange
// ---------------------------------------------------------------------------

/// One directed edge of a face: the consecutive vertex pair (a → b).
struct FaceEdge { uint a, b; }

/// Forward range over all consecutive vertex pairs of a face polygon.
/// Yields FaceEdge(face[j], face[(j+1) % N]) for j in 0..N.
struct FaceEdgeRange {
    private const(uint)[] _verts;
    private uint _j;

    this(const(uint)[] verts) { _verts = verts; _j = 0; }

    @property bool      empty() const { return _j >= _verts.length; }
    @property FaceEdge  front() const { return FaceEdge(_verts[_j], _verts[(_j + 1) % _verts.length]); }
    void popFront() { ++_j; }
    @property FaceEdgeRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexFaceRange
// ---------------------------------------------------------------------------

/// Forward range over all faces incident to a vertex.
/// Wraps VertexDartRange and projects each dart to its face index.
struct VertexFaceRange {
    private const(Loop)[]  _loops;
    private VertexDartRange _inner;
    private const(uint)[] _csr;    // task 0447: materialized CSR fallback (see fromCsr)
    private uint   _csrI;
    private bool   _useCsr;

    this(const(Loop)[] loops, uint startLi) {
        _loops = loops;
        _inner = VertexDartRange(loops, startLi);
    }

    /// Task 0447: complete (but arbitrarily ordered) face enumeration for a
    /// vertex whose fan is not `vertexFanOrdered`, built from the CSR
    /// vertex→dart adjacency (`vertDartStart`/`vertDartAdj`), NOT the twin
    /// graph, so it is correct regardless of winding. Exactly one CSR entry
    /// per face incident to `vi` (`loops[li].vert == vi`) — no dedup needed
    /// short of a self-touching degenerate polygon.
    static VertexFaceRange fromCsr(const(Loop)[] loops,
                                    const(uint)[] vertDartStart,
                                    const(uint)[] vertDartAdj,
                                    uint vi)
    {
        VertexFaceRange r;
        r._loops  = loops;
        r._useCsr = true;
        uint[] csr;
        if (vi + 1 < vertDartStart.length)
            foreach (i; vertDartStart[vi] .. vertDartStart[vi + 1])
                csr ~= loops[vertDartAdj[i]].face;
        r._csr = csr;
        return r;
    }

    @property bool empty() const { return _useCsr ? _csrI >= _csr.length : _inner.empty; }
    @property uint front() const { return _useCsr ? _csr[_csrI] : _loops[_inner.front].face; }
    void popFront() { if (_useCsr) ++_csrI; else _inner.popFront(); }
    @property VertexFaceRange save() const { return this; }
}

/// Task 0447 CSR-fallback helper: append `v` to `arr` unless already present.
/// Valence is single-digit to low tens on every real mesh, so a linear scan
/// is cheaper than a set and keeps this dependency-free.
private void csrAddUnique(ref uint[] arr, uint v) nothrow @safe {
    foreach (x; arr) if (x == v) return;
    arr ~= v;
}

// ---------------------------------------------------------------------------
// VertexNeighborRange
// ---------------------------------------------------------------------------

/// Forward range over all vertices directly connected to a vertex by an edge.
/// For boundary vertices emits the extra neighbour at the open end of the fan.
/// Requires buildLoops() (uses vertLoop anchored to the fan start).
struct VertexNeighborRange {
    private const(Loop)[] _loops;
    private uint _start;
    private uint _cur;
    private bool _done;
    private bool _atExtra;
    private uint _steps;
    private enum uint MAX_STEPS = 1024;

    private const(uint)[] _csr;    // task 0447: materialized CSR fallback (see fromCsr)
    private uint   _csrI;
    private bool   _useCsr;

    this(const(Loop)[] loops, uint startLi) {
        _loops   = loops;
        _start   = startLi;
        _cur     = startLi;
        _done    = (startLi == ~0u);
        _atExtra = false;
        _steps   = 0;
    }

    /// Task 0447: complete (but arbitrarily ordered) neighbour enumeration for
    /// a vertex whose fan is not `vertexFanOrdered`. For every CSR dart `li`
    /// at `vi` (one per incident face), BOTH face-local edges touching `vi`
    /// contribute a neighbour — the succ side (`next(li).vert`) and the pred
    /// side (`prev(li).vert`) — deduped, since a shared edge is normally
    /// reached from two faces. This recovers the neighbour whose only darts
    /// are based at the OTHER endpoint (e.g. the hinge's inconsistently-wound
    /// spine), which a dart-succ-only projection would miss.
    static VertexNeighborRange fromCsr(const(Loop)[] loops,
                                        const(uint)[] vertDartStart,
                                        const(uint)[] vertDartAdj,
                                        uint vi)
    {
        VertexNeighborRange r;
        r._loops  = loops;
        r._useCsr = true;
        uint[] csr;
        if (vi + 1 < vertDartStart.length) {
            foreach (i; vertDartStart[vi] .. vertDartStart[vi + 1]) {
                uint li = vertDartAdj[i];
                csrAddUnique(csr, loops[loops[li].next].vert);
                csrAddUnique(csr, loops[loops[li].prev].vert);
            }
        }
        r._csr = csr;
        return r;
    }

    @property bool empty() const { return _useCsr ? _csrI >= _csr.length : _done; }

    @property uint front() const
    in (!empty)
    {
        if (_useCsr) return _csr[_csrI];
        // Main darts: neighbour is the next vertex in the dart.
        // Extra boundary dart: the open-end vertex is prev(cur).vert.
        return _atExtra ? _loops[_loops[_cur].prev].vert
                        : _loops[_loops[_cur].next].vert;
    }

    void popFront()
    in (!empty)
    {
        if (_useCsr) { ++_csrI; return; }
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }
        // Task 0447 (KEEP-TWIN): same-direction ("meaning-3") twin — see
        // VertexDartRange.popFront. Stop as at a boundary (emit the extra
        // open-end neighbour). Never fires on consistent winding.
        if (_loops[twinPrev].vert == _loops[prevLi].vert) { _atExtra = true; return; }
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexNeighborRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start) _done = true;
    }

    @property VertexNeighborRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexEdgeRange
// ---------------------------------------------------------------------------

/// Forward range over all edge indices incident to a vertex.
///
/// Uses vertLoop[vi] (anchored to the open start of the fan by buildLoops) and
/// walks via twin(prev(li)).  For boundary vertices, emits one extra edge at the
/// end — the boundary edge represented by prev(lastDart) — so all incident edges
/// are always yielded, whether the vertex is interior or on a boundary.
struct VertexEdgeRange {
    private const(Loop)[] _loops;
    private const(uint)[] _loopEdge;
    private uint _start;
    private uint _cur;
    private bool _done;
    private bool _atExtra;   // true while emitting the boundary extra edge
    private uint _steps;
    private enum uint MAX_STEPS = 1024;

    private const(uint)[] _csr;    // task 0447: materialized CSR fallback (see fromCsr)
    private uint   _csrI;
    private bool   _useCsr;

    this(const(Loop)[] loops, const(uint)[] loopEdge, uint startLi) {
        _loops    = loops;
        _loopEdge = loopEdge;
        _start    = startLi;
        _cur      = startLi;
        _done     = (startLi == ~0u);
        _atExtra  = false;
        _steps    = 0;
    }

    /// Task 0447: complete (but arbitrarily ordered) edge enumeration for a
    /// vertex whose fan is not `vertexFanOrdered`. For every CSR dart `li` at
    /// `vi` (one per incident face), BOTH face-local edges touching `vi`
    /// contribute — the succ edge (`loopEdge[li]`) and the pred edge
    /// (`loopEdge[prev(li)]`) — deduped, since a shared edge is normally
    /// reached from two faces (this is precisely how the hinge's marked spine
    /// edge shows up from BOTH its incident faces as a pred-edge, with neither
    /// face contributing it as a succ-edge).
    static VertexEdgeRange fromCsr(const(Loop)[] loops, const(uint)[] loopEdge,
                                    const(uint)[] vertDartStart,
                                    const(uint)[] vertDartAdj,
                                    uint vi)
    {
        VertexEdgeRange r;
        r._loops    = loops;
        r._loopEdge = loopEdge;
        r._useCsr   = true;
        uint[] csr;
        if (vi + 1 < vertDartStart.length) {
            foreach (i; vertDartStart[vi] .. vertDartStart[vi + 1]) {
                uint li = vertDartAdj[i];
                csrAddUnique(csr, loopEdge[li]);
                csrAddUnique(csr, loopEdge[loops[li].prev]);
            }
        }
        r._csr = csr;
        return r;
    }

    @property bool empty() const { return _useCsr ? _csrI >= _csr.length : _done; }

    @property uint front() const
    in (!empty)
    {
        if (_useCsr) return _csr[_csrI];
        return _atExtra ? _loopEdge[_loops[_cur].prev] : _loopEdge[_cur];
    }

    void popFront()
    in (!empty)
    {
        if (_useCsr) { ++_csrI; return; }
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }  // boundary: emit extra next
        // Task 0447 (KEEP-TWIN): same-direction ("meaning-3") twin — see
        // VertexDartRange.popFront. Stop as at a boundary (emit the extra
        // open-end edge). Never fires on consistent winding.
        if (_loops[twinPrev].vert == _loops[prevLi].vert) { _atExtra = true; return; }
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexEdgeRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start) _done = true;
    }

    @property VertexEdgeRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// EdgeFaceRange
// ---------------------------------------------------------------------------

/// Forward range over the faces incident to an edge — 1–2 on a manifold edge,
/// and (since task 1290) the TRUE count on a non-manifold one.
/// Finds the dart va→vb by walking darts around va (O(valence)).
/// Yields the face of that dart, then the face of its twin (if not boundary).
struct EdgeFaceRange {
    // Two faces sit inline, which is every manifold edge and therefore every
    // edge on an ordinary mesh: that path allocates nothing, exactly as before
    // task 1290. A third and further face spills to `_spill`, which is
    // allocated ONLY on the non-manifold path.
    private uint[2] _faces;
    private const(uint)[] _spill;
    private uint    _count;
    private uint    _i;

    // Append WITHOUT dedup — `_tryFrom` below pushes a dart's face and its
    // twin's face unconditionally, and it must keep doing so: on a keyhole
    // face (one face listing the edge twice, task 1220) those are the SAME
    // face and the pre-1290 code yielded it twice, which is what
    // `isEdgeBorder`'s "exactly one incident face" reads as NOT a border.
    // Deduping here would silently reclassify every keyhole edge. The one
    // caller that needs dedup (`_collectViaCsr`, which scans both endpoints
    // and so meets each face twice) does its own check.
    private void _push(uint fi) {
        if (_count < _faces.length) _faces[_count] = fi;
        else                        _spill ~= fi;
        ++_count;
    }
    private bool _has(uint fi) const {
        foreach (k; 0 .. _count) if (_faceAt(k) == fi) return true;
        return false;
    }
    private uint _faceAt(uint k) const {
        return k < _faces.length ? _faces[k] : _spill[k - _faces.length];
    }

    this(const(Loop)[] loops, const(uint[2])[] edges,
         const(uint)[] vertLoop, const(bool)[] vertFanOrdered,
         const(uint)[] vertDartStart, const(uint)[] vertDartAdj,
         uint ei)
    {
        _count = 0; _i = 0;
        if (ei >= edges.length) return;
        uint va = edges[ei][0], vb = edges[ei][1];

        // Task 0447 §5/§5.1: gate on the ENDPOINTS' fan-order status, NOT a
        // flag on the edge itself. A same-direction edge leaves BOTH its
        // endpoints' fans unordered; but a single-face boundary edge sitting
        // on an endpoint whose fan is broken elsewhere would carry no flag of
        // its own — the endpoint-status gate catches that case too (measured:
        // 0 undercounts / 0 overcounts on every topology). `_tryFrom` routes
        // through the now-guarded VertexDartRange, which stops early at a
        // same-direction edge and can miss the dart va→vb, so collect the
        // incident faces straight from the CSR (never via `.twin`) instead.
        bool gate = (va >= vertFanOrdered.length || !vertFanOrdered[va])
                 || (vb >= vertFanOrdered.length || !vertFanOrdered[vb]);
        if (gate) {
            _collectViaCsr(loops, vertDartStart, vertDartAdj, va, vb);
            return;
        }

        if (_tryFrom(loops, vertLoop, va, vb)) return;
        // task 0394 (consumer hardening): an inconsistently-wound patch
        // elsewhere in the mesh (e.g. a same-direction shared edge — see the
        // `makePolygonFromVerts` auto-orient fix, which now prevents this
        // going forward, but does nothing for already-corrupt imports/old
        // saves) can corrupt the dart fan at ONE endpoint of an otherwise
        // perfectly fine edge while leaving the OTHER endpoint's fan clean.
        // Retrying from vb before giving up recovers the incident faces in
        // that case instead of silently reporting none (which made Loop
        // Slice's `collectEdgeRing` a silent no-op). On a well-formed mesh
        // the first attempt always succeeds, so this retry never fires
        // there — inert by construction.
        _tryFrom(loops, vertLoop, vb, va);
    }

    /// Task 0447 §5: SDK-faithful remediation for the endpoints-gated path —
    /// collect the faces of the darts INCIDENT to the edge from BOTH endpoints
    /// via the CSR vertex→dart adjacency, never through `.twin` (which is
    /// exactly what is undefined-in-meaning on these edges). A dart at `from`
    /// is incident to this edge when its next vertex is `to`.
    ///
    /// Task 1290 lifted the two-face cap that used to sit here. It was written
    /// as "not overflowing is the contract, enumerating all 3+ faces is out of
    /// scope (§5.2)" — but that cap, together with treatment A's
    /// `twin==~0u`, is what made a 3-face edge answer with ONE face and read
    /// as an open boundary everywhere downstream. `_push` spills past the
    /// inline pair, so this now reports the true incidence; an ordinary
    /// manifold edge still fills only the inline `uint[2]` and allocates
    /// nothing.
    private void _collectViaCsr(const(Loop)[] loops,
                                 const(uint)[] vertDartStart,
                                 const(uint)[] vertDartAdj,
                                 uint va, uint vb)
    {
        void scanFrom(uint from, uint to) {
            if (from + 1 >= vertDartStart.length) return;
            foreach (i; vertDartStart[from] .. vertDartStart[from + 1]) {
                uint li = vertDartAdj[i];
                if (loops[loops[li].next].vert != to) continue;
                if (!_has(loops[li].face)) _push(loops[li].face);
            }
        }
        scanFrom(va, vb);
        scanFrom(vb, va);
    }

    /// Walk darts from `from`, looking for the one whose next vertex is
    /// `to`; on a hit, fills `_faces`/`_count` and returns true.
    private bool _tryFrom(const(Loop)[] loops, const(uint)[] vertLoop,
                           uint from, uint to)
    {
        if (from >= vertLoop.length || vertLoop[from] == ~0u) return false;
        foreach (li; VertexDartRange(loops, vertLoop[from])) {
            if (loops[loops[li].next].vert == to) {
                _push(loops[li].face);
                uint twin = loops[li].twin;
                if (twin != ~0u)
                    _push(loops[twin].face);
                return true;
            }
        }
        return false;
    }

    @property bool empty() const { return _i >= _count; }
    @property uint front() const { return _faceAt(_i); }
    void popFront() { ++_i; }
    @property EdgeFaceRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// EdgeFaceRange — other-endpoint retry on a corrupted half-edge fan (task 0394)
// ---------------------------------------------------------------------------
//
// Reproduces the observed symptom (a real user model, see task 0394): a
// same-direction shared edge SOMEWHERE in a vertex's fan corrupts the
// half-edge rotation anchored at that vertex (vertLoop[v] can end up
// pointing at a dart that doesn't even belong to v — buildLoops' anchor
// walk follows twin(cur) directly instead of twin(prev(cur)), so a
// mispaired twin at the corrupted edge derails it). A perfectly ordinary,
// uncorrupted edge elsewhere in the SAME fan can then have its default
// (edges[ei][0]-first) facesAroundEdge lookup walk straight into the dead
// end and find nothing — exactly what turned Loop Slice into a silent
// no-op. The retry from the OTHER endpoint (whose own fan is untouched)
// recovers the correct, verified-against-ground-truth face set.

unittest { // corrupted fan elsewhere in the SAME hub vertex recovers a clean
           // bystander edge's incident faces via the other-endpoint retry
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,2,0), Vec3(-1,1,0), Vec3(-1,-1,0),
        Vec3(1,-1,0), Vec3(9,9,0),
    ];
    m.faces = [
        [0u,1u,2u],   // face0 -- query edge (0,1) lives here
        [0u,2u,3u],   // face1
        [0u,3u,4u],   // face2
        [0u,4u,5u],   // face3
        [0u,5u,6u],   // face4
        [0u,6u,1u],   // face5 -- closes the fan back to vertex1
        [3u,0u,7u],   // faceBad -- reuses spoke (0,3) in the SAME direction (3→0)
                      // as face1's (3,0): a genuine same-direction shared edge,
                      // corrupting the vertex-0 half-edge fan elsewhere.
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    uint ei01 = m.edgeIndex(0, 1);
    assert(ei01 != ~0u, "edge (0,1) must exist");
    assert(m.edges[ei01][] == [0u, 1u], "sanity: default direction is va=0, vb=1");

    // Non-vacuous: the OLD single-direction lookup (default endpoint only,
    // no retry) genuinely fails on this corrupted fan -- the bug this fixes.
    {
        EdgeFaceRange pOld;
        bool okOld = pOld._tryFrom(m.loops, m.vertLoop, m.edges[ei01][0], m.edges[ei01][1]);
        assert(!okOld, "sanity: single-direction lookup from the default endpoint "
            ~ "must fail on this corrupted fan -- otherwise this test proves nothing");
    }

    // The retry-equipped public API must recover both true incident faces.
    uint[] found;
    foreach (fi; m.facesAroundEdge(ei01)) found ~= fi;
    import std.algorithm : sort, canFind;
    sort(found);
    assert(found == [0u, 5u],
        "facesAroundEdge must recover both faces incident on edge (0,1) via the "
        ~ "other-endpoint retry, not silently report zero");

    // collectEdgeRing (the direct cause of the Loop Slice no-op) is a thin
    // wrapper over facesAroundEdge (mesh.d ~9949) -- it inherits this fix
    // automatically. Not separately re-derived here: constructing a corrupted
    // fan where the retry ALSO recovers a clean quad-quad ring (rather than
    // just triangle incidence) needs a larger fixture without adding coverage
    // over what's proven above; see the follow-up note in the task file.
}

unittest { // well-formed mesh: retry is inert (never fires; the default
           // single-direction lookup always succeeds on its own, so
           // facesAroundEdge's result is byte-identical to before this fix)
    Mesh m = makeCube();
    m.buildLoops();
    foreach (ei; 0 .. cast(uint)m.edges.length) {
        EdgeFaceRange direct;
        bool okDirect = direct._tryFrom(m.loops, m.vertLoop, m.edges[ei][0], m.edges[ei][1]);
        assert(okDirect, "well-formed mesh: default single-direction lookup must "
            ~ "already succeed on every edge -- the retry must never be needed here");

        uint[] viaPublicApi;
        foreach (fi; m.facesAroundEdge(ei)) viaPublicApi ~= fi;
        import std.algorithm : sort;
        auto direct2 = direct._faces[0 .. direct._count].dup;
        sort(direct2);
        auto viaSorted = viaPublicApi.dup;
        sort(viaSorted);
        assert(direct2 == viaSorted,
            "well-formed mesh: facesAroundEdge result must match the plain "
            ~ "single-direction lookup exactly -- the retry must not alter it");
    }
}

// ---------------------------------------------------------------------------
// AdjacentFaceRange
// ---------------------------------------------------------------------------

/// Forward range over all faces that share an edge with a given face.
/// Uses the half-edge twin links directly — no hash map needed.
/// Boundary edges (twin == ~0u) are skipped silently.
/// Each adjacent face is yielded once per shared edge (normally once per face).
struct AdjacentFaceRange {
    private const(Loop)[] _loops;
    private uint _start;  // faceLoop[fi]: first loop of the face
    private uint _cur;    // loop currently pointing at an adjacent face
    private bool _done;

    this(const(Loop)[] loops, uint faceStart) {
        _loops    = loops;
        _start    = faceStart;
        _cur      = faceStart;
        _done     = (faceStart == ~0u);
        if (!_done) _skipInvalid();
    }

    @property bool empty() const { return _done; }

    /// Index of the adjacent face reached via the current loop's twin.
    @property uint front() const
    in (!_done)
    { return _loops[_loops[_cur].twin].face; }

    void popFront()
    in (!_done)
    {
        _cur = _loops[_cur].next;
        if (_cur == _start) { _done = true; return; }
        _skipInvalid();
    }

    @property AdjacentFaceRange save() const { return this; }

private:
    void _skipInvalid() {
        while (_loops[_cur].twin == ~0u) {
            _cur = _loops[_cur].next;
            if (_cur == _start) { _done = true; return; }
        }
    }
}
