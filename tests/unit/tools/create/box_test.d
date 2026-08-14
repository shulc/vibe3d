// Module unittests for `tools.create.box`, moved verbatim out of source/tools/create/box.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.create.box_test;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import tool;
import edit_session : KeepAliveOnCancel;
import mesh;
import math;
import handler : MoveHandler, BoxHandler, getGizmoPixels, gizmoSize, ToolHandles;
import viewport_scheme : axisColor, schemeColor, SchemeColor;
import eventlog : queryMouse;
import drag;
import shader : Shader, LitShader, drawLitPreview;
import command : Command, CmdFlags;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import tools.create.create_common : pickWorkplane, BuildPlane,
                              pickWorkplaneFrame, WorkplaneFrame,
                              currentWorkplaneFrame, mostFacingAxis,
                              transformPoint, transformDir, snapLocalHit,
                              frameIsLeftHanded, reverseFaceWinding,
                              workplaneCursorPlaneHit;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import params : Param;
import view : View;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math : abs, sqrt, sin, cos, PI;
import tools.create.box;

// ---------------------------------------------------------------------------
// unittest: winding correctness — each face's normal points away from center.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    import std.conv : to;

    // Default unit cube — 8 verts / 6 faces.
    {
        Mesh m;
        BoxParams p;  // defaults: 1x1x1 at origin, 1 segment
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 8,  "default: expected 8 verts");
        assert(m.faces.length    == 6,  "default: expected 6 faces");

        Vec3 cen = Vec3(0, 0, 0);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 n  = m.faceNormal(fi);
            // Compute face centroid
            Vec3 fc = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / m.faces[fi].length);
            float d = dot(n, fc - cen);
            assert(d > 0.0f, "face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // 2/2/2 segments — 26 verts / 24 faces.
    {
        Mesh m;
        BoxParams p;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 26, "2/2/2: expected 26 verts");
        assert(m.faces.length    == 24, "2/2/2: expected 24 faces");

        Vec3 cen = Vec3(0, 0, 0);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 n  = m.faceNormal(fi);
            Vec3 fc = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / m.faces[fi].length);
            float d = dot(n, fc - cen);
            assert(d > 0.0f, "2/2/2 face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // sizeY=0 → XZ plane, 4 verts / 1 face.
    {
        Mesh m;
        BoxParams p;
        p.sizeY = 0.0f;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 4, "plane: expected 4 verts");
        assert(m.faces.length    == 1, "plane: expected 1 face");
    }

    // Non-uniform segments 3/1/2 — faces = 2*(3+1*3+3*2) nope, count properly:
    // -X face: ny*nz = 1*2 = 2; +X: 2; -Y: nx*nz = 3*2 = 6; +Y: 6; -Z: nx*ny = 3*1 = 3; +Z: 3
    // Total = 2+2+6+6+3+3 = 22
    {
        Mesh m;
        BoxParams p;
        p.segmentsX = 3; p.segmentsY = 1; p.segmentsZ = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.faces.length == 22, "3/1/2: expected 22 faces");
    }

    // Rounded cube topology — segments=1,1,1 baseline (verts=8(n²+n+1)).
    // All faces must have outward normals (dot(normal, centroid - origin) > 0).
    foreach (n; [1, 2, 3, 4]) {
        Mesh m;
        BoxParams p;
        p.radius    = 0.1f;
        p.segmentsR = n;
        p.axis      = 1;  // Y-primary
        buildCuboidParametric(&m, p);
        m.buildLoops();

        size_t expectedVerts = 8 * (n * n + n + 1);
        size_t expectedFaces = 8 * n * n + 12 * n + 6;
        import std.conv : to;
        assert(m.vertices.length == expectedVerts,
               "rounded n=" ~ n.to!string ~ ": expected " ~ expectedVerts.to!string
               ~ " verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length == expectedFaces,
               "rounded n=" ~ n.to!string ~ ": expected " ~ expectedFaces.to!string
               ~ " faces, got " ~ m.faces.length.to!string);

        // All face normals must point outward (away from cube center).
        Vec3 cen = Vec3(p.cenX, p.cenY, p.cenZ);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            Vec3 fc  = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / cast(float)m.faces[fi].length);
            float d = dot(fn_, fc - cen);
            assert(d > 0.0f, "rounded n=" ~ n.to!string
                   ~ " face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // Rounded cube with segments > 1 — topology counts (Phase 6.1c).
    // Formula: ring_size = 2*(nx+1)+2*(nz+1)+4*(sR-1)
    //          verts = 2*(nx+1)*(nz+1) + (2*sR + ny-1) * ring_size
    import std.conv : to;
    {
        // (2,1,1) sR=1: 32v/34f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.segmentsX = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 32, "rounded (2,1,1) sR=1: expected 32 verts, got " ~ m.vertices.length.to!string);
    }
    {
        // (2,2,2) sR=1: 54v/56f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 54, "rounded (2,2,2) sR=1: expected 54 verts, got " ~ m.vertices.length.to!string);
    }
    {
        // (2,2,2) sR=2: 98v/104f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 2;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 98, "rounded (2,2,2) sR=2: expected 98 verts, got " ~ m.vertices.length.to!string);
    }
    {
        // (3,3,3) sR=1: 96v/98f
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1;
        p.segmentsX = 3; p.segmentsY = 3; p.segmentsZ = 3;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 96, "rounded (3,3,3) sR=1: expected 96 verts, got " ~ m.vertices.length.to!string);
    }
    // All face normals outward for rounded segments case.
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 2;
        p.segmentsX = 2; p.segmentsY = 2; p.segmentsZ = 2;
        p.axis = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        Vec3 cen = Vec3(0, 0, 0);
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            Vec3 fc  = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / cast(float)m.faces[fi].length);
            float d = dot(fn_, fc - cen);
            assert(d > 0.0f, "rounded (2,2,2) sR=2 face " ~ fi.to!string ~ " has inward/degenerate normal");
        }
    }

    // ---------------------------------------------------------------------------
    // Rounded plane topology — counts (Phase 6.1d).
    // Formula: verts = ringSize + (segAe+1)*(segBe+1)
    //          where ringSize = 2*(segAe+1) + 2*(segBe+1) + 4*(sR-1)
    //          faces = segAe*segBe + 2*segAe + 2*segBe + 4*sR
    // ---------------------------------------------------------------------------

    // Helper: check all face normals point toward the given outward direction.
    void checkPlaneNormals(ref Mesh m, Vec3 outwardDir, string tag) {
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            float d = dot(fn_, outwardDir);
            assert(d > 0.0f, tag ~ ": face " ~ fi.to!string ~ " has wrong normal");
        }
    }

    // XZ plane (sizeY=0), sR=1, seg=(1,1) → 12v/9f
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 12, "rounded plane XZ sR=1 seg(1,1): expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    ==  9, "rounded plane XZ sR=1 seg(1,1): expected 9 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=1 seg(1,1)");
    }

    // XZ plane, sR=2, seg=(1,1) → 16v/13f
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 16, "rounded plane XZ sR=2 seg(1,1): expected 16 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 13, "rounded plane XZ sR=2 seg(1,1): expected 13 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=2 seg(1,1)");
    }

    // XZ plane, sR=1, seg=(2,1,2) → 21v/16f
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        p.segmentsX = 2; p.segmentsZ = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 21, "rounded plane XZ sR=1 seg(2,2): expected 21 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 16, "rounded plane XZ sR=1 seg(2,2): expected 16 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=1 seg(2,2)");
    }

    // YZ plane (sizeX=0), sR=1, seg=(1,1) → 12v/9f, outward=+X
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 0.0f; p.sizeY = 1.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 12, "rounded plane YZ sR=1 seg(1,1): expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    ==  9, "rounded plane YZ sR=1 seg(1,1): expected 9 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(1, 0, 0), "YZ sR=1 seg(1,1)");
    }

    // XY plane (sizeZ=0), sR=1, seg=(1,1) → 12v/9f, outward=+Z
    {
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 1.0f; p.sizeZ = 0.0f;
        p.radius = 0.1f; p.segmentsR = 1;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 12, "rounded plane XY sR=1 seg(1,1): expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    ==  9, "rounded plane XY sR=1 seg(1,1): expected 9 faces, got "  ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 0, 1), "XY sR=1 seg(1,1)");
    }

    // General topology formula check: faces = segAe*segBe + 2*segAe + 2*segBe + 4*sR
    // verts = 2*(segAe+1)+2*(segBe+1)+4*(sR-1) + (segAe+1)*(segBe+1)
    {
        // XZ plane, sR=3, seg=(2,1,3): segAe=2, segBe=3
        Mesh m;
        BoxParams p;
        p.sizeX = 1.0f; p.sizeY = 0.0f; p.sizeZ = 1.0f;
        p.radius = 0.1f; p.segmentsR = 3;
        p.segmentsX = 2; p.segmentsZ = 3;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        int segAe = 2, segBe = 3, sR3 = 3;
        size_t expV = 2*(segAe+1)+2*(segBe+1)+4*(sR3-1) + (segAe+1)*(segBe+1);
        size_t expF = segAe*segBe + 2*segAe + 2*segBe + 4*sR3;
        assert(m.vertices.length == expV, "rounded plane formula verts: expected " ~ expV.to!string ~ " got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == expF, "rounded plane formula faces: expected " ~ expF.to!string ~ " got " ~ m.faces.length.to!string);
        checkPlaneNormals(m, Vec3(0, 1, 0), "XZ sR=3 seg(2,3)");
    }

    // ---------------------------------------------------------------------------
    // Phase 6.1c: sharp rounded cube — vertex/face counts.
    // Formula:
    //   rs_sharp   = 2*(nx+1) + 2*(nz+1) + 4*(n+1)
    //   rings_half = n+2
    //   total_verts = 2*(nx+1)*(nz+1) + 2*(n+2)*rs_sharp
    //   (deduplication means equatorial ring is not double-counted — same verts)
    //
    //   Verified counts: sR=1→104v/114f, sR=2→168v/182f, sR=3→248v/266f
    // ---------------------------------------------------------------------------

    // Helper: count faces with outward normal (for sharp checks that tolerate
    // the flat cap-level corner triangles which intentionally have +Y/-Y normals
    // these boundary triangles lie on the cap plane).
    int countOutwardFaces(ref Mesh m, Vec3 cen = Vec3(0,0,0)) {
        int ok = 0;
        foreach (fi; 0 .. cast(uint)m.faces.length) {
            Vec3 fn_ = m.faceNormal(fi);
            Vec3 fc  = Vec3(0, 0, 0);
            foreach (vi; m.faces[fi]) fc = fc + m.vertices[vi];
            fc = fc * (1.0f / cast(float)m.faces[fi].length);
            if (dot(fn_, fc - cen) > 0.0f) ++ok;
        }
        return ok;
    }

    // sR=1 sharp: 104v / 114f
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.sharp = true;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 104, "sharp sR=1: expected 104 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 114, "sharp sR=1: expected 114 faces, got " ~ m.faces.length.to!string);
        // Majority of faces should have outward normals; a few flat cap-boundary
        // corner triangles may not (same topology, same winding).
        int ok = countOutwardFaces(m);
        assert(ok >= 106, "sharp sR=1: too few outward faces: " ~ ok.to!string ~ "/114");
    }

    // sR=2 sharp: 168v / 182f
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 2; p.sharp = true;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 168, "sharp sR=2: expected 168 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 182, "sharp sR=2: expected 182 faces, got " ~ m.faces.length.to!string);
        int ok = countOutwardFaces(m);
        assert(ok >= 170, "sharp sR=2: too few outward faces: " ~ ok.to!string ~ "/182");
    }

    // sR=3 sharp: 248v / 266f
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 3; p.sharp = true;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 248, "sharp sR=3: expected 248 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 266, "sharp sR=3: expected 266 faces, got " ~ m.faces.length.to!string);
        int ok = countOutwardFaces(m);
        assert(ok >= 254, "sharp sR=3: too few outward faces: " ~ ok.to!string ~ "/266");
    }

    // Axis swap: sharp sR=1 axis=0 (X-primary) — same counts as Y-primary.
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.sharp = true; p.axis = 0;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 104, "sharp sR=1 axis=X: expected 104 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 114, "sharp sR=1 axis=X: expected 114 faces, got " ~ m.faces.length.to!string);
    }

    // Axis swap: sharp sR=1 axis=2 (Z-primary).
    {
        Mesh m;
        BoxParams p;
        p.radius = 0.1f; p.segmentsR = 1; p.sharp = true; p.axis = 2;
        buildCuboidParametric(&m, p);
        m.buildLoops();
        assert(m.vertices.length == 104, "sharp sR=1 axis=Z: expected 104 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length    == 114, "sharp sR=1 axis=Z: expected 114 faces, got " ~ m.faces.length.to!string);
    }
}
