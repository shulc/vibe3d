// Module unittests for `handles.shapes`, moved verbatim out of source/handles/shapes.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.tools.interactive.tests.unit.handles.shapes_test;

import vibe3d.editing.tools.interactive.handles.gl_util;
import vibe3d.util.math.math;
import vibe3d.util.profiling.perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import vibe3d.viewport.gpu.shader;
import vibe3d.viewport.display_policy.viewport_scheme;
import bindbc.sdl;
import bindbc.opengl;
import std.math : sin, cos, sqrt, PI, abs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import vibe3d.editing.interaction.data.ai.interaction : AiIntent;
import vibe3d.editing.tools.interactive.handles.shapes;

