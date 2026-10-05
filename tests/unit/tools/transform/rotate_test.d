// Module unittests for `tools.transform.rotate`, moved verbatim out of source/tools/transform/rotate.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.rotate_test;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import tools.transform.transform;
import handler;
import mesh;
import editmode;
import seltype : SelType;
import math;
import shader;
import toolpipe.packets : FalloffPacket;
import std.math;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import tools.transform.arcball : ARCBALL_RADIUS_PX, arcballRotation,
                                 arcballAxisToWorld;
import snap : SnapResult;
import snap_render : drawSnapOverlay, clearLastSnap;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;
import params : Param;
import falloff_handles : screenFalloffActive, screenFalloffSetCenter, screenFalloffLMBBegin;
import tools.transform.rotate;


unittest { // a re-chained principal ring re-derives its grab reference in the PUSHED arc plane
    import mesh_gpu : GpuMesh;
    import view : View;
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
