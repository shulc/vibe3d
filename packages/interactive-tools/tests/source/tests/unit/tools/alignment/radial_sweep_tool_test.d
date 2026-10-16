// Module unittests for `tools.alignment.radial_sweep_tool`, moved verbatim out of source/tools/alignment/radial_sweep_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.alignment.radial_sweep_tool_test;

import bindbc.opengl;
import bindbc.sdl;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import std.math : PI, abs, cos, sin;
import tool;
import vibe3d.mesh.core.mesh;
import math;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.params.params : Param, IntEnumEntry;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import shader : Shader, LitShader, drawLitPreview;
import handler : ToolHandles, BoxHandler, gizmoSize, drawThickLinesExt;
import drag : planeDragDelta, screenAxisDelta, gesturePrevPixel;
import vibe3d.platform.input.eventlog : queryMouse;
import std.conv : to;
import tools.alignment.radial_sweep_tool;

