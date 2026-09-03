module snapshot;

import std.algorithm.iteration : map;
import std.array : array;

import mesh;
import math;
import change_bus : MeshChangeAll;
import perf_probe : g_perf, Cat;

// ---------------------------------------------------------------------------
// MeshSnapshot — full pre-apply mesh + selection + subpatch state, used by
// commands whose revert() needs to restore "whatever the mesh looked like
// before". Captures everything via .dup so subsequent mesh mutations don't
// alias the snapshot.
//
// Heavyweight (~MB for large meshes); commands that only mutate a small
// slice (e.g. mesh.move_vertex, subpatch_toggle) should snapshot only the
// affected fields instead of using this helper.
//
// Note: Command instances hold their editMode by value (not ref), so
// the snapshot doesn't capture or restore edit mode here. If a command
// changes editMode (none currently do — that's a tool / app.d concern),
// it must handle that separately.
// ---------------------------------------------------------------------------

struct MeshSnapshot {
    Vec3[]   vertices;
    uint[2][] edges;
    uint[][] faces;
    // Packed per-element flag words (selection + subpatch + any future
    // reserved bits) — the same representation the mesh stores. faceMarks
    // carries both the Select and Subpatch bits, so subpatch round-trips
    // automatically and new mark bits need no snapshot change.
    uint[]   vertexMarks;
    uint[]   edgeMarks;
    uint[]   faceMarks;
    int[]    vertexSelectionOrder;
    int[]    edgeSelectionOrder;
    int[]    faceSelectionOrder;
    int      vertexSelectionOrderCounter;
    int      edgeSelectionOrderCounter;
    int      faceSelectionOrderCounter;
    Surface[] surfaces;
    uint[]    faceMaterial;
    uint[]    facePart;
    MeshMap[] meshMaps;
    // Selection sets (task 1060) — mesh METADATA, same class as facePart /
    // meshMaps above, so they capture/restore alongside them rather than
    // riding the selection-only SelectionSnapshot below. `edgeSetMask` is an
    // associative array: a plain struct-copy ALIASES it (D AAs are reference
    // types), so `.dup` here is not optional — without it, mutating the live
    // mesh's edge-set registry after capture would silently mutate this
    // snapshot too, and an undo would then restore whatever the live mesh
    // most recently did instead of the pre-apply state. `meshMaps.dup` above
    // sets the identical precedent for the array case.
    string[]     vertexSetNames;
    ulong[]      vertexSetMask;
    string[]     edgeSetNames;
    ulong[ulong] edgeSetMask;
    bool[ulong]  wireEdgeKeys;
    string[]     polygonSetNames;
    ulong[]      faceSetMask;
    bool     filled = false;

    /// Destructive descriptor transfer used by prepared owners. The source is
    /// cleared in the same nonallocating operation, so ownership cannot remain
    /// aliased across owner and installed tool state.
    void moveInto(ref MeshSnapshot destination) nothrow @nogc {
        destination = this;
        this = MeshSnapshot.init;
    }

    /// Detached duplicate for prepared images that must retain a witness while
    /// a command independently owns the snapshot it will later install.
    MeshSnapshot ownedDup() const {
        MeshSnapshot s;
        s.vertices = vertices.dup;
        s.edges = edges.dup;
        s.faces = faces.map!(f => f.dup).array;
        s.vertexMarks = vertexMarks.dup;
        s.edgeMarks = edgeMarks.dup;
        s.faceMarks = faceMarks.dup;
        s.vertexSelectionOrder = vertexSelectionOrder.dup;
        s.edgeSelectionOrder = edgeSelectionOrder.dup;
        s.faceSelectionOrder = faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter = edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter = faceSelectionOrderCounter;
        s.surfaces = surfaces.dup;
        s.faceMaterial = faceMaterial.dup;
        s.facePart = facePart.dup;
        s.meshMaps = meshMaps.map!(mm => mm.dup).array;
        s.vertexSetNames = vertexSetNames.dup;
        s.vertexSetMask = vertexSetMask.dup;
        s.edgeSetNames = edgeSetNames.dup;
        s.edgeSetMask = edgeSetMask.dup;
        s.wireEdgeKeys = wireEdgeKeys.dup;
        s.polygonSetNames = polygonSetNames.dup;
        s.faceSetMask = faceSetMask.dup;
        s.filled = filled;
        return s;
    }

    /// Exact, allocation-free witness that the live mesh still has the full
    /// projection captured by `capture`. Prepared owners use this at commit:
    /// a version counter is insufficient because several legitimate paths
    /// write mesh storage directly without advancing it.
    bool matches(in Mesh mesh) const nothrow @nogc {
        if (!filled || vertices != mesh.vertices || edges != mesh.edges ||
            vertexMarks != mesh.vertexMarks || edgeMarks != mesh.edgeMarks ||
            faceMarks != mesh.faceMarks ||
            vertexSelectionOrder != mesh.vertexSelectionOrder ||
            edgeSelectionOrder != mesh.edgeSelectionOrder ||
            faceSelectionOrder != mesh.faceSelectionOrder ||
            vertexSelectionOrderCounter != mesh.vertexSelectionOrderCounter ||
            edgeSelectionOrderCounter != mesh.edgeSelectionOrderCounter ||
            faceSelectionOrderCounter != mesh.faceSelectionOrderCounter ||
            surfaces != mesh.surfaces || faceMaterial != mesh.faceMaterial ||
            facePart != mesh.facePart || meshMaps != mesh.meshMaps ||
            vertexSetNames != mesh.vertexSetNames ||
            vertexSetMask != mesh.vertexSetMask ||
            edgeSetNames != mesh.edgeSetNames ||
            edgeSetMask != mesh.edgeSetMask ||
            wireEdgeKeys != mesh.wireEdgeKeys ||
            polygonSetNames != mesh.polygonSetNames ||
            faceSetMask != mesh.faceSetMask || faces.length != mesh.faces.length)
            return false;
        foreach (i, face; faces)
            if (face != mesh.faces[i]) return false;
        return true;
    }

    /// Exact deep projection comparison for prepared owners that retain both
    /// a live-state witness and a detached session baseline.
    bool matches(in MeshSnapshot other) const nothrow @nogc {
        if (filled != other.filled || vertices != other.vertices ||
            edges != other.edges || vertexMarks != other.vertexMarks ||
            edgeMarks != other.edgeMarks || faceMarks != other.faceMarks ||
            vertexSelectionOrder != other.vertexSelectionOrder ||
            edgeSelectionOrder != other.edgeSelectionOrder ||
            faceSelectionOrder != other.faceSelectionOrder ||
            vertexSelectionOrderCounter != other.vertexSelectionOrderCounter ||
            edgeSelectionOrderCounter != other.edgeSelectionOrderCounter ||
            faceSelectionOrderCounter != other.faceSelectionOrderCounter ||
            surfaces != other.surfaces || faceMaterial != other.faceMaterial ||
            facePart != other.facePart || meshMaps != other.meshMaps ||
            vertexSetNames != other.vertexSetNames ||
            vertexSetMask != other.vertexSetMask ||
            edgeSetNames != other.edgeSetNames || edgeSetMask != other.edgeSetMask ||
            wireEdgeKeys != other.wireEdgeKeys ||
            polygonSetNames != other.polygonSetNames ||
            faceSetMask != other.faceSetMask || faces.length != other.faces.length)
            return false;
        foreach (i, face; faces) if (face != other.faces[i]) return false;
        return true;
    }

    static MeshSnapshot capture(in Mesh mesh) {
        MeshSnapshot s;
        s.vertices             = mesh.vertices.dup;
        s.edges                = mesh.edges.dup;
        // .range needed because the templated `map!` instantiation
        // through `alias this` can't carry const(FaceList) cleanly.
        s.faces                = mesh.faces.range.map!(f => f.dup).array;
        s.vertexMarks          = mesh.vertexMarks.dup;
        s.edgeMarks            = mesh.edgeMarks.dup;
        s.faceMarks            = mesh.faceMarks.dup;
        s.vertexSelectionOrder = mesh.vertexSelectionOrder.dup;
        s.edgeSelectionOrder   = mesh.edgeSelectionOrder.dup;
        s.faceSelectionOrder   = mesh.faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = mesh.vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter   = mesh.edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter   = mesh.faceSelectionOrderCounter;
        s.surfaces             = mesh.surfaces.dup;
        s.faceMaterial         = mesh.faceMaterial.dup;
        s.facePart             = mesh.facePart.dup;
        // Deep-dup each map (its `data` too) so later mesh mutations don't
        // alias the snapshot — MeshMap.dup dups the float[] data.
        s.meshMaps             = mesh.meshMaps.map!(mm => mm.dup).array;
        // Selection sets (task 1060). `.dup` on the AA is REQUIRED — a bare
        // `= mesh.edgeSetMask` would alias the live mesh's associative
        // array (see the field's doc comment above).
        s.vertexSetNames        = mesh.vertexSetNames.dup;
        s.vertexSetMask         = mesh.vertexSetMask.dup;
        s.edgeSetNames          = mesh.edgeSetNames.dup;
        s.edgeSetMask           = mesh.edgeSetMask.dup;
        s.wireEdgeKeys          = mesh.wireEdgeKeys.dup;
        s.polygonSetNames       = mesh.polygonSetNames.dup;
        s.faceSetMask           = mesh.faceSetMask.dup;
        s.filled               = true;
        return s;
    }

    /// Stored byte size of everything `capture` duplicated, under the ONE
    /// accounting rule in `source/plane_bytes.d` — the same rule
    /// `MeshEditDelta.byteSize()` uses (task 1903 Stage B, plan §8.2).
    ///
    /// WHY IT EXISTS AT ALL. The §8 measurement is a RATIO: op-log bytes over
    /// snapshot bytes, on a local edit to a large mesh. Until this method there
    /// was no snapshot number to divide by (`grep -c 'byteSize\|sizeof'
    /// source/snapshot.d` → 0), so the "is the delta smaller?" question had one
    /// instrument and one guess.
    ///
    /// WHAT IT MUST NOT MISS, and why each is easy to miss:
    ///   * `meshMaps` — a `MeshMap[]` whose `data` is per-CORNER for a UV map,
    ///     i.e. the largest single term on a real mesh, sitting behind a struct
    ///     array that looks like a small registry;
    ///   * `edgeSetMask` — a `ulong[ulong]`, the one plane whose type looks
    ///     scalar. Rule 3 counts it; a naive walk reads it as zero;
    ///   * the three name registries — arrays of `string`, rule 2 over rule 4.
    /// A snapshot measured on a fixture with no maps and no sets is roughly a
    /// third of its real size, and the ratio then lies IN THE SNAPSHOT's
    /// FAVOUR — which is why the §8 stand is `makeTaggedGridFull` and not a
    /// cube.
    ///
    /// WHAT GUARDS THIS METHOD, AND WHERE EACH GUARD STOPS.
    /// `tests/unit/byte_size_test.d` enumerates this struct's fields through
    /// `FieldNameTuple` the same way it enumerates `MeshOpEntry`'s, so a
    /// DYNAMIC ARRAY or AA declared on `MeshSnapshot` itself and left without
    /// a line here reddens. That enumeration is blind in two directions and
    /// both are real: a new SCALAR field is already inside the `.sizeof` term
    /// and needs no line, and a new heap field on a NESTED struct
    /// (`Surface`, `MeshMap`) is invisible to it — the enumeration sees
    /// `meshMaps` as one populated field and cannot tell which of a `MeshMap`'s
    /// members were read. The `static assert`s on the two nested loops below
    /// are what covers that second blind spot, in the spelling `MeshMap.dup`
    /// already uses (`mesh.d`): they are the tripwire for the NEXT field.
    ///
    /// `@nogc` is deliberate and not decoration: a measuring device that
    /// allocates perturbs the GC readout printed beside its own number.
    size_t byteSize() const pure nothrow @safe @nogc {
        import plane_bytes : planeBytes;
        // Rule 5: the struct's own bytes, once. `filled` and the three
        // selection-order counters are scalars and live inside this term.
        size_t n = MeshSnapshot.sizeof;
        n += planeBytes(vertices);
        n += planeBytes(edges);                 // uint[2][] — pairs held INLINE
        n += planeBytes(faces);
        n += planeBytes(vertexMarks);
        n += planeBytes(edgeMarks);
        n += planeBytes(faceMarks);
        n += planeBytes(vertexSelectionOrder);
        n += planeBytes(edgeSelectionOrder);
        n += planeBytes(faceSelectionOrder);
        // Surface[] carries two strings per entry; the array term is the
        // struct bytes, the names are their own heap.
        n += planeBytes(surfaces);
        static assert(Surface.tupleof.length == 7,
            "Surface gained a field — if it is heap-backed, add it to the loop "
          ~ "below before bumping this count. The FieldNameTuple enumeration in "
          ~ "tests/unit/byte_size_test.d sees `surfaces` as ONE populated field "
          ~ "and cannot tell which of a Surface's members were read.");
        foreach (ref sf; surfaces) {
            n += planeBytes(sf.name);
            n += planeBytes(sf.compiledFromTreeId);
        }
        n += planeBytes(faceMaterial);
        n += planeBytes(facePart);
        // MeshMap[] — same shape, and `data` is the term that dominates a real
        // mesh. `present` is the per-element presence channel (empty ⇒ all
        // present), so it is legitimately 0 on most maps and must still be read.
        n += planeBytes(meshMaps);
        static assert(MeshMap.tupleof.length == 6,
            "MeshMap gained a field — if it is heap-backed, add it to the loop "
          ~ "below before bumping this count. Same blind spot as Surface above: "
          ~ "the field enumeration cannot see inside a nested struct, which is "
          ~ "exactly how `present` would go uncounted.");
        foreach (ref mm; meshMaps) {
            n += planeBytes(mm.name);
            n += planeBytes(mm.data);
            n += planeBytes(mm.present);
        }
        n += planeBytes(vertexSetNames);
        n += planeBytes(vertexSetMask);
        n += planeBytes(edgeSetNames);
        n += planeBytes(edgeSetMask);           // ulong[ulong] — rule 3
        n += planeBytes(wireEdgeKeys);
        n += planeBytes(polygonSetNames);
        n += planeBytes(faceSetMask);
        return n;
    }

    void restore(ref Mesh mesh) const {
        // Perf (task 1370): the RESTORE half of every interactive-tool
        // preview rebuild — ~16 array dups, `faces.map!dup`, plus
        // `buildLoops()` + `resizeAllMeshMaps()` below. Timed HERE, once,
        // instead of sixteen times at the `rebuildPreview` sites, so two
        // edits decompose the preview wrapper for every tool that shares it.
        //
        // The category is named for the use that motivated it, but the timer
        // is on the PRIMITIVE: undo/redo restore through here too. That is
        // only sound because the perf lane's window is bounded by
        // `perfReset` and contains nothing but the driven rebuilds — and
        // that is CHECKED, not assumed: invariant I8c in tools/perf/run.d
        // requires previewRestore.count == toolPreview.count exactly, so an
        // unexpected restore inside the window turns the lane red instead of
        // quietly inflating the wrapper's share.
        //
        // No-op in the default build (PerfProbe version gate).
        auto zRestore = g_perf.scope_(Cat.previewRestore);
        mesh.vertices                    = vertices.dup;
        mesh.edges                       = edges.dup;
        mesh.faces                       = faces.map!(f => f.dup).array;
        // Whole-word restore: faceMarks carries Select + Subpatch (+ any
        // reserved bits) together, so this restores the full per-element
        // flag state. Lengths match the geometry restored just above
        // because they were captured alongside it.
        mesh.vertexMarks                 = vertexMarks.dup;
        mesh.edgeMarks                   = edgeMarks.dup;
        mesh.faceMarks                   = faceMarks.dup;
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
        mesh.surfaces                    = surfaces.dup;
        mesh.faceMaterial                = faceMaterial.dup;
        mesh.facePart                    = facePart.dup;
        // Restore the map registry (deep-dup so the live mesh doesn't alias
        // the snapshot's data). buildLoops below rebuilds loops/edges; the
        // restored maps' lengths already match the restored geometry because
        // they were captured alongside it, but resizeAllMeshMaps keeps them
        // correct if buildLoops were ever to change an element count.
        mesh.meshMaps                    = meshMaps.map!(mm => mm.dup).array;
        // Selection sets (task 1060) — restore alongside facePart/meshMaps,
        // `.dup`ing the AA again so the LIVE mesh does not end up aliasing
        // THIS snapshot going forward (symmetric with capture()'s dup).
        mesh.vertexSetNames              = vertexSetNames.dup;
        mesh.vertexSetMask               = vertexSetMask.dup;
        mesh.edgeSetNames                = edgeSetNames.dup;
        mesh.edgeSetMask                 = edgeSetMask.dup;
        mesh.wireEdgeKeys                = wireEdgeKeys.dup;
        mesh.polygonSetNames             = polygonSetNames.dup;
        mesh.faceSetMask                 = faceSetMask.dup;
        // TASK 1906 STAGE 2d — A RESTORE IS A STRUCTURAL CHANGE AND MUST SAY SO.
        //
        // This method writes `edges` and `faces` DIRECTLY, bypassing every
        // structural primitive on `Mesh` (`addEdge`, `rebuildEdges`,
        // `rewriteFaces`), each of which bumps `structVersion` as part of its
        // contract. The restore did not, so `structVersion` was the one counter
        // an undo could leave lying: the op bumped it on the way out and the
        // undo silently reverted the connectivity underneath it.
        //
        // That was survivable while `structVersion`'s only consumers stamped
        // themselves inside the same call (`loopsStamp`, `edgeMapStamp` — both
        // re-stamped by the `buildLoops()` immediately below, which is why the
        // bump goes BEFORE it and not after). It stopped being survivable when
        // stage 2d re-keyed two caches that outlive the call onto it —
        // `Mesh.vertexAdjacencyCSR`'s memo and `PenSnapGuide.polyCount_` — and
        // an undo that changes the edge list while the vertex count holds
        // (drop two adjacent faces, undo) would serve the pre-undo answer.
        // MEASURED, not reasoned: before this bump the restore left
        // `structVersion` at delta 0 while `mutationVersion` moved by 1.
        ++mesh.structVersion;
        mesh.buildLoops();
        mesh.resizeAllMeshMaps();
        // Snapshot restore rebuilds the WHOLE mesh — geometry, topology, marks
        // and materials may all have changed across the undo/redo. Emit the
        // bulk All mask (which includes Geometry, so the stamp bumps both
        // mutationVersion and topologyVersion exactly as the old two lines did).
        //
        // `commitRestored`, not `commitChange` (task 1903 §3.2 S4): this is a
        // WHOLE-STATE restoration, not a mutation site the batch seam is
        // closing, and it fires on every `/api/reset` revert and every
        // snapshot-path undo. Ticking `changeBus.unbatchedGeometryCommits`
        // here would give that counter a moving baseline it could never be
        // asserted against. Everything else — the version bumps, the derive
        // and the delivery — is identical.
        mesh.commitRestored(MeshChangeAll);
    }

    // -------------------------------------------------------------------------
    // restoreGeometryKeepSelection — geometry-only revert while selection is
    // represented by its own history records.
    //
    // A geometry-move undo must
    // NOT overwrite the live selection with the pre-move snapshot's selection.
    // This method restores positions, edges, faces, surfaces, faceMaterial, and
    // meshMaps — but KEEPS the current selection marks (vertexMarks, edgeMarks,
    // faceMarks) and selection-order counters.
    //
    // Topology-safety rule: keeping the current marks is only correct when the
    // op did NOT change element counts (a pure transform leaves vertex/edge/face
    // counts identical to the snapshot). If counts DIFFER (topology-changing op
    // — e.g. edge.extrude / edge.extend that adds vertices), the live marks
    // would index out-of-bounds or address the wrong elements after the revert,
    // so we fall back to the full snapshot marks in that case.
    //
    // Consequence: topology-changing tools that go through ToolDoApplyCommand
    // (edge.extrude, edge.extend) still restore the pre-apply selection when
    // because their vertex/face counts change.
    // That is intentional and correct: there is no "current" selection that is
    // valid against the reverted (smaller) mesh.
    // -------------------------------------------------------------------------
    void restoreGeometryKeepSelection(ref Mesh mesh) const {
        // Capture current marks from the live mesh BEFORE we alter the mesh,
        // so we can re-apply them if topology matches.
        auto liveVertexMarks          = mesh.vertexMarks.dup;
        auto liveEdgeMarks            = mesh.edgeMarks.dup;
        auto liveFaceMarks            = mesh.faceMarks.dup;
        auto liveVertexSelOrder       = mesh.vertexSelectionOrder.dup;
        auto liveEdgeSelOrder         = mesh.edgeSelectionOrder.dup;
        auto liveFaceSelOrder         = mesh.faceSelectionOrder.dup;
        int  liveVertexSelOrderCtr    = mesh.vertexSelectionOrderCounter;
        int  liveEdgeSelOrderCtr      = mesh.edgeSelectionOrderCounter;
        int  liveFaceSelOrderCtr      = mesh.faceSelectionOrderCounter;

        // Restore geometry (positions, topology, materials, maps).
        mesh.vertices     = vertices.dup;
        mesh.edges        = edges.dup;
        mesh.faces        = faces.map!(f => f.dup).array;
        mesh.surfaces     = surfaces.dup;
        mesh.faceMaterial = faceMaterial.dup;
        mesh.facePart     = facePart.dup;
        mesh.meshMaps     = meshMaps.map!(mm => mm.dup).array;
        // Selection sets (task 1060) — mesh metadata like facePart/meshMaps
        // just above, so they restore with GEOMETRY here too, never with the
        // kept live selection marks below.
        mesh.vertexSetNames  = vertexSetNames.dup;
        mesh.vertexSetMask   = vertexSetMask.dup;
        mesh.edgeSetNames    = edgeSetNames.dup;
        mesh.edgeSetMask     = edgeSetMask.dup;
        mesh.wireEdgeKeys    = wireEdgeKeys.dup;
        mesh.polygonSetNames = polygonSetNames.dup;
        mesh.faceSetMask     = faceSetMask.dup;
        // Task 1906 stage 2d — same direct `edges`/`faces` write, same reason,
        // same placement before `buildLoops()`. See `restore` above.
        ++mesh.structVersion;
        mesh.buildLoops();
        mesh.resizeAllMeshMaps();

        // Topology-safety check: keep current marks only when element counts
        // are unchanged (pure transform — no elements added or removed).
        // If topology changed, the snapshot marks are the safe fallback.
        //
        // IMPORTANT: compare the PRE-RESTORE live counts (captured above in
        // liveXxxMarks.length) against the snapshot counts — NOT mesh.xxx.length
        // after the restore.  After restore, mesh.xxx.length trivially equals
        // xxx.length (we just wrote from the snapshot), so the post-restore
        // comparison would always report "unchanged" even for topology-shrinking
        // ops like mesh.reduce, making the live-marks loop walk out-of-bounds
        // when the reduced mesh had fewer elements than the snapshot.
        bool topologyUnchanged =
            liveVertexMarks.length == vertices.length &&
            liveEdgeMarks.length   == edges.length    &&
            liveFaceMarks.length   == faces.length;

        if (topologyUnchanged) {
            // Pure transform: splice the live selection marks back in,
            // preserving the selection that was current when the undo fired.
            mesh.vertexMarks                 = liveVertexMarks;
            mesh.edgeMarks                   = liveEdgeMarks;
            // For faceMarks, preserve the live SELECT bits but restore the
            // SUBPATCH bits from the snapshot (subpatch is geometry-class
            // state that reverts with the geometry, not a selection).
            auto restoredFaceMarks = liveFaceMarks.dup;
            foreach (i; 0 .. mesh.faces.length) {
                // Replace subpatch bit from snapshot; keep live select bit.
                restoredFaceMarks[i] =
                    (restoredFaceMarks[i] & ~Mesh.Marks.Subpatch)
                    | (faceMarks[i] & Mesh.Marks.Subpatch);
            }
            mesh.faceMarks = restoredFaceMarks;
            mesh.vertexSelectionOrder        = liveVertexSelOrder;
            mesh.edgeSelectionOrder          = liveEdgeSelOrder;
            mesh.faceSelectionOrder          = liveFaceSelOrder;
            mesh.vertexSelectionOrderCounter = liveVertexSelOrderCtr;
            mesh.edgeSelectionOrderCounter   = liveEdgeSelOrderCtr;
            mesh.faceSelectionOrderCounter   = liveFaceSelOrderCtr;
        } else {
            // Topology changed: fall back to snapshot marks (safe against
            // changed element counts).
            mesh.vertexMarks                 = vertexMarks.dup;
            mesh.edgeMarks                   = edgeMarks.dup;
            mesh.faceMarks                   = faceMarks.dup;
            mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
            mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
            mesh.faceSelectionOrder          = faceSelectionOrder.dup;
            mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
            mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
            mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
        }

        // `commitRestored` — see restore() above (task 1903 §3.2 S4).
        mesh.commitRestored(MeshChangeAll);
    }
}

// ---------------------------------------------------------------------------
// SelectionSnapshot — lightweight: captures selection arrays + counters
// without touching geometry. Used by select.* commands and any future
// command that only mutates selection state.
// ---------------------------------------------------------------------------

struct SelectionSnapshot {
    bool[] selectedVertices;
    bool[] selectedEdges;
    bool[] selectedFaces;
    int[]  vertexSelectionOrder;
    int[]  edgeSelectionOrder;
    int[]  faceSelectionOrder;
    int    vertexSelectionOrderCounter;
    int    edgeSelectionOrderCounter;
    int    faceSelectionOrderCounter;
    bool   filled = false;

    static SelectionSnapshot capture(in Mesh mesh) {
        SelectionSnapshot s;
        s.selectedVertices     = mesh.selectedVertices.dup;
        s.selectedEdges        = mesh.selectedEdges.dup;
        s.selectedFaces        = mesh.selectedFaces.dup;
        s.vertexSelectionOrder = mesh.vertexSelectionOrder.dup;
        s.edgeSelectionOrder   = mesh.edgeSelectionOrder.dup;
        s.faceSelectionOrder   = mesh.faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = mesh.vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter   = mesh.edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter   = mesh.faceSelectionOrderCounter;
        s.filled               = true;
        return s;
    }

    void restore(ref Mesh mesh) const {
        // TASK 1906 STAGE 3 — THE SELECTION-UNDO DELIVERY BOUNDARY. The three
        // bulk setters below publish through `noteSelectionChange`, which
        // accumulates and never delivers, and this method is reached from a
        // command's `revert()` — the one path `Command.apply`'s delivery batch
        // deliberately does NOT wrap. So before this, a selection-only undo
        // reached the bus solely through the per-frame drain: it was the last
        // two frames of residue the stage-3 census measured, after the command
        // anchor, `symmetry_pick` and the bulk clears had taken the rest.
        //
        // The batch is what makes it ONE delivery for the three domains rather
        // than three, and it also makes this correct when a caller already has
        // a batch open (it nests; the outer close delivers).
        mesh.beginDeliveryBatch();
        scope(exit) { mesh.deliverAccumulated(); mesh.endDeliveryBatch(); }
        mesh.setVerticesSelectedFrom(selectedVertices);
        mesh.setEdgesSelectedFrom(selectedEdges);
        mesh.setFacesSelectedFrom(selectedFaces);
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        // Hide (code review, task 0613 — S3): the bulk setters above may
        // have silently refused a now-hidden element (Mesh's own Select ∧
        // Hide = ∅ invariant, doc/hide_geometry_plan.md §3.1 — their guard
        // zeroes that element's order entry when it refuses). The wholesale
        // order-array overwrite just above was captured BEFORE any refusal,
        // so it can resurrect a stale nonzero stamp for an element that the
        // setter just refused to select — same corruption class fixed at
        // mesh.d's selectVerticesFrom/selectEdgesFrom/selectFacesFrom. Re-zero
        // here too, keyed off the mesh's actual (post-refusal) selection
        // state, not the snapshot's.
        foreach (i; 0 .. mesh.vertexSelectionOrder.length)
            if (!mesh.isVertexSelected(i)) mesh.vertexSelectionOrder[i] = 0;
        foreach (i; 0 .. mesh.edgeSelectionOrder.length)
            if (!mesh.isEdgeSelected(i)) mesh.edgeSelectionOrder[i] = 0;
        foreach (i; 0 .. mesh.faceSelectionOrder.length)
            if (!mesh.isFaceSelected(i)) mesh.faceSelectionOrder[i] = 0;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
    }
}
