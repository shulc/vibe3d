module mesh;

import bindbc.opengl;
import std.math : sqrt;
import math;
import shader;
// ---------------------------------------------------------------------------
// Mesh
// ---------------------------------------------------------------------------

private bool hasAnySelected(const bool[] sel) {
    foreach (s; sel) if (s) return true;
    return false;
}

struct Mesh {
    Vec3[]    vertices;
    uint[2][] edges;
    uint[][]  faces;
    bool[]    selectedVertices;
    bool[]    selectedEdges;
    bool[]    selectedFaces;

    // Resize selection arrays to match geometry and clear them.
    // Call after catmullClark / importLWO / reset.
    void resetSelection() {
        selectedVertices.length = vertices.length; selectedVertices[] = false;
        selectedEdges.length    = edges.length;    selectedEdges[]    = false;
        selectedFaces.length    = faces.length;    selectedFaces[]    = false;
    }

    // Grow selection arrays to match geometry without clearing.
    // Call after BoxTool or any in-place geometry growth.
    void syncSelection() {
        if (selectedVertices.length < vertices.length) selectedVertices.length = vertices.length;
        if (selectedEdges.length    < edges.length)    selectedEdges.length    = edges.length;
        if (selectedFaces.length    < faces.length)    selectedFaces.length    = faces.length;
    }

    uint addVertex(Vec3 v) {
        vertices ~= v;
        return cast(uint)(vertices.length - 1);
    }
    void addEdge(uint a, uint b) {
        foreach (e; edges)
            if ((e[0]==a && e[1]==b) || (e[0]==b && e[1]==a)) return;
        edges ~= [a, b];
    }
    void addFace(uint[] idx) {
        faces ~= idx.dup;
        for (uint i = 0; i < idx.length; i++)
            addEdge(idx[i], idx[(i+1) % idx.length]);
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
    }
    bool hasAnySelectedVertices() const { return hasAnySelected(selectedVertices); }
    bool hasAnySelectedEdges() const { return hasAnySelected(selectedEdges); }
    bool hasAnySelectedFaces() const { return hasAnySelected(selectedFaces); }
    void clear() { vertices = []; edges = []; faces = []; }
}

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
    return m;
}

// ---------------------------------------------------------------------------
// Catmull-Clark subdivision
// ---------------------------------------------------------------------------

// Returns a new mesh that is one Catmull-Clark subdivision of `m`.
// Each n-gon face is replaced by n quads.
Mesh catmullClark(ref const Mesh m) {
    uint nV = cast(uint)m.vertices.length;
    uint nF = cast(uint)m.faces.length;
    uint nE = cast(uint)m.edges.length;

    // Map edge key → index into m.edges
    uint[ulong] edgeLookup;
    foreach (i, e; m.edges)
        edgeLookup[edgeKey(e[0], e[1])] = cast(uint)i;

    // Adjacency lists
    uint[][] edgeFaces = new uint[][](nE);   // faces sharing this edge (1 or 2)
    uint[][] vertFaces = new uint[][](nV);   // faces that contain this vertex
    uint[][] vertEdges = new uint[][](nV);   // edges that contain this vertex

    foreach (fi, face; m.faces) {
        uint len = cast(uint)face.length;
        foreach (vi; face)
            vertFaces[vi] ~= cast(uint)fi;
        foreach (i; 0 .. len) {
            uint a = face[i], b = face[(i + 1) % len];
            uint ei = edgeLookup[edgeKey(a, b)];
            edgeFaces[ei] ~= cast(uint)fi;
        }
    }
    foreach (ei, e; m.edges) {
        vertEdges[e[0]] ~= cast(uint)ei;
        vertEdges[e[1]] ~= cast(uint)ei;
    }

    // Step 1 — face points: centroid of each face
    Vec3[] facePoints = new Vec3[](nF);
    foreach (fi, face; m.faces) {
        Vec3 s = Vec3(0, 0, 0);
        foreach (vi; face) s = vec3Add(s, m.vertices[vi]);
        float inv = 1.0f / cast(float)face.length;
        facePoints[fi] = Vec3(s.x * inv, s.y * inv, s.z * inv);
    }

    // Step 2 — edge points
    Vec3[] edgePoints = new Vec3[](nE);
    foreach (ei, e; m.edges) {
        Vec3 a = m.vertices[e[0]], b = m.vertices[e[1]];
        if (edgeFaces[ei].length == 2) {
            // Interior: average of 2 endpoints + 2 face points
            Vec3 f0 = facePoints[edgeFaces[ei][0]];
            Vec3 f1 = facePoints[edgeFaces[ei][1]];
            edgePoints[ei] = Vec3((a.x + b.x + f0.x + f1.x) * 0.25f,
                                  (a.y + b.y + f0.y + f1.y) * 0.25f,
                                  (a.z + b.z + f0.z + f1.z) * 0.25f);
        } else {
            // Boundary: midpoint
            edgePoints[ei] = Vec3((a.x + b.x) * 0.5f,
                                  (a.y + b.y) * 0.5f,
                                  (a.z + b.z) * 0.5f);
        }
    }

    // Step 3 — updated original vertex positions
    Vec3[] newVerts = new Vec3[](nV);
    foreach (vi; 0 .. nV) {
        Vec3 v  = m.vertices[vi];
        uint n  = cast(uint)vertFaces[vi].length;
        if (n == 0) { newVerts[vi] = v; continue; }

        // Check for boundary (vertex has at least one boundary edge)
        bool boundary = false;
        foreach (ei; vertEdges[vi])
            if (edgeFaces[ei].length < 2) { boundary = true; break; }

        if (boundary) {
            // Boundary rule: average of v and midpoints of its boundary edges
            Vec3 sum = v;
            int  cnt = 1;
            foreach (ei; vertEdges[vi]) {
                if (edgeFaces[ei].length >= 2) continue;
                Vec3 ea = m.vertices[m.edges[ei][0]];
                Vec3 eb = m.vertices[m.edges[ei][1]];
                sum = vec3Add(sum, Vec3((ea.x + eb.x) * 0.5f,
                                       (ea.y + eb.y) * 0.5f,
                                       (ea.z + eb.z) * 0.5f));
                cnt++;
            }
            float inv = 1.0f / cast(float)cnt;
            newVerts[vi] = Vec3(sum.x * inv, sum.y * inv, sum.z * inv);
        } else {
            // Interior rule: (F + 2R + (n-3)*v) / n
            Vec3 F = Vec3(0, 0, 0);
            foreach (fi; vertFaces[vi]) F = vec3Add(F, facePoints[fi]);
            float fn = cast(float)n;
            F = Vec3(F.x / fn, F.y / fn, F.z / fn);

            uint  ne = cast(uint)vertEdges[vi].length;
            Vec3  R  = Vec3(0, 0, 0);
            foreach (ei; vertEdges[vi]) {
                Vec3 ea = m.vertices[m.edges[ei][0]];
                Vec3 eb = m.vertices[m.edges[ei][1]];
                R = vec3Add(R, Vec3((ea.x + eb.x) * 0.5f,
                                   (ea.y + eb.y) * 0.5f,
                                   (ea.z + eb.z) * 0.5f));
            }
            R = Vec3(R.x / ne, R.y / ne, R.z / ne);

            newVerts[vi] = Vec3((F.x + 2.0f * R.x + (fn - 3.0f) * v.x) / fn,
                                (F.y + 2.0f * R.y + (fn - 3.0f) * v.y) / fn,
                                (F.z + 2.0f * R.z + (fn - 3.0f) * v.z) / fn);
        }
    }

    // Assemble output mesh.
    // Vertex layout in result:
    //   [0 .. nV)          — updated original vertices
    //   [nV .. nV+nE)      — edge points
    //   [nV+nE .. nV+nE+nF) — face points
    Mesh result;
    result.vertices.length = nV + nE + nF;
    foreach (vi; 0 .. nV)  result.vertices[vi]           = newVerts[vi];
    foreach (ei; 0 .. nE)  result.vertices[nV + ei]      = edgePoints[ei];
    foreach (fi; 0 .. nF)  result.vertices[nV + nE + fi] = facePoints[fi];

    // Create edge lookup for result to avoid duplicate edges
    uint[ulong] resultEdgeLookup;

    // Each original n-gon → n quads.
    // For corner i of face fi with verts [..., v_{i-1}, v_i, v_{i+1}, ...]:
    //   quad = [ v_i, edge_point(v_i→v_{i+1}), face_point, edge_point(v_{i-1}→v_i) ]
    foreach (fi, face; m.faces) {
        uint fpIdx = nV + nE + cast(uint)fi;
        uint len   = cast(uint)face.length;
        foreach (i; 0 .. len) {
            uint vi0  = face[i];
            uint vi1  = face[(i + 1) % len];
            uint vim1 = face[(i + len - 1) % len];
            uint eiFwd  = edgeLookup[edgeKey(vi0, vi1)];
            uint eiBack = edgeLookup[edgeKey(vim1, vi0)];
            result.addFaceFast(resultEdgeLookup, [vi0, nV + eiFwd, fpIdx, nV + eiBack]);
        }
    }

    return result;
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

    void init() {
        glGenVertexArrays(1, &faceVao); glGenBuffers(1, &faceVbo);
        glGenVertexArrays(1, &edgeVao); glGenBuffers(1, &edgeVbo);
        glGenVertexArrays(1, &vertVao); glGenBuffers(1, &vertVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &faceVao); glDeleteBuffers(1, &faceVbo);
        glDeleteVertexArrays(1, &edgeVao); glDeleteBuffers(1, &edgeVbo);
        glDeleteVertexArrays(1, &vertVao); glDeleteBuffers(1, &vertVbo);
    }

    void upload(ref const Mesh mesh) {
        // Faces — interleaved [pos(3) + normal(3)] per vertex, flat shading.
        enum FACE_STRIDE = 6;
        float[] faceData;
        faceTriStart.length = 0;
        faceTriCount.length = 0;
        foreach (face; mesh.faces) {
            int start = cast(int)(faceData.length / FACE_STRIDE);
            if (face.length >= 3) {
                // Flat normal from the first triangle of the face.
                Vec3 v0 = mesh.vertices[face[0]];
                Vec3 v1 = mesh.vertices[face[1]];
                Vec3 v2 = mesh.vertices[face[2]];
                Vec3 e1 = vec3Sub(v1, v0), e2 = vec3Sub(v2, v0);
                Vec3 cr = cross(e1, e2);
                float nlen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
                Vec3  n   = nlen > 1e-6f
                            ? Vec3(cr.x/nlen, cr.y/nlen, cr.z/nlen)
                            : Vec3(0, 1, 0);
                for (uint i = 1; i + 1 < face.length; i++) {
                    foreach (idx; [face[0], face[i], face[i+1]]) {
                        Vec3 v = mesh.vertices[idx];
                        faceData ~= [v.x, v.y, v.z, n.x, n.y, n.z];
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

        // Edges
        float[] edgeData;
        foreach (edge; mesh.edges) {
            Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];
            edgeData ~= [a.x, a.y, a.z, b.x, b.y, b.z];
        }
        edgeVertCount = cast(int)(edgeData.length / 3);
        glBindVertexArray(edgeVao);
        glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
        glBufferData(GL_ARRAY_BUFFER, edgeData.length * float.sizeof, edgeData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // Vertex points
        float[] vertData;
        foreach (v; mesh.vertices)
            vertData ~= [v.x, v.y, v.z];
        vertCount = cast(int)mesh.vertices.length;
        glBindVertexArray(vertVao);
        glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
        glBufferData(GL_ARRAY_BUFFER, vertData.length * float.sizeof, vertData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    // Optimized: update only selected vertices on GPU (much faster for large meshes)
    void uploadSelectedVertices(ref const Mesh mesh, const bool[] toUpdate) {
        enum FACE_STRIDE = 6;

        // O(faces × verts_per_face): for each face check if any vertex moved.
        // Previous code was O(moved_verts × faces × verts_per_face) — n² on large meshes.
        bool[] faceNeedsUpdate = new bool[](mesh.faces.length);
        bool anyFaceUpdate = false;
        for (int fi = 0; fi < cast(int)mesh.faces.length; fi++) {
            foreach (vi; mesh.faces[fi]) {
                if (vi < toUpdate.length && toUpdate[vi]) {
                    faceNeedsUpdate[fi] = true;
                    anyFaceUpdate = true;
                    break;
                }
            }
        }

        // Use glMapBuffer for all three VBOs: 3 driver round-trips total instead of
        // one per updated face/edge/vertex (which could be thousands of calls).

        if (anyFaceUpdate) {
            glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
            float* fp = cast(float*)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);
            if (fp) {
                for (int fi = 0; fi < cast(int)mesh.faces.length; fi++) {
                    if (!faceNeedsUpdate[fi]) continue;
                    const(uint[]) face = mesh.faces[fi];
                    if (face.length < 3) continue;

                    Vec3 v0 = mesh.vertices[face[0]];
                    Vec3 v1 = mesh.vertices[face[1]];
                    Vec3 v2 = mesh.vertices[face[2]];
                    Vec3 cr = cross(vec3Sub(v1, v0), vec3Sub(v2, v0));
                    float nlen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
                    Vec3 n = nlen > 1e-6f
                        ? Vec3(cr.x/nlen, cr.y/nlen, cr.z/nlen)
                        : Vec3(0, 1, 0);

                    int k = faceTriStart[fi] * FACE_STRIDE;
                    for (size_t i = 1; i + 1 < face.length; i++) {
                        foreach (idx; [face[0], face[i], face[i + 1]]) {
                            Vec3 v = mesh.vertices[idx];
                            fp[k++] = v.x; fp[k++] = v.y; fp[k++] = v.z;
                            fp[k++] = n.x; fp[k++] = n.y; fp[k++] = n.z;
                        }
                    }
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // O(edges): for each edge check if either endpoint moved.
        bool anyEdgeUpdate = false;
        bool[] edgeNeedsUpdate = new bool[](mesh.edges.length);
        for (int ei = 0; ei < cast(int)mesh.edges.length; ei++) {
            uint a = mesh.edges[ei][0], b = mesh.edges[ei][1];
            if ((a < toUpdate.length && toUpdate[a]) ||
                (b < toUpdate.length && toUpdate[b])) {
                edgeNeedsUpdate[ei] = true;
                anyEdgeUpdate = true;
            }
        }

        if (anyEdgeUpdate) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);
            if (ep) {
                foreach (ei, edge; mesh.edges) {
                    if (!edgeNeedsUpdate[ei]) continue;
                    Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];
                    int k = cast(int)ei * 6;
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Vertex points.
        glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
        float* vp = cast(float*)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);
        if (vp) {
            foreach (vi, needsUpdate; toUpdate) {
                if (!needsUpdate) continue;
                Vec3 v = mesh.vertices[vi];
                int k = cast(int)vi * 3;
                vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
            }
            glUnmapBuffer(GL_ARRAY_BUFFER);
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

    // Draw faces with per-face hover highlights (Polygons mode).
    // Optimized: minimal draw calls for large meshes.
    void drawFacesHighlighted(const ref LitShader shader,
                               int hoveredFace, const bool[] selectedFaces) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);

        // If no hovered face, draw all at once
        if (hoveredFace < 0 || hoveredFace >= faceTriStart.length) {
            glUniform3f(shader.locColor, 0.8f, 0.8f, 0.8f);
            glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
        } else {
            // Draw all faces except hovered face in one batch
            glUniform3f(shader.locColor, 0.8f, 0.8f, 0.8f);
            int hoverStart = faceTriStart[hoveredFace];
            int hoverCount = faceTriCount[hoveredFace];

            // Draw faces before hovered
            if (hoverStart > 0)
                glDrawArrays(GL_TRIANGLES, 0, hoverStart);

            // Draw faces after hovered
            if (hoverStart + hoverCount < faceVertCount)
                glDrawArrays(GL_TRIANGLES, hoverStart + hoverCount,
                            faceVertCount - hoverStart - hoverCount);

            // Draw hovered face with highlight
            if (hoverCount > 0) {
                glUniform3f(shader.locColor, 0.5f, 0.71f, 0.79f);
                glDrawArrays(GL_TRIANGLES, hoverStart, hoverCount);
            }
        }

        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw only the selected faces geometry (no color set — caller sets up shader).
    // Optimized: batch selected faces to minimize draw calls.
    void drawSelectedFacesOverlay(const bool[] selectedFaces) {
        glBindVertexArray(faceVao);

        // If many selected faces, draw them in batches
        int batchStart = -1;
        for (int i = 0; i < cast(int)faceTriStart.length; i++) {
            if (i >= cast(int)selectedFaces.length || !selectedFaces[i]) {
                if (batchStart >= 0) {
                    // Draw the current batch
                    int batchEnd = i;
                    int startIdx = faceTriStart[batchStart];
                    int endIdx = (batchEnd < cast(int)faceTriStart.length)
                                ? faceTriStart[batchEnd] : faceVertCount;
                    glDrawArrays(GL_TRIANGLES, startIdx, endIdx - startIdx);
                    batchStart = -1;
                }
            } else {
                if (batchStart < 0) batchStart = i;
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
    // Optimized: batch rendering for large meshes.
    // hoveredEdge = -1 means no hover; selectedEdges may be shorter than edgeCount.
    void drawEdges(GLint locColor, int hoveredEdge, const bool[] selectedEdges) {
        int edgeCount = edgeVertCount / 2;
        glBindVertexArray(edgeVao);

        // Default gray edges — with depth test (skip hovered and selected)
        // Batch draw all default edges
        glUniform3f(locColor, 0.9f, 0.9f, 0.9f);

        // Check once if all edges are selected (avoids per-edge iteration in gray pass).
        bool allEdgesSelected = (selectedEdges.length >= edgeCount && hoveredEdge < 0);
        if (allEdgesSelected)
            foreach (s; selectedEdges[0 .. edgeCount]) if (!s) { allEdgesSelected = false; break; }

        if (hoveredEdge < 0 && selectedEdges.length == 0) {
            // No selection: draw everything gray in one call.
            glDrawArrays(GL_LINES, 0, edgeVertCount);
        } else if (!allEdgesSelected) {
            // Partial selection: draw gray edges, skipping selected/hovered.
            int batchStart = -1;
            for (int i = 0; i < edgeCount; i++) {
                bool skipThis = (i == hoveredEdge) ||
                    (i < cast(int)selectedEdges.length && selectedEdges[i]);
                if (!skipThis) {
                    if (batchStart < 0) batchStart = i;
                } else {
                    if (batchStart >= 0) {
                        glDrawArrays(GL_LINES, batchStart * 2, (i - batchStart) * 2);
                        batchStart = -1;
                    }
                }
            }
            if (batchStart >= 0)
                glDrawArrays(GL_LINES, batchStart * 2, (edgeCount - batchStart) * 2);
        }
        // allEdgesSelected: gray pass skipped entirely — 0 unselected edges to draw.

        // Selected and hovered — drawn without depth test so they show through faces.
        glDisable(GL_DEPTH_TEST);

        if (allEdgesSelected && hoveredEdge < 0) {
            // All edges selected: one draw call.
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            glDrawArrays(GL_LINES, 0, edgeVertCount);
        } else if (selectedEdges.length > 0) {
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            int batchStart = -1;
            for (int i = 0; i < cast(int)selectedEdges.length; i++) {
                if (selectedEdges[i] && i != hoveredEdge) {
                    if (batchStart < 0) batchStart = i;
                } else {
                    if (batchStart >= 0) {
                        glDrawArrays(GL_LINES, batchStart * 2, (i - batchStart) * 2);
                        batchStart = -1;
                    }
                }
            }
            if (batchStart >= 0)
                glDrawArrays(GL_LINES, batchStart * 2, (cast(int)selectedEdges.length - batchStart) * 2);
        }

        // Draw hovered edge
        if (hoveredEdge >= 0 && hoveredEdge < edgeCount) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            glDrawArrays(GL_LINES, hoveredEdge * 2, 2);
        }

        glEnable(GL_DEPTH_TEST);
        glBindVertexArray(0);
    }

    // Draw vertex dots (call AFTER picking so hovered/selected state is current)
    void drawVertices(GLint locColor, int hovered, const bool[] selected) {
        glBindVertexArray(vertVao);

        // All vertices — small gray dots, with depth test
        glPointSize(5.0f);
        glUniform3f(locColor, 0.6f, 0.6f, 0.6f);
        glDrawArrays(GL_POINTS, 0, vertCount);

        // Selected and hovered — drawn without depth test so they show through faces.
        glDisable(GL_DEPTH_TEST);

        glPointSize(10.0f);
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        foreach (i; 0 .. selected.length)
            if (selected[i]) glDrawArrays(GL_POINTS, cast(int)i, 1);

        if (hovered >= 0 && hovered < vertCount) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            glDrawArrays(GL_POINTS, hovered, 1);
        }

        glEnable(GL_DEPTH_TEST);
        glPointSize(1.0f);
        glBindVertexArray(0);
    }
}
