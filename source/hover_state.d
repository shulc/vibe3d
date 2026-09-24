module hover_state;

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

/// A tool whose target-edge highlight stays drawn through its live edit
/// outside a drag; the viewport otherwise hides the hover while the tool has an
/// uncommitted edit. A display capability, discovered by cast (Edge Slice:
/// a measured law; the rationale sits at its one reader, ui/viewport_render.d).
interface TargetHighlightKeeper {}

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
