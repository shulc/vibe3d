// Module unittests for `tools.transform.rotate`, moved verbatim out of source/tools/transform/rotate.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.rotate_test;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;
import tools.transform.transform;
import handler;
import mesh;
import editmode;
import seltype : SelType;
import math;
import shader;
import toolpipe.packets : FalloffPacket;
import std.math;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import tools.transform.arcball : ARCBALL_RADIUS_PX, arcballRotation,
                                 arcballAxisToWorld;
import snap : SnapResult;
import snap_render : drawSnapOverlay, clearLastSnap;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;
import params : Param;
import falloff_handles : screenFalloffActive, screenFalloffSetCenter, screenFalloffLMBBegin;
import tools.transform.rotate;

