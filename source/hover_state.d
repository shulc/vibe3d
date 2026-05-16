module hover_state;

/// Cross-module hover state. app.d's pickVertices / pickEdges /
/// pickFaces write the GPU-resolved hovered element indices here
/// after each motion frame; consumers (currently
/// ElementMoveTool.tryPickElement) read them to keep click-pick
/// aligned with hover-highlight. Without sharing this state the CPU-
/// centroid pickFace in element_move.d disagrees with the GPU ID-
/// buffer hover on overlapping projections — user sees one polygon
/// highlight but the drag lands on a different (hidden) polygon
/// behind it.
///
/// Values are -1 when no element of that type is currently hovered.
__gshared int g_hoveredVertex = -1;
__gshared int g_hoveredEdge   = -1;
__gshared int g_hoveredFace   = -1;
