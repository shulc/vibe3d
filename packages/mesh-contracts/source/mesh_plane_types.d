module mesh_plane_types;

import mesh_types : FaceIdx;
import std.format : format;

/// Sentinel: this new element has no ancestor (a cap, a bridge quad, a
/// section stitched from a whole shell's boundary; a welded vertex's
/// discarded twin). Its planes take `T.init` under the carry below.
enum uint kNoSource = ~0u;

/// Where each NEW face came from — one entry per new face, so `oldOfNew` is
/// TOTAL over the new array by construction. That totality is why the carry
/// below is a single pass with no gaps and no second sweep, and it is also
/// why the direction is newToOld rather than oldToNew: an oldToNew mapping
/// cannot express DUPLICATION (`arrayFacesGrid`, `mirrorFacesPlane`,
/// `insertEdgeLoopsMulti`, `triangulateFacesByMask` all take one old face to
/// several new ones), while newToOld says exactly "this new face's plane
/// values come from old face N" for every new face, including duplicates of
/// N. It is also the direction the corner protocol already speaks
/// (`Mesh.CornerRewrite.carriedPerFace`'s `srcFaceOfNewFace`,
/// `Mesh.CornerRewrite.relocated`'s `oldLoopOfNewLoop`) — see `rewriteFaces`'s
/// `rw` parameter below.
struct FaceSource {
    const(uint)[] oldOfNew;      // length == newFaces.length; kNoSource allowed

    /// Adapter for the compaction sites that already build (and in one case
    /// RETURN, as part of its own public contract —
    /// `Mesh.triangulateFacesByMask`'s `faceOriginOut`) an
    /// oldToNew `int[]` with `-1` for a dropped face. One pass, one
    /// allocation; the caller's existing return value is untouched — this is
    /// purely a reader that turns their oldToNew into the primitive's
    /// newToOld.
    static FaceSource fromOldToNew(const int[] oldToNew, size_t newCount) {
        auto o2n = new uint[](newCount);
        o2n[] = kNoSource;
        foreach (oldIdx, newIdx; oldToNew) {
            if (newIdx < 0) continue;
            assert(cast(size_t) newIdx < newCount,
                   format("FaceSource.fromOldToNew: oldToNew[%d] = %d is out "
                        ~ "of range for newCount = %d",
                          oldIdx, newIdx, newCount));
            o2n[cast(size_t) newIdx] = cast(uint) oldIdx;
        }
        return FaceSource(o2n);
    }

    /// Every new face inherits from the old face at the SAME index — the
    /// shape of a rewrite that reshapes windings without renumbering
    /// (`cleanDegenerateFaces`'s in-place rewrite branch, `mirrorFacesPlane`'s
    /// rollback path).
    static FaceSource identity(size_t n) {
        auto o = new uint[](n);
        foreach (i; 0 .. n) o[i] = cast(uint) i;
        return FaceSource(o);
    }
}

/// The vertex sibling of `FaceSource`. Same contract, over the per-vertex
/// planes (`kVertPlanes` below).
struct VertSource {
    const(uint)[] oldOfNew;      // length == newVerts.length; kNoSource allowed

    static VertSource fromOldToNew(const int[] oldToNew, size_t newCount) {
        auto o2n = new uint[](newCount);
        o2n[] = kNoSource;
        foreach (oldIdx, newIdx; oldToNew) {
            if (newIdx < 0) continue;
            assert(cast(size_t) newIdx < newCount,
                   format("VertSource.fromOldToNew: oldToNew[%d] = %d is out "
                        ~ "of range for newCount = %d",
                          oldIdx, newIdx, newCount));
            o2n[cast(size_t) newIdx] = cast(uint) oldIdx;
        }
        return VertSource(o2n);
    }

    static VertSource identity(size_t n) {
        auto o = new uint[](n);
        foreach (i; 0 .. n) o[i] = cast(uint) i;
        return VertSource(o);
    }
}

// ---------------------------------------------------------------------------
// The plane tables. THE PRIMITIVE'S BODY IS GENERATED FROM THESE LISTS, so
// "the primitive forgot an array" is not a reachable state — the only
// reachable mistake is forgetting to add a new field to the table, and the
// three guards below (L1 in this module, L2 + L3 in
// `tests/unit/mesh_planes_census_test.d` / `mesh_planes_test.d`) each catch
// that in a different way, none of them self-satisfying (§3 of the plan).
//
// SIBLING LIST — NO LONGER A SECOND HAND-MAINTAINED ONE (task 4059).
// `source/mesh_edit_delta.d`'s `MeshOpEntry` carries a per-face group
// (`faceMat`/`facePrt`/`faceSub`/`faceSetMsk`/`faceOrd`) for the undo/redo
// op-log. The two lists remain independent in ROLE — one is the LIVE-mesh
// carry, the other a REPLAY payload — but they no longer diverge by
// forgetfulness: `kFacePlaneEntryField` below states the correspondence, and
// `MeshEditTracker.recordFaceReindex` fills the entry with a `static foreach`
// over it. A plane added to `kFacePlanes` with no line in that table is a
// COMPILE error at that site ("key `\"…\"` not found in associative array"),
// not a runtime finding. `tests/unit/mesh_planes_census_test.d`'s
// `kFacePlaneToEntryField` unittest still runs and still earns its place: it
// checks the direction a compiler cannot — that every mapped name is a REAL
// `MeshOpEntry` field, and that no per-face-shaped `MeshOpEntry` field is
// left unclassified.
// ---------------------------------------------------------------------------

/// The per-face planes carried by `rewriteFaces`.
enum string[] kFacePlanes = [
    "faceMarks",            // Select | Subpatch | Hide | Lock — ONE word, so
                             //   subpatch and hide ride free; there is no
                             //   separate subpatch array to forget.
    "faceMaterial",
    "facePart",
    "faceSelectionOrder",
    "faceSetMask",
];

/// `kFacePlanes` name -> the `MeshOpEntry` field that carries it in the
/// op-log (task 4059; MOVED here from `tests/unit/mesh_planes_census_test.d`,
/// where it lived as a test-side hand-maintained copy).
///
/// WHY IT MOVED. The comment above says a new `kFacePlanes` entry "is a new
/// field `MeshOpEntry` should probably also carry — check that file when
/// extending this one". "Check that file" is exactly the obligation this
/// module exists to delete: the op-log's recorder listed the same five planes
/// a THIRD time, by hand, as twelve parameters on
/// `Mesh.recordFaceReindexIfWanted`. With the correspondence stated here,
/// `MeshEditTracker.recordFaceReindex` fills the entry with a `static
/// foreach` over `kFacePlanes`, so a plane added to that list is a COMPILE
/// error here (no mapping) rather than a silently uncarried undo payload.
///
/// `faceMarks` maps to `faceSub`, and the value is NARROWED: only the
/// Subpatch BIT rides the drop set, not the whole word. That is a
/// pre-existing, documented limit of `RemoveFaces`'s own reverse — Select and
/// Hide are restored through their own delta kinds — and `FaceReindex`
/// inherits it rather than inventing a new rule. `mesh_planes.captureFacePlaneDrop`
/// in core is where the narrowing lives, in ONE place, instead of at each
/// recorder call site.
enum string[string] kFacePlaneEntryField = [
    "faceMarks":          "faceSub",
    "faceMaterial":       "faceMat",
    "facePart":           "facePrt",
    "faceSelectionOrder": "faceOrd",
    "faceSetMask":        "faceSetMsk",
];

/// The per-vertex planes carried by `rewriteVertices`.
enum string[] kVertPlanes = [
    "vertexMarks", "vertexSelectionOrder", "vertexSetMask",
];

/// The per-EDGE planes carried across a `Mesh.rebuildEdges()` by
/// `captureEdgePlanes`/`applyEdgePlanes` below (task 4059).
///
/// WHY THIS LIST IS SHORT AND WHY IT IS NOT A `rewriteEdges`. There is no
/// edge-domain sibling of `rewriteFaces`, because nothing in the tree hands
/// `edges` a new array with a newToOld correspondence: `edges` is DERIVED,
/// re-discovered from `faces` in face/corner order by `Mesh.rebuildEdges`,
/// and that discovery has no memory of the previous numbering. So the edge
/// domain's correspondence is not an index map — it is the edge's own
/// undirected endpoint KEY (`mesh_topo.edgeKey`), which is what
/// `edgeSetMask`'s exemption below has always said about the edge domain and
/// is why THAT plane needs no carry at all.
///
/// `edgeNonManifold_` is deliberately absent: it is a DERIVED bit that
/// `buildLoops` recomputes wholesale, in the same class as `faceLoop` /
/// `vertLoop` in `kExemptPlanes`.
enum string[] kEdgePlanes = [
    "edgeMarks",            // Select | Subpatch | Hide | Lock — the edge word,
                             //   same fold `faceMarks` has for faces.
    "edgeSelectionOrder",
];

/// Per-face/per-vertex-SHAPED `Mesh` fields that L2's census selects (name
/// prefix `face`/`vertex`/`vert`, type has `.length`) but that this
/// primitive deliberately does NOT carry — each with why. Measured
/// 2026-08-25 (`tests/unit/mesh_planes_census_test.d`'s own probe): the
/// census selects 16 fields; 8 are `kFacePlanes`/`kVertPlanes` above, these
/// first 8 entries are the rest.
///
/// TASK 4059 EXTENDED THIS TO THE EDGE DOMAIN. `edgeSetMask` used to be the
/// ODD entry here — its name starts `edge`, which L2's prefix selector did not
/// reach, so it was recorded purely so a reader classifying it (being
/// `ulong[ulong]`, it LOOKS exactly like a per-element plane) found the reason
/// beside its siblings rather than nowhere. With `kEdgePlanes` above there is
/// a per-edge carry to be forgotten, so L2 now selects the `edge` prefix too
/// and the four entries below it are consulted at runtime like every other.
/// See `rewriteVertices`'s doc comment below for who owns the re-key
/// `edgeSetMask` names.
enum string[string] kExemptPlanes = [
    "faces":            "the SUBJECT `rewriteFaces` assigns, not a plane it carries",
    "vertices":         "the SUBJECT `rewriteVertices` assigns, not a plane it carries",
    "faceLoop":         "rebuilt wholesale by Mesh.buildLoops",
    "vertLoop":         "rebuilt wholesale by Mesh.buildLoops",
    "vertFanOrdered_":  "derived adjacency cache, rebuilt by buildLoops",
    "vertDartStart":    "derived adjacency cache (CSR offsets), rebuilt by buildLoops",
    "vertDartAdj":      "derived adjacency cache (CSR neighbours), rebuilt by buildLoops",
    "vertexSetNames":   "a NAME registry (string per slot), not a per-element plane",
    "edges":            "the SUBJECT Mesh.rebuildEdges re-derives, not a plane it carries",
    "edgeIndexMap":     "derived key->index lookup, rebuilt wholesale by rebuildEdges/buildLoops",
    "edgeNonManifold_": "derived adjacency bit, rebuilt wholesale by buildLoops (task 1290)",
    "edgeSetNames":     "a NAME registry (string per slot), not a per-element plane",
    "edgeSetMask":      "key-space (ulong[ulong]), not index-space — immune to face AND "
                       ~ "vertex renumbering by construction. Re-keyed by "
                       ~ "mesh_selsets.selSetRekeyEdges on a VERTEX remap only, which is "
                       ~ "the CALLER's obligation (called right after the plane carry and "
                       ~ "before rebuildEdges() at every existing site, e.g. "
                       ~ "Mesh.rekeyEdgeSetsThroughRemap) — never this primitive's, and never "
                       ~ "rewriteFaces's, since a face renumbering alone cannot invalidate "
                       ~ "an edge key.",
];

/// Authoritative value-plane types (task 20262330). Core verifies each
/// binding against its live storage; payload generation needs no live mesh.
enum string[string] kFacePlaneType = [
    "faceMarks": "uint[]",
    "faceMaterial": "uint[]",
    "facePart": "uint[]",
    "faceSelectionOrder": "int[]",
    "faceSetMask": "ulong[]",
];

/// One value per `kFacePlanes` plane, for a LIST of faces, in the shapes
/// `MeshOpEntry` stores. The fields are GENERATED from `kFacePlanes`, so
/// adding a plane there adds a field here with no edit.
struct FacePlaneDrops {
    // Evaluate the complete declaration in CTFE: DMD 2.112.0 cannot lower
    // an associative-array lookup directly inside a mixin expression.
    static foreach (n; kFacePlanes)
        mixin((() => kFacePlaneType[n] ~ " " ~ n ~ ";")());
}


/// Everything a `Kind.FaceReindex` op-log entry needs, in ONE value.
///
/// It replaces a twelve-parameter call — `recordFaceReindexIfWanted(oldOfNew,
/// oldFaceCount, newFaceLists, dropIdx, dropLists, dropMat, dropPrt, dropSub,
/// dropSetMsk, dropOrd, survIdx, survLists)` — five of whose parameters were
/// the plane list written out a third time by hand, in an order nothing
/// checked. A positional list of five same-shaped `uint[]`/`int[]`/`ulong[]`
/// arguments is one transposition away from recording the wrong plane under
/// the wrong name, and no count can see that: swap `dropMat` and `dropPrt` and
/// every length, every arity and every face index still agrees.
struct FaceReindexRecord {
    uint[]         oldOfNew;       // newToOld, TOTAL over the new face array
    uint           oldFaceCount;
    uint[][]       newFaceLists;   // POST-rewrite windings
    FaceIdx[]      dropIdx;        // old indices no new face names
    uint[][]       dropLists;      // their PRE-rewrite windings
    FacePlaneDrops dropPlanes;     // their planes, parallel to dropIdx
    FaceIdx[]      survIdx;        // review finding B2 (task 1902 Stage H)
    uint[][]       survLists;      // ditto

    /// The name of the FIRST field above that is not at its `.init` value, or
    /// `null` when the record is entirely unfilled. Generated from
    /// `this.tupleof`, so a field added to the list above joins the check
    /// with no edit — the same property `kFacePlanes` buys the planes.
    ///
    /// WHY IT EXISTS (task 4059 review). Collapsing twelve COMPULSORY
    /// parameters into eight DEFAULT-INITIALISED fields gave up the
    /// compiler's arity check: a caller may now fill six fields, forget
    /// `oldFaceCount`, and compile clean. `recordFaceReindex`'s no-op guard
    /// is `oldFaceCount == 0 && newFaceLists.length == 0`, so such a record
    /// is swallowed WHOLE and in silence — which is review finding B3
    /// (a destructive drop-everything rewrite recorded as nothing) coming
    /// back through a different door. The guard's real precondition is that
    /// a no-op record is EMPTY, not merely that two of its fields are zero,
    /// and that is what this states. There is one call site today; this
    /// stands in for the compiler at the second one.
    string firstAssignedField() const {
        static foreach (i, _; typeof(this).tupleof)
            if (this.tupleof[i] != typeof(this.tupleof[i]).init)
                return __traits(identifier, typeof(this).tupleof[i]);
        return null;
    }
}

/// How far a plane is taken when the geometry array has changed length.
enum PlaneFit : ubyte {
    /// `plane.length = faces.length` — grows a short plane AND truncates a
    /// long one. The shape the six topology kernels and `Mesh.resetSelection`
    /// wrote by hand.
    Exact,
    /// `if (plane.length < faces.length) plane.length = faces.length` — grow
    /// only, never truncate. `Mesh.syncSelection`'s shape, and the difference
    /// is load-bearing: `syncSelection` is documented as "grow selection
    /// arrays to match geometry WITHOUT clearing", and it is called on paths
    /// where `faces` may be SHORTER than a plane that still holds values a
    /// later step reads. Truncating there would be a silent data loss the
    /// `Exact` arm's callers have already decided they want.
    GrowOnly,
}

/// WHO ASKS FOR THE CARRY, and why it is not simply on.
///
/// MEASURED 2026-09-04, and this is the finding that shaped the enum. Wiring
/// the carry into `Mesh.rebuildEdges` unconditionally moves EIGHT rows of the
/// frozen undo-parity corpus — `weld_merge`, `create_stable`,
/// `delete_remove`, `slice_cut`, `cleanup`, `bevel`, `vertex_bevel`,
/// `extrude_extend`, each on the `edgePlanes` plane of its postOp dump (the
/// per-cell breakdown is in task 4190's card). Six are ORDER stamps, two are
/// Select bits.
///
/// WHAT THOSE EIGHT ROWS PROVE, AND WHAT THEY DO NOT. They prove that arming
/// the carry CHANGES what the user sees selected after eight shipped
/// operations — no more. All eight fixtures are SELF-GENERATED from our own
/// replay (`provenance.source` is `"simulated"`, `provenance.reference` is
/// `"vibe3d-selfgen"`, and `weld_merge.json`'s own note reads "No reference
/// editor involved"), so they are not evidence about the reference at all.
/// WHICH edges an extrude or an inset should leave selected is a law we are
/// matching, not one we may design (`CLAUDE.md`, "Unknowns are CAPTURED, not
/// invented") — and it is UNMEASURED. That capture is step 0 of task 4190,
/// which is why deferring is right: the eight rows say the decision is not
/// free, and only the capture can settle it. So the default arm is
/// byte-identical to the behaviour before this task.
///
/// THERE IS ALSO A SOUNDNESS BOUNDARY, and it is why an unconditional carry
/// would be wrong even once that decision is made. An edge KEY is a pair of
/// VERTEX INDICES, so a vertex renumbering invalidates every key — and
/// `rebuildEdges` cannot see one. At `Mesh.compactUnreferenced` and both weld
/// remaps, `vertices` is reassigned and `faces` rewritten into the new
/// numbering while `edges` still holds the OLD endpoints, so a key lookup
/// there can MISS (a dropped mark, the conservative failure) or COLLIDE (a
/// mark landing on an unrelated edge, the dangerous one). This is the same
/// boundary `kExemptPlanes`' `edgeSetMask` entry already draws — "re-keyed by
/// mesh_selsets.selSetRekeyEdges on a VERTEX remap only, which is the
/// CALLER's obligation". `edgeSetMask` has that re-key; the two planes here do
/// not, and giving them one is task 4191. Until then `byKey` may only be
/// asked for by a caller whose kernel renumbers no vertex — today
/// `Mesh.spinEdge` and `Mesh.spinEdgesByKeys`, which rewrite windings only.
enum EdgePlaneCarry : ubyte {
    /// Leave `edgeMarks` / `edgeSelectionOrder` exactly as they are: the
    /// behaviour every call site had before task 4059, stale index-space
    /// values and all, with the caller's own `clearEdgeSelectionResize()` /
    /// `resizeEdgeSelection()` still owning the cleanup. The DEFAULT, so that
    /// wiring the mechanism changes nothing until somebody asks.
    leaveIndexed,
    /// Carry each plane through the rebuild by the edge's undirected endpoint
    /// KEY, and size the planes to the rebuilt `edges`.
    byKey,
}

/// Authored-wire handling for a vertex-index remap. Compaction carries keys;
/// a non-injective weld drops every key whose endpoint moved because that
/// merge is not invertible in the current operation log.
enum WireKeyPolicy { carry, dropMoved }

