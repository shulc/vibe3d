module mesh;

import bindbc.opengl;
import math;
// ---------------------------------------------------------------------------
// Mesh
// ---------------------------------------------------------------------------

struct Mesh {
    Vec3[]    vertices;
    uint[2][] edges;
    uint[][]  faces;

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
    void clear() { vertices = []; edges = []; faces = []; }
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
        // Faces (fan triangulation) — track per-face offsets
        float[] faceData;
        faceTriStart.length = 0;
        faceTriCount.length = 0;
        foreach (face; mesh.faces) {
            int start = cast(int)(faceData.length / 3);
            if (face.length >= 3) {
                for (uint i = 1; i + 1 < face.length; i++) {
                    foreach (idx; [face[0], face[i], face[i+1]]) {
                        Vec3 v = mesh.vertices[idx];
                        faceData ~= [v.x, v.y, v.z];
                    }
                }
            }
            int count = cast(int)(faceData.length / 3) - start;
            faceTriStart ~= start;
            faceTriCount  ~= count;
        }
        faceVertCount = cast(int)(faceData.length / 3);
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
        glBufferData(GL_ARRAY_BUFFER, faceData.length * float.sizeof, faceData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

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

    // Draw faces only (writes depth buffer)
    void drawFaces(GLuint program, GLint locColor) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glUniform3f(locColor, 0.8f, 0.8f, 0.8f);
        glBindVertexArray(faceVao);
        glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw faces with per-face hover/selection highlights (Polygons mode).
    void drawFacesHighlighted(GLuint program, GLint locColor,
                               int hoveredFace, const bool[] selectedFaces) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);
        foreach (i; 0 .. cast(int)faceTriStart.length) {
            bool sel = i < cast(int)selectedFaces.length && selectedFaces[i];
            bool hov = (i == hoveredFace);
            if (hov)
                glUniform3f(locColor, 0.5f, 0.71f, 0.79f);
            else if (sel)
                glUniform3f(locColor, 1.0f, 0.64f, 0.0f);     // orange
            else
                glUniform3f(locColor, 0.8f, 0.8f, 0.8f);  // default grey
            glDrawArrays(GL_TRIANGLES, faceTriStart[i], faceTriCount[i]);
        }
        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw edges with optional hover/selection highlights.
    // hoveredEdge = -1 means no hover; selectedEdges may be shorter than edgeCount.
    void drawEdges(GLint locColor, int hoveredEdge, const bool[] selectedEdges) {
        int edgeCount = edgeVertCount / 2;
        glBindVertexArray(edgeVao);

        // Default gray edges (skip hovered and selected)
        glUniform3f(locColor, 0.9f, 0.9f, 0.9f);
        foreach (i; 0 .. edgeCount) {
            if (i == hoveredEdge) continue;
            if (i < cast(int)selectedEdges.length && selectedEdges[i]) continue;
            glDrawArrays(GL_LINES, i * 2, 2);
        }

        // Selected edges — orange
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        foreach (i; 0 .. cast(int)selectedEdges.length)
            if (selectedEdges[i] && i != hoveredEdge)
                glDrawArrays(GL_LINES, i * 2, 2);

        // Hovered edge — yellow (drawn last = on top)
        if (hoveredEdge >= 0 && hoveredEdge < edgeCount) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            glDrawArrays(GL_LINES, hoveredEdge * 2, 2);
        }

        glBindVertexArray(0);
    }

    // Draw vertex dots (call AFTER picking so hovered/selected state is current)
    void drawVertices(GLint locColor, int hovered, const bool[] selected) {
        glBindVertexArray(vertVao);

        // All vertices — small gray dots
        glPointSize(5.0f);
        glUniform3f(locColor, 0.6f, 0.6f, 0.6f);
        glDrawArrays(GL_POINTS, 0, vertCount);

        // Selected — larger orange
        glPointSize(10.0f);
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        foreach (i; 0 .. selected.length)
            if (selected[i]) glDrawArrays(GL_POINTS, cast(int)i, 1);

        // Hovered — bright yellow (drawn last = on top)
        if (hovered >= 0 && hovered < vertCount) {
            glPointSize(10.0f);
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            glDrawArrays(GL_POINTS, hovered, 1);
        }

        glPointSize(1.0f);
        glBindVertexArray(0);
    }
}
