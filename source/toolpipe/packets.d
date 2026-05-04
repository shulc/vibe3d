module toolpipe.packets;

import math : Vec3;
import mesh : Mesh;
import editmode : EditMode;

// ---------------------------------------------------------------------------
// Packet types — the wire format between Tool Pipe stages.
//
// Names mirror MODO's LXsP_TOOL_* string IDs (lxtool.h) so future SDK /
// Python bridging is direct: `LXsP_TOOL_SUBJECT` → `SubjectPacket`,
// `LXsP_TOOL_ACTCENTER` → `ActionCenterPacket`, etc.
//
// Phase 7.0 ships only the SubjectPacket (constructed at pipe entry from
// the current scene state). The remaining packet types are stubbed here
// with the fields each later subphase needs, so the ToolState struct
// shape is stable and 7.1+ subphases just populate values without
// rearranging the layout.
// ---------------------------------------------------------------------------

/// LXsP_TOOL_SUBJECT — mesh + selection + edit mode at pipe entry.
/// Read-only snapshot; stages must not mutate the scene mesh through this
/// pointer (use the regular Mesh* path with snapshot/undo as elsewhere).
struct SubjectPacket {
    Mesh*      mesh;
    EditMode   editMode;
    // Snapshot of selection-bit arrays at evaluation time. Useful for
    // stages that compute selection-derived values (Action Center
    // "selection center", Falloff "lasso") without re-reading the mesh's
    // arrays mid-pipe.
    bool[]     selectedVertices;
    bool[]     selectedEdges;
    bool[]     selectedFaces;
}

/// LXsP_TOOL_ACTCENTER — the action origin produced by ACEN stage in 7.2.
/// Default = world origin so 7.0 callers see a sane value if they read
/// it before any ACEN stage is registered.
struct ActionCenterPacket {
    Vec3 center = Vec3(0, 0, 0);
    // Whether this center is "auto" (recomputes on selection change) or
    // "manual" (sticky until user moves it). Maps to MODO's A column in
    // the Tool Pipe panel.
    bool isAuto = true;
}

/// LXsP_TOOL_AXIS — orientation produced by AXIS stage in 7.2.
/// Default = world axes (right=+X, up=+Y, fwd=+Z).
struct AxisPacket {
    Vec3 right = Vec3(1, 0, 0);
    Vec3 up    = Vec3(0, 1, 0);
    Vec3 fwd   = Vec3(0, 0, 1);
    bool isAuto = true;
}

/// Workplane state — produced by WORK stage in 7.1. Default = world XZ
/// plane (normal = +Y, axis1 = +X, axis2 = +Z), matching the Y-up
/// convention. A stage choosing the most-camera-facing plane (which
/// today's BoxTool / Pen / etc. do via `pickMostFacingPlane`) overrides
/// these fields.
struct WorkplanePacket {
    Vec3 normal = Vec3(0, 1, 0);
    Vec3 axis1  = Vec3(1, 0, 0);
    Vec3 axis2  = Vec3(0, 0, 1);
    bool isAuto = true;
}

/// LXsP_TOOL_FALLOFF — soft-selection weight, populated by WGHT stage in
/// 7.5. Stored as a delegate the stage hands back to the actor; default
/// returns 1.0 for every vertex (rigid transform — current behaviour).
alias FalloffWeightFn = float delegate(Vec3 worldPos, uint vertIdx);

struct FalloffPacket {
    FalloffWeightFn weight;     // null → use defaultWeight
    static float defaultWeight(Vec3 _, uint __) { return 1.0f; }
}

/// LXsP_TOOL_SYMMETRY — populated by SYMM stage in 7.6. Per-axis flags
/// for X/Y/Z mirroring; default = no symmetry.
struct SymmetryPacket {
    bool[3] axisFlags;
    Vec3    pivot = Vec3(0, 0, 0);
}

/// Snap state — populated by SNAP stage in 7.3. The cursor's effective
/// world position after snap; if no snap fired, equals the raw cursor.
/// `applied` lets actors render snap-feedback hints when relevant.
struct SnapPacket {
    Vec3 cursorWorld = Vec3(0, 0, 0);
    bool applied     = false;
}
