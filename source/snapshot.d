module snapshot;

import std.algorithm.iteration : map;
import std.array : array;

import mesh;
import math;
import change_bus : MeshChangeAll;

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
    // Packed per-element flag words (selection + subpatch + any future
    // reserved bits) — the same representation the mesh stores. faceMarks
    // carries both the Select and Subpatch bits, so subpatch round-trips
    // automatically and new mark bits need no snapshot change.
    uint[]   vertexMarks;
    uint[]   edgeMarks;
    uint[]   faceMarks;
    int[]    vertexSelectionOrder;
    int[]    edgeSelectionOrder;
    int[]    faceSelectionOrder;
    int      vertexSelectionOrderCounter;
    int      edgeSelectionOrderCounter;
    int      faceSelectionOrderCounter;
    Surface[] surfaces;
    uint[]    faceMaterial;
    MeshMap[] meshMaps;
    bool     filled = false;

    static MeshSnapshot capture(in Mesh mesh) {
        MeshSnapshot s;
        s.vertices             = mesh.vertices.dup;
        s.edges                = mesh.edges.dup;
        // .range needed because the templated `map!` instantiation
        // through `alias this` can't carry const(FaceList) cleanly.
        s.faces                = mesh.faces.range.map!(f => f.dup).array;
        s.vertexMarks          = mesh.vertexMarks.dup;
        s.edgeMarks            = mesh.edgeMarks.dup;
        s.faceMarks            = mesh.faceMarks.dup;
        s.vertexSelectionOrder = mesh.vertexSelectionOrder.dup;
        s.edgeSelectionOrder   = mesh.edgeSelectionOrder.dup;
        s.faceSelectionOrder   = mesh.faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = mesh.vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter   = mesh.edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter   = mesh.faceSelectionOrderCounter;
        s.surfaces             = mesh.surfaces.dup;
        s.faceMaterial         = mesh.faceMaterial.dup;
        // Deep-dup each map (its `data` too) so later mesh mutations don't
        // alias the snapshot — MeshMap.dup dups the float[] data.
        s.meshMaps             = mesh.meshMaps.map!(mm => mm.dup).array;
        s.filled               = true;
        return s;
    }

    void restore(ref Mesh mesh) const {
        mesh.vertices                    = vertices.dup;
        mesh.edges                       = edges.dup;
        mesh.faces                       = faces.map!(f => f.dup).array;
        // Whole-word restore: faceMarks carries Select + Subpatch (+ any
        // reserved bits) together, so this restores the full per-element
        // flag state. Lengths match the geometry restored just above
        // because they were captured alongside it.
        mesh.vertexMarks                 = vertexMarks.dup;
        mesh.edgeMarks                   = edgeMarks.dup;
        mesh.faceMarks                   = faceMarks.dup;
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
        mesh.surfaces                    = surfaces.dup;
        mesh.faceMaterial                = faceMaterial.dup;
        // Restore the map registry (deep-dup so the live mesh doesn't alias
        // the snapshot's data). buildLoops below rebuilds loops/edges; the
        // restored maps' lengths already match the restored geometry because
        // they were captured alongside it, but resizeAllMeshMaps keeps them
        // correct if buildLoops were ever to change an element count.
        mesh.meshMaps                    = meshMaps.map!(mm => mm.dup).array;
        mesh.buildLoops();
        mesh.resizeAllMeshMaps();
        // Snapshot restore rebuilds the WHOLE mesh — geometry, topology, marks
        // and materials may all have changed across the undo/redo. Emit the
        // bulk All mask (which includes Geometry, so commitChange bumps both
        // mutationVersion and topologyVersion exactly as the old two lines did).
        mesh.commitChange(MeshChangeAll);
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
        mesh.setVerticesSelectedFrom(selectedVertices);
        mesh.setEdgesSelectedFrom(selectedEdges);
        mesh.setFacesSelectedFrom(selectedFaces);
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
    }
}
