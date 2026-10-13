// Module unittests for `tools.alignment.radial_sweep_tool`, moved verbatim out of source/tools/alignment/radial_sweep_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.alignment.radial_sweep_tool_test;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import std.math : PI, abs, cos, sin;
import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import shader : Shader, LitShader, drawLitPreview;
import handler : ToolHandles, BoxHandler, gizmoSize, drawThickLinesExt;
import drag : planeDragDelta, screenAxisDelta, gesturePrevPixel;
import eventlog : queryMouse;
import std.conv : to;
import tools.alignment.radial_sweep_tool;

