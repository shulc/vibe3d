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
