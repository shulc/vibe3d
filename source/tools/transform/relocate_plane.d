module tools.transform.relocate_plane;

// The ORTHOGRAPHIC click-relocate (below). A perspective relocate is the
// create click law (`create_common.screenToPlacementWorld`): pinned K-W W2a,
// unpinned K-W3 (task 9476, `tests/test_create_click_plane_rule.d` W3a / W3b).

import math : Vec3, Viewport, isAxisView, dot;
import std.math : abs;

import viewgrid : vectorSnap, axisComp, withAxisComp;

/// An ORTHOGRAPHIC click-relocate: the press drags a handle standing at the
/// centre held BEFORE the press across the view plane, so the landing keeps
/// that centre's depth along the view axis and takes the other two
/// coordinates from the click (gap 364, task 7134; fixture
/// `tests/fixtures/relocate_axis_view_depth.json`). The camera focus never
/// enters — a different law from the create tools' placement click, which
/// does land through the focus.
///
/// Everything is in ONE frame, the caller's: plane-local under a pinned work
/// plane (a turned axis view then looks along a LOCAL axis), world otherwise.
/// In an axis view the two in-plane coordinates are snapped to `inPlaneSnap`
/// (the view's sub-step; 0.01 at pixel 0.0078125 in the capture) and the depth
/// is copied, never snapped. An ortho view with no locked axis keeps the same
/// depth rule on the view-perpendicular plane through `prior`, unsnapped: the
/// reference has no such view, so nothing measured snaps it.
///
/// Returns false only for a degenerate (zero) view direction.
bool orthoRelocateThroughPrior(const ref Viewport vp, Vec3 rayOrigin, Vec3 rayDir,
                               Vec3 prior, float inPlaneSnap, out Vec3 c)
        @safe pure nothrow @nogc {
    immutable Vec3 n = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    // The view TYPE decides the arm (`isAxisView`, the one axis-view
    // predicate); the axis it looks along is then the largest component of
    // its direction in the caller's frame.
    if (isAxisView(vp)) {
        immutable int k = abs(n.x) >= abs(n.y) && abs(n.x) >= abs(n.z) ? 0
                        : (abs(n.y) >= abs(n.z) ? 1 : 2);
        c = withAxisComp(vectorSnap(rayOrigin, inPlaneSnap), k, axisComp(prior, k));
        return true;
    }
    immutable float denom = dot(n, rayDir);
    if (abs(denom) < 1e-9f) return false;
    c = rayOrigin + rayDir * (dot(n, prior - rayOrigin) / denom);
    return true;
}
