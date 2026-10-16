module vibe3d.util.spatial.workplane_basis;

import vibe3d.util.math.math : Vec3, dot;
import vibe3d.util.spatial.spatial : Viewport;
import std.math : abs;

/// The construction plane selected at tool activation: the world axis plane
/// most directly facing the camera (largest absolute component of the view
/// matrix's forward row). Carries the plane normal and its two orthogonal
/// in-plane axes in world space.
///
/// Usage:
///   auto bp = pickMostFacingPlane(vp);
///   // bp.normal is the plane normal (one of ±X, ±Y, ±Z world axes)
///   // bp.axis1 / bp.axis2 are the in-plane spanning vectors
struct BuildPlane {
    Vec3 normal;   /// unit — perpendicular to the plane
    Vec3 axis1;    /// unit — first in-plane axis
    Vec3 axis2;    /// unit — second in-plane axis (axis1 × normal direction)
}

/// Shared "most-facing basis axis" argmax, used by every construction-plane
/// picker in the Create-tools (see the call-site list in each file's
/// `choosePlane` — box/sphere/cone/cylinder/capsule/torus/tube/pen/
/// vertex_place, plus `pickMostFacingPlane` and `planeDragDelta`). Returns
/// only the winning INDEX (0=a, 1=b, 2=c) — callers keep their own
/// index→axis mapping (signed or unsigned, local or world), so every call
/// site's output is unchanged by routing through here.
///
/// Tie-break matches every existing call site's `>=` chain exactly: `a`
/// wins ties over `b`/`c`; `b` wins ties over `c`.
int mostFacingAxis(Vec3 camBack, Vec3 a, Vec3 b, Vec3 c) {
    float da = abs(dot(camBack, a));
    float db = abs(dot(camBack, b));
    float dc = abs(dot(camBack, c));
    if      (da >= db && da >= dc) return 0;
    else if (db >= da && db >= dc) return 1;
    else                            return 2;
}

/// Select the build plane based on which world axis the camera is most
/// directly facing. Examines the view matrix's third row (forward vector)
/// and picks the world-aligned plane whose normal is closest to the camera's
/// line of sight.
///
/// Returns a BuildPlane whose axes are always in canonical world order:
///   X-dominant → normal=X,  axis1=Y, axis2=Z
///   Y-dominant → normal=Y,  axis1=X, axis2=Z
///   Z-dominant → normal=Z,  axis1=X, axis2=Y
///
/// PenTool uses this for the initial click then locks to that plane
/// regardless of subsequent camera changes.
BuildPlane pickMostFacingPlane(const ref Viewport vp) {
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    final switch (mostFacingAxis(camBack, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))) {
        case 0: return BuildPlane(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
        case 1: return BuildPlane(Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1));
        case 2: return BuildPlane(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0));
    }
}
