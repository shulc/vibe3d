// Module unittests for `tools.transform.rotate`, moved verbatim out of source/tools/transform/rotate.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.tools.interactive.tests.unit.tools.transform.rotate_test;

import bindbc.opengl;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import bindbc.sdl;
import vibe3d.editing.tools.interactive.tools.transform.transform;
import vibe3d.editing.tools.interactive.handler;
import vibe3d.mesh.core.mesh;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.contracts.seltype : SelType;
import vibe3d.util.math.math;
import vibe3d.util.spatial.spatial : Viewport, projectToWindowFull;
import vibe3d.viewport.gpu.shader;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : FalloffPacket;
import std.math;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import vibe3d.editing.tools.transform.tools.transform.arcball : ARCBALL_RADIUS_PX, arcballRotation,
                                 arcballAxisToWorld;
import vibe3d.editing.selection.query.snap : SnapResult;
import vibe3d.editing.tools.interactive.snap_render : drawSnapOverlay, clearLastSnap;
import vibe3d.editing.pipeline.runtime.falloff : evaluateFalloff;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;
import vibe3d.editing.params.params : Param;
import vibe3d.editing.tools.interactive.falloff_handles : screenFalloffActive, screenFalloffSetCenter, screenFalloffLMBBegin;
import vibe3d.editing.tools.interactive.tools.transform.rotate;


unittest { // a re-chained principal ring re-derives its grab reference in the PUSHED arc plane
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.viewport.camera.view : View;
    static class VpRotate : RotateTool {
        this(Mesh* delegate() m, GpuMesh* g, EditMode* e) { super(m, g, e); }
        void rig(Viewport vp, int axis, int mx, int my) { cachedVp = vp; dragAxis = axis; lastMX = mx; lastMY = my; }
    }
    static Vec3 privateVec(RotateTool t, string name) {
        foreach (i, ref f; t.tupleof)
            static if (is(typeof(f) == Vec3))
                if (__traits(identifier, RotateTool.tupleof[i]) == name) return f;
        assert(0, name);
    }
    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto t = new VpRotate(() => &mesh, &gpu, &mode);
    auto view = new View(0, 0, 1280, 800);
    Viewport vp = view.viewport();
    t.setWrapperGizmoPose(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
    float px, py, pz;
    assert(projectToWindowFull(Vec3(0, 0.5f, 0.3f), vp, px, py, pz), "rig: grab pixel projects");
    t.rig(vp, 0, cast(int)px, cast(int)py);
    immutable float c = cos(PI / 6), s = sin(PI / 6);
    immutable r = Vec3(c, s, 0), u = Vec3(-s, c, 0), f = Vec3(0, 0, 1);
    t.setWrapperInputFrame(r, u, f, true);
    immutable ref_ = privateVec(t, "dragRefDir");
    assert(privateVec(t, "dragAxisVec") == r, "rig: the pushed X axis is the drag axis");
    assert(abs(ref_.length - 1.0f) < 1e-4f && abs(dot(ref_, r)) < 1e-4f,
        "re-chained grab reference not re-derived in the pushed ring plane");
}
