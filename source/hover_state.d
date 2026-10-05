module hover_state;

import input_frame_state : InputFrameState;


/// Cross-module hover state. `publishHover` writes the GPU-resolved
/// hovered element indices here after each frame's pick and at a
/// press's re-pick; a press reads them through `hoverAtPress` to keep
/// click-pick aligned with hover-highlight. The
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
/// was before the last edit, not the current one. Written beside them by
/// `publishHover` alone; a PRESS reads through `hoverAtPress` (task 7114,
/// 9439; tests/unit/hover_stale_writer_census_test.d pins both).
__gshared bool g_hoverIndexSpaceStale = false;

struct HoverIds { int vertex = -1, edge = -1, face = -1; }

/// The ONE press-time hover read: a press never acts on a stale index space,
/// so while the ids are held it answers "nothing hovered". Draw and report
/// readers keep the held globals (the hover draw holds, no flicker).
HoverIds hoverAtPress() {
    if (g_hoverIndexSpaceStale) return HoverIds.init;
    return HoverIds(g_hoveredVertex, g_hoveredEdge, g_hoveredFace);
}

/// The ONE hover publish, for the frame and the press-time re-pick: the
/// candidates see the raw picks; an active tool keeps one type (V > E > F,
/// written back into `ifs`); the globals copy `ifs`, held ids included.
void publishHover(InputFrameState ifs, bool toolActive, int mx, int my) {
    import ai.element_candidates : publishElementCandidates;
    publishElementCandidates(mx, my, ifs.hoveredVertex, ifs.hoveredEdge, ifs.hoveredFace);
    if (toolActive) {
        if (ifs.hoveredVertex >= 0) ifs.hoveredEdge = ifs.hoveredFace = -1;
        else if (ifs.hoveredEdge >= 0) ifs.hoveredFace = -1;
    }
    g_hoveredVertex = ifs.hoveredVertex;
    g_hoveredEdge   = ifs.hoveredEdge;
    g_hoveredFace   = ifs.hoveredFace;
    g_hoverIndexSpaceStale = ifs.previewIndexSpaceStale();
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
