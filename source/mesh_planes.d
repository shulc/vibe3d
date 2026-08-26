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
// SIBLING LIST: `source/mesh_edit_delta.d`'s `MeshOpEntry` carries its own
// hand-maintained per-face group (`faceMat`/`facePrt`/`faceSub`/
// `faceSetMsk`/`faceOrd` — task 1902 Stage H added `faceOrd`, closing the
// gap this comment used to flag) for the undo/redo op-log. The two lists
// are independent (one is the LIVE-mesh carry, the other is a REPLAY
// payload) but describe the same five per-face planes, so a new entry in
// `kFacePlanes` below is a new field `MeshOpEntry` should probably also
// carry — check that file when extending this one. Executable side of this
// cross-reference: `tests/unit/mesh_planes_census_test.d`'s
// `kFacePlaneToEntryField` unittest walks `kFacePlanes` against
// `MeshOpEntry`'s field set by name and reddens when the two diverge.
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

/// The per-vertex planes carried by `rewriteVertices`.
enum string[] kVertPlanes = [
    "vertexMarks", "vertexSelectionOrder", "vertexSetMask",
];

/// Per-face/per-vertex-SHAPED `Mesh` fields that L2's census selects (name
/// prefix `face`/`vertex`/`vert`, type has `.length`) but that this
/// primitive deliberately does NOT carry — each with why. Measured
/// 2026-08-25 (`tests/unit/mesh_planes_census_test.d`'s own probe): the
/// census selects 16 fields; 8 are `kFacePlanes`/`kVertPlanes` above, these
/// first 8 entries are the rest.
///
/// `edgeSetMask` below is the ODD entry: its name starts `edge`, not
/// `face`/`vertex`/`vert`, so L2's prefix selector never reaches it and this
/// entry is never consulted at runtime — it is recorded here purely so a
/// reader classifying `edgeSetMask` (which, being `ulong[ulong]`, LOOKS
/// exactly like a per-element plane) finds the reason next to its siblings
/// rather than nowhere (plan §2.4, §9 risk "edgeSetMask mistaken for an
/// index plane"). See `rewriteVertices`'s doc comment below for who owns the
/// re-key it names.
enum string[string] kExemptPlanes = [
    "faces":            "the SUBJECT `rewriteFaces` assigns, not a plane it carries",
    "vertices":         "the SUBJECT `rewriteVertices` assigns, not a plane it carries",
    "faceLoop":         "rebuilt wholesale by Mesh.buildLoops",
    "vertLoop":         "rebuilt wholesale by Mesh.buildLoops",
    "vertFanOrdered_":  "derived adjacency cache, rebuilt by buildLoops",
    "vertDartStart":    "derived adjacency cache (CSR offsets), rebuilt by buildLoops",
    "vertDartAdj":      "derived adjacency cache (CSR neighbours), rebuilt by buildLoops",
    "vertexSetNames":   "a NAME registry (string per slot), not a per-element plane",
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
//   2026-08-25, task 1906 stage 3 — CURRENT:
//     Mesh.tupleof.length                          == 54
//     count of those fields that are array-shaped  == 34
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

static assert(Mesh.tupleof.length == 54,
    "Mesh gained (or lost) an instance field. Classify it before bumping this "
  ~ "count: per-face data goes in kFacePlanes, per-vertex data in kVertPlanes "
  ~ "— INCLUDING data behind a wrapper struct such as FaceList, which is not "
  ~ "an array type and which the array-shaped assert below will NOT flag. "
  ~ "Anything derived, rebuilt or scalar: bump this count and say why in the "
  ~ "commit message. dmd stops at the first failing static assert in this "
  ~ "module: bump this count, recompile, and read the array-shaped assert "
  ~ "below to learn which KIND landed.");

static assert(countArrayShapedFields!Mesh == 34,
    "Mesh gained (or lost) an ARRAY-shaped field. If the 54-count above moved "
  ~ "too, the new field is a plain array — a plane candidate, classify it. If "
  ~ "ONLY the count above moved, it is a scalar or a wrapper type.");

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
    FaceIdx[] recDropIdx;
    uint[][]  recDropLists;
    uint[]    recDropMat, recDropPrt, recDropSub;
    ulong[]   recDropSetMsk;
    int[]     recDropOrd;
    FaceIdx[] recSurvIdx;      // review finding B2
    uint[][]  recSurvLists;    // review finding B2
    uint      recOldFaceCount;
    if (wantFaceReindexRecord) {
        recOldFaceCount = cast(uint) m.faces.length;
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
            allOld.reserve(recOldFaceCount);
            foreach (fi; m.faceIndices) allOld ~= fi;
            m.recordPolyVertexPayload(allOld);
        }
        // Which old index is named by at least one new face — the complement
        // is the drop set, same "named by no new face" test §7.2 describes —
        // and, for a survivor, the FIRST new index naming it: the same
        // tie-break `applyFaceReindexReverse` uses ("all such copies are
        // equal … within one entry", plan §7.2).
        bool[] named = new bool[](recOldFaceCount);
        uint[] firstNewOfOld = new uint[](recOldFaceCount);
        firstNewOfOld[] = uint.max;
        foreach (nf, of; src.oldOfNew) {
            if (of == kNoSource || of >= recOldFaceCount) continue;
            named[of] = true;
            if (firstNewOfOld[of] == uint.max) firstNewOfOld[of] = cast(uint) nf;
        }
        foreach (fi; m.faceIndices) {
            if (!named[fi]) {
                recDropIdx    ~= fi;
                recDropLists  ~= m.faces[fi].dup;
                recDropMat    ~= (fi < m.faceMaterial.length) ? m.faceMaterial[fi] : 0;
                recDropPrt    ~= (fi < m.facePart.length) ? m.facePart[fi] : 0;
                recDropSub    ~= (m.isFaceSubpatch(fi) ? 1u : 0u);
                recDropSetMsk ~= (fi < m.faceSetMask.length) ? m.faceSetMask[fi] : 0UL;
                recDropOrd    ~= (fi < m.faceSelectionOrder.length) ? m.faceSelectionOrder[fi] : 0;
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
                recSurvIdx   ~= fi;
                recSurvLists ~= m.faces[fi].dup;
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
        uint[][] recNewLists;
        recNewLists.reserve(newFaces.length);
        foreach (l; newFaces) recNewLists ~= l.dup;
        m.recordFaceReindexIfWanted(src.oldOfNew.dup, recOldFaceCount, recNewLists,
                                    recDropIdx, recDropLists, recDropMat, recDropPrt,
                                    recDropSub, recDropSetMsk, recDropOrd,
                                    recSurvIdx, recSurvLists);
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
