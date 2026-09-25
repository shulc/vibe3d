module hover_state;

import editmode : EditMode;

/// Cross-module hover state. app.d's pickVertices / pickEdges /
/// pickFaces write the GPU-resolved hovered element indices here
/// after each motion frame; consumers (currently
/// XfrmTransformTool.tryPickElement when falloff.element is active)
/// read them to keep click-pick aligned with hover-highlight. The
/// GPU ID-buffer is the source of truth — any CPU-projected pick
/// can disagree on overlapping faces and pick a hidden polygon
/// while the user sees the front one highlighted.
///
/// Values are -1 when no element of that type is currently hovered.
__gshared int g_hoveredVertex = -1;
__gshared int g_hoveredEdge   = -1;
__gshared int g_hoveredFace   = -1;

/// True when the three indices above were HELD from an earlier frame because
/// the live subpatch preview's index space is stale
/// (`InputFrameState.previewIndexSpaceStale`): they then index the mesh as it
/// was before the last edit, not the current one. Written beside
/// `g_hoveredEdge` by exactly the two publishers of it (`FrameRunner.
/// resolveHover`, `InputRouter.refreshHoverPickAt`); a consumer that indexes
/// the current mesh with a held id must not act on it (task 7114;
/// tests/unit/hover_stale_writer_census_test.d pins the writers).
__gshared bool g_hoverIndexSpaceStale = false;

/// H7 (tool session model, slice M6): whether the viewport draws the element
/// under the cursor while a tool is armed. It is DATA — the rollover flag of
/// the tool's policy (`ToolSessionPolicy.rollovers`) and of the pipe stages it
/// runs with (`Stage.rollovers`), each from the captured flags table and the
/// C-H7 cells (`toolcards/tool_session_model/`, gap 309/310) — read by ONE
/// viewport path (`ui/viewport_render.d : rolloverShown`). WHICH elements are
/// hovered is a separate question, the tool's pick need
/// (`Tool.wantsHoverForType`): a tool that picks no type shows nothing
/// whatever its flag. No tool armed: the selection type decides, as before.
enum Rollover : ubyte {
    /// Nothing is drawn under the armed tool (C-H7: Slice, Edge Extend,
    /// Polygon Bevel, Move, vertex Bevel — 0 px).
    none,
    /// The hovered target outside a drag, live edit or not (Edge Slice keeps
    /// its target edge through a live chain, C-H7: 286 px).
    target,
    /// As `target`, but hidden while an edit is live — a vibe3d divergence,
    /// only for ids with no counterpart in the flags table.
    untilLive,
    /// Only a hovered VERTEX, outside a drag, in every selection mode: the
    /// element falloff's flag (C-H7-elem: Element Move 36 px on a vertex, 0 on
    /// an edge in edge and polygon mode).
    vertices,
}

/// The rule of one flag, as a pure function of the frame's facts.
bool rolloverDraws(Rollover r, EditMode type, bool dragging, bool live)
        pure nothrow @nogc @safe {
    final switch (r) {
        case Rollover.none:      return false;
        case Rollover.target:    return !dragging;
        case Rollover.untilLive: return !dragging && !live;
        case Rollover.vertices:  return !dragging && type == EditMode.Vertices;
    }
}

/// The ITEM under the cursor, as a `Document.layers` index (task 0647).
///
/// A different KIND of value from the three above and deliberately in the same
/// place: they index into the primary layer's geometry, this indexes the layer
/// array itself. Item-mode hover highlights the whole item under the cursor,
/// so the unit of the answer changes with the selection type, and a consumer
/// that read `g_hoveredFace` to find out which item is hot would be right only
/// while the document has one layer.
///
/// -1 when the current selection type is not Item, or when the cursor is over
/// empty space. Both are "nothing is hovered" and neither latches: the picker
/// clears this to -1 before every attempt, so a frame in which the ray misses
/// leaves no residue from the frame before it.
__gshared int g_hoveredItem = -1;
