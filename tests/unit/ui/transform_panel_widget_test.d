// The legacy (VIBE3D_FORMS=0) Tool-Properties panel of the transform tool,
// driven through its ACTUAL ImGui widgets — task 0870.
//
// This is the lane task 0801 did not have. That defect — the wrapped panel's
// slider wrote the sub-tool's accumulator while the apply re-read the wrapper's
// unchanged truth — lived two months behind two green gates, because no
// automatic path could touch an ImGui widget. It was found by reading, and
// proven only by a human at a keyboard under Xvfb.
//
// So the assertion here is deliberately the one a human made by hand:
//   ctrl+click the row, type an absolute value, press Enter, and look at the
//   MESH.
// Everything between the keystroke and the vertices is the shipped path —
// `XfrmTransformTool.drawProperties` → `ScaleTool.drawProperties` → the
// `DragFloat` → `applyScaleAbsoluteCpuOnly` → the wrapper's run-baseline apply.
// The harness supplies only what SDL would have supplied: a display size and an
// input queue (see tests/unit/ui/headless_panel.d).
//
// What it costs: one ImGui context and ~10 frames per gesture, no window, no GL,
// no display server.
module tests.unit.ui.transform_panel_widget_test;

import std.math : fabs;

import mesh : Mesh, GpuMesh, makeCube;
import editmode : EditMode;
import seltype : SelType;
import tools.transform.xfrm_transform : XfrmTransformTool;

import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;

// A wrapped transform tool in one bank — the `scale` / `rotate` factory flags
// from `registration.d`, minus the app-only wiring (undo history, gizmo host,
// item targets) a panel edit does not need. `activate()` back-links the
// sub-tools to the wrapper, so this rig is in the WRAPPED role: the one the
// legacy panel occupies in the shipped binary whenever VIBE3D_FORMS=0, and the
// only role 0801's defect lived in.
//
// Selection is left EMPTY on purpose: `mesh.selectedVertexIndices*` reports the
// whole mesh then, which is what a panel edit with nothing selected does in the
// editor, and it keeps the fixture free of selection plumbing.
//
// The rig is heap-allocated because the tool holds a `Mesh*` delegate over it.
private struct PanelRig {
    Mesh      mesh;
    GpuMesh   gpu;
    EditMode  editMode = EditMode.Vertices;
    XfrmTransformTool tool;
}

private PanelRig* makeRig(bool rotateBank) {
    auto rig = new PanelRig;
    rig.mesh = makeCube();
    rig.tool = new XfrmTransformTool(() => &rig.mesh, &rig.gpu, &rig.editMode,
                                     () => SelType.Vertex, null);
    rig.tool.flagT = false;
    rig.tool.flagR = rotateBank;
    rig.tool.flagS = !rotateBank;
    rig.tool.handleFamily = rotateBank ? 1 : 2;
    rig.tool.activate();
    return rig;
}

private PanelRig* makeScaleRig()  { return makeRig(false); }
private PanelRig* makeRotateRig() { return makeRig(true); }

// Widest |x| over the cube's 8 corners — the observable a human reads off
// /api/model after typing into the Scale X row.
private float halfWidthX(ref const Mesh m) {
    float w = 0;
    foreach (ref v; m.vertices) if (fabs(v.x) > w) w = fabs(v.x);
    return w;
}
private float halfWidthY(ref const Mesh m) {
    float w = 0;
    foreach (ref v; m.vertices) if (fabs(v.y) > w) w = fabs(v.y);
    return w;
}

unittest {
    // TYPING AN ABSOLUTE FACTOR INTO THE SCALE X ROW MOVES THE MESH.
    //
    // The 0801 reproduction, headless. Before the fix this went: field shows
    // 2.0000 while typing, snaps back to 1.0000 on the next frame, mesh
    // byte-identical. Both halves are asserted below, because the panel's
    // display field and the geometry failed TOGETHER and either alone would be
    // a weaker claim.
    auto rig = makeScaleRig();
    assert(fabs(halfWidthX(rig.mesh) - 0.5f) < 1e-5f, "cube fixture is not +/-0.5");

    auto ui = openPanel(() { rig.tool.drawProperties(); });
    scope (exit) ui.close();

    ui.frame();                 // layout frame: the harness learns the row pitch
    ui.editRow(0, "2.0");       // ctrl+click Scale X, type 2.0, Enter

    assert(fabs(halfWidthX(rig.mesh) - 1.0f) < 1e-4f,
           "typing 2.0 into the Scale X row must scale the mesh in X: expected "
         ~ "half-width 1.0, got a mesh the widget never reached");
    assert(fabs(halfWidthY(rig.mesh) - 0.5f) < 1e-4f,
           "the Scale X row must not touch Y");
    assert(fabs(rig.tool.publishedScale().x - 2.0f) < 1e-4f,
           "the row must still read the typed value on the next frame — a panel "
         ~ "that re-seeds from an unchanged truth snaps back to 1.0000");
}

unittest {
    // THE SAME ROW, DRAGGED. A drag is the other half of the widget's contract
    // (`IsItemActive` per frame, rather than one `IsItemDeactivatedAfterEdit`),
    // and it is the arm the run-absolute apply reaches most often.
    //
    // DragFloat accumulates MouseDelta.x * v_speed, and the Scale rows are
    // declared with v_speed 0.01 — so 100 px right is +1.00 on the factor.
    auto rig = makeScaleRig();
    auto ui = openPanel(() { rig.tool.drawProperties(); });
    scope (exit) ui.close();

    ui.frame();
    ui.dragRow(0, 100.0f);

    assert(fabs(rig.tool.publishedScale().x - 2.0f) < 1e-3f,
           "a 100px drag at v_speed 0.01 must publish Scale X = 2.0, got "
         ~ "a factor the drag never reached");
    assert(fabs(halfWidthX(rig.mesh) - 1.0f) < 1e-3f,
           "the dragged Scale X factor must reach the mesh");
}

unittest {
    // THE ROTATE BANK'S ROWS, same shape. 0801 broke Rotate and Scale
    // together (one seam, two callers); a lane that pins only one of them
    // would have gone green on half the defect.
    //
    // Typing 90 into Rotate X turns the cube about the world X axis, so each
    // corner maps (x, y, z) -> (x, -z, y).
    //
    // The assertion MUST be per index. A +/-0.5 cube rotated 90 degrees is
    // still a +/-0.5 cube — every bbox, extent and coordinate-set reading of
    // this mesh is IDENTICAL before and after, and an assertion written on one
    // of those passes just as happily on a rotation that never happened.
    // (It did, while this test was being written.)
    auto rig = makeRotateRig();
    auto before = rig.mesh.vertices.dup;
    auto ui = openPanel(() { rig.tool.drawProperties(); });
    scope (exit) ui.close();

    ui.frame();
    ui.editRow(0, "90");

    assert(fabs(rig.tool.publishedRotate().x - 90.0f) < 1e-3f,
           "the Rotate X row must publish the typed 90 degrees");

    foreach (i, ref v; rig.mesh.vertices) {
        assert(fabs(v.x -  before[i].x) < 1e-4f
            && fabs(v.y - -before[i].z) < 1e-4f
            && fabs(v.z -  before[i].y) < 1e-4f,
               "typing 90 into the Rotate X row must turn the mesh about X: "
             ~ "vertex " ~ itoa(i) ~ " did not land at (x, -z, y)");
    }
}

// Assertion messages are built at failure time from a mutable index; keep the
// conversion local rather than importing std.conv into the fixture.
private string itoa(size_t i) {
    import std.conv : to;
    return i.to!string;
}
