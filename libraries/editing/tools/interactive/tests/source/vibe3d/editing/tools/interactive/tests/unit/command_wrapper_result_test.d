module vibe3d.editing.tools.interactive.tests.unit.command_wrapper_result_test;

import vibe3d.mesh.change.change_bus : changeBus;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.editing.commands.editor.commands.mesh.vertex_edit : MeshVertexEdit;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.mesh.core.mesh : Mesh, makeCube;
import vibe3d.editing.tools.interactive.tools.common.command_wrapper : XfrmQuantizeTool;
import vibe3d.viewport.camera.view : View;

private void setStep(XfrmQuantizeTool tool, float value) {
    foreach (ref p; tool.params())
        if (p.name == "X" || p.name == "Y" || p.name == "Z")
            *p.fptr = value;
}

// Task 4580: constructing the refire carrier is a read-only operation on the
// live mesh. The returned sparse payload is also independently non-empty, so
// zero bus movement cannot be explained by an inert/no-op fixture.
unittest {
    Mesh mesh = makeCube();
    mesh.buildLoops();
    View view = new View(0, 0, 800, 600);
    auto history = new CommandHistory;
    auto tool = new XfrmQuantizeTool(&mesh, view, EditMode.Vertices, null);
    tool.setGestureBindings(history,
        () => new MeshVertexEdit(&mesh, view, EditMode.Vertices));
    tool.activate();
    setStep(tool, 0.3f);

    const liveBefore = mesh.vertices.dup;
    const mutationBefore = mesh.mutationVersion;
    const deliveriesBefore = changeBus.deliveryCount;
    const positionsBefore = changeBus.totalPosition;

    auto edit = cast(MeshVertexEdit)tool.buildRefireCommand();

    assert(edit !is null && edit.editIndices.length == mesh.vertices.length,
        "control: the Quantize result must contain every moved cube vertex");
    assert(mesh.vertices == liveBefore,
        "refire builder changed live vertices while only constructing a command");
    assert(changeBus.deliveryCount == deliveriesBefore &&
           changeBus.totalPosition == positionsBefore,
        "refire builder published Position while only constructing a command");
    assert(mesh.mutationVersion == mutationBefore,
        "refire builder advanced the live mesh mutation stamp");

    setStep(tool, 0.0f);
    auto refused = tool.buildRefireCommand();
    assert(refused is null, "invalid Quantize steps must refuse result construction");
    assert(mesh.vertices == liveBefore && mesh.mutationVersion == mutationBefore,
        "failed result construction must leave the live mesh untouched");
    assert(changeBus.deliveryCount == deliveriesBefore &&
           changeBus.totalPosition == positionsBefore,
        "failed result construction must publish no Position change");
}
