module tools.edit.bridge_tool_source_cells;

import tools.edit.bridge_tool;
import display_state : DrawPlan;
import bindbc.sdl;
import operator : VectorStack;
import tool;
import mesh;
import mesh_gpu : GpuMesh;
import mesh_ops.bridge : BridgeOpenParams, openBridgeSegments, bridgeLoopsSpans, bridgeOpenRows, facesBoundedByLoop,
                         kBridgeEditScope;
import math;
import editmode : EditMode;
import params : IntEnumEntry, Param;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import tools.common.session_mesh_key : SessionMeshKey;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditScope;
import shader : Shader, LitShader;
import model_preview : ModelPreviewView;
import std.json : JSONValue;
import prepared_tool_effect : PreparedToolStateDelta, PreparedToolStateKind,
    PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedDeactivateEffect, PreparedDeactivateKind;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolParamDoorClient;
import prepared_bridge_activation : PreparedBridgeActivationOwner,
    PreparedBridgeDeactivateOwner;
import mesh_gpu : GpuCreateOwner, GpuCreateUploadOwner, GpuUploadOwner,
    GpuResourceOwner;
import document : Layer;
import command_history : PreparedHistoryKind;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
version (unittest) import std.conv : to;

unittest {
    Mesh owned;
    auto tool = new BridgeTool(() => &owned, null, LitShader.init, null);
    tool.engaged = false;
    auto prepared = tool.prepareParamState("segments");
    assert(!tool.engaged);
    assert(prepared.boolValue); // using the original false state instead REDs
    BridgePreparedState handle;
    assert(tool.validatePreparedState(prepared, handle));
    tool.installLegacyPreparedState(handle);
    assert(tool.engaged); // installed state == legacy assignment
    tool.engaged = false;
    tool.installLegacyPreparedState(handle);
    assert(!tool.engaged);
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

    import snapshot : MeshSnapshot;
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
