// Module unittests for `commands.workplane`, moved verbatim out of source/commands/workplane.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.commands.workplane_test;

import std.math : isNaN, sqrt;
import std.json : JSONValue, JSONType;
import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.pipeline.contracts.operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import vibe3d.mesh.core.mesh    : Mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.util.math.math     : Vec3, dot, cross, normalize;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : g_pipeCtx;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.workplane : WorkplaneStage;
import vibe3d.apps.desktop.commands.workplane;

unittest {
    // Right-handed basis check. Given (normal, axis2), reconstruct axis1
    // the same way apply() does and verify the triple is right-handed
    // and orthonormal.
    import std.math : abs;
    Vec3 normal = normalize(Vec3(0.3f, 1.0f, 0.4f));
    Vec3 raw    = Vec3(2, 0, 0);     // some in-plane edge (will be projected)
    Vec3 axis2  = normalize(raw - normal * dot(raw, normal));
    Vec3 axis1  = normalize(cross(normal, axis2));
    Vec3 axis2b = normalize(cross(axis1, normal));

    // Orthogonality.
    assert(abs(dot(axis1, normal)) < 1e-5f);
    assert(abs(dot(axis1, axis2b)) < 1e-5f);
    assert(abs(dot(normal, axis2b)) < 1e-5f);
    // Right-handed: axis1 × normal = axis2.
    Vec3 r = cross(axis1, normal);
    assert(abs(r.x - axis2b.x) < 1e-5f);
    assert(abs(r.y - axis2b.y) < 1e-5f);
    assert(abs(r.z - axis2b.z) < 1e-5f);
}
