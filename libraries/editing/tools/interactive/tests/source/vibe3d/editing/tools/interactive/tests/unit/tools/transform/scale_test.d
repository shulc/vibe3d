// Module unittests for `tools.transform.scale`, moved verbatim out of source/tools/transform/scale.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.tools.interactive.tests.unit.tools.transform.scale_test;

import bindbc.opengl;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import bindbc.sdl;
import sdl.stdinc : SDL_FALSE, SDL_TRUE, SDL_bool;
import vibe3d.editing.tools.interactive.tools.transform.transform;
import vibe3d.editing.tools.interactive.handler;
import vibe3d.mesh.core.mesh;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.contracts.seltype : SelType;
import vibe3d.util.math.math;
import vibe3d.viewport.gpu.shader;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : FalloffPacket;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math : sqrt;
import vibe3d.editing.selection.query.snap : SnapResult;
import vibe3d.editing.tools.interactive.snap_render : drawSnapOverlay, clearLastSnap;
import vibe3d.editing.pipeline.runtime.falloff : evaluateFalloff;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : FalloffPacket, SnapPacket, SymmetryPacket;
import vibe3d.editing.params.params : Param;
import vibe3d.editing.tools.interactive.falloff_handles : screenFalloffActive, screenFalloffSetCenter, screenFalloffLMBBegin;
import vibe3d.editing.tools.interactive.tools.transform.scale;

