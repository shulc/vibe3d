module mesh_corner_maps;

// ---------------------------------------------------------------------------
// The per-CORNER map vocabulary: what a kernel that rewrites `faces` says
// became of the corners, and the two shapes of value a new corner can take.
//
// WHY THIS MODULE EXISTS (task 0830). Until now "is the per-corner map valid"
// was decided by one arithmetic test — `data.length == loops.length * dim` —
// inside `Mesh.resizePolyVertexMaps`. Length is a PROXY for meaning and it
// failed in both directions, in three separate tasks:
//
//   * length mismatched (task 0690): a local edit to ONE face zeroed the whole
//     mesh's UV, at eighteen different write sites, most of them silently;
//   * length matched by coincidence (task 0697): a face bevel "carried" the map
//     — the cap kept its UN-inset source values (right only at `inset == 0`)
//     and every wall read zero. Worse than a documented drop, because it looks
//     like a working feature;
//   * no channel at all (task 0689): the undo delta replay dropped the plane
//     and needed its own provenance pass to get it back.
//
// The carry MACHINERY was already built (`carryPolyVertexMaps`, per-corner
// since 0697; `growPolyVertexMapsForAppendedCorners`; `remapPolyVertexMaps`).
// What was missing is OBLIGATION: the carry was a kernel's courtesy and the
// length check was the only arbiter. This module is that obligation, as a
// type — `CornerProvenance`. A kernel that rewrites faces states which of five
// things happened to the corners, and a kernel that cannot state a
// correspondence declares the loss BY TYPE (`CornerDrop`) rather than by
// appearing in a comment block.
//
// Split out of mesh.d and re-exported from it (`public import
// mesh_corner_maps;`), the same shape as `mesh_topo` (task 0717), so every
// existing `import mesh : PolyVertexBlend;` call site resolves unchanged.
// ---------------------------------------------------------------------------

/// Provenance of ONE vertex an operation inserted: the blend of ORIGINAL
/// vertices that produced it, as up to four (vertex, weight) pairs with the
/// weights summing to 1 — an edge midpoint uses two, a quad bilerp four.
///
/// Consumed by `Mesh.carryPolyVertexMaps` (per-corner map carry, mechanism (c),
/// task 0682): a corner sitting on an inserted vertex takes the SAME weighted
/// combination of the source face's corner VALUES that its position took of the
/// source face's corner POSITIONS. Four is the ceiling because it covers every
/// insertion the mesh kernels perform (edge split, bilerp); a hypothetical
/// wider blend is rejected by `add` rather than silently truncated to a
/// non-normalised subset (see `full`).
struct PolyVertexBlend {
    uint[4]  src = [~0u, ~0u, ~0u, ~0u];
    float[4] w   = [0.0f, 0.0f, 0.0f, 0.0f];
    ubyte    n   = 0;
    /// True once a 5th source was refused — the record is then unusable and
    /// `carryPolyVertexMaps` leaves such a corner at zero rather than applying
    /// a partial (weights < 1) blend.
    bool     overflow = false;

    void add(uint vertex, float weight) {
        if (n >= 4) { overflow = true; return; }
        src[n] = vertex;
        w[n]   = weight;
        ++n;
    }
}

/// A per-corner value an operation GENERATES rather than inherits — mechanism
/// (e), task 0697. Some measured laws are not a weighted sum of any existing
/// corner: a face bevel's inset ring is the source face's UV POLYGON inset by
/// its own distance, and an extrude wall's swept coordinate is a fresh 0→1
/// parameterisation. Both are still anchored in the source face's own island
/// (`srcFace` + `srcCorner`), which is what keeps them per-island — the value
/// is computed from that face's corner values, never from a global projection.
///
/// Applies to a 2-component (UV-shaped) PolyVertex map ONLY. Both laws are
/// statements about a plane — "inset this polygon", "sweep this coordinate" —
/// and neither has a meaning for a 1-D weight channel or a 3-D colour, so a map
/// of any other `dim` leaves the corner at the honest zero. v1 registers exactly
/// one PolyVertex map (`kUvMapName`, dim 2), so today that branch is unreachable
/// in practice and exists to keep a future channel from being silently mangled.
struct PolyVertexGen {
    enum Law : ubyte {
        /// Inset the source face's UV polygon so every UV edge moves inward by
        /// `amount * uvPerimeter`, and take the vertex at `srcCorner`.
        /// `amount` is the GEOMETRIC ratio `insetDistance / geometricPerimeter`,
        /// computed by the kernel; the map supplies its own `uvPerimeter`, so
        /// the same record serves every 2-D map. Frozen law, fixture cases
        /// `face_bevel_connected*`.
        InsetRing,
        /// Component 0 becomes `amount` (the swept coordinate: 0 on the base
        /// ring, 1 on the top ring); component 1 keeps the value the source
        /// corner already had. Frozen law, fixture case
        /// `face_extrude_uv_sweep_u`.
        SweepU,
    }
    size_t newLoop;    /// which NEW corner, in new-face/new-corner order
    uint   srcFace;    /// OLD face whose island the law reads
    uint   srcCorner;  /// corner index inside that old face
    Law    law;
    float  amount;
}

/// Which measured per-corner UV law an extrude gives its WALLS (task 0697).
/// Both are frozen in tests/fixtures/uv_corner_transfer.json; the reference
/// exposes the choice as a tool attribute, active only while a per-corner map is
/// the current one — which for us is simply "a per-corner map exists", the same
/// condition that makes the carry run at all.
enum UvWallLaw : ubyte {
    /// Each wall corner keeps the value of the base corner it stands over, so a
    /// wall is DEGENERATE in UV (zero area) and no existing value is rewritten.
    /// Frozen as `face_extrude_no_uv_sweep`.
    Copy,
    /// Fresh wall parameterisation: u = 0 on the base ring, u = 1 on the top
    /// ring, v = the base corner's own v. The base corners' original u is
    /// discarded ON THE WALLS (the faces that share those vertices keep theirs).
    /// Frozen as `face_extrude_uv_sweep_u`, and the reference's factory setting —
    /// hence the default.
    SweepU,
}

// ---------------------------------------------------------------------------
// The obligation
// ---------------------------------------------------------------------------

/// WHY a kernel cannot state a corner correspondence — the "v1 DROP set" as a
/// TYPE instead of a comment block (task 0830, plan item 3). The comment in
/// `mesh.d` survives as the explanation of each reason; the declaration is what
/// the code executes, so a family cannot leave or enter the set by an edit to
/// prose.
///
/// A reason is not an excuse: each of these names a measurement that does not
/// exist. Where a law IS measured, the kernel carries (see the fixture
/// `tests/fixtures/uv_corner_transfer.json`), and the standing instruction is
/// that unmeasured behaviour gets captured from the reference, never guessed.
enum CornerDrop : ubyte {
    /// Not a drop. The zero value, so `CornerProvenance.init` cannot pass for a
    /// drop declaration either.
    NotDropped,

    /// Catmull-Clark per-corner interpolation is a stated non-goal for v1.
    /// Every corner of the refined cage is new and no measured law says what a
    /// subdivided corner's UV should be.
    SubdivideNoLaw,

    /// A primitive factory REPLACED the mesh (box / sphere / disc / …). There
    /// is no old corner space to correspond to — the previous mesh is gone.
    /// Reserved for that scenario specifically: task 0901 verified every
    /// create-tool commit path (`tools/create/*`, `mesh_ops/box_geom.d`) is a
    /// one-shot APPEND via `addFace` into the live scene mesh (the "existing
    /// geometry survives" convention every leaf tool documents at its commit
    /// site) — never a wholesale replace — so this reason has no live site
    /// today. It stays in the vocabulary for the day a primitive tool grows
    /// an in-place re-parameterise (a genuine mesh replace).
    PrimitiveRebuild,

    /// The kernel creates a fresh surface whose parameterisation no measured
    /// case covers: edge extrude / vertex extrude / edge extend / smooth shift
    /// / path-extrude. Unlike a FACE extrude (whose two wall laws ARE frozen,
    /// task 0697), no capture of these exists.
    ///
    /// NOT bridge (task 0901 correction — this list used to include it):
    /// `mesh_ops/bridge.d`'s five entry points only ever call `addFace` in
    /// their winding loops, never a bare `faces ~=`, so a bridge is exactly
    /// the tail-append shape `CornerProvenance.Kind.Appended` describes — it
    /// does not touch a single corner outside the faces it adds. Declaring it
    /// a DROP would zero every OTHER face's UV in the mesh just because the
    /// user bridged two edges somewhere else, which is not what the kernel
    /// does; see `declareCornerAppend()`'s call sites in `mesh_ops/bridge.d`.
    SweptSurfaceNoLaw,

    /// A plane cut / edge slice splits faces along a chord, and the kernel that
    /// rebuilds the windings (`rebuildFacesWithChordSplits`) does not track
    /// which old face each chord fragment came from. The LAW is known (it is the
    /// same edge-split lerp Loop Slice uses); what is missing is the source, so
    /// this reason marks work that is available, not a measurement gap.
    ///
    /// ALSO THE TWO ARMS OF `Mesh.edgeSliceEx` THAT SPLIT NO FACE (task 1903
    /// Stage L4-P1): the points-only branch, and the KEEP+FINALIZE arm where
    /// Pass 1 spliced a real vertex into the incident windings and Pass 2's
    /// adjacent-hit guard then refused to split anything. Both run the finalize
    /// tail BY HAND, so `rebuildFacesWithChordSplits`' own declaration never
    /// runs; both changed the corner TOTAL, so `buildLoops` owes a declaration.
    /// They declare the same drop for the same reason — no old-corner
    /// correspondence was tracked across the splice loop — and declaring
    /// anything richer there than the split arm itself manages would make the
    /// degenerate tail carry UVs that a real chord split loses.
    ChordSplitNoSource,

    /// A vertex merge / weld rewrote the windings without recording which old
    /// corner each surviving corner was (`applyVertexRemapAndRebuild`). Same
    /// character as `ChordSplitNoSource`: a machinery gap, not a law gap.
    WeldTailNoSource,

    /// A vertex bevel (`bevelVerticesByMask`). Its siblings — edge bevel and
    /// face bevel — left the drop set in task 0697 against frozen cases; this
    /// one has no frozen case at all, so there is nothing to port it against.
    VertexBevelNoCase,

    /// The subpatch cage / preview build produces a DIFFERENT mesh alongside the
    /// cage rather than editing it, and the per-corner plane of the preview is
    /// not addressed by anything today.
    ///
    /// Unused in practice (task 0901 verified): `subpatch_osd.d`'s cage
    /// parameter is `ref const Mesh` (the language forbids mutating it) and
    /// its preview mesh is always either a fresh `out Mesh` (`buildPreview`)
    /// or a `ref Mesh preview` whose hot per-frame `refresh()` path writes
    /// only `preview.vertices` — `preview.faces` is never touched after the
    /// initial build, and no caller ever registers a PolyVertex map on a
    /// preview mesh, so `resizePolyVertexMaps` never even runs against a live
    /// map for it. Kept for the day a preview channel carries one.
    SubpatchCage,

    /// The undo/redo delta replay's fallback: the replay normally carries the
    /// plane itself (`mesh_edit_delta.CornerCarry`, task 0689) and reaches this
    /// only when the carry DECLINES — no map, maps out of step with `faces` at
    /// replay entry, or its own provenance self-check fired.
    DeltaReplayDeclined,

    /// A remesh / decimate / import replaced the topology wholesale from an
    /// external solver that reports no correspondence back.
    ///
    /// Unused in practice (task 0901 verified): `remesh/region_stitch.d` and
    /// `remesh/remesh_job.d` hand their result back as raw `Vec3[]`/`uint[][]`
    /// arrays, never a `Mesh`, and `commands/mesh/remesh.d` assembles those
    /// into a brand-new `Mesh result` (`Mesh.init`, no map ever attached) and
    /// then does `*mesh = result` — the same whole-mesh replace as
    /// `commands/mesh/subdivide.d`, so the map disappears with the old mesh
    /// rather than being dropped by this reason. Kept for a future in-place
    /// foreign-topology rewrite (a decimator that edits `faces` without
    /// replacing the `Mesh` value).
    ForeignTopology,
}

/// What became of the CORNERS across a `faces` rewrite — the declaration a
/// kernel owes the per-corner map plane, and the thing
/// `Mesh.resizePolyVertexMaps` consumes instead of inferring from length.
///
/// FIVE SHAPES, and they are exhaustive because they are the five things that
/// can happen to a corner space:
///
///   Unchanged  every corner keeps its slot AND its meaning. A vertex repoint
///              (`spinEdge`, an extrude's inset) is this: the corner still is
///              the same corner of the same face, it just names a different
///              vertex. Per-corner values are addressed by (face, corner), so
///              nothing moves.
///   Appended   the pre-existing corners keep slot and order, and N brand-new
///              corners arrive at the TAIL. Growth is a SPECIAL CASE of
///              correspondence — identity on the prefix, "new" on the suffix —
///              not a different mechanism; it earns its own shape only because
///              materialising the identity prefix would be O(corners) per
///              appended face.
///   Relocated  a flat `oldLoopOfNewLoop` in new-face/new-corner order: each new
///              corner names the old corner it came from, or `~0u` for "new".
///              Mechanisms (a) and (b).
///   Carried    `Relocated` plus the two things a pure relocation cannot say: a
///              corner standing on an INSERTED vertex (a weighted blend of old
///              corners) and a corner whose value the kernel COMPUTES
///              (`PolyVertexGen`). Mechanisms (c), (c') and (e).
///   Dropped    the kernel cannot state a correspondence and says so, with a
///              reason. The plane comes out length-correct and ZERO.
///
/// The default-constructed value is `Undeclared`, which is not any of the five:
/// it is the state of a kernel that has said nothing. `Mesh.declareCornerProvenance`
/// refuses it at entry, and a face rewrite that reaches `buildLoops` while still
/// undeclared drops the plane rather than keeping values whose meaning nobody
/// vouched for.
struct CornerProvenance {
    /// The five shapes plus the not-a-shape. `Undeclared` is deliberately the
    /// zero value: a field of this type, a `.init`, or a forgotten assignment
    /// all read as "nothing was said", never as a valid claim.
    enum Kind : ubyte { Undeclared, Unchanged, Appended, Relocated, Carried, Dropped }

    /// The six arguments mechanism (c') resolves a carry from, kept together so
    /// the declaration can be stored and applied as ONE value. All tail-const:
    /// the payload is read, never written, and the struct stays assignable
    /// (a top-level `const` field would disable `opAssign` and the declaration
    /// could not be stored on the mesh at all).
    struct Carry {
        const(uint[])[]        newFaces;
        const(uint)[]          srcFaceOfNewCorner;
        const(uint[])[]        oldFaces;
        const(uint)[]          oldFaceLoop;
        PolyVertexBlend[uint]  blendOfNewVertex;
        const(PolyVertexGen)[] gens;
    }

    // Private so the ONLY way to obtain a declaration is to name one of the
    // factories below — "you cannot rewrite faces without saying what became of
    // the corners" is enforced by the type, not by review.
    private Kind          kind_    = Kind.Undeclared;
    private CornerDrop    why_     = CornerDrop.NotDropped;
    private size_t        corners_ = size_t.max;   // size_t.max ⇒ not stated
    private const(uint)[] oldLoopOfNewLoop_;
    private Carry         carry_;

    Kind          kind()    const { return kind_; }
    CornerDrop    why()     const { return why_; }
    /// The Σ-arity the declaration describes, or `size_t.max` when the shape
    /// does not state one (`Unchanged`, `Dropped`). A stated total that
    /// disagrees with `loops.length` at `buildLoops` time means the kernel
    /// described a corner space it did not end in — see `resizePolyVertexMaps`.
    size_t        corners() const { return corners_; }
    bool          declared() const { return kind_ != Kind.Undeclared; }
    const(uint)[] oldLoopOfNewLoop() const { return oldLoopOfNewLoop_; }
    /// The carry payload, by reference and `inout` so the applier sees exactly
    /// the constness it was handed (`Carry`'s fields are tail-const; a plain
    /// `const` accessor would const-qualify the OUTER slices and stop the
    /// payload converting back to the applier's parameter types).
    ref inout(Carry) carry() inout return { return carry_; }

    // --- the five factories ------------------------------------------------

    /// Every corner keeps its slot and its meaning.
    static CornerProvenance unchanged() {
        CornerProvenance p;
        p.kind_ = Kind.Unchanged;
        return p;
    }

    /// Brand-new corners at the tail; every pre-existing corner untouched.
    /// `newTotalCorners` is the Σ-arity AFTER the append, not the number
    /// appended — stated as a TOTAL so the declaration is idempotent: a kernel
    /// that already grew the plane face-by-face (`Mesh.appendFaceRaw`) and one
    /// that appended with a bare `faces ~= …` and states the growth once at the
    /// end reach the same place, and the total is cross-checkable against
    /// `loops.length` the way every other stated total is.
    static CornerProvenance appended(size_t newTotalCorners) {
        CornerProvenance p;
        p.kind_    = Kind.Appended;
        p.corners_ = newTotalCorners;
        return p;
    }

    /// `oldLoopOfNewLoop[newCorner] = oldCorner`, or `~0u` for a new corner.
    static CornerProvenance relocated(const(uint)[] oldLoopOfNewLoop) {
        CornerProvenance p;
        p.kind_             = Kind.Relocated;
        p.oldLoopOfNewLoop_ = oldLoopOfNewLoop;
        p.corners_          = oldLoopOfNewLoop.length;
        return p;
    }

    /// Mechanism (c') — the per-corner source, blends and generated values.
    /// `corners` is derived from the new windings, so a caller cannot state a
    /// total that disagrees with the correspondence it just handed over.
    static CornerProvenance carried(Carry c) {
        CornerProvenance p;
        p.kind_  = Kind.Carried;
        p.carry_ = c;
        size_t total = 0;
        foreach (nf; c.newFaces) total += nf.length;
        p.corners_ = total;
        return p;
    }

    /// No correspondence can be stated, and here is why.
    static CornerProvenance dropped(CornerDrop why) {
        CornerProvenance p;
        p.kind_ = Kind.Dropped;
        p.why_  = why;
        return p;
    }
}

// The type's own contract, asserted here rather than in a kernel's test: the
// default value is not a declaration, each factory produces exactly its own
// shape, and a stated corner total is derived from the correspondence rather
// than taken on the caller's word.
unittest {
    CornerProvenance none;
    assert(!none.declared());
    assert(none.kind() == CornerProvenance.Kind.Undeclared);
    assert(none.why()  == CornerDrop.NotDropped);
    assert(none.corners() == size_t.max);

    assert(CornerProvenance.unchanged().declared());
    assert(CornerProvenance.unchanged().kind() == CornerProvenance.Kind.Unchanged);

    // `appended` states the total AFTER the append, so it is cross-checkable
    // against `loops.length` and re-declaring it cannot grow the plane twice.
    const app = CornerProvenance.appended(7);
    assert(app.kind() == CornerProvenance.Kind.Appended);
    assert(app.corners() == 7);
    assert(CornerProvenance.unchanged().corners() == size_t.max);

    const uint[] rel = [0u, 1u, ~0u, 3u];
    const r = CornerProvenance.relocated(rel);
    assert(r.kind() == CornerProvenance.Kind.Relocated);
    assert(r.corners() == 4);
    assert(r.oldLoopOfNewLoop() == rel);

    // `carried` counts the corners of the windings it was given — a caller
    // cannot overstate the space its correspondence covers.
    CornerProvenance.Carry c;
    c.newFaces = [[0u, 1u, 2u], [2u, 1u, 3u, 4u]];
    const car = CornerProvenance.carried(c);
    assert(car.kind() == CornerProvenance.Kind.Carried);
    assert(car.corners() == 7);

    const d = CornerProvenance.dropped(CornerDrop.SubdivideNoLaw);
    assert(d.declared());
    assert(d.kind() == CornerProvenance.Kind.Dropped);
    assert(d.why()  == CornerDrop.SubdivideNoLaw);
    // A drop states no corner total — it is the shape that cannot describe one.
    assert(d.corners() == size_t.max);
}
