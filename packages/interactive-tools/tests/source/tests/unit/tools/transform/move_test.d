// Module unittests for `tools.transform.move`, moved verbatim out of source/tools/transform/move.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.move_test;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import tools.transform.transform;
import handler;
import viewport_scheme : schemeColor, SchemeColor;
import mesh;
import editmode;
import seltype : SelType;
import math;
import shader;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math;
import drag;
import coord_rounding : coordRounding, coordRoundingFixedIncrement;
import snap : snapCursor, SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import document : primaryModelSpace;
import falloff_handles : screenFalloffActive, screenFalloffSetCenter, screenFalloffLMBBegin;
import tools.transform.move;

