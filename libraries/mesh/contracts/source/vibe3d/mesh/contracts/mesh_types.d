module vibe3d.mesh.contracts.mesh_types;

/// A face index that is known to have been read out of a LIVE `faces` array —
/// task 0831, the type that replaces the rule task 0703 could only write in a
/// comment.
///
/// WHAT WENT WRONG WITHOUT IT. Every recorded index in a `MeshOpEntry` is in
/// the space of the mesh immediately before that entry runs forward (see "THE
/// INDEX SPACE OF AN ENTRY" in `mesh_edit_delta.d`). Two kernels recorded the
/// position a dropped face would have held in the array being BUILT instead —
/// `keptFaces.length` / `newFaces.length` rather than the live `fi`. Both
/// expressions are a `uint`, both compiled, and the two spaces read IDENTICALLY
/// whenever exactly one face is dropped, so every test in the suite was green
/// while an edge dissolve returned its faces reversed on undo.
///
/// WHAT THE TYPE ACTUALLY BUYS, stated narrowly so it is not mistaken for more.
/// There is NO implicit `uint` → `FaceIdx`, so a scratch array's `.length` (or
/// any other computed integer) cannot be appended to a `FaceIdx[]` — that is a
/// compile error, and it is exactly the shape of the 0703 defect. The only
/// unremarkable way to obtain one is `Mesh.faceIndices` / `Mesh.faceAppendBase`,
/// both of which read the live array. Anything else has to say
/// `assumeFaceSpace`, which is greppable and reads as the assertion it is.
///
/// WHAT IT DOES NOT BUY. The tag says "minted from a live `faces`", NOT "minted
/// from the RIGHT live `faces`": iterating the array again AFTER the kernel's
/// own rewrite yields indices this type cannot tell from the pre-rewrite ones.
/// That residue is a lifetime question, not a mint question, and no newtype
/// closes it — see the task-0831 census note in `doc/tasks/`.
///
/// Reads are deliberately free. `alias raw this` forwards to `uint`, so
/// `faces[fi]`, `fi < faces.length`, `insertInPlace(fi, …)` and every existing
/// `uint`/`size_t` parameter keep working with no `.raw` at the call site — the
/// same one-way-conversion trick `FaceList` above uses, for the same reason.
struct FaceIdx {
    private uint _v;
    uint raw() const { return _v; }
    alias raw this;

    /// No default: a `FaceIdx` that nobody minted would be face 0, and face 0
    /// is a real face. (Costs `FaceIdx[].length = n`, which nothing needs.)
    @disable this();
    private this(uint v) { _v = v; }

    /// The named escape, for the one caller that genuinely has a raw index and
    /// can justify the space it is in — a test fixture hand-building a delta,
    /// or a decoder reading indices off disk. Deliberately verbose: an
    /// `assumeFaceSpace` in a kernel is a review question, not a conversion.
    static FaceIdx assumeFaceSpace(size_t v) { return FaceIdx(cast(uint)v); }
}

/// The live face-index space of a mesh, as a range — the ordinary mint for
/// `FaceIdx`. `foreach (fi; m.faceIndices)` replaces `foreach (fi; 0 .. n)` /
/// `foreach (fi, ref f; faces)` in the kernels that record a delta, and is what
/// makes the recorded index un-fakeable from a scratch array's length.
struct FaceIdxRange {
    private uint i, n;
    this(uint start, uint count) { i = start; n = count; }
    bool empty() const { return i >= n; }
    FaceIdx front() const { return FaceIdx(i); }
    void popFront() { ++i; }
    size_t length() const { return n - i; }
}

/// Domain a `MeshMap` channel is attached to — which element array its
/// per-element values run parallel to.
///
///   Point      — one value-tuple per vertex (`data.length == vertices.length * dim`).
///   Edge       — one value-tuple per deduplicated edge (`data.length == edges.length * dim`).
///   PolyVertex — one value-tuple per face-corner (per-loop). The discontinuous
///                per-corner domain (UV seams, per-corner color). Corner `c` of
///                face `fi` is loop index `faceLoop[fi] + c` (CSR layout — see
///                `faceCornerLoop`), so `data.length == loops.length * dim`. The
///                loop index space is rebuilt wholesale by `buildLoops`, so the
///                per-corner values must be RELOCATED across face-mutating edits
///                (not merely length-resized): see the two-mechanism lifecycle on
///                `remapPolyVertexMaps` (arity-preserving) and
///                `rebuildPolyVertexAtFace` (arity-changing).
enum MapDomain {
    Point,
    Edge,
    PolyVertex,
}

/// Conventional name of the per-corner (PolyVertex-domain) UV map. Centralised
/// here so import / export / `.v3d` codec all key on the same literal. v1 scope
/// is a SINGLE UV set under this name; additional sets later are additional named
/// PolyVertex maps ("uv2", …) — the registry already supports N named maps, so
/// nothing here forecloses multi-set.
///
/// This domain is LIVE end-to-end as of the UV-maps milestone: assimp import
/// captures per-corner UV (pre-weld, so seams survive the positional weld), the
/// `.v3d` v4 codec round-trips it losslessly, and assimp export re-splits at UV
/// seams. LWO UV import + export remain pending follow-ups (they require
/// extending the out-of-tree LWO writer dependency; see the `meshMaps` field
/// comment and doc/uv_maps_plan.md Stage 6).
enum string kUvMapName = "uv";

/// Reserved name of the subdivision-surface crease-weight map (Edge domain,
/// dim 1) — task 1062. A per-edge scalar in [the stored value, no upper/
/// lower clamp]; 1.0 == the editor UI's 100%. Reserved the same way
/// `kUvMapName` reserves "uv": one name shared by every mesh's crease
/// channel, so a future user-authored edge map is distinguishable from it
/// (the sibling task, 1060, wanted exactly this — see `MapKind` below).
enum string kCreaseWeightMapName = "crease";

/// A `MeshMap` *kind* — a reserved identity for a same-shaped map, so a
/// caller declares (or reads) a map's domain + dimension in ONE place
/// (`kindInfo` below) instead of open-coding them at each call site, and so
/// a reserved channel (uv / creaseWeight) is distinguishable from a future
/// user-authored map of the same domain/dim. Purely additive over `MeshMap`'s
/// existing (name, dim, domain, data) shape (task 1062 / 1060 §1 amendment 1)
/// — this is a lookup table, not a data-layout change.
enum MapKind {
    /// Shape not declared. What a map created through the RAW `addMeshMap`
    /// carries, and what a pre-1069 `.v3d` block's maps read back as. NOT a
    /// synonym for "no map" — it is the honest "nobody said which kind this
    /// is". Every filter that excludes a kind must be written NEGATIVELY, or
    /// it drops every legacy map (task 1069, plan §1).
    unclassified,
    uv,             // PolyVertex, dim 2, reserved name kUvMapName
    vertexWeight,   // Point,      dim 1, caller-supplied name (many per mesh)
    creaseWeight,   // Edge,       dim 1, reserved name kCreaseWeightMapName
    /// A morph channel storing a per-vertex DELTA from the base position
    /// (task 1069). Point, dim 3, caller-supplied name (many per mesh).
    /// Created EMPTY — no vertex has an entry — and an absent entry means
    /// zero displacement, so absent and "entry == (0,0,0)" produce the same
    /// geometry (they differ on the wire and by entry identity only).
    morphRelative,
    /// A morph channel storing a per-vertex absolute POSITION (task 1069).
    /// Point, dim 3, caller-supplied name. Created DENSE — a snapshot of
    /// every base position — and an absent entry means "stay at the base",
    /// which is a DIFFERENT thing from a stored zero. This is the kind for
    /// which the presence channel is geometrically observable.
    morphAbsolute,
}

/// True for the two morph kinds. Exists so kind filters read as one negative
/// test (`!isMorphKind(m.kind)`) instead of two comparisons that the next
/// morph-like kind would silently escape.
bool isMorphKind(MapKind k) pure nothrow @nogc @safe {
    return k == MapKind.morphRelative || k == MapKind.morphAbsolute;
}

/// One `MapKind`'s declared shape. `reservedName` is empty for a kind that
/// allows many independently-named instances per mesh (vertexWeight, and both
/// morph kinds); a non-empty `reservedName` is the one name that kind's
/// channel is created under (uv / creaseWeight — see `kindInfo`'s callers).
///
/// `tracksPresence` and `absentIsZero` are the two properties that actually
/// differ between the two morph kinds (task 1069): they are NOT one kind with
/// a flag, they are two registry members whose declarations differ here.
struct MapKindInfo {
    MapDomain domain;
    ubyte     dim;
    string    reservedName;
    /// Does this kind allocate a `MeshMap.present` channel? False for every
    /// kind whose data is dense by construction — those pay nothing.
    bool      tracksPresence;
    /// What an ABSENT entry means. True ⇒ the zero vector / scalar (so absence
    /// is geometrically invisible); false ⇒ "stay at the base position", which
    /// moves a vertex and is therefore observable in geometry. Vacuous for a
    /// kind that does not track presence.
    bool      absentIsZero;
}

/// `(domain, dim, reservedName, tracksPresence, absentIsZero)` for a
/// `MapKind`. The one place a `MeshMap` kind's shape is declared;
/// `addMeshMapOfKind` and the `debug` asserts on `creaseWeightMap`/etc read it
/// back rather than repeating the tuple. A `final switch`, so a new member
/// cannot be added without declaring its shape here.
MapKindInfo kindInfo(MapKind kind) pure nothrow @nogc @safe {
    final switch (kind) {
        case MapKind.unclassified:
            // dim 0 is deliberately un-constructible: `addMeshMap` rejects
            // `dim == 0`, so `addMeshMapOfKind(MapKind.unclassified)` returns
            // null rather than registering a shapeless map.
            return MapKindInfo(MapDomain.Point, 0, "", false, true);
        case MapKind.uv:
            return MapKindInfo(MapDomain.PolyVertex, 2, kUvMapName, false, true);
        case MapKind.vertexWeight:
            return MapKindInfo(MapDomain.Point, 1, "", false, true);
        case MapKind.creaseWeight:
            return MapKindInfo(MapDomain.Edge, 1, kCreaseWeightMapName, false, true);
        case MapKind.morphRelative:
            return MapKindInfo(MapDomain.Point, 3, "", true, true);
        case MapKind.morphAbsolute:
            return MapKindInfo(MapDomain.Point, 3, "", true, false);
    }
}

