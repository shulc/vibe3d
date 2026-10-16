module vibe3d.editing.commands.runtime.tests.unit.commands.mesh.session_edit_source_public_test;

import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditDelta, MeshEditScope;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;

// ---------------------------------------------------------------------------
// wireName / label / editScope round-trip — no snapshots involved; this unit
// test only pins the per-caller metadata contract the ctor establishes.
//
// The old form of this banner claimed evaluate()/revert() "need a real
// GL-backed GpuMesh to be meaningful and are exercised by the HTTP suite
// instead". That was false and it actively discouraged the next reader from
// covering them: neither touches GL — `MeshSnapshot.restore` is pure data
// plus `buildLoops`/`resizeAllMeshMaps`/`commitChange`. They are covered
// CPU-only in `packages/command-runtime/tests/source/tests/unit/session_edit_payload_test.d` (task 1552).
// ---------------------------------------------------------------------------


unittest {
    import vibe3d.mesh.core.mesh      : Mesh;
    import vibe3d.viewport.camera.view       : View;
    import vibe3d.editing.contracts.editmode   : EditMode;

    Mesh mesh;
    View view = new View(0, 0, 1, 1);

    // Plain form (editScope omitted): matches array/bevel/clone/loop_slice/
    // reduce/smooth_shift — no override before the merge, so the base
    // Command.editScope() default (None) must still come through.
    auto plain = new MeshSessionEdit(&mesh, view, EditMode.Vertices,
                                      "mesh.bevel_edit", "Bevel");
    assert(plain.name()  == "mesh.bevel_edit");
    assert(plain.label() == "Bevel", "label falls back to defaultLabel before setSnapshots");
    assert(plain.editScope() == MeshEditScope.None);
    assert(plain.isOperationInverse() == false);

    // setSnapshots's own label argument overrides the ctor default, exactly
    // as the per-class `setSnapshots(before_, after_, string label_ = "X")`
    // did — every real caller passes an explicit label (grep confirms none
    // rely on the old per-class default), so only the override path matters.
    MeshSnapshot dummy;
    plain.setSnapshots(dummy, dummy, "Custom Label");
    assert(plain.label() == "Custom Label");

    // Union form (editScope supplied): matches edge_extrude/edge_extend/
    // face_extrude/radial_array/stroke_extrude.
    auto scoped = new MeshSessionEdit(&mesh, view, EditMode.Vertices,
                                       "mesh.edge_extrude_edit", "Edge Extrude",
                                       MeshEditScope.Geometry | MeshEditScope.Marks);
    assert(scoped.name()      == "mesh.edge_extrude_edit");
    assert(scoped.label()     == "Edge Extrude");
    assert(scoped.editScope() == (MeshEditScope.Geometry | MeshEditScope.Marks));
    assert(scoped.isOperationInverse() == false, "false until setDelta is called");

    // setDelta flips isOperationInverse() and (like setSnapshots) installs
    // its own label — mirrors edge_extrude_edit.d's original setDelta().
    MeshEditDelta delta;
    scoped.setDelta(delta, "Edge Extrude (delta)");
    assert(scoped.isOperationInverse() == true);
    assert(scoped.label() == "Edge Extrude (delta)");

    // The irregular stroke_extrude wire name is a real (if inconsistent)
    // pre-existing quirk — camelCase "strokeExtrude" instead of the
    // snake_case every sibling uses. Preserved byte-for-byte, not
    // normalized, since undo history / replay dispatch on it.
    auto stroke = new MeshSessionEdit(&mesh, view, EditMode.Vertices,
                                       "mesh.strokeExtrude_edit", "Stroke Extrude",
                                       MeshEditScope.Geometry | MeshEditScope.Marks);
    assert(stroke.name() == "mesh.strokeExtrude_edit");
}
