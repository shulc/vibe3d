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

/// The gather's distances from the cursor PIXEL CENTRE (mx + 0.5, my + 0.5) —
/// the ID buffer's and the pixel ray's convention — to a gathered vertex and
/// edge given as window points (null = none gathered).
PickGather pickDistances(int mx, int my, const(float[2])* v, const(float[2][2])* e,
                         bool polygon) {
    import math : closestOnSegment2D;
    immutable float cx = mx + 0.5f, cy = my + 0.5f;
    float dist(float x, float y) { return ((x - cx) ^^ 2 + (y - cy) ^^ 2) ^^ 0.5f; }
    PickGather g;
    if (v !is null) g.vertex = dist((*v)[0], (*v)[1]);
    if (e !is null) {
        float t;
        g.edge = closestOnSegment2D(cx, cy, (*e)[0][0], (*e)[0][1], (*e)[1][0], (*e)[1][1], t);
        g.edgeMid = dist(((*e)[0][0] + (*e)[1][0]) * 0.5f, ((*e)[0][1] + (*e)[1][1]) * 0.5f);
    }
    if (polygon) g.polygon = 0.0f;
    return g;
}

// Tool presses have their own facing admission; ordinary selection keeps its policy.
import mesh : Mesh;
import math : Vec3, Viewport, ModelSpace, dot, cross, screenPointToRay,
    projectToWindowFull, eyeVectorAt, closestPointOnSegmentToRay, closestOnSegment2D,
    rayTriangleIntersect, aimSpace;

struct ToolPressSource { const(Mesh)* mesh; ModelSpace space; int layer = -1; }
struct ToolPressTarget {
    int kind = -1, index = -1, source = -1;
    Vec3 pointWorld;
    ToolPressSource owner;
    float reductionMetric = float.nan;
}

// Same-class restoration uses original array order only under exact final and
// integer-reduction ties within one source slot (task9528; private phase0/tie evidence).
bool toolPressCandidateWins(float incomingDistance, ToolPressTarget incoming,
                            float currentDistance, ToolPressTarget current) {
    return incomingDistance < currentDistance || (incomingDistance == currentDistance
        && incoming.source == current.source
        && incoming.reductionMetric == current.reductionMetric
        && incoming.index < current.index);
}
__gshared ToolPressSource[] delegate() toolPressSourcesResolver;

// Raw support is query-owned; hidden support still determines representation scope.
struct ToolPressSupport {
    bool[] faces, edges, vertices;
    uint[] edgeFaces;
    bool[] edgeFront, vertexFront, vertexBorder;
}

ToolPressSupport toolPressSupport(const ref Mesh m, ModelSpace space,
                                 const ref Viewport vp) {
    import mesh : edgeKey;
    ToolPressSupport s;
    s.faces = new bool[](m.faces.length);
    s.edges = new bool[](m.edges.length); s.edges[] = true;
    s.vertices = new bool[](m.vertices.length); s.vertices[] = true;
    s.edgeFaces = new uint[](m.edges.length);
    s.edgeFront = new bool[](m.edges.length);
    s.vertexFront = new bool[](m.vertices.length);
    s.vertexBorder = new bool[](m.vertices.length);
    uint[] vertexFaces = new uint[](m.vertices.length);
    uint[][ulong] indices;
    foreach (ei, e; m.edges) indices[edgeKey(e[0], e[1])] ~= cast(uint)ei;
    size_t[] vertexSeen = new size_t[](m.vertices.length); vertexSeen[] = size_t.max;
    size_t[] edgeSeen = new size_t[](m.edges.length); edgeSeen[] = size_t.max;
    foreach (fi, f; m.faces) {
        const ordinary = f.length >= 3 && !m.isFaceSubpatch(fi);
        s.faces[fi] = ordinary;
        const front = ordinary && toolPressFaceAdmitted(m, cast(uint)fi, space, vp, true);
        foreach (i, vi; f) {
            if (vi < m.vertices.length && vertexSeen[vi] != fi) {
                vertexSeen[vi] = fi; ++vertexFaces[vi];
                s.vertices[vi] = s.vertices[vi] && ordinary;
                s.vertexFront[vi] = s.vertexFront[vi] || front;
            }
            if (auto ids = edgeKey(vi, f[(i + 1) % f.length]) in indices)
                foreach (ei; *ids) if (edgeSeen[ei] != fi) {
                    edgeSeen[ei] = fi; ++s.edgeFaces[ei];
                    s.edges[ei] = s.edges[ei] && ordinary;
                    s.edgeFront[ei] = s.edgeFront[ei] || front;
                }
        }
    }
    foreach (ei, e; m.edges) {
        s.edges[ei] = s.edges[ei] && s.edgeFaces[ei] > 0 && s.edgeFaces[ei] <= 2;
        foreach (vi; e) if (vi < s.vertices.length) {
            s.vertices[vi] = s.vertices[vi] && s.edges[ei];
            s.vertexBorder[vi] = s.vertexBorder[vi] || s.edgeFaces[ei] == 1;
        }
    }
    foreach (vi; 0 .. s.vertices.length) s.vertices[vi] = s.vertices[vi] && vertexFaces[vi] > 0;
    return s;
}

bool toolPressFaceAdmitted(const ref Mesh m, uint fi, ModelSpace space,
                            const ref Viewport vp, bool facing) {
    if (m.isFaceHidden(fi) || m.faces[fi].length < 3) return false;
    if (!facing) return true;
    const f = m.faces[fi];
    const a = space.toWorldPoint(m.vertices[f[0]]);
    Vec3 n = Vec3(0, 0, 0);
    foreach (i; 1 .. f.length - 1)
        n = n + cross(space.toWorldPoint(m.vertices[f[i]]) - a,
                      space.toWorldPoint(m.vertices[f[i + 1]]) - a);
    return dot(n, eyeVectorAt(vp, a)) <= 0;
}

bool toolPressEdgeAdmitted(const ref Mesh m, uint ei, ModelSpace space,
                            const ref Viewport vp, bool facing) {
    const s = toolPressSupport(m, space, vp);
    return !m.isEdgeHidden(ei) && s.edges[ei] && (!facing || s.edgeFaces[ei] == 1 || s.edgeFront[ei]);
}

bool toolPressVertexAdmitted(const ref Mesh m, uint vi, ModelSpace space,
                              const ref Viewport vp, bool facing) {
    const s = toolPressSupport(m, space, vp);
    return !m.isVertexHidden(vi) && s.vertices[vi] && (!facing || s.vertexFront[vi] || s.vertexBorder[vi]);
}

enum ToolQueryIntent { pressQuery, legacyHover }
struct LegacyPressGather {
    PickGather distances;
    ToolPressTarget vertex, edge, polygon;
}
alias LegacyPressProvider = LegacyPressGather delegate(const(bool)[] vertices,
    const(bool)[] edges, const(bool)[] faces);
struct ToolPressPolicy {
    const(ToolPressSource)[] sources;
    bool facing, occlusion, facesDrawn;
    float reach = kElementPickRadiusPx;
    ToolQueryIntent intent;
    ToolPressSource legacySource;
    LegacyPressProvider legacy;
}

/// Read-only source-aware press election. Source ids never become edit-target ids.
ToolPressTarget toolPressAt(int mx, int my, const ref Viewport vp,
        const(ToolPressSource)[] sources, bool facing, bool occlusion, bool facesDrawn,
        float reach = kElementPickRadiusPx, ToolPressPolicy policy = ToolPressPolicy.init) {
    policy.sources = sources; policy.facing = facing; policy.occlusion = occlusion;
    policy.facesDrawn = facesDrawn; policy.reach = reach;
    return toolPressAt(mx, my, vp, policy);
}

ToolPressTarget toolPressAt(int mx, int my, const ref Viewport vp, ToolPressPolicy policy) {
    const sources = policy.sources;
    const facing = policy.facing, occlusion = policy.occlusion, facesDrawn = policy.facesDrawn;
    const reach = policy.reach;
    ToolPressSupport[] support;
    if (policy.intent == ToolQueryIntent.pressQuery)
        foreach (src; sources) support ~= src.mesh is null ? ToolPressSupport.init
            : toolPressSupport(*src.mesh, src.space, vp);
    Vec3 org, dir;
    screenPointToRay(mx + 0.5f, my + 0.5f, vp, org, dir);
    float nearestSurface(Vec3 o, Vec3 d, out int source, out int face) {
        float best = float.infinity;
        source = face = -1;
        foreach (si, src; sources) {
            if (src.mesh is null || !src.space.invertible) continue;
            const m = src.mesh;
            foreach (fi, f; m.faces) {
                if (!support[si].faces[fi] || !toolPressFaceAdmitted(*m, cast(uint)fi, src.space, vp, facing)) continue;
                const a = src.space.toWorldPoint(m.vertices[f[0]]);
                foreach (i; 1 .. f.length - 1) {
                    float t, u, v;
                    if (rayTriangleIntersect(o, d, a, src.space.toWorldPoint(m.vertices[f[i]]),
                            src.space.toWorldPoint(m.vertices[f[i + 1]]), t, u, v)
                            && t >= 0 && t < best) {
                        best = t; source = cast(int)si; face = cast(int)fi;
                    }
                }
            }
        }
        return best;
    }
    bool visible(Vec3 p) {
        if (!occlusion) return true;
        float x, y, z;
        if (!projectToWindowFull(p, vp, x, y, z)) return false;
        Vec3 o, d;
        screenPointToRay(x, y, vp, o, d);
        int si, fi;
        const depth = nearestSurface(o, d, si, fi);
        const t = dot(p - o, d) / dot(d, d);
        return depth >= t - 1e-4f * (1 + t);
    }
    ToolPressTarget vertex, edge, polygon;
    PickGather g;
    if (policy.intent == ToolQueryIntent.pressQuery) foreach (si, src; sources) {
        if (src.mesh is null || !src.space.invertible) continue;
        const m = src.mesh;
        const s = support[si];
        const aim = aimSpace(vp, src.space);
        foreach (vi, v; m.vertices) {
            if (!s.vertices[vi] || m.isVertexHidden(vi) || (facing && !s.vertexFront[vi] && !s.vertexBorder[vi])) continue;
            const p = src.space.toWorldPoint(v);
            float x, y, z;
            if (!projectToWindowFull(p, vp, x, y, z)) continue;
            const d = (((x - mx - 0.5f) ^^ 2) + ((y - my - 0.5f) ^^ 2)) ^^ 0.5f;
            auto candidate = ToolPressTarget(kCascadeVertex, cast(int)vi, cast(int)si, p, src);
            float ix, iy, iz;
            if (projectToWindowFull(v, aim.vp, ix, iy, iz)) {
                const dx = ix - cast(float)mx, dy = iy - cast(float)my;
                candidate.reductionMetric = dx * dx + dy * dy;
            }
            if (d <= reach && toolPressCandidateWins(d, candidate, g.vertex, vertex) && visible(p)) {
                g.vertex = d;
                vertex = candidate;
            }
        }
        foreach (ei, e; m.edges) {
            if (!s.edges[ei] || m.isEdgeHidden(ei) || (facing && s.edgeFaces[ei] != 1 && !s.edgeFront[ei])) continue;
            const a = src.space.toWorldPoint(m.vertices[e[0]]), b = src.space.toWorldPoint(m.vertices[e[1]]);
            float ax, ay, az, bx, by, bz, u;
            if (!projectToWindowFull(a, vp, ax, ay, az) || !projectToWindowFull(b, vp, bx, by, bz)) continue;
            const d = closestOnSegment2D(mx + 0.5f, my + 0.5f, ax, ay, bx, by, u);
            const p = closestPointOnSegmentToRay(a, b, org, dir);
            auto candidate = ToolPressTarget(kCascadeEdge, cast(int)ei, cast(int)si, p, src);
            float iax, iay, iaz, ibx, iby, ibz, iu;
            if (projectToWindowFull(m.vertices[e[0]], aim.vp, iax, iay, iaz) &&
                projectToWindowFull(m.vertices[e[1]], aim.vp, ibx, iby, ibz))
                candidate.reductionMetric = closestOnSegment2D(cast(float)mx, cast(float)my,
                    iax, iay, ibx, iby, iu);
            if (d <= reach && toolPressCandidateWins(d, candidate, g.edge, edge) && visible(p)) {
                g.edge = d;
                g.edgeMid = (((ax + bx) * 0.5f - mx - 0.5f) ^^ 2 + ((ay + by) * 0.5f - my - 0.5f) ^^ 2) ^^ 0.5f;
                edge = candidate;
            }
        }
    }
    if (policy.intent == ToolQueryIntent.pressQuery && facesDrawn) {
        int si, fi;
        const t = nearestSurface(org, dir, si, fi);
        if (si >= 0) {
            g.polygon = 0;
            polygon = ToolPressTarget(kCascadePolygon, fi, si, org + dir * t, sources[si]);
        }
    }
    if (policy.legacy !is null) {
        ToolPressSupport subset;
        if (policy.intent == ToolQueryIntent.pressQuery) {
            bool prepared;
            foreach (si, src; sources) if (src.mesh is policy.legacySource.mesh) { subset = support[si]; prepared = true; break; }
            if (!prepared && policy.legacySource.mesh !is null)
                subset = toolPressSupport(*policy.legacySource.mesh, policy.legacySource.space, vp);
        }
        const old = policy.legacy(subset.vertices, subset.edges, subset.faces);
        if (toolPressCandidateWins(old.distances.vertex, old.vertex, g.vertex, vertex)) { g.vertex = old.distances.vertex; vertex = old.vertex; }
        if (toolPressCandidateWins(old.distances.edge, old.edge, g.edge, edge)) { g.edge = old.distances.edge; g.edgeMid = old.distances.edgeMid; edge = old.edge; }
        if (old.distances.polygon < g.polygon) { g.polygon = old.distances.polygon; polygon = old.polygon; }
    }
    switch (electElement(g)) {
        case kCascadeVertex: return vertex;
        case kCascadeEdge: return edge;
        case kCascadePolygon: return polygon;
        default: return ToolPressTarget.init;
    }
}
