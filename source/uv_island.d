module uv_island;

/// Pure UV-layout helpers: island detection, bbox, fit-affine, shelf-pack.
///
/// No mesh mutation, no `commitChange`, no OpenGL.  Every function here is
/// analytic — exercisable by `dub test --config=tests` unit tests with no
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
// Run by `dub test --config=tests` (mandatory for changes to core modules).
// ---------------------------------------------------------------------------
