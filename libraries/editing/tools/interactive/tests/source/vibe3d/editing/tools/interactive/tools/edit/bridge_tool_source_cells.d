module vibe3d.editing.tools.interactive.tools.edit.bridge_tool_source_cells;

import vibe3d.editing.tools.interactive.tools.edit.bridge_tool;
import vibe3d.viewport.display_policy.display_state : DrawPlan;
import bindbc.sdl;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import vibe3d.editing.tools.interactive.tool;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
import vibe3d.mesh.ops.mesh_ops.bridge : BridgeOpenParams, openBridgeSegments, bridgeLoopsSpans, bridgeOpenRows, facesBoundedByLoop,
                         kBridgeEditScope;
import vibe3d.util.math.math;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.params.params : IntEnumEntry, Param;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.editing.tools.state.tools.common.session_mesh_key : SessionMeshKey;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditScope;
import vibe3d.viewport.gpu.shader : Shader, LitShader;
import vibe3d.editing.tools.interactive.model_preview : ModelPreviewView;
import std.json : JSONValue;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedToolStateDelta, PreparedToolStateKind,
    PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedDeactivateEffect, PreparedDeactivateKind;
import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolParamDoorClient;
import vibe3d.editing.tools.interactive.prepared_bridge_activation : PreparedBridgeActivationOwner,
    PreparedBridgeDeactivateOwner;
import vibe3d.viewport.gpu.mesh_gpu : GpuCreateOwner, GpuCreateUploadOwner, GpuUploadOwner,
    GpuResourceOwner;
import vibe3d.documents.model.document : Layer;
import vibe3d.editing.commands.runtime.command_history : PreparedHistoryKind;
import vibe3d.mesh.core.mesh : beginPreparedShadow, drainPreparedShadowDelivery;
version (unittest) import std.conv : to;



// ---------------------------------------------------------------------------
// Module unittests — dubtest-lane parity + regression gate (task 0357).
// CPU-only (plain Mesh, no GpuMesh/GL): exercises resolveBridgeSelection /
// applyBridgeOp / rebuildBridgePreview directly, mirroring
// tools/mirror.d's / tools/tack.d's free-function unittest pattern.
// ---------------------------------------------------------------------------

private Mesh makeTwoCapMesh() {
    // Same fixture as tests/test_bridge.d's loadCaps(): two coaxial unit
    // squares, cap A at z=0 (face 0), cap B at z=1 (face 1).
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    m.buildLoops();
    // selectFace/selectEdge index straight into faceMarks/edgeMarks without
    // auto-growing (addFace/addEdge don't touch them) — size explicitly so
    // the unittests below can select() before running the tool.
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;
    return m;
}

unittest { // Polygon mode, spans=1: remove=true/false are bit-exact both
           // states (task 0357 Remove Polygons requirement).
    Mesh m1 = makeTwoCapMesh();
    m1.selectFace(0);
    m1.selectFace(1);
    auto sel1 = resolveBridgeSelection(m1, EditMode.Polygons);
    assert(sel1.valid && sel1.polygonMode, "polygon-mode selection must resolve");
    assert(sel1.capFaces.length == 2, "polygon mode: capFaces = the 2 selected faces");

    BridgeParams p1; p1.segments = 1; p1.remove = true;
    auto r1 = applyBridgeOp(m1, sel1.loopA, sel1.loopB, sel1.capFaces, p1);
    assert(r1.added == 4, "spans=1: expected 4 bridge quads");
    assert(r1.removed, "remove=true must delete the 2 caps");
    assert(m1.faces.length == 4, "remove=true: expected 4 faces, got "
        ~ m1.faces.length.to!string);
    assert(m1.vertices.length == 8, "remove=true: no new verts at spans=1");

    Mesh m2 = makeTwoCapMesh();
    m2.selectFace(0);
    m2.selectFace(1);
    auto sel2 = resolveBridgeSelection(m2, EditMode.Polygons);
    BridgeParams p2; p2.segments = 1; p2.remove = false;
    auto r2 = applyBridgeOp(m2, sel2.loopA, sel2.loopB, sel2.capFaces, p2);
    assert(r2.added == 4, "spans=1: expected 4 bridge quads");
    assert(!r2.removed, "remove=false must NOT delete the caps");
    assert(m2.faces.length == 6, "remove=false: expected 6 faces (2 caps + 4 bridge), got "
        ~ m2.faces.length.to!string);
    assert(m2.vertices.length == 8, "remove=false: no new verts at spans=1");
}

unittest { // Edge mode: remove=true generalizes to deleting a face that
           // happens to be exactly bounded by a bridged loop (task 0357
           // closes the "edge-mode never removes" gap on the NEW tool
           // only — commands.mesh.bridge's existing one-shot Command is
           // untouched and keeps its own always-preserve behaviour).
    Mesh m = makeTwoCapMesh();
    // Select every edge of both cap rims (mirrors test_bridge.d's edge-mode
    // setup) — no explicit vertex/edge selection API on the bare Mesh here,
    // so drive it through markEdgeSelected by scanning for the two rims.
    foreach (ei; 0 .. m.edges.length) {
        auto e = m.edges[ei];
        bool bothA = e[0] < 4 && e[1] < 4;
        bool bothB = e[0] >= 4 && e[1] >= 4;
        if (bothA || bothB) m.selectEdge(cast(int)ei);
    }
    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid && !sel.polygonMode, "edge-mode selection must resolve");
    assert(sel.capFaces.length == 2,
        "edge mode: both cap faces are exactly bounded by their rim loop, expected 2 capFaces, got "
        ~ sel.capFaces.length.to!string);

    BridgeParams p; p.segments = 1; p.remove = true;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p);
    assert(r.added == 4, "edge mode spans=1: expected 4 bridge quads");
    assert(r.removed, "edge mode remove=true must delete the 2 bounding caps");
    assert(m.faces.length == 4, "edge mode remove=true: expected 4 faces, got "
        ~ m.faces.length.to!string);
}

unittest { // rebuildBridgePreview is NON-CUMULATIVE — 5 repeat calls land
           // on the identical vertex/face count (mirrors tools/mirror.d's
           // / tools/tack.d's own non-cumulative proof).
    Mesh baseMesh = makeTwoCapMesh();
    baseMesh.selectFace(0);
    baseMesh.selectFace(1);
    auto sel = resolveBridgeSelection(baseMesh, EditMode.Polygons);
    assert(sel.valid);

    import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
    MeshSnapshot baseSnap = MeshSnapshot.capture(baseMesh);

    BridgeParams p; p.segments = 3; p.twist = 1.0f; p.remove = true;

    Mesh previewMesh;
    size_t expectedVerts = size_t.max, expectedFaces = size_t.max;
    foreach (i; 0 .. 5) {
        rebuildBridgePreview(baseSnap, previewMesh, sel.loopA, sel.loopB, sel.capFaces, p);
        if (i == 0) {
            expectedVerts = previewMesh.vertices.length;
            expectedFaces = previewMesh.faces.length;
            assert(expectedVerts == 16, "expected 8 orig + 8 new verts, got "
                ~ expectedVerts.to!string);
            assert(expectedFaces == 12, "expected 12 faces (3 spans * 4), got "
                ~ expectedFaces.to!string);
        } else {
            assert(previewMesh.vertices.length == expectedVerts,
                "preview accumulated verts on repeat #" ~ i.to!string);
            assert(previewMesh.faces.length == expectedFaces,
                "preview accumulated faces on repeat #" ~ i.to!string);
        }
    }
}
