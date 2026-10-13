module tools.create.sphere_source_cells;

import tools.create.sphere;
import prepared_tool_effect : PreparedParamDelta, PreparedParamKind;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import spatial : Viewport;
import params : Param;
import shader : LitShader;
import tools.create.primitive_create_tool : SizedRadialCreateTool;
import tools.create.create_common : primitivePlacementFrame, ringCount;
import prepared_record_context : PreparedRecordContext, PreparedToolParamDoorClient;
import document : Layer;
import std.math : sin, cos, acos, PI, abs, sqrt;

unittest {
    // The base choosePlane reads the pinned basis and keeps its unsigned normal.
    import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
    import toolpipe.stages.workplane : WorkplaneStage;
    auto savedAxisPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedAxisPipe;
    auto axisCtx = new ToolPipeContext();
    auto axisStage = new WorkplaneStage(); axisCtx.pipeline.add(axisStage); g_pipeCtx = axisCtx;
    axisStage.edit(2, -1, 3, 30, 40, 15);
    Mesh axisMesh; GpuMesh axisGpu;
    auto axisTool = new SphereTool(() => &axisMesh, &axisGpu, LitShader.init);
    const axisFrame = primitivePlacementFrame();
    foreach (k; 0 .. 3) foreach (sign; [-1.0f, 1.0f]) {
        Viewport axisVp; axisVp.view[] = 0;
        const world = k == 0 ? axisFrame.axis1 : k == 1 ? axisFrame.normal : axisFrame.axis2;
        axisVp.view[2] = sign * world.x;
        axisVp.view[6] = sign * world.y;
        axisVp.view[10] = sign * world.z;
        const chosen = axisTool.chosenPlaneForTest(axisVp);
        const expected = Vec3(k == 0 ? 1 : 0, k == 1 ? 1 : 0, k == 2 ? 1 : 0);
        assert((chosen - expected).length < 1e-6f,
               "production choosePlane lost the pinned principal axis or its sign");
    }
    g_pipeCtx = savedAxisPipe;

    Mesh owned;
    auto tool = new SphereTool(() => &owned, null, LitShader.init);
    SphereParams seed;
    seed.sizeX = 2; seed.sizeY = 3; seed.sizeZ = 5; seed.axis = 0;
    tool.p1SetParams(seed);
    tool.axisAtLastSync = 1;
    auto prepared = tool.prepareAxisParam("axis");
    auto before = tool.p1Params;
    assert(before.sizeX == 2 && before.sizeY == 3 && before.sizeZ == 5);
    assert(prepared.x == 5 && prepared.y == 2 && prepared.z == 3);
    SpherePreparedParamHandle handle;
    assert(tool.validatePreparedParam(prepared, handle));
    tool.installLegacyPreparedParam(handle);
    auto after = tool.p1Params;
    assert(after.sizeX == 5 && after.sizeY == 2 && after.sizeZ == 3);
    assert(tool.axisAtLastSync == 0);
    after.sizeX = 9; tool.p1SetParams(after);
    tool.installLegacyPreparedParam(handle);
    assert(tool.p1Params.sizeX == 9); // one-shot handle cannot replay

    auto unrelated = tool.prepareAxisParam("sizeX");
    assert(unrelated.kind == PreparedParamKind.None);
    auto sameAxis = tool.prepareAxisParam("axis");
    assert(sameAxis.kind == PreparedParamKind.None);

    auto invalid = PreparedParamDelta.sphereAxis(prepared.owner, 3, 11, 12, 13);
    SpherePreparedParamHandle refused;
    assert(!tool.validatePreparedParam(invalid, refused));
    assert(!refused.consumable && !refused.apply);
    auto beforeRefusedInstall = tool.p1Params;
    tool.installLegacyPreparedParam(refused);
    auto afterRefusedInstall = tool.p1Params;
    assert(afterRefusedInstall.sizeX == beforeRefusedInstall.sizeX &&
           afterRefusedInstall.sizeY == beforeRefusedInstall.sizeY &&
           afterRefusedInstall.sizeZ == beforeRefusedInstall.sizeZ);
    assert(tool.axisAtLastSync == 0);
}
