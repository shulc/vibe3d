module screen_buckets;

// ---------------------------------------------------------------------------
// A screen-space bucket grid over axis-aligned pixel boxes — the broad phase
// for "which of these N boxes can contain this pixel" (task 1351).
//
// WHAT IT IS FOR. `VisibilityProbe` asks that question once per candidate
// vertex against every front-facing face, which is O(candidates x faces): on a
// 100 K-face sheet with the faces turned toward the eye, one snap query costs
// ~8 SECONDS (measured, n = 316, 100 489 verts / 99 856 faces). A candidate and
// a face can only interact when the face's screen box covers the candidate's
// pixel, so bucketing the boxes by cell reduces the walk to the handful of
// faces that overlap one cell.
//
// WHY IT IS A LEAF MODULE WITH NO GLOBALS, and why that is a different shape
// from `snap.d`'s `CandidateGrid` rather than a duplicate of it:
//
//   * `snap.d`'s grid is a CACHE. It lives in module state (`g_gridSets`),
//     is keyed on (slot, kind, mesh address, mutation version, viewport), is
//     rebuilt when the key moves, and its query runs through module scratch
//     under a mutex. That machinery earns its keep there: the same grid is
//     queried many times per frame from the same key.
//   * This kernel is a pure FUNCTION: boxes in, CSR out, by value. Its result
//     lives inside a `VisibilityProbe`, which is itself a stack value built by
//     a `const` method of `Mesh` — there is nowhere to hang a cache and nothing
//     to lock. What the two share is the MECHANISM (a counting sort into cells);
//     they deliberately do not share a budget, because the domains differ in
//     kind: this one is bounded by the viewport by construction (the caller
//     clips), while a candidate grid's is not.
//
// It imports NOTHING but Phobos maths. In particular it does not import `snap`,
// which has a module constructor — `mesh` -> `snap` would be a constructor
// cycle and a druntime abort at startup, not a style question.
// ---------------------------------------------------------------------------

import std.math : floor, isFinite;

/// Ceiling on the number of `int`s ONE bucket build may allocate: `cellStart`
/// (cells + 1), the fill cursor (cells) and `items` (one entry per box per
/// overlapped cell). Sized well above any domain a clipped viewport can
/// produce, so it is a BACKSTOP and not a working mode — the working bound is
/// the caller's clip rectangle, which is the viewport plus a query pad.
///
/// It has to exist anyway, and not because the viewport is unbounded: `items`
/// is bounded by the domain only THROUGH the boxes, and a single face seen
/// edge-on spans the whole domain by itself, so F faces can ask for F x cells
/// entries with no viewport being large at all.
enum long MAX_OCCL_BUCKET_INTS = 1 << 22;   // 4.2 M ints = 16 MiB

/// Cell edge in pixels. DERIVED, not tuned: at the size this exists for
/// (n = 316, ~100 K faces on a [-1, 1] sheet filling ~770 px) a face projects
/// to roughly 2 px, so a 16 px cell holds ~64 of them — which is the walk
/// length a candidate pays, against ~100 000 for the linear scan. Bigger cells
/// buy a shorter cell list and a longer walk; smaller ones the reverse, and
/// below the mean face size the entry count starts growing instead.
enum float OCCL_CELL_PX = 16.0f;

/// CSR buckets over a bounded pixel domain. `built == false` means the caller
/// must fall back to walking everything — either the budget was exceeded, or a
/// box was not finite and dropping it would have changed an answer.
struct ScreenBuckets {
    int   minCx, minCy;     // cell coordinate of the domain's low corner
    int   nCols, nRows;
    float cellPx = OCCL_CELL_PX;
    float domX0, domY0, domX1, domY1;   // the clip rectangle, in pixels
    int[] cellStart;        // length nCols*nRows + 1
    int[] items;            // box indices, repeated across overlapped cells
    bool  built;
}

/// Bucket `boxes` (four floats per entry: minX, maxX, minY, maxY) into a CSR
/// grid over the pixel rectangle [x0, x1] x [y0, y1].
///
/// A box that does not intersect the rectangle is DROPPED, and that is the
/// half of this function that pays for itself: without it the border cells
/// accumulate an entry for every off-screen face, which is exactly the
/// configuration a modeller works in when snapping near the edge of the view.
/// It is sound because the caller only ever queries pixels INSIDE the
/// rectangle — a pixel outside it takes the caller's own linear path.
///
/// Returns `built == false` (and leaves the arrays null) when the build would
/// exceed `maxInts`, or when any box carries a non-finite bound. The second is
/// not fastidiousness: the linear walk's bbox test is `px < minX || px > maxX
/// || ...`, every comparison of which is FALSE against NaN, so a NaN box is a
/// live occluder there. Dropping it here would make the two paths disagree,
/// which is the one thing a broad phase may never do.
ScreenBuckets buildScreenBuckets(const(float)[] boxes,
                                 float x0, float y0, float x1, float y1,
                                 float cellPx = OCCL_CELL_PX,
                                 long maxInts = MAX_OCCL_BUCKET_INTS)
{
    ScreenBuckets g;
    g.cellPx = cellPx;
    g.domX0 = x0; g.domY0 = y0; g.domX1 = x1; g.domY1 = y1;
    if (!(cellPx > 0) || !isFinite(cellPx)) return g;
    if (!(isFinite(x0) && isFinite(y0) && isFinite(x1) && isFinite(y1))) return g;
    if (!(x1 >= x0 && y1 >= y0)) return g;
    // THE CELL COORDINATE HAS TO SURVIVE THE CAST, and `isFinite` is not that
    // check. `cast(long)floor(1e30f / 16)` is out of `long`'s range; x86 hands
    // back `long.min` for it, so `minCx` and `maxCx` both come out `long.min`,
    // their difference is 1, the budget test below passes with a ONE-CELL grid,
    // and every box then indexes that grid at `floor(px/16) - long.min`, which
    // wraps to an arbitrary `int`. That is an out-of-bounds WRITE in the fill
    // pass, reached from a caller passing a big-but-finite pad — measured, not
    // theorised (the caller-side clamp on `queryPadPx` was removed as a
    // mutation and the corpus died on `ArrayIndexError` here).
    //
    // A domain wider than a billion pixels is not a camera; refusing it costs
    // the caller its linear fallback and nothing else.
    enum float MAX_DOMAIN_PX = 1.0e9f;
    if (!(x0 >= -MAX_DOMAIN_PX && x1 <= MAX_DOMAIN_PX
       && y0 >= -MAX_DOMAIN_PX && y1 <= MAX_DOMAIN_PX)) return g;

    immutable size_t n = boxes.length / 4;
    immutable float inv = 1.0f / cellPx;

    immutable long minCx = cast(long)floor(x0 * inv);
    immutable long minCy = cast(long)floor(y0 * inv);
    immutable long maxCx = cast(long)floor(x1 * inv);
    immutable long maxCy = cast(long)floor(y1 * inv);
    immutable long spanCols = maxCx - minCx + 1;
    immutable long spanRows = maxCy - minCy + 1;
    if (spanCols <= 0 || spanRows <= 0) return g;
    // Guarded so the product cannot overflow: past the ceiling on either axis
    // the answer is already decided.
    immutable long cells = (spanCols > maxInts || spanRows > maxInts)
                         ? long.max : spanCols * spanRows;
    if (cells > maxInts) return g;

    // Per-box clipped cell range, and the entry count, in one pass. No
    // allocation yet, so an over-budget domain costs O(boxes) and nothing else.
    auto lo = new int[](n * 2);
    auto hi = new int[](n * 2);
    auto keep = new bool[](n);
    long entries = 0;
    foreach (i; 0 .. n) {
        immutable size_t o = i * 4;
        float bx0 = boxes[o], bx1 = boxes[o + 1];
        float by0 = boxes[o + 2], by1 = boxes[o + 3];
        if (!(isFinite(bx0) && isFinite(bx1) && isFinite(by0) && isFinite(by1)))
            return g;   // see the doc comment: a NaN box must not be dropped
        // No overlap with the clip rectangle ⇒ this box can never contain a
        // queried pixel, because every queried pixel is inside it.
        if (bx1 < x0 || bx0 > x1 || by1 < y0 || by0 > y1) continue;
        if (bx0 < x0) bx0 = x0;
        if (bx1 > x1) bx1 = x1;
        if (by0 < y0) by0 = y0;
        if (by1 > y1) by1 = y1;
        // Clamped to the rectangle first, so these casts are bounded by the
        // domain and cannot overflow on a projection that came back at 1e30.
        immutable int cx0 = cast(int)(cast(long)floor(bx0 * inv) - minCx);
        immutable int cy0 = cast(int)(cast(long)floor(by0 * inv) - minCy);
        immutable int cx1 = cast(int)(cast(long)floor(bx1 * inv) - minCx);
        immutable int cy1 = cast(int)(cast(long)floor(by1 * inv) - minCy);
        lo[i * 2] = cx0; lo[i * 2 + 1] = cy0;
        hi[i * 2] = cx1; hi[i * 2 + 1] = cy1;
        keep[i] = true;
        entries += cast(long)(cx1 - cx0 + 1) * (cy1 - cy0 + 1);
        if (2 * cells + entries + 1 > maxInts) return g;
    }
    if (2 * cells + entries + 1 > maxInts) return g;

    g.minCx = cast(int)minCx;
    g.minCy = cast(int)minCy;
    g.nCols = cast(int)spanCols;
    g.nRows = cast(int)spanRows;
    immutable size_t nCells = cast(size_t)cells;

    // CSR counting sort. Boxes are walked in ascending index in BOTH passes,
    // so within each bucket the entries stay index-ascending — which keeps the
    // bucketed walk in the same order as the linear one wherever the two visit
    // the same faces.
    auto counts = new int[](nCells + 1);
    foreach (i; 0 .. n) {
        if (!keep[i]) continue;
        foreach (cy; lo[i * 2 + 1] .. hi[i * 2 + 1] + 1)
            foreach (cx; lo[i * 2] .. hi[i * 2] + 1)
                counts[cast(size_t)cy * g.nCols + cx + 1]++;
    }
    foreach (i; 1 .. nCells + 1) counts[i] += counts[i - 1];
    g.cellStart = counts;
    g.items = new int[](counts[nCells]);
    auto cursor = new int[](nCells);
    foreach (i; 0 .. nCells) cursor[i] = counts[i];
    foreach (i; 0 .. n) {
        if (!keep[i]) continue;
        foreach (cy; lo[i * 2 + 1] .. hi[i * 2 + 1] + 1)
            foreach (cx; lo[i * 2] .. hi[i * 2] + 1) {
                immutable size_t c = cast(size_t)cy * g.nCols + cx;
                g.items[cursor[c]++] = cast(int)i;
            }
    }
    g.built = true;
    return g;
}

/// The box indices bucketed into the cell containing pixel (px, py).
///
/// `inDomain` is false when the pixel lies outside the clip rectangle the
/// buckets were built over (or when they were not built at all); the returned
/// slice is then empty and the caller MUST answer some other way — the buckets
/// know nothing about that pixel, which is not the same statement as "nothing
/// covers it".
const(int)[] queryScreenCell(const ref ScreenBuckets g, float px, float py,
                             out bool inDomain)
{
    inDomain = false;
    if (!g.built) return null;
    // NaN fails every one of these, which is the answer we want.
    if (!(px >= g.domX0 && px <= g.domX1 && py >= g.domY0 && py <= g.domY1))
        return null;
    immutable float inv = 1.0f / g.cellPx;
    immutable long cx = cast(long)floor(px * inv) - g.minCx;
    immutable long cy = cast(long)floor(py * inv) - g.minCy;
    if (cx < 0 || cy < 0 || cx >= g.nCols || cy >= g.nRows) return null;
    inDomain = true;
    immutable size_t c = cast(size_t)cy * g.nCols + cast(size_t)cx;
    return g.items[g.cellStart[c] .. g.cellStart[c + 1]];
}

// ---------------------------------------------------------------------------
unittest {
    // Three boxes: one inside, one straddling the left edge (so its clipped
    // cell range starts at the domain edge and its unclipped one is negative),
    // one entirely outside.
    float[] boxes = [
        100.0f, 140.0f,  50.0f,  90.0f,      // 0: inside
        -40.0f,  20.0f,  50.0f,  90.0f,      // 1: straddles x = 0
      -900.0f, -800.0f,  50.0f,  90.0f,      // 2: entirely outside
    ];
    auto g = buildScreenBuckets(boxes, 0, 0, 320, 240, 16.0f);
    assert(g.built);

    bool inDom;
    auto a = queryScreenCell(g, 120.0f, 70.0f, inDom);
    assert(inDom && a.length == 1 && a[0] == 0, "the inside box must bucket");

    auto b = queryScreenCell(g, 4.0f, 70.0f, inDom);
    assert(inDom && b.length == 1 && b[0] == 1,
        "the clipped part of a straddling box must still bucket");

    // Every cell of the domain: box 2 must appear nowhere.
    foreach (e; g.items) assert(e != 2, "an entirely-outside box was inserted");

    // A pixel outside the domain is NOT answered — the caller has to fall back.
    auto c = queryScreenCell(g, -50.0f, 70.0f, inDom);
    assert(!inDom && c.length == 0);

    // Budget: a ceiling of zero must refuse to build rather than allocate.
    auto tiny = buildScreenBuckets(boxes, 0, 0, 320, 240, 16.0f, 0);
    assert(!tiny.built, "the budget must be able to refuse the build");
    bool dummy;
    assert(queryScreenCell(tiny, 120.0f, 70.0f, dummy).length == 0 && !dummy);

    // A non-finite box refuses the whole build: dropping it would make the
    // bucketed answer differ from the linear one, which never drops it.
    float[] nan = boxes.dup;
    nan[1] = float.nan;
    assert(!buildScreenBuckets(nan, 0, 0, 320, 240, 16.0f).built);

    // A domain too wide for the cell coordinate to survive the cast to `long`
    // must be REFUSED, not bucketed. Without the guard this call writes out of
    // bounds in the fill pass rather than returning anything at all — the cell
    // span comes out as 1 (both corners cast to `long.min`) and every box then
    // indexes that single cell at a wrapped `int`.
    assert(!buildScreenBuckets(boxes, -1.0e30f, -1.0e30f, 1.0e30f, 1.0e30f,
                               16.0f).built);
    assert(!buildScreenBuckets(boxes, float.nan, 0, 320, 240, 16.0f).built);
    assert(!buildScreenBuckets(boxes, 0, 0, float.infinity, 240, 16.0f).built);
    // A zero or negative cell size is a division by zero away from nonsense.
    assert(!buildScreenBuckets(boxes, 0, 0, 320, 240, 0.0f).built);
    assert(!buildScreenBuckets(boxes, 0, 0, 320, 240, -16.0f).built);
    // An inverted rectangle is not an empty one — refuse rather than guess.
    assert(!buildScreenBuckets(boxes, 320, 0, 0, 240, 16.0f).built);
}
