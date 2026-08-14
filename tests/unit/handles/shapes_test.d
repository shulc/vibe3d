// Module unittests for `handles.shapes`, moved verbatim out of source/handles/shapes.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.handles.shapes_test;

import handles.gl_util;
import math;
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import shader;
import viewport_scheme;
import bindbc.sdl;
import bindbc.opengl;
import std.math : sin, cos, sqrt, PI, abs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import ai.interaction : AiIntent;
import handles.shapes;

