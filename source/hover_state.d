module hover_state;


/// Cross-module hover state. `InputFrameState.publishHover` writes the
/// GPU-resolved hovered element indices here after each frame's pick and at a
/// press's re-pick; a press reads them through `hoverAtPress` to keep
/// click-pick aligned with hover-highlight. The
/// GPU ID-buffer is the source of truth — any CPU-projected pick
/// can disagree on overlapping faces and pick a hidden polygon
/// while the user sees the front one highlighted.
///
/// Values are -1 when no element of that type is currently hovered.
__gshared int g_hoveredVertex = -1;
__gshared int g_hoveredEdge   = -1;
__gshared int g_hoveredFace   = -1;

/// True when the three indices above were HELD from an earlier frame because
/// the live subpatch preview's index space is stale
/// (`InputFrameState.previewIndexSpaceStale`): they then index the mesh as it
/// was before the last edit, not the current one. Written beside them by
/// `InputFrameState.publishHover` alone; a PRESS reads through `hoverAtPress` (task 7114,
/// 9439; tests/unit/hover_stale_writer_census_test.d pins both).
__gshared bool g_hoverIndexSpaceStale = false;

struct HoverIds { int vertex = -1, edge = -1, face = -1; }

/// The ONE press-time hover read: a press never acts on a stale index space,
/// so while the ids are held it answers "nothing hovered". Draw and report
/// readers keep the held globals (the hover draw holds, no flicker).
HoverIds hoverAtPress() {
    if (g_hoverIndexSpaceStale) return HoverIds.init;
    return HoverIds(g_hoveredVertex, g_hoveredEdge, g_hoveredFace);
}


/// The ITEM under the cursor, as a `Document.layers` index (task 0647).
///
/// A different KIND of value from the three above and deliberately in the same
/// place: they index into the primary layer's geometry, this indexes the layer
/// array itself. Item-mode hover highlights the whole item under the cursor,
/// so the unit of the answer changes with the selection type, and a consumer
/// that read `g_hoveredFace` to find out which item is hot would be right only
/// while the document has one layer.
///
/// -1 when the current selection type is not Item, or when the cursor is over
/// empty space. Both are "nothing is hovered" and neither latches: the picker
/// clears this to -1 before every attempt, so a frame in which the ray misses
/// leaves no residue from the frame before it.
__gshared int g_hoveredItem = -1;

// ---- ElementPick: the one element-pick law (task 9441) ---------------------
// One reach, one comparator, for every element pick (selection click and
// hover, action-centre Element pick, topology-pen press) and for the snap
// election's cross-type cascade. Captured (private fixtures K-P, K-OC):
// a click reaches 8 px EUCLIDEAN screen distance, inclusive, vertex and edge
// alike, and snapping does not widen it; a mixed-type pick gathers within that
// reach, then ranks Vertex / Edge / Polygon by `cascadeClassWins` with the
// vertex tolerance doubled, after an edge-midpoint veto.

/// The element-pick reach, px. Also the cascade's tolerance base (the snap
/// election takes `min(acceptance range, this)`).
enum float kElementPickRadiusPx = 8.0f;
/// The same preference under the name its snap-election readers use.
enum float kCandidateToleranceBasePx = kElementPickRadiusPx;
/// The vertex class's tolerance multiplier (a vertex may beat a nearer edge).
enum float kVertexToleranceScale = 2.0f;
/// The drawn vertex POINT SIZE, px: a vertex click also takes every vertex
/// whose squared distance is within min(reach, this)² of the nearest's.
enum float kVertexPointSizePx = 6.0f;

/// The distance an ABSENT class carries into the comparator — finite, because
/// the comparator subtracts it.
enum float kAbsentClassDist = 1e12f;

/// The three cascade classes, in the order the merge asks them.
enum int kCascadeVertex  = 0;
enum int kCascadeEdge    = 1;
enum int kCascadePolygon = 2;

/// Does class `i` win the merge, given each class's nearest distance (`d`,
/// `kAbsentClassDist` where absent), which classes have a candidate (`has`)
/// and class `i`'s tolerance? The measured clauses, in order: no candidate →
/// lose; the only class → win; nearest → win; inside its own tolerance → win;
/// trails the next class by >= tol → lose; trails the last by < tol → win.
bool cascadeClassWins(int i, const ref bool[3] has, const ref float[3] d,
                      float tol) pure nothrow @nogc @safe
{
    if (!has[i]) return false;                       // 1
    immutable int j = (i + 1) % 3;
    immutable int k = (i + 2) % 3;
    if (!has[j] && !has[k]) return true;             // 2
    if (d[j] >= d[i] && d[k] >= d[i]) return true;   // 3
    if (tol >  d[i]) return true;                    // 4
    if (tol <= d[i] - d[j]) return false;            // 5
    if (tol >  d[i] - d[k]) return true;             // 6
    return false;
}

/// One mixed-type gather, screen px from the cursor: `float.infinity` = no
/// candidate of that class in reach. `edgeMid` is the gathered edge's
/// midpoint; `polygon` is 0 for a polygon under the cursor.
struct PickGather {
    float vertex  = float.infinity;
    float edge    = float.infinity;
    float edgeMid = float.infinity;
    float polygon = float.infinity;
}

/// The class a mixed-type element pick takes (`kCascadeVertex` …
/// `kCascadePolygon`), or -1. The vertex is vetoed when the edge's midpoint is
/// inside the reach and nearer than it (K-P P5cA).
int electElement(PickGather g) pure nothrow @nogc @safe {
    bool[3]  has = [g.vertex < float.infinity, g.edge < float.infinity,
                    g.polygon < float.infinity];
    if (has[0] && has[1] && g.edgeMid < kElementPickRadiusPx && g.edgeMid < g.vertex)
        has[0] = false;
    float[3] d = [has[0] ? g.vertex : kAbsentClassDist, has[1] ? g.edge : kAbsentClassDist,
                  has[2] ? g.polygon : kAbsentClassDist];
    foreach (i; 0 .. 3)
        if (cascadeClassWins(i, has, d, i == kCascadeVertex
                ? kVertexToleranceScale * kElementPickRadiusPx : kElementPickRadiusPx))
            return i;
    return -1;
}

/// The pick-visibility occlusion term of the cell the last hover publish read
/// (`InputFrameState.publishHover` writes it): under a style that draws no
/// faces nothing occludes and no polygon is pickable by a press (K-P P10).
__gshared bool g_hoverOcclusion = true;
