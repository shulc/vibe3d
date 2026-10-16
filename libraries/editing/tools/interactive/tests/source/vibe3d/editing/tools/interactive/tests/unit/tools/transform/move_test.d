// Module unittests for `tools.transform.move`, moved verbatim out of source/tools/transform/move.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.tools.interactive.tests.unit.tools.transform.move_test;

import bindbc.opengl;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import bindbc.sdl;
import vibe3d.editing.tools.interactive.tools.transform.transform;
import vibe3d.editing.tools.interactive.handler;
import vibe3d.viewport.display_policy.viewport_scheme : schemeColor, SchemeColor;
import vibe3d.mesh.core.mesh;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.contracts.seltype : SelType;
import vibe3d.util.math.math;
import vibe3d.viewport.gpu.shader;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import std.math;
import vibe3d.editing.tools.interactive.drag;
import vibe3d.editing.tools.interactive.coord_rounding : coordRounding, coordRoundingFixedIncrement;
import vibe3d.editing.selection.query.snap : snapCursor, SnapResult;
import vibe3d.editing.tools.interactive.snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import vibe3d.documents.model.document : primaryModelSpace;
import vibe3d.editing.tools.interactive.falloff_handles : screenFalloffActive, screenFalloffSetCenter, screenFalloffLMBBegin;
import vibe3d.editing.tools.interactive.tools.transform.move;

