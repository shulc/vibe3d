// Task 9429 (wave-2 plan §9.4): the shared topology-step bodies of
// `source/tools/topology_step.d`, read through one client each. Its own module so
// a text-census red (`topology_step_mixin_census_test.d`) cannot mask these cells.
// The suite families do not see the gizmo rebase's terms, the tools' hooks, the basis
// the body hands the session, nor the commit pair's re-base (the 9429 drill).
module tests.unit.topology_step_mixin_test;

import editmode : EditMode;
import math : Vec3;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import shader : LitShader;
import snapshot : MeshSnapshot;
import tools.alignment.mirror : MirrorTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.edit.edge_bevel : EdgeBevelTool;

private Mesh selectedCube(EditMode m) {
    Mesh c = makeCube();
    c.syncSelection();
    if (m == EditMode.Edges) c.selectEdge(0); else c.selectFace(0);
    return c;
}

unittest { // the gizmo rebase over the live mesh: frame on it, drag state cleared, hook ran
    Mesh mesh = selectedCube(EditMode.Edges), old = makeCube();
    old.vertices[0] = Vec3(4, 5, 6);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedActivationForTest(old);
    const want = tool.preparedFrameForTest(mesh);
    // Rig: the seed is stale everywhere the rebase must write (form item 5).
    const s = tool.readInteractionForTest();
    assert(want.gizmoValid && s.anchor != want.anchor && s.dragPart != -1 && s.built
           && !tool.previewResetForTest(), "9429 rig VOID: the seed does not differ from the rebase");
    tool.rebaseTopologyStep(MeshSnapshot.capture(mesh));
    const r = tool.readInteractionForTest();
    assert(r.gizmoValid && r.anchor == want.anchor && r.baseAnchor == want.baseAnchor
           && r.widthAxis == want.widthAxis && r.gizmoSelHash == want.gizmoSelHash,
           "9429 gizmo rebase: the frame over a matching basis is not the live mesh's");
    assert(!r.built && r.dragPart == -1, "9429 gizmo rebase: built or dragPart survived a rebase");
    assert(tool.previewResetForTest(), "9429 edge bevel hook: the rebase kept the old preview key");
    assert(tool.topologyStepLabel() == "Edge Bevel" && tool.topologyStepMesh() is &mesh
           && tool.topologyStepBasis().matches(mesh),
           "9429 client body: Edge Bevel's label, mesh or basis is not its own");
}

unittest { // the gizmo rebase over a stale basis: frame on the basis, mesh put back, built
    Mesh mesh = selectedCube(EditMode.Edges), basis = selectedCube(EditMode.Edges);
    const v = basis.edges[0][0];
    basis.vertices[v] = basis.vertices[v] + Vec3(0.5f, 0.25f, 0);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &mesh, &gpu, &mode, LitShader.init);
    Mesh old = makeCube();
    tool.seedPreparedActivationForTest(old);
    const onBasis = tool.preparedFrameForTest(basis), onLive = tool.preparedFrameForTest(mesh);
    assert(onBasis.gizmoValid && onBasis.anchor != onLive.anchor,
           "9429 rig VOID: the basis does not move the frame");
    const live = mesh.vertices.dup;
    tool.rebaseTopologyStep(MeshSnapshot.capture(basis));
    const r = tool.readInteractionForTest();
    assert(r.anchor == onBasis.anchor && r.widthAxis == onBasis.widthAxis,
           "9429 gizmo rebase: the frame over a stale basis is not the basis's");
    assert(r.built && r.dragPart == -1 && mesh.vertices == live,
           "9429 gizmo rebase: a stale basis left built false, a drag part, or the basis on screen");
}

unittest { // Smooth Shift's own hook: a rebased step belongs to an engaged operation
    Mesh mesh = selectedCube(EditMode.Polygons);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Polygons;
    auto tool = new SmoothShiftTool(() => &mesh, &gpu, &mode, LitShader.init);
    tool.seedPreparedParamForTest(mesh, false);
    assert(!tool.buildPreparedParamUpdate(mesh).expected.engaged, "9429 rig VOID: seeded engaged");
    tool.rebaseTopologyStep(MeshSnapshot.capture(mesh));
    assert(tool.buildPreparedParamUpdate(mesh).expected.engaged,
           "9429 smooth shift hook: a rebased step is not engaged");
    assert(tool.topologyStepLabel() == "Smooth Shift", "9429 client body: Smooth Shift's label");
}

unittest { // Mirror's basis field and own rebase, through the shared restore body
    Mesh mesh = selectedCube(EditMode.Polygons), other = makeCube();
    other.vertices[0] = Vec3(4, 5, 6);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    auto tool = new MirrorTool(() => &mesh, &gpu, LitShader.init);
    assert(!tool.topologyStepBasis().matches(other), "9429 rig VOID: the basis already matches");
    tool.restoreTopologyStep(tool.captureAttrImage(), MeshSnapshot.capture(other));
    assert(tool.topologyStepBasis().matches(other),
           "9429 client body: Mirror's basis is not the field its rebase wrote");
    assert(tool.topologyStepLabel() == "Mirror" && tool.topologyStepMesh() is &mesh,
           "9429 client body: Mirror's label or mesh is not its own");
}

unittest { // the session commit pair: re-bases an active tool in place, refuses an idle one
    Mesh mesh = selectedCube(EditMode.Polygons);
    GpuMesh gpu; gpu.suppressCageUpload = true;
    EditMode mode = EditMode.Polygons;
    auto tool = new SmoothShiftTool(() => &mesh, &gpu, &mode, LitShader.init);
    assert(!tool.commitUncommittedEdit() && !tool.commitOperation(),
           "9429 commit pair: an inactive tool committed, or the in-place commit is not refused");
    tool.seedPreparedParamForTest(mesh, true);
    const s = tool.buildPreparedParamUpdate(mesh).expected;
    assert(s.active && s.built && s.engaged, "9429 rig VOID: the seed is not a built, engaged tool");
    assert(tool.commitOperation(), "9429 commit pair: an active tool's close was refused");
    const e = tool.buildPreparedParamUpdate(mesh).expected;
    assert(!e.built && !e.engaged, "9429 commit pair: the close did not re-base the tool in place");
}
