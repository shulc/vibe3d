module uv_island;

/// Pure UV-layout helpers: island detection, bbox, fit-affine, shelf-pack.
///
/// No mesh mutation, no `commitChange`, no OpenGL.  Every function here is
/// analytic — exercisable by `dub test --config=modeling` unit tests with no
/// running app.
///
/// Island connectivity rule (task-specified, vibe3d-divergence):
///   Two face-corners belong to the same island if they can be reached through
///   a chain of
///     (a) same-face adjacency  — all corners of one face are co-island, or
///     (b) shared-vertex + matching UV coords (within kUvDegenEps) — seams
///         (same vert, different UV) split islands; continuous UV is needed.
///
/// Shelf-pack heuristic (vibe3d-divergence):
///   Sort islands by (height desc, id asc).  binW = max(maxIslandW, √Σarea).
///   Greedy row/shelf scan; uniform scale s = 1/max(packedW, packedH) maps
///   everything into [0,1]².  Per-island affine = diag(s,s) + translation so
///   (uv − bboxMin + slot) × s lands in the allocated slot inside [0,1]².

import mesh        : Mesh, MeshMap, MapDomain;
import uv_transform : UvAffine;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

enum float kUvDegenEps = 1e-6f;

// ---------------------------------------------------------------------------
// UvBBox — axis-aligned bounding box in UV space
// ---------------------------------------------------------------------------

struct UvBBox {
    float umin =  float.infinity;
    float umax = -float.infinity;
    float vmin =  float.infinity;
    float vmax = -float.infinity;

    bool  valid()  const { return umin <= umax && vmin <= vmax; }
    float width()  const { return (umax > umin) ? umax - umin : 0.0f; }
    float height() const { return (vmax > vmin) ? vmax - vmin : 0.0f; }
}

// ---------------------------------------------------------------------------
// loopsBBox — bbox of a subset of UV corners
// ---------------------------------------------------------------------------

UvBBox loopsBBox(const(MeshMap)* map, const size_t[] loops) {
    UvBBox bb;
    foreach (l; loops) {
        const float u = map.data[l * 2];
        const float v = map.data[l * 2 + 1];
        if (u < bb.umin) bb.umin = u;
        if (u > bb.umax) bb.umax = u;
        if (v < bb.vmin) bb.vmin = v;
        if (v > bb.vmax) bb.vmax = v;
    }
    return bb;
}

// ---------------------------------------------------------------------------
// computeUvIslands — union-find over affected UV loops
//
// Returns a `size_t[]` of length `map.data.length / 2` (= total loop count).
//   result[l] = island id for loop l, if l ∈ loops (affected).
//   result[l] = size_t.max                           otherwise.
//
// Island ids are assigned in ascending first-loop order (stable, reproducible).
// `count` is set to the number of distinct islands found.
// ---------------------------------------------------------------------------

size_t[] computeUvIslands(const ref Mesh m, const(MeshMap)* map,
                           const size_t[] loops, out size_t count) {
    const size_t total = map.data.length / 2;

    // Self-parent for ALL indices — safe even if non-affected loops are never
    // touched (avoids a silent footgun if future callers query non-affected entries).
    auto parent = new size_t[](total);
    foreach (i; 0 .. total) parent[i] = i;

    // Path-halving find (non-recursive, mutates parent for compression).
    size_t find(size_t x) {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]]; // path halving
            x = parent[x];
        }
        return x;
    }

    void unite(size_t a, size_t b) {
        a = find(a);
        b = find(b);
        if (a != b) parent[a] = b;
    }

    // --- Intra-face union: all affected corners of the same face → same island.
    size_t[uint] faceFirst; // face index → first affected loop seen for that face
    foreach (l; loops) {
        const uint fi = m.loops[l].face;
        if (auto pp = fi in faceFirst) {
            unite(l, *pp);
        } else {
            faceFirst[fi] = l;
        }
    }

    // --- Cross-face union: same vertex + matching UV → same island (seam check).
    //     Valence is small so O(k²) per vertex is fine.
    size_t[][uint] vertLoops; // vertex index → affected loops incident to that vertex
    foreach (l; loops) {
        const uint vi = m.loops[l].vert;
        vertLoops[vi] ~= l;
    }
    foreach (vloops; vertLoops.byValue()) {
        import std.math : fabs;
        for (size_t i = 0; i < vloops.length; i++) {
            const size_t li = vloops[i];
            const float  ui = map.data[li * 2];
            const float  vi_ = map.data[li * 2 + 1];
            for (size_t j = i + 1; j < vloops.length; j++) {
                const size_t lj = vloops[j];
                if (fabs(ui - map.data[lj * 2])     <= kUvDegenEps &&
                    fabs(vi_ - map.data[lj * 2 + 1]) <= kUvDegenEps)
                    unite(li, lj);
            }
        }
    }

    // --- Assign island ids in ascending first-loop-index order.
    auto result = new size_t[](total);
    foreach (ref r; result) r = size_t.max;

    size_t[size_t] rootToIsland;
    count = 0;
    foreach (l; loops) {
        const size_t root = find(l);
        if (auto pp = root in rootToIsland) {
            result[l] = *pp;
        } else {
            rootToIsland[root] = count;
            result[l] = count;
            count++;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// computeFitAffine — affine that maps `box` to [0,1]²
//
// fill mode (keepAspect=false, default):
//   Non-uniform scale so bbox exactly fills [0,1]².  Degenerate axis (range ≤
//   kUvDegenEps): scale=1, collapsed coord mapped to 0.5.
//
// keepAspect mode (keepAspect=true):
//   Uniform scale s=1/max(du,dv), then translate to centre in [0,1]².
//   Both degenerate: s=1, both axes centred at 0.5.
// ---------------------------------------------------------------------------

UvAffine computeFitAffine(UvBBox box, bool keepAspect) {
    const float du = box.umax - box.umin;
    const float dv = box.vmax - box.vmin;
    UvAffine a;

    if (!keepAspect) {
        const float su = (du <= kUvDegenEps) ? 1.0f : 1.0f / du;
        const float tu = (du <= kUvDegenEps) ? (0.5f - box.umin) : (-box.umin / du);
        const float sv = (dv <= kUvDegenEps) ? 1.0f : 1.0f / dv;
        const float tv = (dv <= kUvDegenEps) ? (0.5f - box.vmin) : (-box.vmin / dv);
        a.lin   = [[su, 0.0f], [0.0f, sv]];
        a.trans = [tu, tv];
    } else {
        const float maxD = (du > dv) ? du : dv;
        const float s    = (maxD <= kUvDegenEps) ? 1.0f : 1.0f / maxD;
        const float offsetU = (1.0f - s * du) * 0.5f;
        const float offsetV = (1.0f - s * dv) * 0.5f;
        a.lin   = [[s, 0.0f], [0.0f, s]];
        a.trans = [offsetU - s * box.umin, offsetV - s * box.vmin];
    }
    return a;
}

// ---------------------------------------------------------------------------
// computeShelfPack — greedy shelf packer → per-island UvAffine
//
// Input:  `boxes[i]` = current UV bbox of island i.
//         `gutter`   = gap between placed boxes (UV units before scaling).
// Output: one UvAffine per input box (indexed by original island id).
//
// Algorithm (vibe3d-divergence):
//   1. Sort by (height desc, island-id asc) — stable, reproducible.
//   2. binW = max(maxIslandWidth, √(Σ box area)) — roughly-square target.
//   3. Greedy row scan: wrap to next shelf when cursor + boxW > binW.
//   4. s = 1 / max(packedW, packedH)  (zero-guard: s=1 if degenerate).
//   5. Affine: diag(s,s) + trans so (uv − bboxMin + slot) × s ∈ [0,1]².
// ---------------------------------------------------------------------------

UvAffine[] computeShelfPack(const UvBBox[] boxes, float gutter) {
    import std.math : sqrt;

    const size_t n = boxes.length;
    auto result = new UvAffine[](n); // default-init = identity per island
    if (n == 0) return result;

    // Sort order: height desc, then original index asc.
    auto order = new size_t[](n);
    foreach (i; 0 .. n) order[i] = i;
    // Insertion sort (n = island count, typically small).
    for (size_t i = 1; i < n; i++) {
        const size_t key = order[i];
        const float  kh  = boxes[key].height();
        size_t j = i;
        while (j > 0) {
            const size_t prev = order[j - 1];
            const float  ph   = boxes[prev].height();
            if (kh < ph || (kh == ph && key > prev)) break;
            order[j] = order[j - 1];
            j--;
        }
        order[j] = key;
    }

    // Bin width.
    float totalArea = 0.0f;
    float maxW      = 0.0f;
    foreach (b; boxes) {
        const float w = b.width();
        const float h = b.height();
        totalArea += w * h;
        if (w > maxW) maxW = w;
    }
    const float sqrtArea = sqrt(totalArea);
    const float binW = (maxW > sqrtArea) ? maxW : sqrtArea;

    // Greedy shelf scan.
    auto slots = new float[2][](n); // slots[i] = (x, y) in packed space
    float curX   = 0.0f;
    float curY   = 0.0f;
    float shelfH = 0.0f;

    foreach (ord; order) {
        const float w = boxes[ord].width();
        const float h = boxes[ord].height();
        // Wrap to next shelf (only when there's already something on this shelf).
        if (curX > 0.0f && curX + w > binW) {
            curY  += shelfH + gutter;
            curX   = 0.0f;
            shelfH = 0.0f;
        }
        slots[ord] = [curX, curY];
        curX += w + gutter;
        if (h > shelfH) shelfH = h;
    }
    const float packedH = curY + shelfH;

    // packedW = max right edge across all placed boxes.
    float packedW = 0.0f;
    foreach (i; 0 .. n) {
        const float right = slots[i][0] + boxes[i].width();
        if (right > packedW) packedW = right;
    }

    // Uniform scale to fit [0,1]²; zero-guard for all-degenerate input.
    const float maxPacked = (packedW > packedH) ? packedW : packedH;
    const float s = (maxPacked <= kUvDegenEps) ? 1.0f : 1.0f / maxPacked;

    // Build per-island affines.
    foreach (i; 0 .. n) {
        result[i].lin   = [[s, 0.0f], [0.0f, s]];
        result[i].trans = [s * (slots[i][0] - boxes[i].umin),
                           s * (slots[i][1] - boxes[i].vmin)];
    }
    return result;
}

// ---------------------------------------------------------------------------
// Module-level unit tests — analytic goldens on the pure layout math.
// Run by `dub test --config=modeling` (mandatory for changes to core modules).
// ---------------------------------------------------------------------------

unittest {
    import std.math : fabs, isNaN, isInfinity;
    enum float eps = 1e-5f;
    bool feq(float a, float b) { return fabs(a - b) < eps; }

    float applyU(in UvAffine a, float u, float v) {
        return a.lin[0][0]*u + a.lin[0][1]*v + a.trans[0];
    }
    float applyV(in UvAffine a, float u, float v) {
        return a.lin[1][0]*u + a.lin[1][1]*v + a.trans[1];
    }

    // ----------------------------------------------------------------
    // computeFitAffine — fill mode, known bbox.
    //
    // bbox = [-0.5, 0.5] × [-0.5, 0.5]: fill should scale by 1/1 = 1
    // and translate by +0.5 → maps (-0.5,-0.5)→(0,0) and (0.5,0.5)→(1,1).
    {
        UvBBox bb;
        bb.umin = -0.5f; bb.umax = 0.5f;
        bb.vmin = -0.5f; bb.vmax = 0.5f;
        auto a = computeFitAffine(bb, false);
        assert(feq(applyU(a, -0.5f, -0.5f), 0.0f), "fill: corner (-0.5,-0.5) u=0");
        assert(feq(applyV(a, -0.5f, -0.5f), 0.0f), "fill: corner (-0.5,-0.5) v=0");
        assert(feq(applyU(a,  0.5f,  0.5f), 1.0f), "fill: corner (0.5,0.5) u=1");
        assert(feq(applyV(a,  0.5f,  0.5f), 1.0f), "fill: corner (0.5,0.5) v=1");
    }

    // computeFitAffine — fill, non-square bbox [0,4]×[0,2].
    {
        UvBBox bb;
        bb.umin = 0.0f; bb.umax = 4.0f;
        bb.vmin = 0.0f; bb.vmax = 2.0f;
        auto a = computeFitAffine(bb, false);
        // su=0.25, tu=0; sv=0.5, tv=0
        assert(feq(applyU(a, 0.0f, 0.0f), 0.0f), "fill non-sq: (0,0) u=0");
        assert(feq(applyV(a, 0.0f, 0.0f), 0.0f), "fill non-sq: (0,0) v=0");
        assert(feq(applyU(a, 4.0f, 2.0f), 1.0f), "fill non-sq: (4,2) u=1");
        assert(feq(applyV(a, 4.0f, 2.0f), 1.0f), "fill non-sq: (4,2) v=1");
    }

    // computeFitAffine — degenerate u-axis (collapsed).
    {
        UvBBox bb;
        bb.umin = 0.3f; bb.umax = 0.3f; // collapsed
        bb.vmin = 0.0f; bb.vmax = 2.0f;
        auto a = computeFitAffine(bb, false);
        // u: scale=1, trans= 0.5 - 0.3 = 0.2 → collapsed coord maps to 0.5
        // v: scale=0.5, trans=0 → [0,2]→[0,1]
        assert(feq(applyU(a, 0.3f, 0.0f), 0.5f), "degenerate-u: maps to 0.5");
        assert(feq(applyV(a, 0.3f, 0.0f), 0.0f), "degenerate-u: v min=0");
        assert(feq(applyV(a, 0.3f, 2.0f), 1.0f), "degenerate-u: v max=1");
        // No NaN / infinity.
        assert(!isNaN(a.trans[0]) && !isInfinity(a.trans[0]), "degenerate-u: no NaN in trans[0]");
    }

    // computeFitAffine — keepAspect, non-square bbox.
    {
        UvBBox bb;
        bb.umin = 0.0f; bb.umax = 2.0f; // w=2, h=1
        bb.vmin = 0.0f; bb.vmax = 1.0f;
        auto a = computeFitAffine(bb, true);
        // s = 1/max(2,1) = 0.5; scaled = (1,0.5); offset = (0, 0.25)
        // u' = 0.5*u + 0; v' = 0.5*v + 0.25
        assert(feq(applyU(a, 0.0f, 0.0f), 0.0f),  "keepAspect: umin→0");
        assert(feq(applyU(a, 2.0f, 0.0f), 1.0f),  "keepAspect: umax→1");
        assert(feq(applyV(a, 0.0f, 0.0f), 0.25f), "keepAspect: vmin→0.25 (centred)");
        assert(feq(applyV(a, 0.0f, 1.0f), 0.75f), "keepAspect: vmax→0.75 (centred)");
    }

    // ----------------------------------------------------------------
    // computeShelfPack — single unit-square island.
    //
    // w==h==1 → s = 1/max(1,1) = 1 → maps bbox exactly to [0,1]².
    {
        UvBBox b;
        b.umin = 0.0f; b.umax = 1.0f;
        b.vmin = 0.0f; b.vmax = 1.0f;
        auto affines = computeShelfPack([b], 0.0f);
        assert(affines.length == 1);
        // Mapped corners:
        assert(feq(applyU(affines[0], 0.0f, 0.0f), 0.0f), "single: (0,0) u=0");
        assert(feq(applyV(affines[0], 0.0f, 0.0f), 0.0f), "single: (0,0) v=0");
        assert(feq(applyU(affines[0], 1.0f, 1.0f), 1.0f), "single: (1,1) u=1");
        assert(feq(applyV(affines[0], 1.0f, 1.0f), 1.0f), "single: (1,1) v=1");
    }

    // computeShelfPack — two unit-square boxes, no overlap, both in [0,1]².
    {
        UvBBox b0; b0.umin = 0.0f; b0.umax = 1.0f; b0.vmin = 0.0f; b0.vmax = 1.0f;
        UvBBox b1; b1.umin = 2.0f; b1.umax = 3.0f; b1.vmin = 0.0f; b1.vmax = 1.0f;
        auto affines = computeShelfPack([b0, b1], 0.0f);
        assert(affines.length == 2);

        // Map each bbox through its affine to get the packed bbox.
        float u0min = applyU(affines[0], b0.umin, b0.vmin);
        float u0max = applyU(affines[0], b0.umax, b0.vmin);
        float v0min = applyV(affines[0], b0.umin, b0.vmin);
        float v0max = applyV(affines[0], b0.umin, b0.vmax);

        float u1min = applyU(affines[1], b1.umin, b1.vmin);
        float u1max = applyU(affines[1], b1.umax, b1.vmin);
        float v1min = applyV(affines[1], b1.umin, b1.vmin);
        float v1max = applyV(affines[1], b1.umin, b1.vmax);

        // Both within [0,1]².
        assert(u0min >= -eps && u0max <= 1.0f + eps, "pack2: island 0 u in [0,1]");
        assert(v0min >= -eps && v0max <= 1.0f + eps, "pack2: island 0 v in [0,1]");
        assert(u1min >= -eps && u1max <= 1.0f + eps, "pack2: island 1 u in [0,1]");
        assert(v1min >= -eps && v1max <= 1.0f + eps, "pack2: island 1 v in [0,1]");

        // Non-overlap: positive-area intersection must be zero (touching at edge = ok).
        float overlapU = (u0max < u1min || u1max < u0min)
            ? 0.0f : ((u0max < u1max ? u0max : u1max) - (u0min > u1min ? u0min : u1min));
        float overlapV = (v0max < v1min || v1max < v0min)
            ? 0.0f : ((v0max < v1max ? v0max : v1max) - (v0min > v1min ? v0min : v1min));
        float area = (overlapU > 0 ? overlapU : 0.0f) * (overlapV > 0 ? overlapV : 0.0f);
        assert(area <= eps, "pack2: islands must not overlap");
    }

    // computeShelfPack — all-degenerate (every box w==h==0, Σarea=0).
    // s must be 1 (zero-guard), output must be finite.
    {
        UvBBox b0; b0.umin = 0.5f; b0.umax = 0.5f; b0.vmin = 0.5f; b0.vmax = 0.5f;
        UvBBox b1; b1.umin = 1.0f; b1.umax = 1.0f; b1.vmin = 1.0f; b1.vmax = 1.0f;
        auto affines = computeShelfPack([b0, b1], 0.0f);
        foreach (i, ref a; affines) {
            assert(!isNaN(a.lin[0][0])  && !isInfinity(a.lin[0][0]),  "degenPack: lin finite");
            assert(!isNaN(a.trans[0])   && !isInfinity(a.trans[0]),   "degenPack: trans finite");
            // s == 1 (zero-guard fired)
            assert(feq(a.lin[0][0], 1.0f), "degenPack: s==1");
        }
    }
}
