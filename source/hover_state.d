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
