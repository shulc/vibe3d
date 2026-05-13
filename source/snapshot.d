module snapshot;

import std.algorithm.iteration : map;
import std.array : array;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshSnapshot — full pre-apply mesh + selection + subpatch state, used by
// commands whose revert() needs to restore "whatever the mesh looked like
// before". Captures everything via .dup so subsequent mesh mutations don't
// alias the snapshot.
//
// Heavyweight (~MB for large meshes); commands that only mutate a small
// slice (e.g. mesh.move_vertex, subpatch_toggle) should snapshot only the
// affected fields instead of using this helper.
//
// Note: Command instances hold their editMode by value (not ref), so
// the snapshot doesn't capture or restore edit mode here. If a command
// changes editMode (none currently do — that's a tool / app.d concern),
// it must handle that separately.
// ---------------------------------------------------------------------------

struct MeshSnapshot {
    Vec3[]   vertices;
    uint[2][] edges;
    uint[][] faces;
    bool[]   selectedVertices;
    bool[]   selectedEdges;
    bool[]   selectedFaces;
    int[]    vertexSelectionOrder;
    int[]    edgeSelectionOrder;
    int[]    faceSelectionOrder;
    int      vertexSelectionOrderCounter;
    int      edgeSelectionOrderCounter;
    int      faceSelectionOrderCounter;
    bool[]   isSubpatch;
    bool     filled = false;

    static MeshSnapshot capture(in Mesh mesh) {
        MeshSnapshot s;
        s.vertices             = mesh.vertices.dup;
        s.edges                = mesh.edges.dup;
        // .range needed because the templated `map!` instantiation
        // through `alias this` can't carry const(FaceList) cleanly.
        s.faces                = mesh.faces.range.map!(f => f.dup).array;
        s.selectedVertices     = mesh.selectedVertices.dup;
        s.selectedEdges        = mesh.selectedEdges.dup;
        s.selectedFaces        = mesh.selectedFaces.dup;
        s.vertexSelectionOrder = mesh.vertexSelectionOrder.dup;
        s.edgeSelectionOrder   = mesh.edgeSelectionOrder.dup;
        s.faceSelectionOrder   = mesh.faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = mesh.vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter   = mesh.edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter   = mesh.faceSelectionOrderCounter;
        s.isSubpatch           = mesh.isSubpatch.dup;
        s.filled               = true;
        return s;
    }

    void restore(ref Mesh mesh) const {
        mesh.vertices                    = vertices.dup;
        mesh.edges                       = edges.dup;
        mesh.faces                       = faces.map!(f => f.dup).array;
        mesh.selectedVertices            = selectedVertices.dup;
        mesh.selectedEdges               = selectedEdges.dup;
        mesh.selectedFaces               = selectedFaces.dup;
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
        mesh.isSubpatch                  = isSubpatch.dup;
        mesh.buildLoops();
        ++mesh.mutationVersion;
        // Snapshot restore rebuilds the WHOLE mesh — topology may
        // have changed across the undo/redo, so cached subpatch
        // topology must invalidate.
        ++mesh.topologyVersion;
    }
}

// ---------------------------------------------------------------------------
// SelectionSnapshot — lightweight: captures selection arrays + counters
// without touching geometry. Used by select.* commands and any future
// command that only mutates selection state.
// ---------------------------------------------------------------------------

struct SelectionSnapshot {
    bool[] selectedVertices;
    bool[] selectedEdges;
    bool[] selectedFaces;
    int[]  vertexSelectionOrder;
    int[]  edgeSelectionOrder;
    int[]  faceSelectionOrder;
    int    vertexSelectionOrderCounter;
    int    edgeSelectionOrderCounter;
    int    faceSelectionOrderCounter;
    bool   filled = false;

    static SelectionSnapshot capture(in Mesh mesh) {
        SelectionSnapshot s;
        s.selectedVertices     = mesh.selectedVertices.dup;
        s.selectedEdges        = mesh.selectedEdges.dup;
        s.selectedFaces        = mesh.selectedFaces.dup;
        s.vertexSelectionOrder = mesh.vertexSelectionOrder.dup;
        s.edgeSelectionOrder   = mesh.edgeSelectionOrder.dup;
        s.faceSelectionOrder   = mesh.faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = mesh.vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter   = mesh.edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter   = mesh.faceSelectionOrderCounter;
        s.filled               = true;
        return s;
    }

    void restore(ref Mesh mesh) const {
        mesh.selectedVertices            = selectedVertices.dup;
        mesh.selectedEdges               = selectedEdges.dup;
        mesh.selectedFaces               = selectedFaces.dup;
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
    }
}
