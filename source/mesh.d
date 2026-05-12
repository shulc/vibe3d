module mesh;

import bindbc.opengl;
import std.math : sqrt;
import std.parallelism : parallel;
import std.range : iota;
import math;
import shader;
// ---------------------------------------------------------------------------
// Mesh
// ---------------------------------------------------------------------------

private bool hasAnySelected(const bool[] sel) {
    foreach (s; sel) if (s) return true;
    return false;
}

/// Half-edge dart: represents the directed edge vert → next(vert) inside one face.
struct Loop {
    uint vert;   // start vertex of this dart
    uint face;   // face this loop belongs to
    uint next;   // index of the next loop in the same face (CCW)
    uint prev;   // index of the previous loop in the same face
    uint twin;   // dart in the adjacent face (reverse direction); ~0u if boundary
}

struct Mesh {
    Vec3[]    vertices;
    uint[2][] edges;
    uint[][]  faces;

    Loop[]     loops;        // all half-edge loops
    uint[]     faceLoop;     // faceLoop[fi] = index of first loop of face fi
    uint[]     vertLoop;     // vertLoop[vi] = loop starting at vi (anchored to fan start for boundary verts)
    uint[]     loopEdge;     // loopEdge[li] = index in edges[] of the undirected edge for loop li
    uint[ulong] edgeIndexMap; // edgeKey(a,b) → index in edges[]; populated by buildLoops + addEdge
    bool[]    selectedVertices;
    bool[]    selectedEdges;
    bool[]    selectedFaces;
    int[]     vertexSelectionOrder;  // 1-based counter; 0 = not manually selected
    int[]     edgeSelectionOrder;    // 1-based counter; 0 = not manually selected
    int[]     faceSelectionOrder;    // 1-based counter; 0 = not manually selected
    int       vertexSelectionOrderCounter;
    int       edgeSelectionOrderCounter;
    int       faceSelectionOrderCounter;
    // Persistent per-face subpatch flag (LightWave-style Tab toggle). Faces
    // with isSubpatch[fi] == true are displayed through a subdivided preview
    // while the cage geometry remains authoritative.
    bool[]    isSubpatch;
    // Monotonic counter bumped on any topology or vertex-position change that
    // invalidates the subpatch preview. Mutators that touch geometry should
    // increment this so cached previews can detect the change.
    ulong     mutationVersion;
    /// Counter for TOPOLOGY-only changes — bumped when faces / edges /
    /// vertices are added or removed, when isSubpatch changes (which
    /// changes subpatch preview output topology), or when a snapshot
    /// restore brings in new geometry. NOT bumped on pure vertex-
    /// position writes (move drag, undo of move, etc.) — that's what
    /// `mutationVersion` is for. Callers that cache topology-derived
    /// data (e.g. SubpatchPreview's per-level adjacency) compare this
    /// to know whether the cache is still valid, vs. just refreshing
    /// positions.
    ulong     topologyVersion;

    // Resize selection arrays to match geometry and clear them.
    // Call after catmullClark / importLWO / reset.
    void resetSelection() {
        selectedVertices.length     = vertices.length;
        vertexSelectionOrder.length = vertices.length;
        selectedEdges.length        = edges.length;
        edgeSelectionOrder.length   = edges.length;
        selectedFaces.length        = faces.length;
        faceSelectionOrder.length   = faces.length;
        isSubpatch.length           = faces.length;
        clearVertexSelection();
        clearEdgeSelection();
        clearFaceSelection();
        isSubpatch[] = false;
        ++mutationVersion; ++topologyVersion;
    }

    // Bring each *SelectionOrderCounter up to the maximum value in its order array.
    // Needed after commands that write *SelectionOrder via a slice on a struct copy
    // (the scalar counters do not propagate back through ref-less copies).
    void syncSelectionCounter() {
        foreach (ord; vertexSelectionOrder)
            if (ord > vertexSelectionOrderCounter) vertexSelectionOrderCounter = ord;
        foreach (ord; edgeSelectionOrder)
            if (ord > edgeSelectionOrderCounter) edgeSelectionOrderCounter = ord;
        foreach (ord; faceSelectionOrder)
            if (ord > faceSelectionOrderCounter) faceSelectionOrderCounter = ord;
    }

    // Grow selection arrays to match geometry without clearing.
    // Call after BoxTool or any in-place geometry growth.
    void syncSelection() {
        if (selectedVertices.length < vertices.length) selectedVertices.length = vertices.length;
        if (selectedEdges.length    < edges.length)    selectedEdges.length    = edges.length;
        if (selectedFaces.length    < faces.length)    selectedFaces.length    = faces.length;
        if (vertexSelectionOrder.length < vertices.length) vertexSelectionOrder.length = vertices.length;
        if (edgeSelectionOrder.length   < edges.length)    edgeSelectionOrder.length   = edges.length;
        if (faceSelectionOrder.length   < faces.length)    faceSelectionOrder.length   = faces.length;
        if (isSubpatch.length           < faces.length)    isSubpatch.length           = faces.length;
    }

    // Rebuild the deduplicated `edges` array from the current `faces`.
    // Call after any topology op that adds/removes faces (poly bevel, edge
    // bevel) so the edge list stays in sync. Selection arrays are resized
    // afterward via syncSelection.
    void rebuildEdgesFromFaces() {
        edges = [];
        bool[ulong] seen;
        foreach (face; faces) {
            foreach (i, _; face) {
                uint u = face[i];
                uint w = face[(i + 1) % face.length];
                ulong key = edgeKey(u, w);
                if (key !in seen) {
                    seen[key] = true;
                    edges ~= [u, w];
                }
            }
        }
    }

    uint addVertex(Vec3 v) {
        vertices ~= v;
        ++mutationVersion; ++topologyVersion;
        return cast(uint)(vertices.length - 1);
    }

    /// Merge coincident vertices (within `epsSq` squared distance) by
    /// remapping each later-indexed coincident vert onto the lowest-indexed
    /// vert at that position. Face vertex references are rewritten;
    /// consecutive duplicates that arise post-remap are dropped (so a quad
    /// whose two adjacent corners merged becomes a triangle); faces that
    /// fall below 3 distinct verts are removed entirely. The edge array is
    /// rebuilt; edge selection is cleared. Welded vertices are left in
    /// `vertices` (call `compactUnreferenced` afterwards to compact).
    /// Returns the number of vertex remaps performed.
    /// Used by edge bevel after `updateEdgeBevelPositions` to fold cap
    /// vertices that two BoundVerts (in possibly different BevVerts)
    /// happen to slide onto the same world-space point — the natural
    /// outcome when re-beveling on top of an already-overshot cap.
    /// Weld vertices marked true in `mask` whose pairwise squared distance
    /// is below `epsSq`. Verts outside the mask are not candidates for
    /// either side of a weld pair. Faces that collapse to fewer than 3
    /// unique verts are dropped (degenerate). Edge list rebuilt; selection
    /// arrays cleared. Returns the number of verts welded into another.
    ///
    /// MODO equivalent: `vert.merge range:fixed dist:eps keep:false` on
    /// the selected verts. epsSq=1e-12 + all-true mask matches the
    /// existing weldCoincidentVertices() behavior (used by edge bevel).
    size_t weldVerticesByMask(in bool[] mask, double epsSq) {
        if (vertices.length < 2) return 0;
        if (mask.length != vertices.length) return 0;
        int[] remap;
        remap.length = vertices.length;
        foreach (i; 0 .. vertices.length) remap[i] = cast(int)i;
        foreach (i; 0 .. vertices.length) {
            if (!mask[i]) continue;
            if (remap[i] != cast(int)i) continue;
            foreach (j; i + 1 .. vertices.length) {
                if (!mask[j]) continue;
                if (remap[j] != cast(int)j) continue;
                Vec3 d = vertices[i] - vertices[j];
                if (d.x * d.x + d.y * d.y + d.z * d.z < epsSq)
                    remap[j] = cast(int)i;
            }
        }
        size_t welded = 0;
        foreach (i; 0 .. vertices.length)
            if (remap[i] != cast(int)i) ++welded;
        if (welded == 0) return 0;

        uint[][] newFaces;
        bool[]   newSubpatch;
        int[]    newOrder;
        newFaces.reserve(faces.length);
        foreach (fi, ref face; faces) {
            uint[] f;
            f.reserve(face.length);
            foreach (vid; face) {
                uint mapped = (vid < remap.length) ? cast(uint)remap[vid] : vid;
                if (f.length == 0 || f[$ - 1] != mapped) f ~= mapped;
            }
            if (f.length > 1 && f[$ - 1] == f[0]) f = f[0 .. $ - 1];
            if (f.length >= 3) {
                newFaces    ~= f;
                newSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
                newOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            }
        }
        faces              = newFaces;
        isSubpatch         = newSubpatch;
        faceSelectionOrder = newOrder;
        selectedFaces.length = faces.length;
        selectedFaces[]      = false;

        edges.length = 0;
        edgeIndexMap.clear();
        foreach (ref face; faces)
            foreach (k; 0 .. face.length)
                addEdge(face[k], face[(k + 1) % face.length]);
        selectedEdges.length      = edges.length;
        selectedEdges[]           = false;
        edgeSelectionOrder.length = edges.length;
        compactUnreferenced();
        // See deleteFacesByMask: loops carry stale indices after face/vert
        // compaction.
        buildLoops();
        ++mutationVersion; ++topologyVersion;
        return welded;
    }

    /// Move every vertex marked true in `mask` to `target`. No welding
    /// happens here; the verts merely coincide in space. Combine with
    /// weldVerticesByMask() to collapse them into one. Used by
    /// `vert.join` (set target = centroid or first-selected) before the
    /// weld pass.
    void collapseVerticesByMask(in bool[] mask, Vec3 target) {
        if (mask.length != vertices.length) return;
        bool any = false;
        foreach (i; 0 .. mask.length) {
            if (!mask[i]) continue;
            vertices[i] = target;
            any = true;
        }
        if (any) { ++mutationVersion; ++topologyVersion; }
    }

    size_t weldCoincidentVertices(double epsSq = 1e-12) {
        if (vertices.length < 2) return 0;
        int[] remap;
        remap.length = vertices.length;
        foreach (i; 0 .. vertices.length) remap[i] = cast(int)i;
        foreach (i; 0 .. vertices.length) {
            if (remap[i] != cast(int)i) continue;
            foreach (j; i + 1 .. vertices.length) {
                if (remap[j] != cast(int)j) continue;
                Vec3 d = vertices[i] - vertices[j];
                if (d.x * d.x + d.y * d.y + d.z * d.z < epsSq)
                    remap[j] = cast(int)i;
            }
        }
        size_t welded = 0;
        foreach (i; 0 .. vertices.length)
            if (remap[i] != cast(int)i) ++welded;
        if (welded == 0) return 0;

        uint[][] newFaces;
        newFaces.reserve(faces.length);
        foreach (ref face; faces) {
            uint[] f;
            f.reserve(face.length);
            foreach (vid; face) {
                uint mapped = (vid < remap.length) ? cast(uint)remap[vid] : vid;
                if (f.length == 0 || f[$ - 1] != mapped) f ~= mapped;
            }
            // Wrap-around dup: last == first means the face cycles back to
            // its start through a remapped corner.
            if (f.length > 1 && f[$ - 1] == f[0]) f = f[0 .. $ - 1];
            if (f.length >= 3) newFaces ~= f;
        }
        faces = newFaces;

        edges.length = 0;
        edgeIndexMap.clear();
        foreach (ref face; faces)
            foreach (k; 0 .. face.length)
                addEdge(face[k], face[(k + 1) % face.length]);

        selectedEdges.length = edges.length;
        selectedEdges[] = false;
        edgeSelectionOrder.length = edges.length;
        // Face selection is potentially invalidated (face indices changed
        // since collapsed faces are removed). Caller may re-derive.
        if (selectedFaces.length > faces.length) selectedFaces.length = faces.length;
        if (faceSelectionOrder.length > faces.length) faceSelectionOrder.length = faces.length;
        if (isSubpatch.length > faces.length) isSubpatch.length = faces.length;

        ++mutationVersion; ++topologyVersion;
        return welded;
    }

    /// Remove vertices not referenced by any face. Updates all face vertex
    /// references via a remap table and re-derives the edges array. Returns
    /// the number of vertices removed.
    /// Useful after topology mutations (e.g. bevel arc miter) that leave
    /// stale BoundVerts or cap mids unreferenced.
    size_t compactUnreferenced() {
        bool[] referenced;
        referenced.length = vertices.length;
        foreach (ref face; faces)
            foreach (vid; face)
                if (vid < referenced.length) referenced[vid] = true;
        // Build old→new index map
        uint[] remap;
        remap.length = vertices.length;
        Vec3[] newVerts;
        newVerts.reserve(vertices.length);
        size_t removed = 0;
        foreach (i, ref v; vertices) {
            if (referenced[i]) {
                remap[i] = cast(uint)newVerts.length;
                newVerts ~= v;
            } else {
                remap[i] = cast(uint)~0u;
                ++removed;
            }
        }
        if (removed == 0) return 0;
        // Rewrite face vertex IDs
        foreach (ref face; faces)
            foreach (ref vid; face)
                if (vid < remap.length) vid = remap[vid];
        vertices = newVerts;
        // Re-derive edges from faces (remap can break edge endpoints).
        edges.length = 0;
        edgeIndexMap.clear();
        foreach (ref face; faces)
            foreach (k; 0 .. face.length)
                addEdge(face[k], face[(k + 1) % face.length]);
        // Selection arrays follow vertices length; truncate / repack the
        // simple cases (selected vertices: re-built bool array).
        selectedVertices.length = vertices.length;
        vertexSelectionOrder.length = vertices.length;
        // Edges have changed — clear edge selection for safety.
        selectedEdges.length = edges.length;
        selectedEdges[] = false;
        edgeSelectionOrder.length = edges.length;
        ++mutationVersion; ++topologyVersion;
        return removed;
    }
    /// Drop the faces marked true in `mask`. Edges are rebuilt from the
    /// surviving faces; orphan vertices (no longer referenced by any
    /// remaining face) are removed via compactUnreferenced(). Selection
    /// arrays are resized and cleared (re-selecting after a delete is
    /// the caller's responsibility — index validity is unstable across
    /// a compact). Returns the number of faces removed.
    ///
    /// This is the unified delete primitive: Tier 1.1 mesh.delete dispatches
    /// here for every edit mode by translating its selection into a face
    /// mask (verts → faces incident; edges → faces incident; polys
    /// directly).
    size_t deleteFacesByMask(in bool[] mask) {
        if (mask.length != faces.length) return 0;
        uint[][] keptFaces;
        bool[]   keptSubpatch;
        int[]    keptOrder;
        size_t   removed = 0;
        keptFaces.reserve(faces.length);
        keptSubpatch.reserve(faces.length);
        keptOrder.reserve(faces.length);
        foreach (i, ref f; faces) {
            if (mask[i]) { ++removed; continue; }
            keptFaces ~= f;
            keptSubpatch ~= (i < isSubpatch.length        ? isSubpatch[i]        : false);
            keptOrder    ~= (i < faceSelectionOrder.length ? faceSelectionOrder[i] : 0);
        }
        if (removed == 0) return 0;
        faces              = keptFaces;
        isSubpatch         = keptSubpatch;
        faceSelectionOrder = keptOrder;
        // Selection bits don't survive index changes; clear and let caller
        // restore as needed.
        selectedFaces.length = faces.length;
        selectedFaces[] = false;
        // Re-derive edges from the surviving faces. Some edges may be gone
        // entirely (only-touched the deleted faces); others stay. Always
        // do this even if no verts were orphaned — compactUnreferenced
        // skips the rebuild when removed==0.
        edges.length = 0;
        edgeIndexMap.clear();
        foreach (ref f; faces)
            foreach (k; 0 .. f.length)
                addEdge(f[k], f[(k + 1) % f.length]);
        selectedEdges.length      = edges.length;
        selectedEdges[]           = false;
        edgeSelectionOrder.length = edges.length;
        // Compact orphan vertices (no-op if all verts still referenced).
        compactUnreferenced();
        // Half-edge loops carry face/vert indices that compaction just
        // invalidated; rebuild so adjacentFaces / verticesAroundVertex /
        // friends return live indices. (Without this, the next consumer
        // of `loops` walks stale data and either reports wrong adjacency
        // or indexes out of bounds.)
        buildLoops();
        ++mutationVersion; ++topologyVersion;
        return removed;
    }

    /// Dissolve the vertices marked true in `mask`: each selected vert
    /// is dropped from every face's boundary list (a quad becomes a
    /// triangle, a triangle becomes degenerate and the face is dropped).
    /// Edges are rebuilt and orphan verts compacted out.
    ///
    /// This is MODO's `delete vertex` semantics — it preserves the
    /// surrounding faces by re-shaping them, rather than killing every
    /// incident face like a naive "delete incident topology" would.
    size_t dissolveVerticesByMask(in bool[] mask) {
        if (mask.length != vertices.length) return 0;
        size_t dissolved = 0;
        foreach (vi; 0 .. mask.length) if (mask[vi]) ++dissolved;
        if (dissolved == 0) return 0;

        // Rebuild faces array, dropping each masked vert from every face's
        // boundary. Faces shrunk below 3 verts (degenerate) are dropped.
        uint[][] newFaces;
        bool[]   newSubpatch;
        int[]    newOrder;
        newFaces.reserve(faces.length);
        newSubpatch.reserve(faces.length);
        newOrder.reserve(faces.length);
        foreach (fi, ref f; faces) {
            uint[] kept;
            foreach (vid; f) {
                if (vid < mask.length && mask[vid]) continue;
                kept ~= vid;
            }
            if (kept.length >= 3) {
                newFaces    ~= kept;
                newSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
                newOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            }
        }
        faces              = newFaces;
        isSubpatch         = newSubpatch;
        faceSelectionOrder = newOrder;
        selectedFaces.length = faces.length;
        selectedFaces[]      = false;

        // Rebuild edges from the new faces (some edges are gone, some
        // boundaries are shorter). compactUnreferenced then removes the
        // dissolved (now-orphan) verts and re-derives edges yet again.
        edges.length = 0;
        edgeIndexMap.clear();
        foreach (ref f; faces)
            foreach (k; 0 .. f.length)
                addEdge(f[k], f[(k + 1) % f.length]);
        selectedEdges.length      = edges.length;
        selectedEdges[]           = false;
        edgeSelectionOrder.length = edges.length;
        compactUnreferenced();
        // See deleteFacesByMask: loops carry stale indices after face/vert
        // compaction.
        buildLoops();
        ++mutationVersion; ++topologyVersion;
        return dissolved;
    }

    /// Dissolve every vertex that is incident to exactly 2 edges. Such
    /// verts are pinch-points along a chain of edges in the surrounding
    /// faces — collapsing them merges the two adjacent boundary edges
    /// into one. Used as a cleanup pass after removeEdgesByMask to match
    /// modo_cl's `delete` / `remove` behavior on edge selections, which
    /// dissolves the edge AND drops the now-orphaned 2-valent endpoints.
    /// Returns the number of verts dissolved.
    size_t dissolveDegree2Verts() {
        // Tally the number of edges incident to each vertex.
        int[] degree;
        degree.length = vertices.length;
        foreach (e; edges) {
            uint a = e[0], b = e[1];
            if (a < degree.length) ++degree[a];
            if (b < degree.length) ++degree[b];
        }
        bool[] mask;
        mask.length = vertices.length;
        size_t cnt = 0;
        foreach (i, d; degree) {
            if (d == 2) { mask[i] = true; ++cnt; }
        }
        if (cnt == 0) return 0;
        return dissolveVerticesByMask(mask);
    }

    /// Dissolve the edges marked true in `mask`: each selected edge is
    /// removed, and any group of faces transitively connected through
    /// selected edges is merged into a single polygon along the union's
    /// outer boundary.
    ///
    /// Algorithm: union-find over faces, edges within a component drop
    /// out, the remaining directed half-edges of the component form a
    /// closed walk = the merged polygon boundary. Handles fans (multiple
    /// selected edges sharing a vertex) cleanly — pairwise-merge would
    /// produce a bowtie polygon in that case. Boundary edges (only one
    /// adjacent face) are skipped. Returns the number of selected edges
    /// actually dissolved.
    size_t removeEdgesByMask(in bool[] mask) {
        if (mask.length != edges.length) return 0;

        // Snapshot selected edges as undirected keys; edge-array indices
        // are unstable across compactUnreferenced.
        bool[ulong] selectedEdgeKeys;
        foreach (i; 0 .. edges.length)
            if (mask[i])
                selectedEdgeKeys[edgeKeyOrdered(edges[i][0], edges[i][1])] = true;
        if (selectedEdgeKeys.length == 0) return 0;

        // Build face → face union-find via selected edges.
        size_t nFaces = faces.length;
        int[] parent;  parent.length = nFaces;
        int[] rank_;   rank_.length  = nFaces;
        foreach (i; 0 .. nFaces) parent[i] = cast(int)i;
        int find(int x) { while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; } return x; }
        void unite(int a, int b) {
            a = find(a); b = find(b); if (a == b) return;
            if (rank_[a] < rank_[b]) { int t = a; a = b; b = t; }
            parent[b] = a;
            if (rank_[a] == rank_[b]) ++rank_[a];
        }

        // For each selected edge, find both adjacent faces and unite them.
        // Boundary edges (only 1 adjacent face) leave their face alone.
        size_t dissolved = 0;
        foreach (key; selectedEdgeKeys.byKey) {
            int fA = -1, fB = -1;
            foreach (fi; 0 .. nFaces) {
                auto f = faces[fi];
                bool has = false;
                foreach (k; 0 .. f.length) {
                    if (edgeKeyOrdered(f[k], f[(k + 1) % f.length]) == key) {
                        has = true; break;
                    }
                }
                if (!has) continue;
                if      (fA == -1) fA = cast(int)fi;
                else if (fB == -1) { fB = cast(int)fi; break; }
            }
            if (fA != -1 && fB != -1) {
                unite(fA, fB);
                ++dissolved;
            }
        }
        if (dissolved == 0) return 0;

        // Group faces by component root.
        size_t[][int] componentFaces;
        foreach (fi; 0 .. nFaces) {
            int r = find(cast(int)fi);
            componentFaces[r] ~= fi;
        }

        // For each multi-face component: walk the boundary and produce the
        // merged polygon. Single-face components are untouched.
        bool[] dropFace      = new bool[](nFaces);
        uint[][] newPolyList;
        bool[]   newPolySubpatch;
        int[]    newPolyOrder;
        foreach (root, comp; componentFaces) {
            if (comp.length < 2) continue;

            // Gather directed half-edges from the component, dropping any
            // half-edge whose undirected key is in selectedEdgeKeys.
            uint[][uint] outAt;  // outAt[u] = list of `v` for each surviving u→v
            foreach (fi; comp) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    uint a = f[k], b = f[(k + 1) % f.length];
                    if (edgeKeyOrdered(a, b) in selectedEdgeKeys) continue;
                    outAt[a] ~= b;
                }
            }

            // Walk: start at any vertex with an outgoing half-edge, follow
            // until back to start. A simple connected face fan produces one
            // closed loop; degenerate inputs may leave half-edges behind
            // (we accept the first walk).
            if (outAt.length == 0) continue;
            uint startV = uint.max;
            foreach (k; outAt.byKey) { startV = k; break; }

            uint[] poly;
            uint cur = startV;
            while (true) {
                poly ~= cur;
                auto p = cur in outAt;
                if (p is null || (*p).length == 0) break;
                uint nxt = (*p)[0];
                *p = (*p)[1 .. $];
                if (nxt == startV) break;
                cur = nxt;
            }

            if (poly.length < 3) continue;

            // Mark every face in the component for removal; the new
            // merged polygon will replace them.
            foreach (fi; comp) dropFace[fi] = true;

            // Inherit subpatch flag and selection-order from the FIRST
            // face in the component (arbitrary but deterministic).
            int firstFi = cast(int)comp[0];
            newPolyList      ~= poly;
            newPolySubpatch  ~= (firstFi < cast(int)isSubpatch.length        ? isSubpatch[firstFi]        : false);
            newPolyOrder     ~= (firstFi < cast(int)faceSelectionOrder.length ? faceSelectionOrder[firstFi] : 0);
        }

        // Compact: drop faces, append merged polygons.
        uint[][] keptFaces;
        bool[]   keptSubpatch;
        int[]    keptOrder;
        foreach (fi; 0 .. nFaces) {
            if (dropFace[fi]) continue;
            keptFaces ~= faces[fi];
            keptSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
            keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
        }
        foreach (i; 0 .. newPolyList.length) {
            keptFaces    ~= newPolyList[i];
            keptSubpatch ~= newPolySubpatch[i];
            keptOrder    ~= newPolyOrder[i];
        }
        faces              = keptFaces;
        isSubpatch         = keptSubpatch;
        faceSelectionOrder = keptOrder;
        selectedFaces.length = faces.length;
        selectedFaces[]      = false;

        // Rebuild edges + compact orphan verts.
        edges.length = 0;
        edgeIndexMap.clear();
        foreach (ref f; faces)
            foreach (k; 0 .. f.length)
                addEdge(f[k], f[(k + 1) % f.length]);
        selectedEdges.length      = edges.length;
        selectedEdges[]           = false;
        edgeSelectionOrder.length = edges.length;
        compactUnreferenced();
        // See deleteFacesByMask: loops carry stale indices after face/vert
        // compaction.
        buildLoops();
        ++mutationVersion; ++topologyVersion;
        return dissolved;
    }

    private static ulong edgeKeyOrdered(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32) | b : (cast(ulong)b << 32) | a;
    }

    void addEdge(uint a, uint b) {
        ulong key = edgeKey(a, b);
        if (key in edgeIndexMap) return;
        edgeIndexMap[key] = cast(uint)edges.length;
        edges ~= [a, b];
        ++mutationVersion; ++topologyVersion;
    }
    void addFace(uint[] idx) {
        faces ~= idx.dup;
        for (uint i = 0; i < idx.length; i++)
            addEdge(idx[i], idx[(i+1) % idx.length]);
        ++mutationVersion; ++topologyVersion;
    }
    // Fast version using hash lookup for duplicate checking
    void addFaceFast(ref uint[ulong] edgeLookup, uint[] idx) {
        faces ~= idx.dup;
        for (uint i = 0; i < idx.length; i++) {
            uint a = idx[i];
            uint b = idx[(i+1) % idx.length];
            ulong key = edgeKey(a, b);
            if (key !in edgeLookup) {
                edges ~= [a, b];
                edgeLookup[key] = cast(uint)(edges.length - 1);
            }
        }
        ++mutationVersion; ++topologyVersion;
    }
    bool hasAnySelectedVertices() const { return hasAnySelected(selectedVertices); }
    bool hasAnySelectedEdges() const { return hasAnySelected(selectedEdges); }
    bool hasAnySelectedFaces() const { return hasAnySelected(selectedFaces); }
    bool hasAnySubpatch() const        { return hasAnySelected(isSubpatch); }
    /// True iff every face is subpatch-marked AND there's at least one
    /// face. Gates the OSD-accelerated SubpatchPreview fast path:
    /// OpenSubdiv subdivides the WHOLE mesh, so selective subpatch
    /// (some faces marked, others not) keeps the existing vibe3d
    /// catmullClarkSelected path.
    bool allSubpatch() const {
        if (faces.length == 0) return false;
        if (isSubpatch.length < faces.length) return false;
        foreach (i; 0 .. faces.length)
            if (!isSubpatch[i]) return false;
        return true;
    }

    void setSubpatch(size_t idx, bool on) {
        if (idx >= isSubpatch.length) return;
        if (isSubpatch[idx] != on) {
            isSubpatch[idx] = on;
            ++mutationVersion; ++topologyVersion;
        }
    }
    void clearSubpatch() {
        bool any = false;
        foreach (b; isSubpatch) if (b) { any = true; break; }
        isSubpatch[] = false;
        if (any) { ++mutationVersion; ++topologyVersion; }
    }

    void clearVertexSelection() {
        selectedVertices[] = false;
        vertexSelectionOrder[] = 0;
        vertexSelectionOrderCounter = 0;
    }
    void clearEdgeSelection() {
        selectedEdges[] = false;
        edgeSelectionOrder[] = 0;
        edgeSelectionOrderCounter = 0;
    }
    void clearFaceSelection() {
        selectedFaces[] = false;
        faceSelectionOrder[] = 0;
        faceSelectionOrderCounter = 0;
    }

    void selectVertex(int idx) {
        if (!selectedVertices[idx])
            vertexSelectionOrder[idx] = ++vertexSelectionOrderCounter;
        selectedVertices[idx] = true;
    }
    void deselectVertex(int idx) {
        selectedVertices[idx] = false;
        vertexSelectionOrder[idx] = 0;
    }

    void selectEdge(int idx) {
        if (!selectedEdges[idx])
            edgeSelectionOrder[idx] = ++edgeSelectionOrderCounter;
        selectedEdges[idx] = true;
    }
    void deselectEdge(int idx) {
        selectedEdges[idx] = false;
        edgeSelectionOrder[idx] = 0;
    }

    void selectFace(int idx) {
        if (!selectedFaces[idx])
            faceSelectionOrder[idx] = ++faceSelectionOrderCounter;
        selectedFaces[idx] = true;
    }
    void deselectFace(int idx) {
        selectedFaces[idx] = false;
        faceSelectionOrder[idx] = 0;
    }

    void clear() {
        vertices = []; edges = []; faces = [];
        loops = []; faceLoop = []; vertLoop = [];
        edgeIndexMap.clear();   // stale keys would shadow new addEdge calls
    }

    /// Compute the unit normal of face fi using the first triangle (v0, v1, v2).
    /// Returns (0,1,0) for degenerate or tiny faces.
    Vec3 faceNormal(uint fi) const {
        // Newell's method: sums signed cross-product contributions from every
        // consecutive vertex pair. Robust to (a) collinear leading triples
        // (e.g. after splitting an edge — the inserted midpoint sits on the
        // line through its two original neighbors) and (b) slightly non-planar
        // n-gons. The naive "cross of the first two edges" fails on (a) and
        // produces a poor approximation on (b).
        const uint[] face = faces[fi];
        if (face.length < 3) return Vec3(0, 1, 0);
        float nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. face.length) {
            Vec3 a = vertices[face[i]];
            Vec3 b = vertices[face[(i + 1) % face.length]];
            nx += (a.y - b.y) * (a.z + b.z);
            ny += (a.z - b.z) * (a.x + b.x);
            nz += (a.x - b.x) * (a.y + b.y);
        }
        float len = sqrt(nx*nx + ny*ny + nz*nz);
        return len > 1e-6f ? Vec3(nx / len, ny / len, nz / len) : Vec3(0, 1, 0);
    }

    /// Return the other endpoint of edge `ei` given one of its vertices `vi`.
    /// In debug builds, asserts that `vi` is actually one of the edge's endpoints.
    pragma(inline, true)
    uint edgeOtherVertex(uint ei, uint vi) const {
        uint a = edges[ei][0];
        uint b = edges[ei][1];
        debug assert(vi == a || vi == b,
                     "edgeOtherVertex: vi does not belong to edge ei");
        return (vi == a) ? b : a;
    }

    /// Return a range over all consecutive vertex pairs (directed edges) of face `fi`.
    FaceEdgeRange faceEdges(uint fi) const { return FaceEdgeRange(faces[fi]); }

    /// Return a range over all vertices directly connected to vertex `vi` by an edge.
    VertexNeighborRange verticesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        return VertexNeighborRange(loops, first);
    }

    /// Return a range over all edge indices incident to vertex `vi`.
    /// Correctly handles boundary vertices: emits the extra boundary edge at the end.
    /// Requires buildLoops() to have been called (uses vertLoop and loopEdge).
    VertexEdgeRange edgesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        return VertexEdgeRange(loops, loopEdge, first);
    }

    /// Return a range over all faces incident to vertex `vi`.
    VertexFaceRange facesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        return VertexFaceRange(loops, first);
    }

    /// Return a range over the 1–2 faces incident to edge `ei`.
    EdgeFaceRange facesAroundEdge(uint ei) const {
        return EdgeFaceRange(loops, edges, vertLoop, ei);
    }

    /// Return a range over all faces that share an edge with face `fi`.
    /// Uses twin links from the half-edge structure — no hash map needed.
    AdjacentFaceRange adjacentFaces(uint fi) const {
        uint start = (fi < faceLoop.length) ? faceLoop[fi] : ~0u;
        return AdjacentFaceRange(loops, start);
    }

    /// Return a hash of the current vertex selection state (seed = 0).
    /// Useful for detecting selection changes between frames.
    uint selectionHashVertices() const {
        uint h = 0;
        foreach (i, s; selectedVertices) if (s) h = h * 31 + cast(uint)i;
        return h;
    }

    /// Return a hash of the current edge selection state (seed = 1).
    uint selectionHashEdges() const {
        uint h = 1;
        foreach (i, s; selectedEdges) if (s) h = h * 31 + cast(uint)i;
        return h;
    }

    /// Return a hash of the current face selection state (seed = 2).
    uint selectionHashFaces() const {
        uint h = 2;
        foreach (i, s; selectedFaces) if (s) h = h * 31 + cast(uint)i;
        return h;
    }

    /// Return the vertex indices touched by the current vertex selection.
    /// If nothing is selected, returns all vertex indices.
    int[] selectedVertexIndicesVertices() const {
        int[] idx;
        if (hasAnySelected(selectedVertices)) {
            foreach (i, s; selectedVertices)
                if (s && i < vertices.length) idx ~= cast(int)i;
        } else {
            foreach (i; 0 .. vertices.length) idx ~= cast(int)i;
        }
        return idx;
    }

    /// Return the vertex indices touched by the current edge selection.
    /// Each vertex is included at most once.
    /// If nothing is selected, returns all vertex indices.
    int[] selectedVertexIndicesEdges() const {
        int[] idx;
        if (hasAnySelected(selectedEdges)) {
            bool[] added = new bool[](vertices.length);
            foreach (i, edge; edges) {
                if (i >= selectedEdges.length || !selectedEdges[i]) continue;
                if (!added[edge[0]]) { added[edge[0]] = true; idx ~= cast(int)edge[0]; }
                if (!added[edge[1]]) { added[edge[1]] = true; idx ~= cast(int)edge[1]; }
            }
        } else {
            foreach (i; 0 .. vertices.length) idx ~= cast(int)i;
        }
        return idx;
    }

    /// Return the vertex indices touched by the current face selection.
    /// Each vertex is included at most once.
    /// If nothing is selected, returns all vertex indices.
    int[] selectedVertexIndicesFaces() const {
        int[] idx;
        if (hasAnySelected(selectedFaces)) {
            bool[] added = new bool[](vertices.length);
            foreach (i, face; faces) {
                if (i >= selectedFaces.length || !selectedFaces[i]) continue;
                foreach (vi; face)
                    if (!added[vi]) { added[vi] = true; idx ~= cast(int)vi; }
            }
        } else {
            foreach (i; 0 .. vertices.length) idx ~= cast(int)i;
        }
        return idx;
    }

    /// Return the centroid of the current vertex selection (or all vertices if none selected).
    Vec3 selectionCentroidVertices() const {
        bool any = hasAnySelected(selectedVertices);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        foreach (i, v; vertices) {
            if (!any || (i < selectedVertices.length && selectedVertices[i])) {
                sum += v;
                count++;
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    /// Return the centroid of vertices belonging to the current edge selection
    /// (or all edge vertices if none selected).  Each vertex is counted once.
    Vec3 selectionCentroidEdges() const {
        bool any = hasAnySelected(selectedEdges);
        bool[] vis = new bool[](vertices.length);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        foreach (i, edge; edges) {
            if (any && !(i < selectedEdges.length && selectedEdges[i])) continue;
            foreach (vi; edge) {
                if (!vis[vi]) {
                    sum += vertices[vi];
                    count++;
                    vis[vi] = true;
                }
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    /// Return the centroid of vertices belonging to the current face selection
    /// (or all face vertices if none selected).  Each vertex is counted once.
    Vec3 selectionCentroidFaces() const {
        bool any = hasAnySelected(selectedFaces);
        bool[] vis = new bool[](vertices.length);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        foreach (i, face; faces) {
            if (any && !(i < selectedFaces.length && selectedFaces[i])) continue;
            foreach (vi; face) {
                if (!vis[vi]) {
                    sum += vertices[vi];
                    count++;
                    vis[vi] = true;
                }
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    // ---- BBOX CENTER variants ------------------------------------------
    //
    // Same selection logic as `selectionCentroid*` but return (min+max)/2
    // per axis instead of the vertex-position mean. Used by ACEN.Select /
    // .Border / .Auto to match MODO 9's empirical "selection-center" pivot,
    // which is the bounding-box midpoint of the selected verts (not the
    // vertex average — verified against MODO via tools/modo_diff/
    // run_acen_drag.sh on the asymmetric pattern). For symmetric selections
    // the two coincide; only asymmetric / clustered selections distinguish
    // them. Phase 2 of doc/acen_modo_parity_plan.md.

    Vec3 selectionBBoxCenterVertices() const {
        bool any = hasAnySelected(selectedVertices);
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (i, v; vertices) {
            if (any && !(i < selectedVertices.length && selectedVertices[i])) continue;
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            seen = true;
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    /// Selection bbox extent (min, max) along world axes. Falls back
    /// to the whole geometry when nothing is selected, mirroring the
    /// `selectionBBoxCenter*` family. `seen` is false only on an
    /// empty mesh — caller can synthesise a sensible default. Used by
    /// the FalloffStage's auto-size path (phase 7.5).
    void selectionBBoxMinMaxVertices(out Vec3 mn, out Vec3 mx, out bool seen) const {
        bool any = hasAnySelected(selectedVertices);
        mn = Vec3(float.infinity, float.infinity, float.infinity);
        mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        seen = false;
        foreach (i, v; vertices) {
            if (any && !(i < selectedVertices.length && selectedVertices[i])) continue;
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            seen = true;
        }
    }

    void selectionBBoxMinMaxEdges(out Vec3 mn, out Vec3 mx, out bool seen) const {
        bool any = hasAnySelected(selectedEdges);
        bool[] vis = new bool[](vertices.length);
        mn = Vec3(float.infinity, float.infinity, float.infinity);
        mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        seen = false;
        foreach (i, edge; edges) {
            if (any && !(i < selectedEdges.length && selectedEdges[i])) continue;
            foreach (vi; edge) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
    }

    void selectionBBoxMinMaxFaces(out Vec3 mn, out Vec3 mx, out bool seen) const {
        bool any = hasAnySelected(selectedFaces);
        bool[] vis = new bool[](vertices.length);
        mn = Vec3(float.infinity, float.infinity, float.infinity);
        mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        seen = false;
        foreach (i, face; faces) {
            if (any && !(i < selectedFaces.length && selectedFaces[i])) continue;
            foreach (vi; face) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
    }

    Vec3 selectionBBoxCenterEdges() const {
        bool any = hasAnySelected(selectedEdges);
        bool[] vis = new bool[](vertices.length);
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (i, edge; edges) {
            if (any && !(i < selectedEdges.length && selectedEdges[i])) continue;
            foreach (vi; edge) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    Vec3 selectionBBoxCenterFaces() const {
        bool any = hasAnySelected(selectedFaces);
        bool[] vis = new bool[](vertices.length);
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (i, face; faces) {
            if (any && !(i < selectedFaces.length && selectedFaces[i])) continue;
            foreach (vi; face) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    /// Bounding-box center of the selection's BORDER vertices — verts on
    /// edges with exactly one selected adjacent face and at least one
    /// unselected adjacent face. For a cube top face this is the
    /// perimeter (same as `selectionBBoxCenterFaces`); for a sphere top
    /// hemisphere it's only the equator ring (the inner verts are NOT
    /// on a border edge). Mirrors MODO `actr.border` semantics.
    /// Falls back to `selectionBBoxCenterFaces` when there's no border
    /// edge (every selected face's edges are also adjacent to other
    /// selected faces — closed selection on a closed manifold).
    Vec3 selectionBorderBBoxCenterFaces() const {
        if (!hasAnySelected(selectedFaces)) return Vec3(0, 0, 0);
        bool[] onBorder = new bool[](vertices.length);
        bool   any      = false;
        // For each edge, count selected and unselected adjacent faces.
        foreach (ei; 0 .. cast(uint)edges.length) {
            int sel = 0, unsel = 0;
            foreach (fi; facesAroundEdge(ei)) {
                if (fi < selectedFaces.length && selectedFaces[fi]) sel++;
                else                                                unsel++;
            }
            if (sel == 1 && unsel >= 1) {
                onBorder[edges[ei][0]] = true;
                onBorder[edges[ei][1]] = true;
                any = true;
            }
        }
        if (!any) return selectionBBoxCenterFaces();
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        foreach (vi, on; onBorder) if (on) {
            Vec3 v = vertices[vi];
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
        }
        return (mn + mx) * 0.5f;
    }

    /// Return the centroid (average position) of face `fi`.
    Vec3 faceCentroid(uint fi) const {
        const uint[] face = faces[fi];
        Vec3 s = Vec3(0, 0, 0);
        foreach (vi; face) s += vertices[vi];
        float inv = 1.0f / cast(float)face.length;
        return s * inv;
    }

    /// Return a bool mask (indexed by vertex index) where `true` means the vertex
    /// belongs to at least one front-facing face AND is not occluded by any
    /// other front-facing face along the eye→vertex ray.
    ///
    /// A face is front-facing when its normal points toward the camera
    /// (dot(normal, face[0] - eye) < 0). Occlusion is tested by ray-casting
    /// from the eye through each candidate vertex against every other
    /// front-facing face: if the ray crosses a face's plane inside its
    /// polygon at a smaller t than the vertex distance, the vertex is hidden
    /// behind that face. Used by pickVertices / pickEdges and the RMB lasso
    /// path so neither picks elements behind opaque geometry — including
    /// disjoint mesh components in the same Mesh struct (cube + cube,
    /// cube + cylinder, etc.).
    ///
    /// `vp` is used to prune occluder candidates by screen-space bbox: a face
    /// can occlude a vertex only if the vertex's projected pixel falls inside
    /// the face's screen bounding rectangle. For scenes with non-overlapping
    /// components (the common case) this drops the cost from O(V·F) toward
    /// O(V + F). Inside the bbox, point-in-polygon and the depth check are
    /// done in screen space (using already-projected face corners), avoiding
    /// the per-iteration 3D-to-2D dominant-axis projection of the original
    /// implementation.
    bool[] visibleVertices(Vec3 eye, const ref Viewport vp) const {
        import math : pointInPolygon2D, projectToWindowFull;
        import std.math : abs;

        bool[] vis = new bool[](vertices.length);
        if (vertices.length == 0 || faces.length == 0) return vis;

        // Project every vertex once. Behind-camera verts get vsValid=false
        // and skip both candidate selection and occluder polygon membership.
        auto vsx     = new float[](vertices.length);
        auto vsy     = new float[](vertices.length);
        auto vsZ     = new float[](vertices.length);
        auto vsValid = new bool [](vertices.length);
        foreach (vi, q; vertices) {
            float sx, sy, ndcZ;
            if (projectToWindowFull(q, vp, sx, sy, ndcZ)) {
                vsx[vi] = sx; vsy[vi] = sy; vsZ[vi] = ndcZ;
                vsValid[vi] = true;
            }
        }

        // Pass 1: collect front-facing faces with cached screen polygons +
        // bboxes, and seed the visibility mask.
        struct FrontFace {
            uint    fi;
            Vec3    n;             // face plane normal (un-normalised, fine for ray-plane)
            float   minX, maxX, minY, maxY;
            float[] sxs, sys;      // screen-space corner positions
        }
        FrontFace[] front;
        front.reserve(faces.length);
        foreach (fi, ref face; faces) {
            if (face.length < 3) continue;
            Vec3 fn = cross(vertices[face[1]] - vertices[face[0]],
                            vertices[face[2]] - vertices[face[0]]);
            if (dot(fn, vertices[face[0]] - eye) >= 0) continue;
            foreach (vi; face) vis[vi] = true;

            float mnx = float.infinity, mxx = -float.infinity;
            float mny = float.infinity, mxy = -float.infinity;
            auto sxs = new float[](face.length);
            auto sys = new float[](face.length);
            bool anyValid = false;
            foreach (i, vk; face) {
                if (!vsValid[vk]) continue;
                anyValid = true;
                sxs[i] = vsx[vk]; sys[i] = vsy[vk];
                if (vsx[vk] < mnx) mnx = vsx[vk];
                if (vsx[vk] > mxx) mxx = vsx[vk];
                if (vsy[vk] < mny) mny = vsy[vk];
                if (vsy[vk] > mxy) mxy = vsy[vk];
            }
            // A face with any corner behind the camera can't reliably act as
            // an occluder via screen-space tests — skip it. Vertex-on-face
            // candidacy was already seeded above, so nothing is lost.
            if (!anyValid) continue;
            bool allValid = true;
            foreach (vk; face) if (!vsValid[vk]) { allValid = false; break; }
            if (!allValid) continue;

            front ~= FrontFace(cast(uint)fi, fn, mnx, mxx, mny, mxy, sxs, sys);
        }

        // Pass 2: per candidate vertex, walk only those front faces whose
        // screen bbox contains the vertex's projected pixel; do screen-space
        // point-in-polygon, then a 3D ray-plane depth test to confirm the
        // face is actually closer to the eye. Faces that own the vertex are
        // skipped (their plane passes through the vertex; FP noise near t=1
        // is also handled by the (1 - ε) cutoff).
        enum float OCCL_EPS = 1e-4f;
        foreach (vi; 0 .. vertices.length) {
            if (!vis[vi] || !vsValid[vi]) continue;
            float vsxi = vsx[vi], vsyi = vsy[vi];
            Vec3  vpos = vertices[vi];
            Vec3  dir  = vpos - eye;

            foreach (ref ff; front) {
                if (vsxi < ff.minX || vsxi > ff.maxX ||
                    vsyi < ff.minY || vsyi > ff.maxY) continue;

                const(uint)[] face = faces[ff.fi];
                bool ownsVi = false;
                foreach (v; face) if (v == vi) { ownsVi = true; break; }
                if (ownsVi) continue;

                if (!pointInPolygon2D(vsxi, vsyi, ff.sxs, ff.sys)) continue;

                float denom = dot(ff.n, dir);
                if (abs(denom) < 1e-9f) continue;
                float t = dot(ff.n, vertices[face[0]] - eye) / denom;
                if (t <= 0.0f || t >= 1.0f - OCCL_EPS) continue;

                vis[vi] = false;
                break;
            }
        }
        return vis;
    }

    /// Return the canonical edge key for edge `ei` (order-independent hash of its two vertices).
    pragma(inline, true)
    ulong edgeKeyOf(uint ei) const {
        return edgeKey(edges[ei][0], edges[ei][1]);
    }

    /// Return the index in `edges[]` of the edge connecting vertices `a` and `b`.
    /// Returns `~0u` if no such edge exists.  O(1) via `edgeIndexMap`.
    pragma(inline, true)
    uint edgeIndex(uint a, uint b) const {
        if (auto p = edgeKey(a, b) in edgeIndexMap) return *p;
        return ~0u;
    }

    /// Same as `edgeIndex` but accepts a pre-computed canonical key.
    pragma(inline, true)
    uint edgeIndexByKey(ulong key) const {
        if (auto p = key in edgeIndexMap) return *p;
        return ~0u;
    }

    // -----------------------------------------------------------------------
    // Quad-loop / ring helpers
    // -----------------------------------------------------------------------

    /// Given edge `ei` and one of its incident faces `fi`, return the index of
    /// the other face sharing `ei`.  Returns -1 if `ei` is a boundary edge.
    int adjacentFaceThrough(uint ei, uint fi) const {
        foreach (f; facesAroundEdge(ei))
            if (f != fi) return cast(int)f;
        return -1;
    }

    /// Find the winding-order position of the edge with canonical key `ek` in
    /// face `fi`.  Returns -1 if not found.
    int findEdgeInFace(uint fi, ulong ek) const {
        const face = faces[fi];
        for (int j = 0; j < cast(int)face.length; j++)
            if (edgeKey(face[j], face[(j+1) % face.length]) == ek) return j;
        return -1;
    }

    /// Walk an edge loop starting from `startEdge` in the direction given by
    /// `startFace`.  Returns ordered edge indices; `startEdge` is first.
    /// Stops at non-quad faces, boundaries, or when the loop closes.
    int[] walkEdgeLoop(int startEdge, int startFace) const {
        if (startFace < 0 || startFace >= cast(int)faces.length) return [];
        const sfv = faces[startFace];
        if (sfv.length != 4) return [];
        int si = findEdgeInFace(cast(uint)startFace, edgeKeyOf(cast(uint)startEdge));
        if (si < 0) return [];
        uint a = sfv[si], b = sfv[(si+1)%4];
        int curEdge = startEdge, curFace = startFace;
        int[] res; bool[ulong] vis;
        while (true) {
            ulong ck = edgeKey(a, b);
            if (ck in vis) break;
            vis[ck] = true;
            res ~= curEdge;
            const face = faces[curFace];
            if (face.length != 4) break;
            int jb = -1;
            for (int j = 0; j < 4; j++) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb-1+4)%4], next = face[(jb+1)%4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            uint sei = edgeIndex(b, c); if (sei == ~0u) break;
            int nf = adjacentFaceThrough(sei, cast(uint)curFace); if (nf < 0) break;
            const nface = faces[nf];
            if (nface.length != 4) break;
            int jb2 = -1;
            for (int j = 0; j < 4; j++) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2-1+4)%4], n2 = nface[(jb2+1)%4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            uint bd_ei = edgeIndex(b, d); if (bd_ei == ~0u) break;
            a = b; b = d; curEdge = cast(int)bd_ei; curFace = nf;
        }
        return res;
    }

    /// Walk a vertex loop in the direction `startVert`→`nextVert`.
    /// Returns ordered vertex indices starting with `startVert`.
    /// Stops at non-quad faces, boundaries, or when the loop closes.
    uint[] walkVertexLoop(uint startVert, uint nextVert) const {
        uint sei = edgeIndex(startVert, nextVert);
        if (sei == ~0u) return [];
        int startFace = -1;
        foreach (fi; facesAroundEdge(sei)) {
            const fv = faces[fi];
            if (fv.length != 4) continue;
            for (int j = 0; j < 4; j++)
                if (fv[j] == startVert && fv[(j+1)%4] == nextVert) { startFace = cast(int)fi; break; }
            if (startFace >= 0) break;
        }
        if (startFace < 0) return [];
        uint a = startVert, b = nextVert;
        int curFace = startFace;
        uint[] res; bool[ulong] vis;
        while (true) {
            ulong ck = edgeKey(a, b);
            if (ck in vis) break;
            vis[ck] = true;
            res ~= a;
            const face = faces[curFace];
            if (face.length != 4) break;
            int jb = -1;
            for (int j = 0; j < 4; j++) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb-1+4)%4], next = face[(jb+1)%4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            uint seis = edgeIndex(b, c); if (seis == ~0u) break;
            int nf = adjacentFaceThrough(seis, cast(uint)curFace); if (nf < 0) break;
            const nface = faces[nf];
            if (nface.length != 4) break;
            int jb2 = -1;
            for (int j = 0; j < 4; j++) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2-1+4)%4], n2 = nface[(jb2+1)%4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            a = b; b = d; curFace = nf;
        }
        return res;
    }

    /// Walk a face loop entered via `entryKey` into `startFace`.
    /// Returns ordered face indices; `startFace` is first.
    int[] walkFaceLoop(int startFace, ulong entryKey) const {
        int[] res; bool[int] vis;
        int cur = startFace; ulong entry = entryKey;
        while (true) {
            if (cur in vis) break;
            vis[cur] = true;
            res ~= cur;
            const face = faces[cur];
            if (face.length != 4) break;
            int ei = findEdgeInFace(cast(uint)cur, entry);
            if (ei < 0) break;
            ulong oppKey = edgeKey(face[(ei+2)%4], face[(ei+3)%4]);
            uint opp_idx = edgeIndexByKey(oppKey);
            if (opp_idx == ~0u) break;
            int nf = adjacentFaceThrough(opp_idx, cast(uint)cur);
            if (nf < 0) break;
            cur = nf; entry = oppKey;
        }
        return res;
    }

    /// Walk an edge ring starting from `startEdge` in the direction given by
    /// `startFace`.  Returns the opposite edge indices encountered at each quad.
    /// The starting edge itself is NOT included — the caller handles it.
    int[] walkEdgeRing(int startEdge, int startFace) const {
        int[] res; bool[int] vis;
        int curFace = startFace;
        ulong curKey = edgeKeyOf(cast(uint)startEdge);
        while (true) {
            if (curFace in vis) break;
            const face = faces[curFace];
            if (face.length != 4) break;
            int j = findEdgeInFace(cast(uint)curFace, curKey);
            if (j < 0) break;
            vis[curFace] = true;
            int oppJ = (j+2)%4;
            ulong oppKey = edgeKey(face[oppJ], face[(oppJ+1)%4]);
            uint opp_ei = edgeIndexByKey(oppKey);
            if (opp_ei == ~0u) break;
            res ~= cast(int)opp_ei;
            int nf = adjacentFaceThrough(opp_ei, cast(uint)curFace);
            if (nf < 0) break;
            curFace = nf; curKey = oppKey;
        }
        return res;
    }

    /// Return an input range over all loop indices (darts) incident to vertex `vi`.
    /// Each yielded value is a uint loop index `li` with `loops[li].vert == vi`.
    /// Traversal follows twin(prev(li)); stops at a boundary or a full circle.
    /// If `startLi == ~0u`, uses `vertLoop[vi]` as the first dart.
    /// Returns an empty range when the vertex is isolated (vertLoop[vi] == ~0u).
    VertexDartRange dartsAroundVertex(uint vi, uint startLi = ~0u) const {
        uint first = (startLi != ~0u) ? startLi : vertLoop[vi];
        debug if (first != ~0u)
            assert(loops[first].vert == vi,
                   "dartsAroundVertex: startLi does not belong to vertex vi");
        return VertexDartRange(loops, first);
    }

    /// Rebuild the half-edge loop structure from the current faces/vertices.
    /// Must be called after any topology change (addFace, catmullClark, bevel, etc.).
    void buildLoops() {

        // Pre-compute total loop count + per-face start offset in one
        // pass. Lets pass 1 below run in parallel — each face writes
        // to a disjoint loops[faceLoop[fi] .. faceLoop[fi]+N] slice.
        faceLoop.length = faces.length;
        size_t total = 0;
        foreach (fi, f; faces) {
            faceLoop[fi] = cast(uint)total;
            total += f.length;
        }

        loops.length    = total;
        vertLoop.length = vertices.length;
        loopEdge.length = total;

        // Initialise sentinels in bulk (the SIMD-friendly default is
        // ~0u, which is the boundary marker for `twin` and the
        // missing-edge marker for loopEdge).
        vertLoop[] = ~0u;
        loopEdge[] = ~0u;

        // Pass 1: fill vert, face, next, prev. Independent across
        // faces — each writes to its own slice of `loops`. Skip
        // vertLoop seeding inside the parallel body (it's a shared
        // write to the same vert from multiple faces, which races on
        // last-writer-wins; do it in a separate serial pass for
        // determinism).
        enum size_t PARALLEL_BUILD_MIN = 4096;
        void fillOneFace(size_t fi) {
            auto face = faces[fi];
            uint li = faceLoop[fi];
            uint N = cast(uint)face.length;
            foreach (i; 0 .. N) {
                loops[li + i].vert = face[i];
                loops[li + i].face = cast(uint)fi;
                loops[li + i].next = li + (i + 1) % N;
                loops[li + i].prev = li + (i + N - 1) % N;
                loops[li + i].twin = ~0u;
            }
        }
        if (faces.length >= PARALLEL_BUILD_MIN) {
            foreach (fi; parallel(iota(faces.length))) fillOneFace(fi);
        } else {
            foreach (fi; 0 .. faces.length) fillOneFace(fi);
        }

        // Serial vertLoop seed pass — every loop writes vertLoop[its vert].
        foreach (idx; 0 .. total) {
            vertLoop[loops[idx].vert] = cast(uint)idx;
        }


        // Pass 2: rebuild edgeIndexMap (serial — AA insert isn't
        // thread-safe) and fill loopEdge in parallel (D AAs ARE safe
        // for read-only concurrent lookup). edgeIndexMap is the
        // mesh-wide (undirected) edgeKey → edge index AA, kept for
        // external callers (bevel, split_edge, …).
        edgeIndexMap = null;
        foreach (i, e; edges) edgeIndexMap[edgeKey(e[0], e[1])] = cast(uint)i;
        void fillLoopEdge(size_t idx) {
            uint u = loops[idx].vert;
            uint v = loops[loops[idx].next].vert;
            if (auto p = edgeKey(u, v) in edgeIndexMap)
                loopEdge[idx] = *p;
        }
        if (total >= PARALLEL_BUILD_MIN) {
            foreach (idx; parallel(iota(total))) fillLoopEdge(idx);
        } else {
            foreach (idx; 0 .. total) fillLoopEdge(idx);
        }


        // Pass 3: twin pairing via (max 2) loops-per-edge. The slot
        // assignment (first → A, second → B) needs serial order to
        // avoid a race on the -1-sentinel comparison; the writeback
        // pass (twin from A/B) is parallelisable.
        int[] edgeLoopA = new int[](edges.length);
        int[] edgeLoopB = new int[](edges.length);
        edgeLoopA[] = -1;
        edgeLoopB[] = -1;
        foreach (idx; 0 .. total) {
            uint ei = loopEdge[idx];
            if (ei == ~0u) continue;
            if (edgeLoopA[ei] == -1) edgeLoopA[ei] = cast(int)idx;
            else                     edgeLoopB[ei] = cast(int)idx;
        }
        void fillTwin(size_t idx) {
            uint ei = loopEdge[idx];
            if (ei == ~0u) return;
            int a = edgeLoopA[ei];
            int b = edgeLoopB[ei];
            if (b == -1) return;
            loops[idx].twin = (a == cast(int)idx) ? cast(uint)b : cast(uint)a;
        }
        if (total >= PARALLEL_BUILD_MIN) {
            foreach (idx; parallel(iota(total))) fillTwin(idx);
        } else {
            foreach (idx; 0 .. total) fillTwin(idx);
        }


        // Anchor walk — independent per vertex; for BOUNDARY verts,
        // walk back via next(twin(cur)) until the open start of the
        // fan. For closed meshes (every edge has both A and B loops)
        // the walk just re-traverses a closed ring and ends at `orig`
        // — the resulting vertLoop[vi] is some loop in the same ring
        // we started in, which is what we already had. Detect that
        // case ONCE and skip the per-vertex walk entirely — it's the
        // single biggest cost (~29% of CPU during a subpatch-mode
        // sphere drag profile) for closed-manifold inputs, which are
        // the common case in subpatch preview meshes.
        bool hasBoundary = false;
        foreach (ei; 0 .. edges.length) {
            if (edgeLoopA[ei] != -1 && edgeLoopB[ei] == -1) {
                hasBoundary = true;
                break;
            }
        }
        if (hasBoundary) {
            void anchorOneVert(size_t vi) {
                if (vertLoop[vi] == ~0u) return;
                uint cur  = vertLoop[vi];
                uint orig = cur;
                foreach (_; 0 .. faces.length + 4) {
                    if (loops[cur].twin == ~0u) break;
                    uint back = loops[loops[cur].twin].next;
                    if (back == orig) break;
                    cur = back;
                }
                vertLoop[vi] = cur;
            }
            if (vertices.length >= PARALLEL_BUILD_MIN) {
                foreach (vi; parallel(iota(vertices.length))) anchorOneVert(vi);
            } else {
                foreach (vi; 0 .. vertices.length) anchorOneVert(vi);
            }
        }
    }

}

// ---------------------------------------------------------------------------
// VertexDartRange
// ---------------------------------------------------------------------------

/// Input range (and forward range via .save) over all half-edge dart indices
/// incident to a given vertex.  Each element is a uint loop index `li` such
/// that `loops[li].vert` equals the start vertex.
///
/// Traversal rule: from the current dart `li`, the next dart around the vertex
/// is `twin(prev(li))`.  The range stops when:
///   - `twin == ~0u`  (boundary edge reached), or
///   - the dart wraps back to the starting dart (full circle), or
///   - the internal safety counter exceeds 1024 (degenerate mesh guard).
///
/// The range holds only a slice of `Loop[]`, not a reference to the whole
/// Mesh, so it is a lightweight value type with no cyclic dependency.
struct VertexDartRange {
    private const(Loop)[] _loops;
    private uint  _start;   // first dart (also the stop sentinel for cycles)
    private uint  _cur;     // current dart
    private bool  _done;
    private uint  _steps;

    private enum uint MAX_STEPS = 1024;

    /// Construct from a loops slice and a starting dart index.
    /// If `startLi == ~0u` the range is immediately empty (isolated vertex).
    this(const(Loop)[] loops, uint startLi) {
        _loops = loops;
        _start = startLi;
        _cur   = startLi;
        _done  = (startLi == ~0u);
        _steps = 0;
    }

    /// True when the range has been exhausted.
    @property bool empty() const { return _done; }

    /// The current dart index.
    @property uint front() const
    in (!_done)
    { return _cur; }

    /// Advance to the next dart around the vertex.
    void popFront()
    in (!_done)
    {
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _done = true; return; }
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexDartRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start)
            _done = true;
    }

    /// Save a copy so the range can be used as a ForwardRange.
    @property VertexDartRange save() const { return this; }
}

/// One-time-per-session stderr warning shared by the three half-edge
/// vertex-walk ranges (Dart / Neighbor / Edge). Triggered when a walk
/// fails to return to its starting dart inside MAX_STEPS — typically
/// non-manifold edges in an imported mesh (LWO files commonly share
/// an edge across 3+ faces, which breaks the unique-twin invariant
/// the walk relies on).
///
/// Old behaviour was `debug assert(false, …)`, which crashed debug
/// builds on every degenerate walk; release builds were already
/// gracefully truncating via `_done = true`. The assert was hiding
/// the fact that the underlying topology problem deserves a fix at
/// build-loops time (treat non-manifold edges as boundaries so twins
/// stay well-defined) — log once so the issue stays visible without
/// being a hard stop.
private __gshared bool maxStepsWarned = false;
private void warnMaxStepsExceeded(string rangeName) nothrow {
    if (maxStepsWarned) return;
    maxStepsWarned = true;
    try {
        import std.stdio : stderr;
        stderr.writefln(
            "[mesh] %s: MAX_STEPS exceeded — non-manifold cage edges " ~
            "(walk truncated; selection / loop ops may be incomplete).",
            rangeName);
    } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// FaceEdgeRange
// ---------------------------------------------------------------------------

/// One directed edge of a face: the consecutive vertex pair (a → b).
struct FaceEdge { uint a, b; }

/// Forward range over all consecutive vertex pairs of a face polygon.
/// Yields FaceEdge(face[j], face[(j+1) % N]) for j in 0..N.
struct FaceEdgeRange {
    private const(uint)[] _verts;
    private uint _j;

    this(const(uint)[] verts) { _verts = verts; _j = 0; }

    @property bool      empty() const { return _j >= _verts.length; }
    @property FaceEdge  front() const { return FaceEdge(_verts[_j], _verts[(_j + 1) % _verts.length]); }
    void popFront() { ++_j; }
    @property FaceEdgeRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexFaceRange
// ---------------------------------------------------------------------------

/// Forward range over all faces incident to a vertex.
/// Wraps VertexDartRange and projects each dart to its face index.
struct VertexFaceRange {
    private const(Loop)[]  _loops;
    private VertexDartRange _inner;

    this(const(Loop)[] loops, uint startLi) {
        _loops = loops;
        _inner = VertexDartRange(loops, startLi);
    }

    @property bool empty() const { return _inner.empty; }
    @property uint front() const { return _loops[_inner.front].face; }
    void popFront() { _inner.popFront(); }
    @property VertexFaceRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexNeighborRange
// ---------------------------------------------------------------------------

/// Forward range over all vertices directly connected to a vertex by an edge.
/// For boundary vertices emits the extra neighbour at the open end of the fan.
/// Requires buildLoops() (uses vertLoop anchored to the fan start).
struct VertexNeighborRange {
    private const(Loop)[] _loops;
    private uint _start;
    private uint _cur;
    private bool _done;
    private bool _atExtra;
    private uint _steps;
    private enum uint MAX_STEPS = 1024;

    this(const(Loop)[] loops, uint startLi) {
        _loops   = loops;
        _start   = startLi;
        _cur     = startLi;
        _done    = (startLi == ~0u);
        _atExtra = false;
        _steps   = 0;
    }

    @property bool empty() const { return _done; }

    @property uint front() const
    in (!_done)
    {
        // Main darts: neighbour is the next vertex in the dart.
        // Extra boundary dart: the open-end vertex is prev(cur).vert.
        return _atExtra ? _loops[_loops[_cur].prev].vert
                        : _loops[_loops[_cur].next].vert;
    }

    void popFront()
    in (!_done)
    {
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexNeighborRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start) _done = true;
    }

    @property VertexNeighborRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexEdgeRange
// ---------------------------------------------------------------------------

/// Forward range over all edge indices incident to a vertex.
///
/// Uses vertLoop[vi] (anchored to the open start of the fan by buildLoops) and
/// walks via twin(prev(li)).  For boundary vertices, emits one extra edge at the
/// end — the boundary edge represented by prev(lastDart) — so all incident edges
/// are always yielded, whether the vertex is interior or on a boundary.
struct VertexEdgeRange {
    private const(Loop)[] _loops;
    private const(uint)[] _loopEdge;
    private uint _start;
    private uint _cur;
    private bool _done;
    private bool _atExtra;   // true while emitting the boundary extra edge
    private uint _steps;
    private enum uint MAX_STEPS = 1024;

    this(const(Loop)[] loops, const(uint)[] loopEdge, uint startLi) {
        _loops    = loops;
        _loopEdge = loopEdge;
        _start    = startLi;
        _cur      = startLi;
        _done     = (startLi == ~0u);
        _atExtra  = false;
        _steps    = 0;
    }

    @property bool empty() const { return _done; }

    @property uint front() const
    in (!_done)
    {
        return _atExtra ? _loopEdge[_loops[_cur].prev] : _loopEdge[_cur];
    }

    void popFront()
    in (!_done)
    {
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }  // boundary: emit extra next
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexEdgeRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start) _done = true;
    }

    @property VertexEdgeRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// EdgeFaceRange
// ---------------------------------------------------------------------------

/// Forward range over the 1–2 faces incident to an edge.
/// Finds the dart va→vb by walking darts around va (O(valence)).
/// Yields the face of that dart, then the face of its twin (if not boundary).
struct EdgeFaceRange {
    private uint[2] _faces;
    private uint    _count;
    private uint    _i;

    this(const(Loop)[] loops, const(uint[2])[] edges,
         const(uint)[] vertLoop, uint ei)
    {
        _count = 0; _i = 0;
        if (ei >= edges.length) return;
        uint va = edges[ei][0], vb = edges[ei][1];
        if (va >= vertLoop.length || vertLoop[va] == ~0u) return;
        // Walk darts from va; find the one whose next vertex is vb.
        foreach (li; VertexDartRange(loops, vertLoop[va])) {
            if (loops[loops[li].next].vert == vb) {
                _faces[_count++] = loops[li].face;
                uint twin = loops[li].twin;
                if (twin != ~0u)
                    _faces[_count++] = loops[twin].face;
                break;
            }
        }
    }

    @property bool empty() const { return _i >= _count; }
    @property uint front() const { return _faces[_i]; }
    void popFront() { ++_i; }
    @property EdgeFaceRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// AdjacentFaceRange
// ---------------------------------------------------------------------------

/// Forward range over all faces that share an edge with a given face.
/// Uses the half-edge twin links directly — no hash map needed.
/// Boundary edges (twin == ~0u) are skipped silently.
/// Each adjacent face is yielded once per shared edge (normally once per face).
struct AdjacentFaceRange {
    private const(Loop)[] _loops;
    private uint _start;  // faceLoop[fi]: first loop of the face
    private uint _cur;    // loop currently pointing at an adjacent face
    private bool _done;

    this(const(Loop)[] loops, uint faceStart) {
        _loops    = loops;
        _start    = faceStart;
        _cur      = faceStart;
        _done     = (faceStart == ~0u);
        if (!_done) _skipInvalid();
    }

    @property bool empty() const { return _done; }

    /// Index of the adjacent face reached via the current loop's twin.
    @property uint front() const
    in (!_done)
    { return _loops[_loops[_cur].twin].face; }

    void popFront()
    in (!_done)
    {
        _cur = _loops[_cur].next;
        if (_cur == _start) { _done = true; return; }
        _skipInvalid();
    }

    @property AdjacentFaceRange save() const { return this; }

private:
    void _skipInvalid() {
        while (_loops[_cur].twin == ~0u) {
            _cur = _loops[_cur].next;
            if (_cur == _start) { _done = true; return; }
        }
    }
}

// ---------------------------------------------------------------------------
// edgeKey
// ---------------------------------------------------------------------------

// Canonical edge key: always (min, max) packed into a ulong.
ulong edgeKey(uint a, uint b) {
    return a < b ? (cast(ulong)a << 32 | cast(ulong)b)
                 : (cast(ulong)b << 32 | cast(ulong)a);
}

Mesh makeCube() {
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, -0.5f, -0.5f), // 0
        Vec3( 0.5f, -0.5f, -0.5f), // 1
        Vec3( 0.5f,  0.5f, -0.5f), // 2
        Vec3(-0.5f,  0.5f, -0.5f), // 3
        Vec3(-0.5f, -0.5f,  0.5f), // 4
        Vec3( 0.5f, -0.5f,  0.5f), // 5
        Vec3( 0.5f,  0.5f,  0.5f), // 6
        Vec3(-0.5f,  0.5f,  0.5f), // 7
    ];
    m.addFace([0, 3, 2, 1]);
    m.addFace([4, 5, 6, 7]);
    m.addFace([0, 4, 7, 3]);
    m.addFace([1, 2, 6, 5]);
    m.addFace([3, 7, 6, 2]);
    m.addFace([0, 1, 5, 4]);
    m.buildLoops();
    return m;
}

// Double-sided quad: 4 verts in a diamond pattern at slight ±Z offsets so
// the front and back quads have well-defined non-degenerate normals. Each
// vertex has valence=2 (only the two adjacent diamond-boundary edges) — a
// rare manifold configuration that exercises the weld case for bevels at
// non-collinear angles. Only realistic way to construct this in vibe3d.
Mesh makeDiamond() {
    Mesh m;
    m.vertices = [
        Vec3(-1.0f,  0.0f,  0.05f),  // 0  left
        Vec3( 0.0f, -1.0f, -0.05f),  // 1  bottom
        Vec3( 1.0f,  0.0f,  0.05f),  // 2  right
        Vec3( 0.0f,  1.0f, -0.05f),  // 3  top
    ];
    m.addFace([0, 1, 2, 3]);   // front quad (+Z-ish)
    m.addFace([0, 3, 2, 1]);   // back quad  (-Z-ish, opposite winding)
    m.buildLoops();
    return m;
}

// Regular octahedron centered at origin with verts on the unit axes. Every
// vertex has valence=4, every face is a triangle, and the 3 face normals
// meeting at any vertex are NON-perpendicular (the dihedral is ~109.47°).
// Useful for testing the cube-corner cap algorithm on non-orthogonal frame
// normals (the unit-cube affine map handles any linearly-independent normals).
Mesh makeOctahedron() {
    Mesh m;
    m.vertices = [
        Vec3( 1, 0, 0),  // 0  +X
        Vec3(-1, 0, 0),  // 1  -X
        Vec3( 0, 1, 0),  // 2  +Y
        Vec3( 0,-1, 0),  // 3  -Y
        Vec3( 0, 0, 1),  // 4  +Z
        Vec3( 0, 0,-1),  // 5  -Z
    ];
    // 8 triangular faces, one per octant. Winding is CCW from outside.
    m.addFace([4, 0, 2]);  // +X +Y +Z
    m.addFace([4, 2, 1]);  // -X +Y +Z
    m.addFace([4, 1, 3]);  // -X -Y +Z
    m.addFace([4, 3, 0]);  // +X -Y +Z
    m.addFace([5, 2, 0]);  // +X +Y -Z
    m.addFace([5, 1, 2]);  // -X +Y -Z
    m.addFace([5, 3, 1]);  // -X -Y -Z
    m.addFace([5, 0, 3]);  // +X -Y -Z
    m.buildLoops();
    return m;
}

// L-shaped extrusion in the XY plane, depth 1 along Z. Profile (CCW from +Z):
//   (-1,-1) → (1,-1) → (1,0) → (0,0) → (0,1) → (-1,1)
// The vertex at (0, 0, ±0.5) sits at a CONCAVE corner — its interior
// dihedral on the L's bulk side is 270° (reflex), so the vertical edge
// connecting the two reflex corners is the canonical reflex/miter test edge.
Mesh makeLShape() {
    Mesh m;
    m.vertices = [
        Vec3(-1.0f, -1.0f,  0.5f), //  0 front: bottom-left
        Vec3( 1.0f, -1.0f,  0.5f), //  1 front: bottom-right
        Vec3( 1.0f,  0.0f,  0.5f), //  2 front: inner-bottom
        Vec3( 0.0f,  0.0f,  0.5f), //  3 front: REFLEX corner
        Vec3( 0.0f,  1.0f,  0.5f), //  4 front: inner-top
        Vec3(-1.0f,  1.0f,  0.5f), //  5 front: top-left
        Vec3(-1.0f, -1.0f, -0.5f), //  6 back: bottom-left
        Vec3( 1.0f, -1.0f, -0.5f), //  7 back: bottom-right
        Vec3( 1.0f,  0.0f, -0.5f), //  8 back: inner-bottom
        Vec3( 0.0f,  0.0f, -0.5f), //  9 back: REFLEX corner
        Vec3( 0.0f,  1.0f, -0.5f), // 10 back: inner-top
        Vec3(-1.0f,  1.0f, -0.5f), // 11 back: top-left
    ];
    m.addFace([0, 1, 2, 3, 4, 5]);     // front cap (+Z)
    m.addFace([6, 11, 10, 9, 8, 7]);   // back cap  (-Z)
    m.addFace([0, 6, 7, 1]);           // bottom side (-Y)
    m.addFace([1, 7, 8, 2]);           // right side  (+X, lower half)
    m.addFace([2, 8, 9, 3]);           // inner-bottom side (+Y, inner)
    m.addFace([3, 9, 10, 4]);          // inner-side       (+X, inner)
    m.addFace([4, 10, 11, 5]);         // top side    (+Y)
    m.addFace([5, 11, 6, 0]);          // left side   (-X)
    m.buildLoops();
    return m;
}
/// Faceted subdivide restricted to a face mask: each face where faceMask[fi]
/// is true is split into n quads using its centroid and edge midpoints — no
/// vertex smoothing, unlike Catmull-Clark. Non-selected faces sharing an edge
/// with a selected face are widened to include that edge's midpoint, keeping
/// the mesh manifold (no T-junctions). `faceMask` may be shorter than
/// m.faces.length — missing entries are treated as false. If no face is
/// selected the mesh is returned topologically unchanged.
Mesh facetedSubdivide(ref const Mesh m, const bool[] faceMask) {
    uint nV = cast(uint)m.vertices.length;
    uint nF = cast(uint)m.faces.length;
    uint nE = cast(uint)m.edges.length;

    bool isSelected(size_t fi) {
        return fi < faceMask.length && faceMask[fi];
    }

    // Map edge key → index in m.edges.
    uint[ulong] edgeLookup;
    foreach (i, e; m.edges)
        edgeLookup[edgeKey(e[0], e[1])] = cast(uint)i;

    // An edge is "active" (gets a midpoint) iff at least one adjacent face is
    // selected. Walking selected face perimeters is enough — an unselected
    // face by itself never activates its edges.
    bool[] edgeActive = new bool[](nE);
    foreach (fi, face; m.faces) {
        if (!isSelected(fi)) continue;
        uint len = cast(uint)face.length;
        foreach (i; 0 .. len) {
            uint ei = edgeLookup[edgeKey(face[i], face[(i + 1) % len])];
            edgeActive[ei] = true;
        }
    }

    // Output vertex layout: [original] [edge midpoints] [selected centroids].
    uint[] edgeMidIdx      = new uint[](nE);  edgeMidIdx[]      = uint.max;
    uint[] faceCentroidIdx = new uint[](nF);  faceCentroidIdx[] = uint.max;

    uint outVCount = nV;
    foreach (ei; 0 .. nE) if (edgeActive[ei]) {
        edgeMidIdx[ei] = outVCount++;
    }
    foreach (fi; 0 .. nF) if (isSelected(fi)) {
        faceCentroidIdx[fi] = outVCount++;
    }

    Mesh result;
    result.vertices.length = outVCount;
    foreach (vi; 0 .. nV) result.vertices[vi] = m.vertices[vi];
    foreach (ei; 0 .. nE) if (edgeActive[ei]) {
        Vec3 a = m.vertices[m.edges[ei][0]];
        Vec3 b = m.vertices[m.edges[ei][1]];
        result.vertices[edgeMidIdx[ei]] = (a + b) * 0.5f;
    }
    foreach (fi; 0 .. nF) if (isSelected(fi)) {
        result.vertices[faceCentroidIdx[fi]] = m.faceCentroid(cast(uint)fi);
    }

    uint[ulong] resultEdgeLookup;
    foreach (fi, face; m.faces) {
        uint len = cast(uint)face.length;
        if (isSelected(fi)) {
            uint cIdx = faceCentroidIdx[fi];
            foreach (i; 0 .. len) {
                uint vi0  = face[i];
                uint vi1  = face[(i + 1) % len];
                uint vim1 = face[(i + len - 1) % len];
                uint eFwd  = edgeLookup[edgeKey(vi0, vi1)];
                uint eBack = edgeLookup[edgeKey(vim1, vi0)];
                result.addFaceFast(resultEdgeLookup,
                    [vi0, edgeMidIdx[eFwd], cIdx, edgeMidIdx[eBack]]);
            }
        } else {
            // Keep shape but splice in midpoints of any edge that is shared
            // with a selected face.
            uint[] widened;
            foreach (i; 0 .. len) {
                uint v0 = face[i];
                uint v1 = face[(i + 1) % len];
                widened ~= v0;
                uint ei = edgeLookup[edgeKey(v0, v1)];
                if (edgeMidIdx[ei] != uint.max)
                    widened ~= edgeMidIdx[ei];
            }
            result.addFaceFast(resultEdgeLookup, widened);
        }
    }

    result.buildLoops();
    return result;
}



/// Back-references mapping a subdivided mesh's vertices/edges/faces to an
/// "ultimate source" mesh (typically the cage). Indices are into the source
/// mesh; `uint.max` means the element was introduced by subdivision and has
/// no direct counterpart in the source. `subpatch` is the per-face mask that
/// drives the next subdivision pass.
struct SubpatchTrace {
    uint[] vertOrigin;
    uint[] edgeOrigin;
    uint[] faceOrigin;
    bool[] subpatch;

    /// Identity trace for `m`: every vert/edge/face traces to itself.
    /// `initialSubpatch` is copied into `subpatch`; missing entries default false.
    static SubpatchTrace identity(ref const Mesh m, const bool[] initialSubpatch) {
        SubpatchTrace t;
        t.vertOrigin = new uint[](m.vertices.length);
        t.edgeOrigin = new uint[](m.edges.length);
        t.faceOrigin = new uint[](m.faces.length);
        t.subpatch   = new bool[](m.faces.length);
        foreach (i; 0 .. m.vertices.length) t.vertOrigin[i] = cast(uint)i;
        foreach (i; 0 .. m.edges.length)    t.edgeOrigin[i] = cast(uint)i;
        foreach (i; 0 .. m.faces.length)    t.faceOrigin[i] = cast(uint)i;
        foreach (i; 0 .. m.faces.length)
            t.subpatch[i] = (i < initialSubpatch.length) && initialSubpatch[i];
        return t;
    }
}

/// Cached subdivision preview of a source (cage) mesh. When `active`
/// is true, `mesh`/`trace` hold the OpenSubdiv-emitted limit geometry;
/// otherwise the cage should be rendered directly and this struct is
/// inert. The cache rebuilds lazily when `source.mutationVersion` or
/// `depth` changes; drag-frame position updates go through the cached
/// `osdAccel` stencil table without touching topology.
struct SubpatchPreview {
    Mesh          mesh;
    SubpatchTrace trace;
    bool          active;
    ulong         sourceVersion         = ulong.max;
    /// Last source.topologyVersion we built against. While
    /// `source.topologyVersion` is unchanged but mutationVersion
    /// bumped (move/rotate/scale drag), we skip the full rebuild and
    /// re-evaluate stencil positions via `osdAccel.refresh`.
    ulong         sourceTopologyVersion = ulong.max;
    int           depth                 = -1;

    /// Reverse-lookup: for each CAGE vertex index, the preview-mesh
    /// vertex that carries its smoothed position (`uint.max` if no
    /// preview vert traces back to this cage vert). Built alongside
    /// `trace.vertOrigin[]` so the picking pipeline can iterate the
    /// 8 K cage verts instead of the 500 K+ preview verts at
    /// `subpatchDepth=3` (saves a ~60× factor in the per-frame
    /// hover-pick inner loop on subpatch meshes).
    uint[] cageVertPreview;

    /// OpenSubdiv back-end. Owns the cached topology + stencil table
    /// and drives both full rebuilds (buildPreview) and per-drag-frame
    /// position refreshes (refresh).
    import subpatch_osd : OsdAccel;
    OsdAccel      osdAccel;

    /// Phase 3b — set by the most recent rebuildIfStale fast-path
    /// when the OSD GPU fan-out wrote vibe3d's face VBO directly.
    /// Main loop reads this to skip the duplicate face-VBO write
    /// inside its standard `gpu.refreshPositions` call (uses
    /// refreshNonFacePositions instead).
    bool lastRefreshFannedOut;

    /// `targetFaceVbo` (and `targetFaceVertCount`) wire the GPU fan-
    /// out path: when non-zero, the position-only fast path tries
    /// `osdAccel.refreshIntoFaceVbo` against this VBO before falling
    /// back to the CPU readback. The caller (app.d main loop) passes
    /// gpu.faceVbo + gpu.faceVertCount.
    void rebuildIfStale(ref const Mesh source, int d,
                         GLuint targetFaceVbo = 0,
                         int targetFaceVertCount = 0) {
        lastRefreshFannedOut = false;
        if (sourceVersion == source.mutationVersion && depth == d)
            return;
        // Position-only fast path: cage topology + depth unchanged →
        // ask OSD's stencil table for new limit positions.
        if (active
            && depth == d
            && sourceTopologyVersion == source.topologyVersion
            && osdAccel.valid)
        {
            // Try GPU fan-out: writes positions+normals straight into
            // the caller's face VBO, no CPU readback for that data.
            // Falls back to the CPU/readback path when the layout
            // doesn't line up (different topology already uploaded)
            // or when the GL eval wasn't built (no GL context).
            if (targetFaceVbo != 0 && osdAccel.canFanOut
                && osdAccel.refreshIntoFaceVbo(source,
                        targetFaceVbo, targetFaceVertCount))
            {
                lastRefreshFannedOut = true;
            }
            // Always run osdAccel.refresh so preview.mesh.vertices
            // stays fresh — vibe3d's edge + vert VBOs are written
            // from the CPU side and several other consumers (lasso
            // vis test below the threshold, debug overlays) read
            // preview.vertices too. Phase 3c would drop this when
            // those consumers migrate.
            osdAccel.refresh(source, mesh);
            ++mesh.mutationVersion;
            sourceVersion = source.mutationVersion;
            return;
        }
        rebuild(source, d);
    }

    void rebuild(ref const Mesh source, int d) {
        depth                 = d;
        sourceVersion         = source.mutationVersion;
        sourceTopologyVersion = source.topologyVersion;
        cageVertPreview.length = 0;
        osdAccel.clear();
        if (d <= 0 || !source.hasAnySubpatch()) {
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            return;
        }

        // OsdAccel.buildPreview extracts the subpatch-marked subset
        // (the whole cage when `allSubpatch`, just a slice otherwise),
        // feeds it to OpenSubdiv, and emits the limit Mesh + trace.
        // Non-subpatch faces of the cage do not appear in the preview
        // in the selective case — see OsdAccel.buildPreview for the
        // trade-off rationale.
        if (!osdAccel.buildPreview(source, d, mesh, trace)) {
            // OSD topology creation failed on a degenerate input —
            // leave the preview inert rather than rendering stale
            // geometry. Callers fall through to rendering the cage.
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            return;
        }

        active = true;
        cageVertPreview = new uint[](source.vertices.length);
        cageVertPreview[] = uint.max;
        foreach (pi, origin; trace.vertOrigin) {
            if (origin == uint.max) continue;
            if (origin >= cageVertPreview.length) continue;
            // First preview vert that maps back wins; for the
            // smoothed-original verts there's only one such vert per
            // cage vert anyway.
            if (cageVertPreview[origin] == uint.max)
                cageVertPreview[origin] = cast(uint)pi;
        }
    }
}

// ---------------------------------------------------------------------------
// GpuMesh
// ---------------------------------------------------------------------------

struct GpuMesh {
    GLuint faceVao, faceVbo;
    GLuint edgeVao, edgeVbo;
    GLuint vertVao, vertVbo;   // vertex points
    int    faceVertCount;
    int    edgeVertCount;
    int    vertCount;
    int[]  faceTriStart;   // first vertex index in faceVbo for each face
    int[]  faceTriCount;   // vertex count for each face
    // When true the main loop owns GPU uploads (because a subpatch preview
    // is currently displayed). Tool-side cage uploads become no-ops that
    // only bump the mesh's mutation version so the preview is rebuilt.
    bool   suppressCageUpload;
    // Maps each VBO line-segment to a source (cage) edge index when a
    // subpatch preview was uploaded. Empty for cage uploads, in which case
    // drawEdges assumes VBO segment i == cage edge i.
    uint[] edgeOriginGpu;
    // Maps each VBO face (position in faceTriStart/Count) to its cage face
    // index. Populated for subpatch uploads; empty in cage mode.
    uint[] faceOriginGpu;
    // Maps each vertex VBO entry to a source (cage) vertex index. In cage
    // mode VBO index == cage vertex index. In subpatch mode entries with
    // `vertOrigin[vi] == uint.max` were skipped during upload, so this
    // map translates back. Used by gpu_select.d for vertex picking.
    uint[] vertOriginGpu;
    // Per-triangle-vertex source face index, parallel to faceVbo (one
    // uint per face-VBO vertex). All three corners of a face's triangle
    // fan get the same face index. Drives gpu_select.d's face-ID pass.
    GLuint faceIdVbo;

    // Bumps on every VBO write (full upload, refreshPositions, partial
    // uploadSelectedVertices). Distinct from Mesh.mutationVersion: the
    // transform tools (Move / Rotate / Scale) mutate `mesh.vertices`
    // directly during drag WITHOUT bumping mutationVersion, on purpose
    // (symmetry pair-table / falloff caches must stay stable mid-drag,
    // see TransformTool.captureSymmetryForDrag). That leaves the picker
    // FBO cache stale w.r.t. the actual GPU buffers — gpu_select.d
    // keys on `uploadVersion` instead so it re-renders whenever the
    // VBO contents change, regardless of whether the structural mesh
    // version moved.
    ulong  uploadVersion;

    void init() {
        glGenVertexArrays(1, &faceVao); glGenBuffers(1, &faceVbo);
        glGenVertexArrays(1, &edgeVao); glGenBuffers(1, &edgeVbo);
        glGenVertexArrays(1, &vertVao); glGenBuffers(1, &vertVbo);
        glGenBuffers(1, &faceIdVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &faceVao); glDeleteBuffers(1, &faceVbo);
        glDeleteVertexArrays(1, &edgeVao); glDeleteBuffers(1, &edgeVbo);
        glDeleteVertexArrays(1, &vertVao); glDeleteBuffers(1, &vertVbo);
        glDeleteBuffers(1, &faceIdVbo);
    }

    // When `edgeOrigin`/`vertOrigin` are provided (same length as the mesh's
    // edges/vertices) entries equal to `uint.max` are skipped. This is how
    // the subpatch preview hides derived edges/points while still uploading
    // the full subdivided face surface. `faceOrigin` does not filter (every
    // preview face is rendered) but when supplied is cached in
    // `faceOriginGpu` so selection/hover can translate cage indices.
    void upload(ref const Mesh mesh,
                const uint[] edgeOrigin = null,
                const uint[] vertOrigin = null,
                const uint[] faceOrigin = null) {
        // Redirect tool-side cage refreshes: the GPU buffers currently hold
        // the preview, and main loop owns re-uploads. Bumping the mutation
        // version ensures the preview is rebuilt on the next frame against
        // the latest cage positions.
        if (suppressCageUpload && edgeOrigin.length == 0 && vertOrigin.length == 0) {
            ++(cast(Mesh*)&mesh).mutationVersion;
            return;
        }
        ++uploadVersion;
        // Faces — interleaved [pos(3) + normal(3)] per vertex, flat shading.
        enum FACE_STRIDE = 6;
        float[] faceData;
        // Parallel uint-per-vertex face-index array — see GpuMesh.faceIdVbo.
        uint[]  faceIdData;
        faceTriStart.length = 0;
        faceTriCount.length = 0;
        faceOriginGpu.length = 0;
        if (faceOrigin.length > 0)
            faceOriginGpu = faceOrigin.dup;
        foreach (fi, face; mesh.faces) {
            int start = cast(int)(faceData.length / FACE_STRIDE);
            if (face.length >= 3) {
                // Flat normal from the first triangle of the face.
                Vec3 v0 = mesh.vertices[face[0]];
                Vec3 v1 = mesh.vertices[face[1]];
                Vec3 v2 = mesh.vertices[face[2]];
                Vec3 e1 = v1 - v0, e2 = v2 - v0;
                Vec3 cr = cross(e1, e2);
                float nlen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
                Vec3  n   = nlen > 1e-6f
                            ? cr / nlen
                            : Vec3(0, 1, 0);
                for (uint i = 1; i + 1 < face.length; i++) {
                    foreach (idx; [face[0], face[i], face[i+1]]) {
                        Vec3 v = mesh.vertices[idx];
                        faceData ~= [v.x, v.y, v.z, n.x, n.y, n.z];
                        faceIdData ~= cast(uint)fi;
                    }
                }
            }
            int count = cast(int)(faceData.length / FACE_STRIDE) - start;
            faceTriStart ~= start;
            faceTriCount  ~= count;
        }
        faceVertCount = cast(int)(faceData.length / FACE_STRIDE);
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
        glBufferData(GL_ARRAY_BUFFER, faceData.length * float.sizeof, faceData.ptr, GL_DYNAMIC_DRAW);
        // attr 0: position
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, FACE_STRIDE * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        // attr 1: normal
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, FACE_STRIDE * float.sizeof,
                              cast(void*)(3 * float.sizeof));
        glEnableVertexAttribArray(1);

        // Parallel face-ID VBO, not bound to faceVao — gpu_select.d builds
        // its own VAO combining faceVbo (position at attr 0) with this
        // buffer (face index at attr 1). Always upload at least one
        // sentinel uint so the buffer is non-zero-sized even for empty
        // meshes; glDrawArrays with vertex count 0 won't touch it but
        // glBufferData(0, null) is poorly defined on some drivers.
        glBindBuffer(GL_ARRAY_BUFFER, faceIdVbo);
        if (faceIdData.length > 0) {
            glBufferData(GL_ARRAY_BUFFER, faceIdData.length * uint.sizeof,
                         faceIdData.ptr, GL_DYNAMIC_DRAW);
        } else {
            uint zero = 0;
            glBufferData(GL_ARRAY_BUFFER, uint.sizeof, &zero, GL_DYNAMIC_DRAW);
        }

        // Edges — skip derived edges (edgeOrigin[ei] == uint.max). When a
        // filter is provided, remember each surviving segment's cage origin
        // so drawEdges can translate selection/hover into segment space.
        float[] edgeData;
        edgeOriginGpu.length = 0;
        foreach (ei, edge; mesh.edges) {
            if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max) continue;
            if (edgeOrigin.length > 0)
                edgeOriginGpu ~= edgeOrigin[ei];
            Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];
            edgeData ~= [a.x, a.y, a.z, b.x, b.y, b.z];
        }
        edgeVertCount = cast(int)(edgeData.length / 3);
        glBindVertexArray(edgeVao);
        glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
        glBufferData(GL_ARRAY_BUFFER, edgeData.length * float.sizeof, edgeData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // Vertex points — skip derived vertices (vertOrigin[vi] == uint.max).
        // `vertOriginGpu` records, for each surviving VBO entry, the cage
        // vertex index it came from. In cage mode (no filter) the map is
        // identity; subpatch uploads populate it from `vertOrigin` so
        // gpu_select.d can translate VBO indices back to cage indices.
        float[] vertData;
        int     kept = 0;
        vertOriginGpu.length = 0;
        foreach (vi, v; mesh.vertices) {
            if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max) continue;
            vertData ~= [v.x, v.y, v.z];
            vertOriginGpu ~= (vertOrigin.length > 0)
                ? vertOrigin[vi]
                : cast(uint)vi;
            ++kept;
        }
        vertCount = kept;
        glBindVertexArray(vertVao);
        glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
        glBufferData(GL_ARRAY_BUFFER, vertData.length * float.sizeof, vertData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    /// Refresh vertex POSITIONS only — assumes the face / edge / vert
    /// VBO layouts (vertex count, face triangulation, faceTriStart
    /// offsets, faceIdVbo, edgeOriginGpu, …) all match what the last
    /// full `upload()` produced. Walks the mesh and writes new
    /// pos + (face) normal into the existing buffers via glMapBuffer
    /// — zero array `~=`, zero CPU-side reallocation, zero topology
    /// metadata churn.
    ///
    /// Used by the subpatch preview path: when topologyVersion is
    /// unchanged (mesh moved but didn't change topology), the
    /// SubpatchPreview re-evaluates OpenSubdiv's stencil table into
    /// preview.vertices, and these GPU buffers can be refreshed the
    /// same way instead of rebuilding faceData / edgeData / vertData
    /// arrays from scratch. On the user's 6 K-vert cage sphere drag
    /// (~393 K preview verts) this drops the `upload` hot path from
    /// ~16 % of CPU + ~12 % memmove + ~10 % GC expandArrayUsed to a
    /// single mapped-buffer write per VBO.
    void refreshPositions(ref const Mesh mesh,
                          const uint[] edgeOrigin = null,
                          const uint[] vertOrigin = null) {
        if (faceTriStart.length != mesh.faces.length)
            return;   // layout mismatch — caller should fall back to upload().
        ++uploadVersion;

        enum FACE_STRIDE = 6;

        // Face VBO: re-fan each face's triangles from its first three
        // verts. Normal recomputed per face (one cross + one sqrt).
        // faceTriStart already maps fi → first vertex in the VBO.
        //
        // Map with INVALIDATE_BUFFER_BIT — explicit driver-side orphan,
        // we'll fill the entire buffer below. The two skipped-face
        // patterns (face.length < 3) still write zero into those slots
        // implicitly: we don't touch them, but the orphaned allocation
        // starts as uninitialised garbage. That's tolerable because the
        // skipped faces have faceTriCount[fi] == 0, so drawFaces never
        // dereferences those bytes — they're not referenced by any draw
        // call.
        if (faceVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
            float* fp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (fp) {
                foreach (fi, face; mesh.faces) {
                    if (face.length < 3) continue;
                    immutable uint i0 = face[0];
                    Vec3 v0 = mesh.vertices[i0];
                    Vec3 v1 = mesh.vertices[face[1]];
                    Vec3 v2 = mesh.vertices[face[2]];
                    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                    float cx = ay*bz - az*by;
                    float cy = az*bx - ax*bz;
                    float cz = ax*by - ay*bx;
                    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                    float nx, ny, nz;
                    if (nlen > 1e-6f) { float inv = 1.0f/nlen; nx=cx*inv; ny=cy*inv; nz=cz*inv; }
                    else              { nx=0; ny=1; nz=0; }
                    int k = faceTriStart[fi] * FACE_STRIDE;
                    // Fan-triangulate around face[0]; write [pos, normal]
                    // per vertex with hand-rolled inner loop — avoids the
                    // `foreach (idx; [..])` literal-array GC alloc and the
                    // Vec3 operator-overload temporaries that dominated
                    // an earlier profile.
                    for (size_t i = 1; i + 1 < face.length; i++) {
                        immutable uint ia = i0;
                        immutable uint ib = face[i];
                        immutable uint ic = face[i+1];
                        Vec3 va = mesh.vertices[ia];
                        Vec3 vb = mesh.vertices[ib];
                        Vec3 vc = mesh.vertices[ic];
                        fp[k++] = va.x; fp[k++] = va.y; fp[k++] = va.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vb.x; fp[k++] = vb.y; fp[k++] = vb.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vc.x; fp[k++] = vc.y; fp[k++] = vc.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                    }
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Edge VBO: subpatch mode filters out edges whose
        // edgeOrigin[ei] == uint.max (derived edges that aren't shown).
        // VBO segment order matches the kept-edge walk in `upload`.
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int seg = 0;
                foreach (ei, edge; mesh.edges) {
                    if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max)
                        continue;
                    Vec3 a = mesh.vertices[edge[0]];
                    Vec3 b = mesh.vertices[edge[1]];
                    int k = seg * 6;
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Vertex VBO: subpatch mode filters out verts whose
        // vertOrigin[vi] == uint.max (edge mids / face centroids).
        // VBO order matches the kept-vert walk in `upload`.
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                int seg = 0;
                foreach (vi, v; mesh.vertices) {
                    if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max)
                        continue;
                    int k = seg * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        glBindVertexArray(0);
    }

    /// Edge + vertex VBO position refresh — the subset of
    /// `refreshPositions` that skips the face VBO. Used by Phase 3b's
    /// OSD GPU fan-out path, which writes the face VBO itself; the
    /// edge / vert VBOs still come from CPU `mesh.vertices` because
    /// OSD's stencil output is per-limit-vert only and vibe3d's
    /// edge / vert VBOs need their own layout.
    void refreshNonFacePositions(ref const Mesh mesh,
                                  const uint[] edgeOrigin = null,
                                  const uint[] vertOrigin = null) {
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int seg = 0;
                foreach (ei, edge; mesh.edges) {
                    if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max)
                        continue;
                    Vec3 a = mesh.vertices[edge[0]];
                    Vec3 b = mesh.vertices[edge[1]];
                    int k = seg * 6;
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                int seg = 0;
                foreach (vi, v; mesh.vertices) {
                    if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max)
                        continue;
                    int k = seg * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    // Drag-fast path: re-upload every VBO in full, but skip the GC churn
    // that the array-growth `~=` loops in `upload()` impose. Despite the
    // name + `toUpdate` mask, this no longer takes a partial-write
    // shortcut — `glMapBufferRange + GL_MAP_WRITE_BIT` alone (no invalidate)
    // sounds spec-safe but Mesa orphans the backing store anyway, leaving
    // un-touched faces as garbage. The map-with-invalidate path orphans
    // EXPLICITLY (the driver hands us a fresh allocation) and we fill it
    // from scratch — so every byte in the buffer ends up well-defined.
    //
    // `toUpdate` is retained in the signature for caller compatibility but
    // ignored here; the drag tools always pass the same mesh ref through
    // and we touch the full topology either way.
    void uploadSelectedVertices(ref const Mesh mesh, const bool[] toUpdate) {
        // Preview is currently displayed; cage-indexed scatter writes would
        // corrupt the VBO. Signal a mutation and let the main loop rebuild
        // the preview instead.
        if (suppressCageUpload) {
            ++(cast(Mesh*)&mesh).mutationVersion;
            return;
        }
        ++uploadVersion;
        enum FACE_STRIDE = 6;

        // Face VBO — flat-shaded fan triangulation, one normal per face.
        if (faceVertCount > 0 && faceTriStart.length == mesh.faces.length) {
            glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
            float* fp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (fp) {
                foreach (fi, face; mesh.faces) {
                    if (face.length < 3) continue;
                    immutable uint i0 = face[0];
                    Vec3 v0 = mesh.vertices[i0];
                    Vec3 v1 = mesh.vertices[face[1]];
                    Vec3 v2 = mesh.vertices[face[2]];
                    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                    float cx = ay*bz - az*by;
                    float cy = az*bx - ax*bz;
                    float cz = ax*by - ay*bx;
                    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                    float nx, ny, nz;
                    if (nlen > 1e-6f) { float inv = 1.0f/nlen; nx=cx*inv; ny=cy*inv; nz=cz*inv; }
                    else              { nx=0; ny=1; nz=0; }
                    int k = faceTriStart[fi] * FACE_STRIDE;
                    for (size_t i = 1; i + 1 < face.length; i++) {
                        Vec3 va = mesh.vertices[i0];
                        Vec3 vb = mesh.vertices[face[i]];
                        Vec3 vc = mesh.vertices[face[i+1]];
                        fp[k++] = va.x; fp[k++] = va.y; fp[k++] = va.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vb.x; fp[k++] = vb.y; fp[k++] = vb.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vc.x; fp[k++] = vc.y; fp[k++] = vc.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                    }
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Edge VBO — VBO segment index == cage edge index in cage mode
        // (subpatch upload would have populated edgeOriginGpu and gone
        // through the suppressCageUpload early-return above, so we're
        // guaranteed unfiltered here).
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int k = 0;
                foreach (ei, edge; mesh.edges) {
                    Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Vertex VBO — same invariant: cage upload places vi at vbo slot vi.
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                foreach (vi, v; mesh.vertices) {
                    int k = cast(int)vi * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        glBindVertexArray(0);
    }

    // Draw faces only (writes depth buffer)
    void drawFaces(const ref LitShader shader) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glUniform3f(shader.locColor, 0.8f, 0.8f, 0.8f);
        glBindVertexArray(faceVao);
        glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw faces with per-face hover highlights (Polygons mode). When the
    // subpatch preview is uploaded, `faceOriginGpu` maps each VBO face to
    // its cage face so every preview child of a hovered cage face is tinted.
    void drawFacesHighlighted(const ref LitShader shader,
                               int hoveredFace, const bool[] selectedFaces) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);
        scope(exit) { glDisable(GL_POLYGON_OFFSET_FILL); glBindVertexArray(0); }

        int vboFaceCount = cast(int)faceTriStart.length;

        if (hoveredFace < 0) {
            glUniform3f(shader.locColor, 0.8f, 0.8f, 0.8f);
            glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
            return;
        }

        bool preview = faceOriginGpu.length > 0;
        int cageOf(int fi) {
            return preview ? cast(int)faceOriginGpu[fi] : fi;
        }

        // Cage-mode single-face fast path.
        if (!preview) {
            if (hoveredFace >= vboFaceCount) {
                glUniform3f(shader.locColor, 0.8f, 0.8f, 0.8f);
                glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
                return;
            }
            int hs = faceTriStart[hoveredFace];
            int hc = faceTriCount[hoveredFace];
            glUniform3f(shader.locColor, 0.8f, 0.8f, 0.8f);
            if (hs > 0) glDrawArrays(GL_TRIANGLES, 0, hs);
            if (hs + hc < faceVertCount)
                glDrawArrays(GL_TRIANGLES, hs + hc, faceVertCount - hs - hc);
            if (hc > 0) {
                glUniform3f(shader.locColor, 0.5f, 0.71f, 0.79f);
                glDrawArrays(GL_TRIANGLES, hs, hc);
            }
            return;
        }

        // Preview: batch contiguous VBO-face runs of the same hover state.
        void batchRun(bool hoverState) {
            int batchStart = -1;
            for (int i = 0; i < vboFaceCount; i++) {
                bool isHover = cageOf(i) == hoveredFace;
                if (isHover == hoverState) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    int s = faceTriStart[batchStart];
                    int e = faceTriStart[i];
                    if (e > s) glDrawArrays(GL_TRIANGLES, s, e - s);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0) {
                int s = faceTriStart[batchStart];
                if (faceVertCount > s) glDrawArrays(GL_TRIANGLES, s, faceVertCount - s);
            }
        }
        glUniform3f(shader.locColor, 0.8f, 0.8f, 0.8f);
        batchRun(false);
        glUniform3f(shader.locColor, 0.5f, 0.71f, 0.79f);
        batchRun(true);
    }

    // Draw only the selected faces geometry (no color set — caller sets up shader).
    // Optimized: batch selected faces to minimize draw calls. In subpatch
    // mode each VBO face is mapped through `faceOriginGpu` so all children
    // of a selected cage face are included.
    void drawSelectedFacesOverlay(const bool[] selectedFaces) {
        glBindVertexArray(faceVao);

        bool preview = faceOriginGpu.length > 0;
        bool isSelected(int i) {
            int cage = preview ? cast(int)faceOriginGpu[i] : i;
            return cage >= 0 && cage < cast(int)selectedFaces.length && selectedFaces[cage];
        }

        int batchStart = -1;
        int vboFaceCount = cast(int)faceTriStart.length;
        for (int i = 0; i < vboFaceCount; i++) {
            if (!isSelected(i)) {
                if (batchStart >= 0) {
                    int startIdx = faceTriStart[batchStart];
                    int endIdx   = faceTriStart[i];
                    glDrawArrays(GL_TRIANGLES, startIdx, endIdx - startIdx);
                    batchStart = -1;
                }
            } else if (batchStart < 0) {
                batchStart = i;
            }
        }

        // Draw final batch if exists
        if (batchStart >= 0) {
            int startIdx = faceTriStart[batchStart];
            glDrawArrays(GL_TRIANGLES, startIdx, faceVertCount - startIdx);
        }

        glBindVertexArray(0);
    }

    // Draw edges with optional hover/selection highlights.
    // `selectedEdges` and `hoveredEdge` are indexed by CAGE edges. When a
    // subpatch preview is uploaded, `edgeOriginGpu` maps each VBO segment
    // back to its cage edge so highlights propagate across every segment of
    // the corresponding original edge.
    void drawEdges(GLint locColor, int hoveredEdge, const bool[] selectedEdges) {
        int edgeCount = edgeVertCount / 2;
        glBindVertexArray(edgeVao);

        bool preview = edgeOriginGpu.length > 0;
        int  cageOf(int segIdx) {
            return preview ? cast(int)edgeOriginGpu[segIdx] : segIdx;
        }
        bool segSelected(int segIdx) {
            int c = cageOf(segIdx);
            return c >= 0 && c < cast(int)selectedEdges.length && selectedEdges[c];
        }
        bool segHovered(int segIdx) {
            return hoveredEdge >= 0 && cageOf(segIdx) == hoveredEdge;
        }

        // "All selected" shortcut is only safe when VBO segments are 1:1 with
        // cage edges (cage mode). Skip it in preview mode.
        bool allEdgesSelected = !preview
            && selectedEdges.length >= edgeCount
            && hoveredEdge < 0;
        if (allEdgesSelected)
            foreach (s; selectedEdges[0 .. edgeCount]) if (!s) { allEdgesSelected = false; break; }

        // Gray pass — depth-tested, skip hovered/selected segments.
        glUniform3f(locColor, 0.9f, 0.9f, 0.9f);
        if (hoveredEdge < 0 && selectedEdges.length == 0) {
            glDrawArrays(GL_LINES, 0, edgeVertCount);
        } else if (!allEdgesSelected) {
            int batchStart = -1;
            for (int i = 0; i < edgeCount; i++) {
                bool skip = segHovered(i) || segSelected(i);
                if (!skip) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    glDrawArrays(GL_LINES, batchStart * 2, (i - batchStart) * 2);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0)
                glDrawArrays(GL_LINES, batchStart * 2, (edgeCount - batchStart) * 2);
        }

        // Highlight pass — draw without depth so selection shows through.
        glDisable(GL_DEPTH_TEST);

        if (allEdgesSelected && hoveredEdge < 0) {
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            glDrawArrays(GL_LINES, 0, edgeVertCount);
        } else if (selectedEdges.length > 0) {
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            int batchStart = -1;
            for (int i = 0; i < edgeCount; i++) {
                if (segSelected(i) && !segHovered(i)) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    glDrawArrays(GL_LINES, batchStart * 2, (i - batchStart) * 2);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0)
                glDrawArrays(GL_LINES, batchStart * 2, (edgeCount - batchStart) * 2);
        }

        if (hoveredEdge >= 0) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            if (preview) {
                // A hovered cage edge fans out to every VBO segment tracing
                // back to it.
                for (int i = 0; i < edgeCount; i++)
                    if (segHovered(i))
                        glDrawArrays(GL_LINES, i * 2, 2);
            } else if (hoveredEdge < edgeCount) {
                glDrawArrays(GL_LINES, hoveredEdge * 2, 2);
            }
        }

        glEnable(GL_DEPTH_TEST);
        glBindVertexArray(0);
    }

    // Draw vertex dots (call AFTER picking so hovered/selected state is current)
    /// `hovered` and `selected` are CAGE-indexed. In cage mode the VBO
    /// is also cage-indexed (vertOriginGpu is the identity), so a slot
    /// lookup is direct. In subpatch mode the VBO holds only "vert-
    /// point" preview verts (cage origin recorded in vertOriginGpu)
    /// and most cage-vert indices have no VBO slot — translate
    /// through vertOriginGpu the same way drawEdges does. Without
    /// this, hovering on the subdivided surface highlighted the wrong
    /// preview vert because the cage index from picking was being
    /// used as a raw glDrawArrays offset.
    void drawVertices(GLint locColor, int hovered, const bool[] selected) {
        glBindVertexArray(vertVao);

        // All vertices — small gray dots, with depth test
        glPointSize(5.0f);
        glUniform3f(locColor, 0.6f, 0.6f, 0.6f);
        glDrawArrays(GL_POINTS, 0, vertCount);

        // Selected and hovered — drawn without depth test so they show through faces.
        glDisable(GL_DEPTH_TEST);

        int cageOf(int vboIdx) {
            if (vboIdx >= cast(int)vertOriginGpu.length) return -1;
            uint c = vertOriginGpu[vboIdx];
            return (c == uint.max) ? -1 : cast(int)c;
        }

        glPointSize(10.0f);
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        for (int i = 0; i < vertCount; i++) {
            int c = cageOf(i);
            if (c < 0) continue;
            if (c < cast(int)selected.length && selected[c])
                glDrawArrays(GL_POINTS, i, 1);
        }

        if (hovered >= 0) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            for (int i = 0; i < vertCount; i++) {
                if (cageOf(i) == hovered)
                    glDrawArrays(GL_POINTS, i, 1);
            }
        }

        glEnable(GL_DEPTH_TEST);
        glPointSize(1.0f);
        glBindVertexArray(0);
    }
}
