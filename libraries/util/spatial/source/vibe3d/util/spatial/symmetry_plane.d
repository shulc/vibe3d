module vibe3d.util.spatial.symmetry_plane;

import vibe3d.util.math.math : Vec3, dot;
import std.math : abs;

/// THE side test: 0 within `eps` of the plane, else the sign of
/// `dot(p − planePoint, planeNormal)`. The pairing passes `epsilonWorld`; Edge
/// Extend and the authoring side pass 0 — strict, x = ±1e-4 already flips
/// (doc/measured_laws.md §21).
int symmetrySide(Vec3 planePoint, Vec3 planeNormal, Vec3 p, float eps) pure nothrow @nogc @safe {
    immutable float d = dot(p - planePoint, planeNormal);
    return abs(d) <= eps ? 0 : (d > 0 ? 1 : -1);
}

