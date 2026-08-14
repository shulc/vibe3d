// Module unittests for `tools.create.arc`, moved verbatim out of source/tools/create/arc.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.create.arc_test;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import tool;
import mesh;
import math;
import params : Param;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import tools.create.create_common : currentWorkplaneFrame, WorkplaneFrame, transformPoint;
import editmode : EditMode;
import std.math : sin, cos, PI;
import tools.create.arc;

// ---------------------------------------------------------------------------
// Pure module unittests — run under `dub test --config=tests`.
// ---------------------------------------------------------------------------
unittest { // basic counts and on-circle geometry (axis=Y default)
    import std.math : fabs, sqrt, atan2;

    Mesh m;
    ArcParams p;
    p.radius     = 0.5f;
    p.startAngle = 0.0f;
    p.endAngle   = 180.0f;
    p.segments   = 24;
    p.axis       = 1;
    buildArc(&m, p);

    assert(m.vertices.length == 25,
        "expected 25 verts, got " ~ m.vertices.length.stringof);
    assert(m.edges.length == 24,
        "expected 24 edges, got " ~ m.edges.length.stringof);
    assert(m.faces.length == 0,
        "expected 0 faces, got " ~ m.faces.length.stringof);

    // All verts at radius 0.5 from centre in the bIdx/cIdx plane;
    // axisIdx coord = cen[axis] = 0.
    foreach (v; m.vertices) {
        float[3] vf = [v.x, v.y, v.z];
        assert(fabs(vf[1]) < 1e-5f,
            "vert off axis plane (Y != 0): " ~ vf[1].stringof);
        float r = sqrt(vf[2] * vf[2] + vf[0] * vf[0]);
        assert(fabs(r - 0.5f) < 1e-4f,
            "vert not on radius: " ~ r.stringof);
    }

    // First vert at startAngle=0°, last at endAngle=180°.
    // axis=Y(1) → bIdx=2(Z), cIdx=0(X).
    // At θ=0: bPos=radius*cos(0)=0.5, cPos=radius*sin(0)=0 → Z=0.5, X=0.
    assert(fabs(m.vertices[0].z - 0.5f) < 1e-4f, "first vert b-coord wrong");
    assert(fabs(m.vertices[0].x - 0.0f) < 1e-4f, "first vert c-coord wrong");
    // At θ=180°: bPos=radius*cos(π)=-0.5, cPos=0 → Z=-0.5, X=0.
    assert(fabs(m.vertices[24].z - (-0.5f)) < 1e-4f, "last vert b-coord wrong");
    assert(fabs(m.vertices[24].x - 0.0f)   < 1e-4f, "last vert c-coord wrong");
}

unittest { // segments=1 → 2 verts, 1 edge (minimum)
    Mesh m;
    ArcParams p;
    p.segments   = 1;
    p.radius     = 1.0f;
    p.startAngle = 0.0f;
    p.endAngle   = 90.0f;
    p.axis       = 1;
    buildArc(&m, p);
    assert(m.vertices.length == 2,
        "segments=1: expected 2 verts");
    assert(m.edges.length == 1,
        "segments=1: expected 1 edge");
    assert(m.faces.length == 0,
        "segments=1: expected 0 faces");
}

unittest { // non-Y axis (axis=X and axis=Z keep correct plane coord)
    import std.math : fabs, sqrt;

    foreach (ax; [0, 2]) {
        Mesh m;
        ArcParams p;
        p.radius     = 1.0f;
        p.startAngle = 0.0f;
        p.endAngle   = 180.0f;
        p.segments   = 8;
        p.axis       = ax;
        buildArc(&m, p);
        assert(m.vertices.length == 9,
            "axis=" ~ ax.stringof ~ ": expected 9 verts");
        assert(m.edges.length == 8,
            "axis=" ~ ax.stringof ~ ": expected 8 edges");
        assert(m.faces.length == 0,
            "axis=" ~ ax.stringof ~ ": expected 0 faces");
        // All verts lie on the radius in the perp plane; axis coord = 0.
        foreach (v; m.vertices) {
            float[3] vf = [v.x, v.y, v.z];
            assert(fabs(vf[ax]) < 1e-5f,
                "axis=" ~ ax.stringof ~ ": vert axis coord != 0");
            int bIdx2 = (ax + 1) % 3;
            int cIdx2 = (ax + 2) % 3;
            float r = sqrt(vf[bIdx2] * vf[bIdx2] + vf[cIdx2] * vf[cIdx2]);
            assert(fabs(r - 1.0f) < 1e-4f,
                "axis=" ~ ax.stringof ~ ": vert off unit circle");
        }
    }
}

unittest { // off-centre: every vert has axis coord == cen[axis]
    import std.math : fabs, sqrt;

    Mesh m;
    ArcParams p;
    p.cenX       = 1.0f;
    p.cenY       = 2.0f;
    p.cenZ       = -3.0f;
    p.radius     = 0.5f;
    p.startAngle = 0.0f;
    p.endAngle   = 90.0f;
    p.segments   = 4;
    p.axis       = 1;   // Y is the plane normal; Y coord of all verts = cenY
    buildArc(&m, p);
    foreach (v; m.vertices) {
        import std.math : fabs;
        assert(fabs(v.y - 2.0f) < 1e-5f,
            "off-centre: vert Y != cenY=2, got " ~ v.y.stringof);
        float dx = v.x - 1.0f;
        float dz = v.z - (-3.0f);
        float r = sqrt(dx * dx + dz * dz);
        assert(fabs(r - 0.5f) < 1e-4f,
            "off-centre: vert not on radius=0.5");
    }
}
