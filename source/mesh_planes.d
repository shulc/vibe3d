module mesh_planes;

// ---------------------------------------------------------------------------
// mesh_planes — ONE primitive per domain that rewrites the geometry array
// (`faces` / `vertices`) AND carries every parallel per-element plane through
// it in lock-step, generated from a declared table (task 1902).
//
// THE CLASS OF BUG THIS REMOVES. Every topological kernel that renumbers
// faces or vertices has, until now, hand-built the carry for each parallel
// array — `faceMarks`, `faceMaterial`, `facePart`, `faceSelectionOrder`,
// `faceSetMask` — at its own call site. Measured (task 1902's card, `##
// Лог` 2026-08-25): 19 production face-rewrite sites and 5 vertex ones, 94
// of 95 site×plane cells already correct by hand, and the one gap
// (`loop_slice.d`'s `faceSelectionOrder`) is invisible to every existing
// test because a tail `resetSelection()` zeroes the same plane wholesale —
// "a check that cannot come out differently" (CLAUDE.md). The pattern has
// been re-derived and re-fixed three times (0679, 0921, 1060 Stage 5c). This
// module makes the law mechanical: a kernel states WHERE each new face came
// from, and the primitive carries everything — a plane the kernel does not
// know about still rides along, because the generated body iterates a TABLE,
// not a hand-written list.
//
// SHAPE, and why it is a NEW module. Free functions over `ref Mesh`, kept
// out of `mesh.d` to respect its size ceiling — the same shape
// `mesh_selsets.d` and `mesh_corner_maps.d` already established for exactly
// this reason (see either module's header). `doc/reindex_primitive_plan.md`
// §2.1 records why the primitive is NOT `applyFaceRemap(ref Mesh, in
// FaceRemap)`: the 19 kernels do not have a remap to apply, they have NEW
// WINDINGS with a newToOld correspondence, and `FaceRemap`/`faceRemap`
// already names an oldToNew `int[]` at four existing call sites (two of
// them a public return value) — a same-named newToOld struct would collide
// with an established local meaning at exactly those sites.
//
// STAGE B (this commit) has migrated `mesh.d`'s compaction family — seven
// callers, all in `source/mesh.d`: `Mesh.applyVertexRemapAndRebuild`,
// `Mesh.applyVertexRemap`, `Mesh.deleteFacesByMask`,
// `Mesh.dissolveVerticesByMask`, `Mesh.removeEdgesByMask`,
// `Mesh.triangulateFacesByMask`, `Mesh.arrayFacesGrid`. Every one of them
// passes `rw = null` to `rewriteFaces`: each already declares its per-corner
// (UV) correspondence itself, through its own `beginCornerRelocate()` →
// `rw.relocated(oldLoopOfNewLoop)` call sitting right next to the
// `rewriteFaces` call — a PER-CORNER correspondence, not the PER-NEW-FACE
// one `rewriteFaces`'s own `rw` parameter would declare through
// `rw.carriedPerFace(...)` (plan §6 Stage B). An eighth candidate,
// `Mesh.mirrorFacesPlane`'s weld-collapse rollback, was considered and
// DECLINED: its only `faces =`/`vertices =` assignment restores `rb*`
// snapshots (`.dup`d before the weld pass) verbatim at their OWN pre-weld
// indices — a RESTORE, not a reindex. `rewriteFaces`/`rewriteVertices` read
// every plane off `m`'s OWN live arrays through a `FaceSource`/`VertSource`
// correspondence; there is no way to pull a value from an external snapshot
// like `rbFaceMaterial` through that shape without first writing it back
// onto `m` and then asking the primitive to copy it right back out under
// `.identity()` — strictly more code and one more allocation per plane for
// the same bytes. Stays hand-rolled (plan §6 Stage B; `mesh_planes_census_
// test.d`'s tree-scan `kAllow` still names both of its `faces =`/
// `vertices =` lines).
//
// STAGE C (this commit) migrates `mesh_ops/loop_slice.d`'s single site,
// `insertEdgeLoopsMulti` — the one cell (`faceSelectionOrder`) that was NOT
// already lock-step by hand, and the reason it went unnoticed: the tail
// `resetSelection()` → `clearFaceSelection` zeroes that plane wholesale
// regardless, so a mis-carried order stamp and a correctly-carried one
// produce the same array (plan §6 Stage C — closes the gap structurally,
// not visibly). Unlike Stage B, this site passes its OWN `beginCornerRewrite()`
// handle (`rw`) straight through to `rewriteFaces` — `newSrc`, the
// newToOld correspondence it already built for the corner-map obligation
// (task 0682), is EXACTLY the per-new-face shape `rw.carriedPerFace()` wants
// (plan §2.6), so the corner declaration is issued once, by the primitive,
// instead of twice. `newSrc` is now populated UNCONDITIONALLY (previously
// gated on a live PolyVertex map) since the plane carry needs it whether or
// not a UV map exists; passing `&rw` unconditionally is inert when no map is
// active (`CornerRewrite.carriedPerFace` on an inactive handle degrades to
// `unchanged()` for free). `faceMarks` is the one plane this site's own
// call still overrides right after `rewriteFaces` returns: a Cap Sections
// face folds SEVERAL ring faces' words through `combineFaceMarksWords`
// (`Marks.Hide`-identity AND/OR fold), a value with no single source face
// that the generic per-new-face carry cannot express for a `kNoSource`
// entry — so `rewriteFaces`'s own carry of `faceMarks` here is a throwaway,
// immediately replaced by the site's hand-tracked `newWord` via
// `setFaceMarksFrom(newWord, ~Marks.Select)`, unchanged from before the
// migration (plan §2.7 — selection-bit/word policy stays at the call site).
//
// STAGE D (this commit) migrates all four `mesh_ops/extrude.d` sites — the
// heaviest client (plan §6 Stage D). Sites 14 (`extrudeEdgesByMask`), 15
// (`extrudeVerticesByMask`) and 17 (`smoothShiftFacesByMask`) pass `rw =
// null` (each keeps its own bare `dropCornerProvenance(SweptSurfaceNoLaw)`,
// a stated loss, unchanged); site 16 (`extrudeFacesByMask`) passes its own
// `beginCornerRewrite()` handle straight through, same shape as Stage C —
// its old `rw.carried(newFaces, srcOfCorner, …)` call is replaced by
// `rewriteFaces`'s internal `rw.carriedPerFace(newFaces, oldOfNew, …)`,
// which is the SAME declaration: `srcOfCorner` was always block-constant per
// face (built by a helper that repeated one source value across every
// corner of the face it was building), exactly what `carriedPerFace` derives
// from a per-face array internally. Site 15's previously TAIL-ONLY
// `NewFaceSpec.srcFi` correspondence is flattened into one TOTAL `oldOfNew`
// (identity over the substituted/surviving head, `srcFi` over the freshly
// created tail) — a mechanical change the plan called out explicitly.
//
// The one per-plane divergence found at Stage D, present at sites 15, 16 and
// 17 alike: `faceSelectionOrder` does NOT follow `oldOfNew` the way
// material/part/setmask/marks do. The hand-rolled kernels always zeroed a
// freshly created face's order stamp (`newOrd ~= 0;`) rather than
// inheriting it from the source face material/part/marks/setmask DO inherit
// from — a real semantic difference the generic per-plane carry cannot
// express (task 1902's "duplication semantics differ — STOP or override"
// rule). Each site therefore patches `faceSelectionOrder` back to 0 over
// exactly the created-face range, immediately after the `rewriteFaces` call
// — the same "override right after the call" shape Stage C already
// established for `faceMarks`, applied here to a different plane. Site 14's
// compaction branch (only reachable when a far-vertex overshoot clamp
// collapses a face to <3 corners) has no such divergence: it is a pure
// substitution of `FaceSource.fromOldToNew(faceRemap, …)` for the hand-built
// `kept*` arrays, using the SAME `faceRemap` the kernel's own downstream
// winding-consistency pass still reads.
//
// The remaining face sites (`edge_bevel.d`, `cleanup.d`, `revolve.d`,
// `bevel_vertex.d`) and the vertex sites migrate family-by-family in later
// stages, each one behaviour-preserving by construction (a byte-identical
// mesh, not a corrected one — this task has no user-visible defect to fix,
// see the plan's §0).
//
// `commitChange`: the CALLER's, never the primitive's (plan §2.5). Every
// migrated kernel already calls `rebuildEdges()`/`buildLoops()` and its own
// tail `commitChange(...)` AFTER the rewrite; running one here would derive
// against a half-built mesh (edges not yet rebuilt) and re-introduce a
// per-rewrite commit the perf work in `b1cf488a`/`afbcb1d6` collapsed into
// one tail commit (memory `on2_traps_in_mesh`). So `rewriteFaces` /
// `rewriteVertices` touch neither `mutationVersion` nor `topologyVersion`,
// and `changeBus.missedPublishers` stays satisfied for free — they publish
// nothing, so they cannot miss a publish.
//
// A FOURTH stamp this applies to: `faceMarks`/`vertexMarks` are written RAW
// here (a plain field assignment, not through `noteChange`/
// `noteSelectionChange`), so `marksVersion` — the key
// `tools/transform/transform.d`'s action-centre pivot cache uses — does NOT
// move inside the primitive either. It moves only when the caller's tail
// `commitChange` runs with a flag intersecting `kMarksAffecting`
// (`Marks | Visibility | Points | Polygons`, `source/mesh.d`). Every
// face/vertex-rewrite kernel already commits with `Geometry`
// (`Points | Polygons`) at its tail — a subset of `kMarksAffecting` — so
// `marksVersion` already advances correctly at every migrated site; this is
// stated so a future call site does not narrow its tail commit's flag to
// something outside `kMarksAffecting` while still rewriting marks (plan §2.5).
//
// The O(n²) trap (plan §2.8): the generated body reads the raw
// `uint[]`/`int[]`/`ulong[]` planes directly and never asks a selection
// question, so it never calls any of the three allocating `@property` views
// `Mesh` exposes over the marks arrays (memory `on2_traps_in_mesh` — each
// materialises a fresh `bool[]` per call). `tests/unit/mesh_planes_census_
// test.d` asserts this module's own source text names none of them.
// ---------------------------------------------------------------------------

import mesh : Mesh, PolyVertexBlend, PolyVertexGen, FaceIdx;
import mesh_topo : edgeKey;
import math : Vec3;
import std.format : format;
import std.traits : isDynamicArray, isStaticArray;

// ---------------------------------------------------------------------------
// The correspondence.
// ---------------------------------------------------------------------------

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

    /// Adapter for the compaction sites that already build (and in two cases
    /// RETURN, as part of their own public contract — `Mesh.applyVertexRemap`'s
    /// `faceRemap`, `Mesh.triangulateFacesByMask`'s `faceOriginOut`) an
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
/// inherits it rather than inventing a new rule. `FacePlaneDrops.captureFace`
/// below is where the narrowing lives, in ONE place, instead of at each
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
                       ~ "Mesh.applyVertexRemap) — never this primitive's, and never "
                       ~ "rewriteFaces's, since a face renumbering alone cannot invalidate "
                       ~ "an edge key.",
];

// ---------------------------------------------------------------------------
// L1 — two `static assert`s on `Mesh`'s field counts. Neither alone is the
// gate; together they classify what landed (plan §3 L1):
//
//   uint[] faceDummy;      -> BOTH red   -> plain array, plane candidate
//   ulong  dummyStamp;     -> 56 red only -> scalar, bump 56 and say why
//   FaceList faceDummy2;   -> 56 red only (L2 catches it BY NAME) -> a
//                             wrapper type, exactly the case an array-only
//                             assert cannot see (`FaceList` is not
//                             `isDynamicArray`, and its own doc comment says
//                             a CSR-backed sibling is coming).
//
// THE LIVE NUMBERS ARE THE ONES IN THE TWO `static assert`s BELOW. Keep this
// block a single current statement plus a history line — an earlier revision
// left the pre-task measurement in place and added the new one underneath, so
// one dated block asserted 54 and 56 at once and the `countArrayShapedFields`
// message below still quoted the retired figure.
//
// Measured (`dmd -o- -c -i -version=WithAI` plus the project's five dependency
// import paths, `pragma(msg)` on `Mesh.tupleof.length` and on a `static
// foreach` count of the array-shaped subset — the plan's recorded command; NOT
// a regex over the source text, which is what put a wrong number (33) in an
// earlier draft of that plan):
//
//   2026-08-25, task 1906 stage 3 — superseded:
//     Mesh.tupleof.length                          == 54
//     count of those fields that are array-shaped  == 34
//
//   2026-09-03, task 3910 — CURRENT:
//     Mesh.tupleof.length                          == 55
//     count of those fields that are array-shaped  == 34
//     `wireEdgeKeys` is keyed by a vertex PAIR, like `edgeSetMask`, not by
//     one face/vertex/edge index; it is therefore registry state, not a plane.
//
//   2026-08-25, task 1903 Stage A — superseded: 55 / 34.
//   2026-08-25, task 1906 stage 0 — superseded: 56 / 34.
//   2026-08-25, pre-1906 — superseded: 54 / 34.
//
// What moved and why it is not a plane: 1903 Stage A REMOVED the
// `Mesh.editRecorder_` FIELD. It is now a private accessor over the
// module-level `g_editBatchStack` in `mesh.d` — a pointer to the open edit
// batch's op-log recorder, never per-element data, and deliberately not a
// field any more so that a kernel of the form `*mesh = subdivide(...)` cannot
// swap in the new value's empty tracker mid-record. The array-shaped count is
// unmoved, which is exactly the signal the paired asserts exist to give.
//
// What moved at 1906 stage 3, and the array-shaped count did NOT — which is
// the paired asserts working as designed, since all three are scalars:
//
//   ADDED   `Mesh.stampedVersion_` — `mutationVersion` as of the last stamp
//           made through `commitStamps`, i.e. the witness the missed-publisher
//           guard compares against.
//   REMOVED `Mesh.pendingChanges_` and `Mesh.pendingSelDomains_` — the
//           per-frame drain words. Stage 3 deleted the drain in `source/app.d`
//           that read and zeroed them; every publisher now delivers
//           synchronously, so the second accumulator had no reader left.
//
// None of the three carries per-element data, so nothing about them is carried
// through a face or vertex remap and none belongs in a plane table. The layer
// IDENTITY that stage 3 also added is deliberately NOT here: it is a field of
// `Layer`, not of `Mesh`, so that no wholesale `*mesh = …` and no
// `MeshSnapshot.restore` can copy or restore it (see `document.Layer.birthId`).
// ---------------------------------------------------------------------------

/// Count of `T`'s instance fields whose type is a dynamic or static array —
/// the compile-time counterpart of `MeshMap.dup`'s own field-count tripwire
/// (`source/mesh.d`: "MeshMap gained a field — add it to dup() before
/// bumping this count"), scaled to a `static foreach` instead of hand-listed
/// because `Mesh` has 55 fields where `MeshMap` has 6 (task 1906 stage 0 —
/// this sentence quoted 54 after the count above had already moved, which is
/// the drift the single-current-figure rule in that block now prevents).
template countArrayShapedFields(T) {
    enum size_t countArrayShapedFields = () {
        size_t n = 0;
        static foreach (f; T.tupleof)
            static if (isDynamicArray!(typeof(f)) || isStaticArray!(typeof(f)))
                n++;
        return n;
    }();
}

static assert(Mesh.tupleof.length == 55,
    "Mesh gained (or lost) an instance field. Classify it before bumping this "
  ~ "count: per-face data goes in kFacePlanes, per-vertex data in kVertPlanes "
  ~ "— INCLUDING data behind a wrapper struct such as FaceList, which is not "
  ~ "an array type and which the array-shaped assert below will NOT flag. "
  ~ "Anything derived, rebuilt or scalar: bump this count and say why in the "
  ~ "commit message. dmd stops at the first failing static assert in this "
  ~ "module: bump this count, recompile, and read the array-shaped assert "
  ~ "below to learn which KIND landed.");

static assert(countArrayShapedFields!Mesh == 34,
    "Mesh gained (or lost) an ARRAY-shaped field. If the 55-count above moved "
  ~ "too, the new field is a plain array — a plane candidate, classify it. If "
  ~ "ONLY the count above moved, it is a scalar or a wrapper type.");


// ---------------------------------------------------------------------------
// L1b — THE RATCHET, on `Mesh`'s member SURFACE rather than its fields
// (task 3290, step 4 of `doc/tasks/work/2910-mesh-struct-seams.md`). It sits
// HERE, beside the field pair above, because it is the same family: a number,
// a journal of what that number used to be, and a message that says what to do
// when it moves. dmd stops at the first failing static assert in this module,
// so the four now read as one staged chain — see the table below.
//
// WHY. Audit №4 M9 recorded `source/mesh.d` at 17 970 → 30 636 → 16 654 →
// 18 220 → 20 644 lines and drew the conclusion this block answers: there is no
// holding mechanism BETWEEN the surges. Steps 1–3 of plan 2910 took
// `struct Mesh` from 16 782 to 13 308 lines (2026-08-29); with nothing to hold
// it, that is a one-off tidy the next feature undoes, and no test in the tree
// would report it. The two asserts above cannot: `Mesh.tupleof.length` sat
// still at 54 across the ENTIRE window M9 measured, while the struct gained and
// shed thousands of lines of functions.
//
// WHAT EACH NUMBER SEES — measured with a four-cell probe on this tree (task
// 3290 §Мутация), each cell added to `struct Mesh` alone and reverted:
//
//   ADDED TO `Mesh`                    tupleof array-shaped allMembers overloads
//   uint[] dummy3290_;                   RED       RED         RED       green
//   void dummy3290New() {}              green     green        RED        RED
//   void rebuildEdges(void* d) {}       green     green       green       RED
//     (a 2nd overload of a name `Mesh` already has)
//   enum Dummy3290 { a }                green     green        RED       green
//
// Rows 2–4 are why this is NOT a duplicate of the pair above — the field
// asserts cannot see a function, an overload or a nested type, and those are
// what `struct Mesh` actually grows by. Rows 3 and 4 are why there are TWO
// numbers here and not one: the overload count is not a subset of the name
// count, it is an orthogonal axis, and each is blind to exactly the cell the
// other catches.
//
// NON-VACUITY IS STRUCTURAL HERE, unlike `tests/unit/mesh_by_value_gate.d`,
// which asserts `offenders.length == 0` and therefore needs an anchor guard to
// prove it looked at anything. An assert of the form `== 363` cannot be
// satisfied by looking at nothing: a scope with nothing in it answers 0.
//
// THE CEREMONY THIS COSTS, measured rather than argued (task 3290; plan 2910 §7 question 4),
// because it is charged to every future feature that legitimately adds a `Mesh`
// member. Adding one member function and taking it green: `dub build` fails in
// 1.5 s naming the assert AND the number to write (both messages carry the LIVE
// count — that is what `ctfeDec` below is for, so nobody has to re-run the
// `pragma(msg)` probe); one digit changes; `dub build` fails in 1.6 s on the
// second number; one digit changes; the build links in 7.3 s. Two one-digit
// edits and 3.1 s of compiler time — a `static assert` is reached during
// semantic analysis, so a red one never pays for codegen. The optional third
// cost is a journal line above, under the single-current-figure rule: move the
// retired numbers down, never leave two "current" ones.
//
// THE NAMED BLINDNESS, measured rather than assumed: an `unittest` block in the
// struct BODY contributes ZERO members. Step 1 moved 50 of them out (counted at
// depth 1 on both trees: 50 before, 0 after) and the struct fell 16 782 → 14 636
// lines — its largest single drop of the whole plan — while NEITHER number below
// moved: 377 / 307 on `b14cc214` before it and 377 / 307 on `e7faf2fe` after it,
// both measured here. This ratchet holds the DECLARED surface. The counter that
// sees unittest blocks is `tests/unit/unittest_census_gate.d`, and it sums them
// TREE-WIDE, so putting fifty of them back inside `struct Mesh` moves nothing
// anywhere — a named gap, not a claim this block covers it.
//
// Measured with plan §1.3's command — `dmd -o- -i -I=source -I=third_party`
// plus the dub package import paths, `pragma(msg)` on
// `__traits(allMembers, Mesh).length` and on the fold below — NOT a regex over
// the source text, which is what answered 56 where the compiler answers 54 for
// the pair above:
//
//   2026-09-03, task 3910 — CURRENT:
//     __traits(allMembers, Mesh).length  == 366
//     countMemberOverloads!Mesh          == 297
//     One authoritative registry field plus its bulk loader and canonical
//     file-order methods are the state/operations specified by the codec plan.
//
//   2026-08-29, task 3290, plan 2910 after step 3 (`fc55c13c`) — superseded:
//     __traits(allMembers, Mesh).length  == 363
//     countMemberOverloads!Mesh          == 295
//
//   2026-08-29, after step 2 (`f961b9f1`) — superseded: 374 / 305
//                 (the `VisibilityProbe` group: 3 names, 2 functions)
//   2026-08-29, after step 1 (`e7faf2fe`) — superseded: 377 / 307
//   2026-08-28, before step 1 (`b14cc214`) — superseded: 377 / 307
//
// Every figure above was re-measured on its own tree by task 3290, not copied
// from the step cards.
//
// THREE CONFIGURATION FACTS, all measured, because `==` on a count is only safe
// if the count is the same in every lane that compiles this file:
//   * `-unittest` does not change either number TODAY (363 / 295 with and
//     without). It CAN: the same probe on `b14cc214` answered 377 / 307 plain
//     and 382 / 311 under `-unittest`, the difference being the five
//     `version (unittest)` fixture helpers `t_s1_*` that then lived in the
//     struct — four functions and one manifest `enum`, +5 names / +4 overloads.
//     So a `version (unittest)` MEMBER would make this assert red under
//     `dub test --config=tests` and green under `dub build`. Declare such
//     helpers at MODULE scope, which is where step 1 put those five.
//   * `-version=WithAI` does not change them, and neither does
//     `-version=WithRender` (363 / 295 under both) — `source/mesh.d` declares
//     no `version` block that adds or removes a member outside `unittest`.
//   * Both numbers count PRIVATE members, and answer the same from inside
//     `mesh.d` as from this module — probed on a two-module fixture. That is
//     what makes the ratchet useful to plan 2910 at all: the surface it moves
//     is mostly private.
// ---------------------------------------------------------------------------

/// CTFE decimal, so a failing assert below can NAME the number to write rather
/// than sending the reader off to re-run the `pragma(msg)` probe that produced
/// the journal above. Measured reason (task 3290): the whole ceremony a new
/// `Mesh` member costs is two one-digit edits, and it is only two SMALL edits
/// if the compiler says what the digits are. Not `std.format.format` — this
/// runs inside a `static assert` message on every compile of this module.
private string ctfeDec(size_t n) {
    if (n == 0) return "0";
    string s;
    while (n) { s = cast(char)('0' + (n % 10)) ~ s; n /= 10; }
    return s;
}

/// Count of `T`'s member-function overloads. Deliberately NOT a subset of
/// `__traits(allMembers, T).length`: a second overload of a name `T` already
/// has adds one here and nothing there, which is the one growth shape the name
/// count cannot see (row 3 of the table above).
template countMemberOverloads(T) {
    enum size_t countMemberOverloads = () {
        size_t n = 0;
        static foreach (name; __traits(allMembers, T))
        {{
            static if (__traits(compiles, __traits(getOverloads, T, name)))
                static foreach (ov; __traits(getOverloads, T, name))
                    n++;
        }}
        return n;
    }();
}

static assert(__traits(allMembers, Mesh).length == 366,
    "`struct Mesh` gained (or lost) a member NAME — a function, a nested type, "
  ~ "an `enum`, an `alias` or a field. This is the step-4 RATCHET of "
  ~ "`doc/tasks/work/2910-mesh-struct-seams.md`: the struct was 13 308 lines on "
  ~ "2026-08-29 after three steps took 3 474 out of it, and the audit finding "
  ~ "the plan answers is that it grows back unless something says so out loud. "
  ~ "Before bumping this count, ask where the member belongs. A QUERY over the "
  ~ "mesh has a home that is not the struct: a free function over `ref Mesh` / "
  ~ "`const ref Mesh` in a satellite module (`mesh_visibility.d`, "
  ~ "`mesh_edge_slice.d`, `mesh_selsets.d`, `mesh_corner_maps.d`, "
  ~ "`mesh_topo.d`), re-exported by `public import` from `mesh.d`, so every "
  ~ "call site keeps working through UFCS — and a satellite must carry "
  ~ "`MeshByValueGate`, because a free function taking `Mesh` BY VALUE compiles "
  ~ "everywhere and silently drops writes. If the member genuinely belongs to "
  ~ "the struct, bump this count and say why in the commit message: one line of "
  ~ "ceremony, on purpose. dmd stops at the FIRST failing static assert in this "
  ~ "module, so if the field asserts above moved too you are reading this only "
  ~ "after bumping them; bump this one, recompile, and read the overload assert "
  ~ "below to learn whether a FUNCTION landed or a TYPE. THIS TREE HAS "
  ~ ctfeDec(__traits(allMembers, Mesh).length) ~ " member names.");

static assert(countMemberOverloads!Mesh == 297,
    "`struct Mesh` gained (or lost) a member-function OVERLOAD. Read it with "
  ~ "the name count above: if BOTH moved, a whole new function name landed. If "
  ~ "ONLY the name count moved, what landed is a nested type, an `enum` or an "
  ~ "`alias` — no function. If ONLY THIS ONE moved, it is a second overload of "
  ~ "a name `Mesh` already had, which no other counter in this module can see: "
  ~ "that cell is the reason this assert exists as well as the one above. Same "
  ~ "question either way — a query belongs in a satellite module over "
  ~ "`ref Mesh`, not in the struct. THIS TREE HAS "
  ~ ctfeDec(countMemberOverloads!Mesh) ~ " member-function overloads.");
// ---------------------------------------------------------------------------
// The op-log payload (task 4059) — the THIRD enumeration of the same five
// planes, now derived from the first.
// ---------------------------------------------------------------------------

/// One value per `kFacePlanes` plane, for a LIST of faces, in the shapes
/// `MeshOpEntry` stores. The fields are GENERATED from `kFacePlanes`, so
/// adding a plane there adds a field here with no edit.
struct FacePlaneDrops {
    static foreach (n; kFacePlanes)
        mixin("typeof(Mesh." ~ n ~ ") " ~ n ~ ";");

    /// Append face `fi`'s value on every plane. Reads the planes LAZILY —
    /// `facePart` / `faceMaterial` / `faceSetMask` grow on write and read as
    /// `T.init` past their length by convention (their own declarations in
    /// mesh.d say so), so an out-of-range index is a legal zero and not a
    /// bug to bounds-check away.
    ///
    /// MUST be called BEFORE the carry that overwrites the planes: the whole
    /// point of a drop payload is "the planes of an old face no new face
    /// names", and those values are gone the moment `rewriteFaces`'s carry
    /// loop runs. `CLAUDE.md`'s "the check is CORRECT but runs at the wrong
    /// MOMENT" applies to captures as much as to assertions.
    void captureFace(ref Mesh m, size_t fi) {
        static foreach (n; kFacePlanes) {
            {
                static if (n == "faceMarks") {
                    // THE ONE NARROWING, stated once. `MeshOpEntry.faceSub`
                    // carries the Subpatch BIT alone, not the whole mark word
                    // — see `kFacePlaneEntryField`'s doc comment for why that
                    // is inherited rather than chosen.
                    __traits(getMember, this, n) ~= (m.isFaceSubpatch(fi) ? 1u : 0u);
                } else {
                    auto src = __traits(getMember, m, n);
                    __traits(getMember, this, n) ~=
                        (fi < src.length) ? src[fi] : typeof(src[0]).init;
                }
            }
        }
    }
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

// ---------------------------------------------------------------------------
// The primitive.
// ---------------------------------------------------------------------------

/// Assign `newFaces` AND carry every plane in `kFacePlanes` through `src`.
/// Touches no version stamp and publishes nothing to the change bus or the
/// edit tracker — see this module's header for why that stays the caller's
/// job. This is NOT a behaviour change from today's hand-rolled
/// `faces = newFaces;`: it means `Mesh.loopsValid()` (`loopsStamp ==
/// structVersion`) reads STALE-TRUE for the whole window between this call
/// returning and the caller's own `rebuildEdges()` (the only thing that
/// bumps `structVersion`) — `faces` has already changed but `loopsValid()`
/// cannot see it yet. Every existing kernel already reaches
/// `rebuildEdges()`/`buildLoops()` before anything reads `loops`, so the
/// window is never observed in practice; a caller that queries
/// `loopsValid()`/`loops` between `rewriteFaces` and `rebuildEdges()` gets a
/// lie (plan §2.4).
///
/// `rw` is the optional corner-provenance declaration (task 0830's
/// `Mesh.CornerRewrite`, opened by the CALLER via `m.beginCornerRewrite()`
/// before it built `newFaces`). When non-null, `rewriteFaces` declares the
/// correspondence through the SAME `src.oldOfNew` used for the per-face
/// planes — `carriedPerFace`'s `srcFaceOfNewFace` parameter wants EXACTLY a
/// newToOld array with one entry per new face, which `FaceSource.oldOfNew`
/// already is. That a single value serves both obligations without
/// translation is the strongest evidence newToOld is the right direction for
/// this primitive (plan §2.6). `rw` is null at every Stage B call site
/// (`mesh.d`'s seven migrated callers — this module's header names them):
/// each already declares its OWN per-corner correspondence through
/// `beginCornerRelocate()` → `rw.relocated(oldLoopOfNewLoop)`, a
/// PER-CORNER shape built ahead of time in the kernel's own loop, not the
/// PER-NEW-FACE shape `carriedPerFace` wants — passing that site-local
/// handle in here would invoke the wrong method on it (`CornerRewrite.
/// carried()` asserts on exactly that mismatch: "open it with
/// beginCornerRewrite(), not beginCornerRelocate()"). A future caller that
/// opens with `beginCornerRewrite()` instead (matching THIS parameter's
/// shape) is the first real user of a non-null `rw`; until then the two
/// obligations stay independent — a rewrite with no PolyVertex map active
/// carries its planes exactly the same whether `rw` is passed or not,
/// because `CornerRewrite.carriedPerFace` on an inactive handle degrades to
/// `unchanged()` for free (see `Mesh.openCornerRewrite`'s doc comment: "no
/// map, no capture, arms nothing").
void rewriteFaces(ref Mesh m, uint[][] newFaces, in FaceSource src,
                  Mesh.CornerRewrite* rw = null,
                  PolyVertexBlend[uint] blendOfNewVertex = null,
                  const(PolyVertexGen)[] gens = null) {
    assert(src.oldOfNew.length == newFaces.length,
           format("rewriteFaces: FaceSource.oldOfNew.length (%d) must equal "
                ~ "newFaces.length (%d) — the correspondence must be TOTAL "
                ~ "over the new face array, or a plane silently truncates",
                  src.oldOfNew.length, newFaces.length));

    // Task 1902 Stage H — the op-log seam (plan §7.1). Captured BEFORE the
    // carry loop below overwrites `m`'s plane arrays: the drop set's whole
    // point is "the planes of an old face no new face names", and once the
    // `static foreach` below runs, those old values are gone. Gated on
    // `wantsFaceReindexRecording()` — the tracker's own opt-in, default
    // FALSE and unset by every production site (plan §7.1) — so a disarmed
    // rewrite (every rewrite today) pays exactly one bool+null check here
    // and allocates nothing.
    const bool wantFaceReindexRecord = m.wantsFaceReindexRecording();
    // TASK 4059 — one value, and its per-face plane group is GENERATED from
    // `kFacePlanes` (see `FacePlaneDrops`). The nine locals this replaces were
    // the plane list written out a third time by hand.
    FaceReindexRecord rec;
    if (wantFaceReindexRecord) {
        rec.oldFaceCount = cast(uint) m.faces.length;
        // Task 1903 Stage J — the per-CORNER half of the entry. The forward
        // carry below is many-to-one and lossy (a corner on an inserted vertex
        // is a weighted BLEND, a swept wall corner is GENERATED — neither the
        // blend table nor the gen list is in the op-log), so the pre-rewrite
        // corner values cannot be recovered by inverting the correspondence.
        // They are captured instead, HERE, at the last moment they are still
        // readable: before the `static foreach` carry below re-lays the corner
        // space and before `m.faces` moves. One arity + one value block per OLD
        // face, in index order — the same `Kind.MeshMapDelta` channel
        // `recordRemoveFaces` already pairs with (task 0689), read back by
        // `mesh_edit_delta.CornerCarry`'s FaceReindex case on REVERSE.
        //
        // Cheap where it does not apply and honest where it does. The whole
        // block is already behind `wantsFaceReindexRecording()`, which no
        // production site sets today; and the `hasPolyVertexMap()` gate below
        // is the one that makes the no-map case (the overwhelming majority of
        // meshes) cost NOTHING rather than merely cost little.
        //
        // The gate is on the OUTSIDE, not left to the callee (review round 1,
        // MINOR-5): `recordPolyVertexPayload` does return immediately without
        // a PolyVertex map, but the `allOld` list is built BEFORE it can — an
        // O(faces) reserve + append that no map-less mesh should ever pay.
        // When the map IS there the cost is O(corners) floats; see that
        // function's own COST paragraph for why that is the whole pre-op map
        // at this caller and only `Δ` at the other three.
        if (m.hasPolyVertexMap()) {
            FaceIdx[] allOld;
            allOld.reserve(rec.oldFaceCount);
            foreach (fi; m.faceIndices) allOld ~= fi;
            m.recordPolyVertexPayload(allOld);
        }
        // Which old index is named by at least one new face — the complement
        // is the drop set, same "named by no new face" test §7.2 describes —
        // and, for a survivor, the FIRST new index naming it: the same
        // tie-break `applyFaceReindexReverse` uses ("all such copies are
        // equal … within one entry", plan §7.2).
        bool[] named = new bool[](rec.oldFaceCount);
        uint[] firstNewOfOld = new uint[](rec.oldFaceCount);
        firstNewOfOld[] = uint.max;
        foreach (nf, of; src.oldOfNew) {
            if (of == kNoSource || of >= rec.oldFaceCount) continue;
            named[of] = true;
            if (firstNewOfOld[of] == uint.max) firstNewOfOld[of] = cast(uint) nf;
        }
        foreach (fi; m.faceIndices) {
            if (!named[fi]) {
                rec.dropIdx   ~= fi;
                rec.dropLists ~= m.faces[fi].dup;
                rec.dropPlanes.captureFace(m, fi);   // task 4059 — every plane, from the list
                continue;
            }
            // Review finding B2: a survivor's winding at reverse time would
            // otherwise be read off the CURRENT (post-reindex) mesh — the
            // POST-rewrite winding, not always the PRE-rewrite one this
            // survivor actually had (e.g. `Mesh.removeVertsByMask` drops a
            // corner from a kept face's list while its old index still
            // survives). `m.faces[fi]` is still the OLD winding here (the
            // carry loop below has not run yet), so compare it against the
            // NEW winding the caller is about to install at this face's
            // first naming new index and capture the old one whenever they
            // differ — the common case (unchanged winding) costs nothing
            // beyond this one comparison.
            const uint nf = firstNewOfOld[fi];
            if (nf < newFaces.length && newFaces[nf] != m.faces[fi]) {
                rec.survIdx   ~= fi;
                rec.survLists ~= m.faces[fi].dup;
            }
        }
    }

    // NOTE ON SHAPE: `__traits(getMember, m, n)` is used DIRECTLY (assigned
    // into `built` at the end) rather than bound once through
    // `alias plane = …;`. Measured (a 3-line repro, both directions):
    // `alias` over `__traits(getMember, refParam, name)` compiles but
    // silently loses the INSTANCE — every subsequent use reads as the
    // unqualified static member and dmd 2.112 rejects it ("accessing
    // non-static variable … requires an instance of `Mesh`"), for a `ref`
    // parameter and for a plain local alike. Only the TYPE may be aliased
    // (`typeof(...)` does not evaluate the instance), so `PlaneT` below is
    // the one alias in this loop. `srcPlane`, by contrast, is hoisted with a
    // plain `auto` — a VALUE assignment (dynamic arrays are a length+ptr
    // pair copied by value), not an alias, so it evaluates `m`'s instance
    // exactly once and does not hit the same rejection; it is read-only for
    // the rest of the loop, and it is deliberately the array's OLD contents
    // — the field itself is not reassigned until after the loop, at the
    // final `__traits(getMember, m, n) = built;` line, so hoisting it costs
    // nothing and reads the same bytes the per-iteration lookup did.
    static foreach (n; kFacePlanes) {
        {
            alias PlaneT = typeof(__traits(getMember, m, n));
            auto srcPlane = __traits(getMember, m, n);
            PlaneT built;
            built.length = newFaces.length;          // one allocation per plane
            foreach (nf; 0 .. newFaces.length) {
                const uint of = src.oldOfNew[nf];
                built[nf] = (of == kNoSource || of >= srcPlane.length)
                          ? typeof(built[0]).init
                          : srcPlane[of];  // lazy-length safe (plan §5)
            }
            __traits(getMember, m, n) = built;
        }
    }

    if (rw !is null)
        m.declareCornerProvenance(
            rw.carriedPerFace(newFaces, src.oldOfNew, blendOfNewVertex, gens));

    m.faces = newFaces;

    // Task 1902 Stage H, continued: the entry needs the POST-rewrite
    // windings too — `applyFaceReindexForward`'s replay literally re-calls
    // this primitive (plan §7.2: "one implementation, so replay and live
    // edit cannot drift"), and a duplicate/create face's winding is not
    // derivable from `src.oldOfNew` alone (a spatial array/mirror copy uses
    // NEW vertex indices, not its ancestor's — measured against
    // `arrayFacesGrid`/`mirrorFacesPlane`, the two duplicate-producing sites
    // §7.2 names). This is a correction to §7.2's field table, recorded in
    // the task card's `## Лог`, not a silent addition.
    if (wantFaceReindexRecord) {
        rec.oldOfNew = src.oldOfNew.dup;
        rec.newFaceLists.reserve(newFaces.length);
        foreach (l; newFaces) rec.newFaceLists ~= l.dup;
        m.recordFaceReindexIfWanted(rec);
    }
}

/// The vertex sibling of `rewriteFaces`: assign `newVerts` AND carry every
/// plane in `kVertPlanes` through `src`. No `rw` parameter — corners belong
/// to FACES, not vertices, so `rewriteFaces`'s corner-declaration half has
/// no vertex-domain analogue here. Per-vertex PolyVertex/Point mesh-map
/// carrying and the `Kind.Reindex` op-log publisher (`Mesh.compactUnreferenced`'s
/// existing `recordReindex`) are OUT of Stage A's scope — task 1903 decides
/// them; see this module's header and `doc/reindex_primitive_plan.md` §7.5/§9.
///
/// DOES NOT re-key `edgeSetMask` (`kExemptPlanes` above). That AA is keyed by
/// edge KEY, not index, so a face renumbering alone cannot invalidate it, but
/// a VERTEX renumbering can — an edge's key is derived from its endpoint
/// vertex indices. Re-keying it through `mesh_selsets.selSetRekeyEdges` is
/// the CALLER's obligation, exactly as it is today at every existing vertex
/// remap site (e.g. `Mesh.applyVertexRemap`, which calls it right after its
/// own hand-rolled plane carry and before `rebuildEdges()`): call it
/// immediately after `rewriteVertices` returns, before `rebuildEdges()` /
/// `buildLoops()` run. This primitive deliberately does not call it, so a
/// caller that forgets it fails exactly as loudly as one that forgets it
/// today — this task does not change who owns that call.
void rewriteVertices(ref Mesh m, Vec3[] newVerts, in VertSource src) {
    assert(src.oldOfNew.length == newVerts.length,
           format("rewriteVertices: VertSource.oldOfNew.length (%d) must "
                ~ "equal newVerts.length (%d) — the correspondence must be "
                ~ "TOTAL over the new vertex array, or a plane silently "
                ~ "truncates", src.oldOfNew.length, newVerts.length));

    static foreach (n; kVertPlanes) {
        {
            alias PlaneT = typeof(__traits(getMember, m, n));
            auto srcPlane = __traits(getMember, m, n);  // OLD buffer — see rewriteFaces's
                                                          // NOTE ON SHAPE above
            PlaneT built;
            built.length = newVerts.length;
            foreach (nv; 0 .. newVerts.length) {
                const uint of = src.oldOfNew[nv];
                built[nv] = (of == kNoSource || of >= srcPlane.length)
                          ? typeof(built[0]).init
                          : srcPlane[of];
            }
            __traits(getMember, m, n) = built;
        }
    }

    m.vertices = newVerts;
}

// ---------------------------------------------------------------------------
// The APPEND half of the funnel (task 4059).
//
// `rewriteFaces` above covers the RENUMBERING half: a kernel that replaces
// `faces` wholesale. It does not cover the other, more common shape — a
// kernel that APPENDS faces to the tail and then has to bring every parallel
// plane up to the new length. That was 32 hand-written
// `<plane>.length = faces.length` lines, four in each of eight functions
// (`Mesh.resetSelection`, `Mesh.syncSelection`, `radialArrayFaces`,
// `arrayFaces`, `arrayFacesGrid`, `mirrorFacesPlane`,
// `duplicateSelectedFaces`, `appendGeometry` — measured 2026-09-04, task
// 4059's `## Лог`), plus `resizeSubpatch()`/`resizeFaceSelection()` standing
// in for the fifth. A plane added to `kFacePlanes` reached NONE of them
// without eight separate edits, and the sixteenth of those is the finding
// audit 4 opened with.
//
// WHAT THIS IS NOT. It does not append the WINDINGS — the eight kernels
// interleave their face appends with vertex creation and with
// `appendFaceRaw`'s per-corner map growth, and each one then assigns the new
// faces' plane values from a source face by hand. Folding those loops in
// would ALSO fold `faceMarks` in whole-word, which inherits Hide and Lock on
// a duplicate — a behaviour change, not a refactor (the kernels copy the
// Subpatch bit alone, via `setFaceSubpatch`). The card sketched
// `appendFaces(lists, policy)`; the `lists` half is deliberately not taken
// here, and the reason is that inheritance semantics question, which is a
// measured law we do not have.
// ---------------------------------------------------------------------------

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

/// Bring every plane in `kFacePlanes` to `m.faces.length`.
///
/// Call it AFTER the faces have been appended (or removed) and, at the
/// topology kernels, after `rebuildEdges()` — the position the 32 hand-written
/// lines occupied. Touches no version stamp and publishes nothing, for the
/// same reason `rewriteFaces` does not: see this module's header.
///
/// The body iterates `kFacePlanes`, so a plane added to that list is grown
/// here without anyone remembering to come back. That is the whole point, and
/// it is what the mutation in task 4059's `## Мутация` exercises: drop a name
/// from `kFacePlanes` and `tests/unit/mesh_face_plane_append_test.d`'s
/// by-NAME length assertion for that plane reddens (the by-name spelling is
/// deliberate — an assertion that itself iterated `kFacePlanes` would go green
/// over the shortened list, which is the defect `CLAUDE.md`'s "a check that
/// cannot come out differently" section is about).
///
/// `fit` HAS NO DEFAULT, and the omission is the point. It carried
/// `= PlaneFit.Exact` when this landed, and that made the policy split
/// one-directional: giving a `GrowOnly` site the `Exact` fit is caught by
/// Block C of `tests/unit/mesh_face_plane_append_test.d`, but the reverse —
/// an `Exact` site silently taking `GrowOnly` — was witnessed by nothing.
/// Two call sites were flipped from `Exact` to `GrowOnly` as a mutation and
/// BOTH runs stayed green at 487 modules. That direction is the dangerous
/// one: a grow-only fit leaves a plane LONGER than `faces` after a shrink,
/// and those stale entries become readable again the moment the face array
/// regrows onto them. Without a default the omission is a compile error at
/// the site rather than a test's responsibility, which is the check that
/// cannot be forgotten. All eight call sites spell their fit.
void appendFacePlanes(ref Mesh m, PlaneFit fit) {
    const size_t want = m.faces.length;
    static foreach (n; kFacePlanes) {
        {
            // `__traits(getMember, m, n)` written out at each use rather than
            // bound through an `alias` — see `rewriteFaces`'s NOTE ON SHAPE
            // for why an alias over a `ref` parameter loses the instance.
            if (fit == PlaneFit.Exact || __traits(getMember, m, n).length < want)
                __traits(getMember, m, n).length = want;
        }
    }
}

// ---------------------------------------------------------------------------
// The EDGE domain (task 4059) — the carry `Mesh.rebuildEdges` never had.
//
// THE CLASS OF BUG THIS REMOVES, and it is a live one rather than a tidiness
// itch. `rebuildEdges` empties `edges` and RE-DISCOVERS every edge from
// `faces` in face/corner order, so an edge's index is a function of the face
// order it happens to be found in — a spin, a winding rewrite, a face insert
// all renumber the whole array. Nothing carried `edgeMarks` or
// `edgeSelectionOrder` through that. `rebuildEdges`'s own comment named the
// hazard ("the renumbering hazard this function is famous for — `edgeMarks`
// is NOT re-indexed"), and the tree's answer was 43 hand-written
// `clearEdgeSelectionResize()` / `resizeEdgeSelection()` calls at the call
// sites: an edge selection survived a topology edit only because somebody
// remembered to throw it away.
//
// THE 43 IS CALL EXPRESSIONS, not mentions — the same defect this task
// already corrected once for `rebuildEdges` (commit `30d8b039`). A plain
// `grep -rn … source | wc -l` answers 64, counting every comment that NAMES
// the function, these lines included, so it moves when you write about it.
// Measured 2026-09-05, 43 across 14 files (21 in `mesh.d`), on this branch
// AND on the trunk:
//
//     find source -name '*.d' -print0 | xargs -0 perl -0777 -pe \
//       's{/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"}{ }gs' \
//       | grep -vE '\bvoid\s+(clearEdgeSelectionResize|resizeEdgeSelection)\s*\(' \
//       | grep -oE '\b(clearEdgeSelectionResize|resizeEdgeSelection)\s*\(' | wc -l
//
// THE CORRESPONDENCE IS A KEY, NOT AN INDEX MAP — forced, not chosen. A face
// rewrite HAS a newToOld correspondence because the kernel built the new
// array. `rebuildEdges` is handed nothing and derives everything; what
// survives a re-derive is the edge's undirected endpoint key, which is what
// `kExemptPlanes` already says about `edgeSetMask` ("key-space, not
// index-space — immune to face AND vertex renumbering by construction").
//
// WHAT IT DOES NOT DECIDE. It removes none of the 43 manual resets: whether
// `mesh.extrude` should leave the source edge selected is a law we match,
// not one we may design, and that is task 4190.
// ---------------------------------------------------------------------------

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

/// The edge-key -> OLD-edge-index correspondence, taken BEFORE
/// `Mesh.rebuildEdges` empties `edges`, plus whether there is anything at all
/// to carry.
struct EdgeCarry {
    uint[ulong] oldIndexOfKey;
    /// False when every value on every plane in `kEdgePlanes` is already
    /// `T.init` — the common case (no edge has ever been selected, hidden or
    /// stamped on this mesh). The AA above is then never built, and
    /// `applyEdgePlanes` degrades to a length fit that allocates only when the
    /// edge count actually moved. Measured shape, not a guess: `rebuildEdges`
    /// is called from 39 sites across 12 files (measured 2026-09-05, a
    /// comment- and string-stripped scan of `source/**.d` for
    /// `\brebuildEdges\s*\(`, declaration excluded) and is already
    /// O(corners), so the scan that decides this adds a same-order pass with
    /// no allocation, while the AA it avoids is one hash entry per edge.
    bool armed;
}

/// Snapshot the per-edge planes' correspondence. MUST run before
/// `edges.length = 0`; there is nothing to key from afterwards, and this is
/// the "right check, wrong moment" trap `CLAUDE.md` names — the value read is
/// correct and the position is the whole of it.
EdgeCarry captureEdgePlanes(ref Mesh m) {
    EdgeCarry c;
    static foreach (n; kEdgePlanes) {
        {
            if (!c.armed) {
                foreach (v; __traits(getMember, m, n))
                    if (v != typeof(v).init) { c.armed = true; break; }
            }
        }
    }
    if (!c.armed) return c;
    foreach (ei, ref e; m.edges)
        c.oldIndexOfKey[edgeKey(e[0], e[1])] = cast(uint) ei;
    return c;
}

/// Re-lay every plane in `kEdgePlanes` over the REBUILT `edges`, each value
/// following its edge's endpoint key. An edge the rebuild produced that the
/// snapshot never saw takes `T.init`; an edge the snapshot had that the
/// rebuild did not produce is dropped, which is the correct answer — it is
/// not in the mesh any more.
///
/// MUST run after `edges` has been refilled and BEFORE `rebuildEdges`'s own
/// `commitChange`: the Hide derive that commit runs writes the Select bit of
/// hidden edges, and it must see the carried marks rather than the pre-carry
/// ones.
///
/// Also brings the planes to `edges.length`, which `rebuildEdges` did not do
/// before — the caller's `resizeEdgeSelection()` did. That call is left in
/// place at all 43 sites: it ALSO resizes the Edge-domain mesh maps, which is
/// not this primitive's domain.
void applyEdgePlanes(ref Mesh m, in EdgeCarry c) {
    const size_t want = m.edges.length;
    if (!c.armed) {
        // Every value was `T.init`, so an all-`init` plane of the new length
        // IS the carry's answer — and `.length = want` produces exactly that
        // (a truncation keeps an all-init prefix; a growth zero-fills), with
        // no allocation when the count did not move.
        static foreach (n; kEdgePlanes) {
            {
                if (__traits(getMember, m, n).length != want)
                    __traits(getMember, m, n).length = want;
            }
        }
        return;
    }
    static foreach (n; kEdgePlanes) {
        {
            // See `rewriteFaces`'s NOTE ON SHAPE for why the member is spelled
            // out at each use and only the TYPE is aliased.
            alias PlaneT = typeof(__traits(getMember, m, n));
            auto srcPlane = __traits(getMember, m, n);   // the OLD buffer
            PlaneT built;
            built.length = want;
            foreach (ei; 0 .. want) {
                const ulong key = edgeKey(m.edges[ei][0], m.edges[ei][1]);
                if (auto oi = key in c.oldIndexOfKey)
                    if (*oi < srcPlane.length) built[ei] = srcPlane[*oi];
            }
            __traits(getMember, m, n) = built;
        }
    }
}

// ---------------------------------------------------------------------------
// Version-stamp invariant (plan §2.5) — `rewriteFaces`/`rewriteVertices` must
// move NEITHER `mutationVersion` NOR `topologyVersion`: `commitChange` stays
// the CALLER's job, run once at the kernel's tail, after `rebuildEdges()` /
// `buildLoops()` — never mid-kernel over a `faces` that does not yet agree
// with `edges`. Same shape as `mesh.d`'s own in-struct pin for
// `vertexAdjacencyCSR`'s version-silence (task 0401).
//
// Mutation for this test (§8 M6): add `m.commitChange(MeshEditScope.Polygons)`
// inside `rewriteFaces` (or `rewriteVertices`) — reddens here with the
// message below.
// ---------------------------------------------------------------------------

unittest // rewriteFaces / rewriteVertices touch neither mutationVersion nor topologyVersion
{
    import mesh : makeCube;

    Mesh m = makeCube();
    m.syncSelection();
    const ulong mutBefore = m.mutationVersion;
    const ulong topBefore = m.topologyVersion;

    uint[][] sameFaces = m.faces.dup;
    rewriteFaces(m, sameFaces, FaceSource.identity(sameFaces.length));
    assert(m.mutationVersion == mutBefore && m.topologyVersion == topBefore,
           "rewriteFaces must not move mutationVersion/topologyVersion — the "
         ~ "tail commit is the caller's (plan §2.5)");

    Vec3[] sameVerts = m.vertices.dup;
    rewriteVertices(m, sameVerts, VertSource.identity(sameVerts.length));
    assert(m.mutationVersion == mutBefore && m.topologyVersion == topBefore,
           "rewriteVertices must not move mutationVersion/topologyVersion — "
         ~ "the tail commit is the caller's (plan §2.5)");
}

// ---------------------------------------------------------------------------
// FaceSource / VertSource adapter contracts — pinned here (not in
// mesh_planes_test.d's L3) because they are properties of the correspondence
// TYPE, independent of which planes exist.
// ---------------------------------------------------------------------------

unittest // FaceSource.identity: entry i names old face i, for every i
{
    auto src = FaceSource.identity(5);
    assert(src.oldOfNew.length == 5);
    foreach (i; 0 .. 5) assert(src.oldOfNew[i] == i);
}

unittest // FaceSource.fromOldToNew: -1 (dropped) becomes absent from oldOfNew; a kept index round-trips
{
    // Old faces 0,1,2,3; old face 1 dropped, the rest compact down by one.
    const int[] oldToNew = [0, -1, 1, 2];
    auto src = FaceSource.fromOldToNew(oldToNew, 3);
    assert(src.oldOfNew.length == 3);
    assert(src.oldOfNew[0] == 0, "new face 0 came from old face 0");
    assert(src.oldOfNew[1] == 2, "new face 1 came from old face 2");
    assert(src.oldOfNew[2] == 3, "new face 2 came from old face 3");
}

unittest // VertSource: same two contracts as FaceSource, independently instanced
{
    auto idSrc = VertSource.identity(3);
    assert(idSrc.oldOfNew == [0u, 1u, 2u]);

    const int[] oldToNew = [-1, 0, 1];
    auto src = VertSource.fromOldToNew(oldToNew, 2);
    assert(src.oldOfNew == [1u, 2u]);
}
