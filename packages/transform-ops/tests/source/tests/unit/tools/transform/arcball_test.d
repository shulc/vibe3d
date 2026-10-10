// Module unittests for `tools.transform.arcball`, moved verbatim out of source/tools/transform/arcball.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.arcball_test;

import std.math : sqrt, atan2;
import math : Vec3, Viewport, cross, dot;
import std.math : PI, abs, sin, cos;
import tools.transform.arcball;

unittest {  // The world mapping, and the direction the model turns.
    import math : lookAt, normalize;
    Viewport vp;
    Vec3 eye = Vec3(0, 0, 5), focus = Vec3(0, 0, 0);
    vp.view = lookAt(eye, focus, Vec3(0, 1, 0));
    // Camera on +Z looking at the origin: screen right = +X, screen up = +Y,
    // out of screen = +Z.
    assert(arcballAxisToWorld(Vec3(1, 0, 0), vp).x > 0.999f);
    assert(arcballAxisToWorld(Vec3(0, 1, 0), vp).y > 0.999f);
    assert(arcballAxisToWorld(Vec3(0, 0, 1), vp).z > 0.999f);

    // A press at the centre dragged RIGHT must turn the face the viewer is
    // looking at TOWARD the right — the model follows the pointer. Take the
    // point nearest the eye and check it moves +x.
    Vec3 ax; float ang;
    assert(arcballRotation(0, 0, 100, 0, ARCBALL_RADIUS_PX, ax, ang));
    Vec3 axisW = arcballAxisToWorld(ax, vp);
    Vec3 p = Vec3(0, 0, 1);                       // on the near face
    import std.math : sin, cos;
    immutable float c = cos(ang), s = sin(ang);
    Vec3 rotated = p * c + cross(axisW, p) * s + axisW * (dot(axisW, p) * (1 - c));
    assert(rotated.x > 0.4f, "a rightward drag must carry the near face right");

    // …and a press OUTSIDE the ball, swept clockwise on screen, must turn the
    // model clockwise on screen: about the axis pointing INTO the screen.
    assert(arcballRotation(300, 0, 300, 300, ARCBALL_RADIUS_PX, ax, ang));
    Vec3 clockwise = arcballAxisToWorld(ax, vp);
    assert(clockwise.z < -0.999f,
           "a clockwise screen sweep turns about the INTO-screen axis");
}
