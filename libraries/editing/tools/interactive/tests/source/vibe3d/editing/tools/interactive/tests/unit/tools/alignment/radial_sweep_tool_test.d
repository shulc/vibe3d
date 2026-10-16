// Module unittests for `tools.alignment.radial_sweep_tool`, moved verbatim out of source/tools/alignment/radial_sweep_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.tools.interactive.tests.unit.tools.alignment.radial_sweep_tool_test;

import bindbc.opengl;
import bindbc.sdl;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import std.math : PI, abs, cos, sin;
import vibe3d.editing.tools.interactive.tool;
import vibe3d.mesh.core.mesh;
import vibe3d.util.math.math;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.params.params : Param, IntEnumEntry;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import vibe3d.viewport.gpu.shader : Shader, LitShader, drawLitPreview;
import vibe3d.editing.tools.interactive.handler : ToolHandles, BoxHandler, gizmoSize, drawThickLinesExt;
import vibe3d.editing.tools.interactive.drag : planeDragDelta, screenAxisDelta, gesturePrevPixel;
import vibe3d.platform.input.eventlog : queryMouse;
import std.conv : to;
import vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool;

