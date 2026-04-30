module poly_bevel;

import std.math : sqrt;

import math;
import mesh;

// ---------------------------------------------------------------------------
// Polygon "bevel" — inset + extrude on selected faces.
//
// For each selected face F (with N vertices):
//   1. Allocate N new mesh vertices, initially at the original face vertex
//      positions.
//   2. Replace F with the new vertex ring (the "top" face).
//   3. Emit N side-wall quads connecting each old vertex to the corresponding
//      new vertex: [orig[i], orig[i+1], new[i+1], new[i]].
//   4. Reposition each new vertex via:
//        new[i] = center + (orig[i] - center) * insertScale
//                        + faceNormal * shiftAmount
//      where center = face centroid and faceNormal = unit cross of the first
//      two face edges.
//
// Group mode (groupPolygons=true): adjacent selected faces share new vertices
// at their shared boundary, AND their internal shared edges are removed
// (instead of generating side-wall quads). The resulting top region is one
// connected inset patch matching the union of selected faces.
//
// Approximate Blender analogue: bmesh.ops.inset_individual (group=false) or
// inset_region (group=true), with the new face vertices then moved via the
// same insertScale/shiftAmount formula.
// ---------------------------------------------------------------------------

struct PolyBevelOp {
    int[][] perFaceNewVerts;   // per-original-face new mesh vertex IDs
    int[]   perFaceOrigIdx;    // index into mesh.faces of the (now top) face
}

PolyBevelOp applyPolyBevel(Mesh* mesh, const(int)[] selFaceIdx,
                            float insertScale, float shiftAmount,
                            bool groupPolygons)
{
    PolyBevelOp op;
    if (selFaceIdx.length == 0) return op;

    bool[ulong] internalEdgeSet;
    int[uint]   groupVertMap;

    if (groupPolygons) {
        // Identify internal edges (shared between two selected faces). Used
        // both to remove the original mesh edge and to skip side-wall quad
        // emission on those edges.
        bool[ulong] selEdges;
        foreach (fi; selFaceIdx) {
            auto face = mesh.faces[fi];
            int M = cast(int)face.length;
            foreach (i; 0 .. M) {
                ulong key = (cast(ulong)face[i] << 32) | face[(i + 1) % M];
                selEdges[key] = true;
            }
        }
        foreach (key; selEdges.byKey()) {
            uint a = cast(uint)(key >> 32);
            uint b = cast(uint)(key & 0xFFFF_FFFF);
            ulong rev = (cast(ulong)b << 32) | a;
            if (rev in selEdges)
                internalEdgeSet[key] = true;
        }
        // Drop internal mesh edges (undirected) so the inset top is one
        // contiguous polygon group.
        if (internalEdgeSet.length > 0) {
            bool[ulong] internalPairs;
            foreach (key; internalEdgeSet.byKey()) {
                uint a = cast(uint)(key >> 32);
                uint b = cast(uint)(key & 0xFFFF_FFFF);
                uint mn = a < b ? a : b, mx = a < b ? b : a;
                internalPairs[(cast(ulong)mn << 32) | mx] = true;
            }
            uint[2][] kept;
            bool[]    keptSel;
            int[]     keptOrd;
            foreach (ei, e; mesh.edges) {
                uint mn = e[0] < e[1] ? e[0] : e[1];
                uint mx = e[0] < e[1] ? e[1] : e[0];
                if (((cast(ulong)mn << 32) | mx) in internalPairs) continue;
                kept    ~= e;
                keptSel ~= ei < mesh.selectedEdges.length     ? mesh.selectedEdges[ei]      : false;
                keptOrd ~= ei < mesh.edgeSelectionOrder.length ? mesh.edgeSelectionOrder[ei] : 0;
            }
            mesh.edges              = kept;
            mesh.selectedEdges      = keptSel;
            mesh.edgeSelectionOrder = keptOrd;
        }
    }

    foreach (origFi; selFaceIdx) {
        uint[] origFaceVerts = mesh.faces[origFi].dup;
        int N = cast(int)origFaceVerts.length;
        if (N < 3) continue;

        Vec3[] origPos = new Vec3[](N);
        foreach (i; 0 .. N)
            origPos[i] = mesh.vertices[origFaceVerts[i]];

        Vec3 center = Vec3(0, 0, 0);
        foreach (p; origPos) center += p;
        float invN = 1.0f / cast(float)N;
        center = center * invN;

        Vec3 e1 = origPos[1] - origPos[0];
        Vec3 e2 = origPos[2] - origPos[0];
        Vec3 cr = cross(e1, e2);
        float clen = sqrt(cr.x*cr.x + cr.y*cr.y + cr.z*cr.z);
        Vec3 faceNormal = clen > 1e-6f ? cr / clen : Vec3(0, 1, 0);

        int[] newVerts = new int[](N);
        foreach (i; 0 .. N) {
            Vec3 placed = Vec3(
                center.x + (origPos[i].x - center.x) * insertScale + faceNormal.x * shiftAmount,
                center.y + (origPos[i].y - center.y) * insertScale + faceNormal.y * shiftAmount,
                center.z + (origPos[i].z - center.z) * insertScale + faceNormal.z * shiftAmount,
            );
            if (groupPolygons) {
                uint ov = origFaceVerts[i];
                if (auto p = ov in groupVertMap) {
                    newVerts[i] = *p;
                } else {
                    int nv = cast(int)mesh.addVertex(placed);
                    newVerts[i]      = nv;
                    groupVertMap[ov] = nv;
                }
            } else {
                newVerts[i] = cast(int)mesh.addVertex(placed);
            }
        }

        uint[] topFace = new uint[](N);
        foreach (i; 0 .. N) topFace[i] = cast(uint)newVerts[i];
        mesh.faces[origFi] = topFace;

        foreach (i; 0 .. N) {
            int next = (i + 1) % N;
            if (groupPolygons) {
                ulong key = (cast(ulong)origFaceVerts[i] << 32) | origFaceVerts[next];
                if (key in internalEdgeSet) continue;
            }
            mesh.addFace([origFaceVerts[i],        origFaceVerts[next],
                          cast(uint)newVerts[next], cast(uint)newVerts[i]]);
        }

        op.perFaceNewVerts ~= newVerts;
        op.perFaceOrigIdx  ~= origFi;
    }

    mesh.syncSelection();
    return op;
}
