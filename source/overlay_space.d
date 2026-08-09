module overlay_space;

import std.math : sqrt, isNaN;

import math     : Vec3, ModelSpace;
import document : primaryModelSpace;

// ---------------------------------------------------------------------------
// THE TOOL-OVERLAY SPACE SEAM (task 0645)
//
// A layer's mesh is STORED in the layer's own coordinates and DRAWN through
// that layer's item matrix. A tool that builds its gizmo out of mesh geometry
// — a face centroid, an averaged face normal, a selection centroid — therefore
// holds LOCAL quantities, and every drag primitive it hands them to
// (`drag.screenAxisDelta`, `drag.planeDragDelta`, `drag.haulWorldPerPixel`,
// `handles.gl_util.gizmoSize`) is a WORLD-space function, as is every
// `Handler.draw` / `Handler.hitTest`. Feeding a raw local centroid to those
// puts the handle where the geometry would sit under an identity matrix.
//
// WHY THAT WENT UNNOTICED FOR SO LONG, AND WHY IT DICTATES THE SHAPE OF THE
// FIX. `ToolHandles` uses the SAME `Viewport` for `draw()` and for
// `hitTest()`. So the drawing and the hit-testing agree WITH EACH OTHER: the
// handle sits in the wrong place, and the user still hits it. Converting the
// hit-test on its own would break the one property that currently works. The
// seam is the handle bank's space and it has to be cut whole — which is what
// this module is: ONE object, obtained once, that a tool uses for BOTH the
// handle it draws and the gain of the drag that handle drives.
//
// ── WHICH DIRECTION, AND WHY IT IS `toWorldDir` AND NOT `toWorldNormal` ────
//
// Every axis in this family drives a MOTION: the parameter it hauls is a
// length the kernel then applies ALONG THE LOCAL AXIS, to local vertex
// coordinates (`Mesh.bevelFacesByMask`'s `shift`, `extrudeFaces`'s distance,
// the inset width, the smooth-shift offset). A local displacement `t·u` is
// drawn as the world displacement `t·L·u` — the LINEAR part of the item
// matrix, i.e. `ModelSpace.toWorldDir`. So:
//
//   * the arrow points along `normalize(toWorldDir(u))`, which is where the
//     geometry will actually go, so the handle tracks the cursor and the
//     geometry tracks the handle;
//   * `worldPerLocal == |toWorldDir(u)|` is the ONE number that converts the
//     world length a drag produced back into the local length the parameter
//     means.
//
// Those are the same quantity in two roles, which is exactly why they live in
// one struct: change the handle's position without changing the gain (or the
// reverse) and the handle stops tracking the cursor.
//
// `toWorldNormal` — the inverse-transpose — is the transport for a SURFACE
// NORMAL, and under a non-uniform item scale it points somewhere else. The
// consequence is stated rather than hidden: on such a layer an arrow built
// from a face normal is NOT perpendicular to the drawn face. Making it
// perpendicular is not an overlay change at all — it would mean the KERNEL
// moving the cap along the world surface normal carried back into local
// coordinates, which is the same class of change task 0649 made to the
// transform pipe's apply path, on kernels 0645 does not open. Under any
// similarity (translation + rotation + UNIFORM scale, which is every item
// transform most scenes carry) the two transports differ only by a positive
// factor and the question does not arise.
//
// ── THE IDENTITY PATH IS BYTE-IDENTICAL ───────────────────────────────────
//
// With no item transform every accessor returns its argument verbatim — `pos`
// does not round-trip through a matrix, `axis` does not re-normalise a vector
// that is already unit. That is deliberate and load-bearing: the whole
// existing suite runs at identity, and it must not move by an ULP.
// ---------------------------------------------------------------------------

/// A local unit direction lifted into the space the geometry is DRAWN in,
/// carrying the one scalar that converts lengths between the two readings.
///
/// Obtained from `OverlaySpace.axis`; never constructed directly, because the
/// invariant that `dir` and `worldPerLocal` come from the SAME local axis is
/// the whole point of the type.
struct OverlayAxis {
    /// WORLD-space, unit length — the direction to draw the handle along and
    /// to hand to `drag.screenAxisDelta` as its axis.
    Vec3 dir = Vec3(0, 0, 1);

    /// The world length of one local unit along the originating local axis:
    /// `|L·u|`. 1.0 whenever there is no item transform.
    float worldPerLocal = 1.0f;

    /// A world length measured along `dir` -> the local length the kernel's
    /// parameter means. The inverse of `toWorld`.
    float toLocal(float worldLen) const @safe pure nothrow @nogc {
        return worldPerLocal > 1e-9f ? worldLen / worldPerLocal : worldLen;
    }

    /// A local parameter length -> the world length it is drawn as.
    float toWorld(float localLen) const @safe pure nothrow @nogc {
        return localLen * worldPerLocal;
    }
}

/// The space a tool's overlay is drawn in — the primary layer's item matrix,
/// wrapped so that a handle position and the gain of the drag that handle
/// drives cannot be converted independently of each other.
struct OverlaySpace {
    ModelSpace ms;

    /// True when the item matrix actually does something. A non-invertible
    /// matrix (a zero scale component collapses the geometry to a plane or a
    /// line) is treated as "no conversion": there is no local reading to
    /// convert a world drag back into, and the pre-0645 behaviour is the least
    /// surprising thing to leave in its place. Mirrors `ModelSpace.conjugate`,
    /// which likewise returns its argument untouched there.
    @property bool active() const @safe pure nothrow @nogc {
        return !ms.isIdentity && ms.invertible;
    }

    /// The overlay space of the layer tools edit — `document.primaryModelSpace`,
    /// the same resolver the pick paths, the snap overlay and the aiming seam
    /// read. Cheap; call it once per `draw()` / per gesture start rather than
    /// per handle.
    static OverlaySpace ofPrimary() {
        return OverlaySpace(primaryModelSpace());
    }

    /// A local point -> the world point it is DRAWN at. For a handle anchor,
    /// for `gizmoSize`, and for the anchor of every drag primitive.
    Vec3 pos(Vec3 local) const @safe pure nothrow @nogc {
        return active ? ms.toWorldPoint(local) : local;
    }

    /// A local MOTION direction -> the world direction it is drawn moving
    /// along, plus the gain. `localUnit` is expected to be unit length; at
    /// identity it is handed straight back (see the module header on
    /// byte-identity), so a caller that passes a non-unit vector gets a
    /// different answer at identity than under a transform — pass unit
    /// vectors.
    ///
    /// A degenerate result (the local axis lands in the matrix's null
    /// direction) falls back to the local axis with gain 1 rather than
    /// producing a NaN handle.
    OverlayAxis axis(Vec3 localUnit) const @safe pure nothrow @nogc {
        if (!active) return OverlayAxis(localUnit, 1.0f);
        Vec3  w = ms.toWorldDir(localUnit);
        float g = sqrt(w.x*w.x + w.y*w.y + w.z*w.z);
        if (!(g > 1e-9f) || isNaN(g)) return OverlayAxis(localUnit, 1.0f);
        return OverlayAxis(w * (1.0f / g), g);
    }

    /// A world DISPLACEMENT (what `drag.planeDragDelta` returns) -> the local
    /// displacement that is drawn as it. Exact — no direction to choose, so
    /// no gain question: the full linear inverse does it.
    Vec3 toLocalDelta(Vec3 worldDelta) const @safe pure nothrow @nogc {
        return active ? ms.toLocalDir(worldDelta) : worldDelta;
    }

    /// World length per local unit for a haul that has NO direction — a merge
    /// threshold, an inset width, a parameter that is a distance and not a
    /// displacement along anything.
    ///
    /// There is no exact answer: one local unit is a different world length in
    /// every direction once the item scale is non-uniform, so this is a
    /// DECLARED reading, the mean of the world lengths of the three local unit
    /// axes. It is exact for any similarity (all three agree there), and for a
    /// non-uniform scale it makes the haul feel right on average instead of
    /// right along one arbitrarily-chosen axis. A tool that HAS an axis must
    /// use `axis()` instead — that one is exact.
    float meanWorldPerLocal() const @safe pure nothrow @nogc {
        if (!active) return 1.0f;
        float g = 0.0f;
        foreach (i; 0 .. 3) {
            Vec3 u = Vec3(i == 0 ? 1 : 0, i == 1 ? 1 : 0, i == 2 ? 1 : 0);
            Vec3 w = ms.toWorldDir(u);
            g += sqrt(w.x*w.x + w.y*w.y + w.z*w.z);
        }
        g *= (1.0f / 3.0f);
        return (g > 1e-9f && !isNaN(g)) ? g : 1.0f;
    }
}

// ---------------------------------------------------------------------------
// Unit tests. Each one names the wrong implementation it refuses.
// ---------------------------------------------------------------------------

version (unittest) private ModelSpace tiltedStand() {
    // Translation + rotation about Z + a DIFFERENT scale on all three axes,
    // built by hand so the test does not depend on document.d's composer.
    //
    //   L = Rz(90 deg) * diag(sx, sy, sz)   ->   L*x = (0, sx, 0)
    //                                            L*y = (-sy, 0, 0)
    //                                            L*z = (0, 0, sz)
    enum float sx = 2.0f, sy = 3.0f, sz = 5.0f;
    enum float tx = 7.0f, ty = -4.0f, tz = 11.0f;
    ModelSpace ms;
    // Column-major: m[0..2] = L*x, m[4..6] = L*y, m[8..10] = L*z.
    ms.m = [ 0.0f,   sx, 0.0f, 0.0f,
              -sy, 0.0f, 0.0f, 0.0f,
             0.0f, 0.0f,   sz, 0.0f,
               tx,   ty,   tz, 1.0f];
    // L^-1: Rz(-90) after the reciprocal scale, and the translation column
    // is -L^-1*t.
    ms.mInv = [    0.0f, -1.0f/sy,     0.0f, 0.0f,
                1.0f/sx,     0.0f,     0.0f, 0.0f,
                   0.0f,     0.0f,  1.0f/sz, 0.0f,
                 -ty/sx,    tx/sy,   -tz/sz, 1.0f];
    ms.isIdentity = false;
    ms.invertible = true;
    return ms;
}

unittest { // Identity is byte-identical — the accessor does not round-trip a matrix.
    // The wrong implementation this refuses: "always go through toWorldPoint /
    // always re-normalise". `identityMatrix` multiplication is not guaranteed
    // to reproduce a float bit-for-bit once a denormal or a large exponent is
    // involved, and `normalize` of an already-unit vector is a sqrt away from
    // its input. The whole existing suite runs at identity.
    auto os = OverlaySpace(ModelSpace.world());
    assert(!os.active);
    Vec3 p = Vec3(1.0e-8f, 3.3333333f, -7.7777777f);
    assert(os.pos(p).x == p.x && os.pos(p).y == p.y && os.pos(p).z == p.z);
    Vec3 u = Vec3(0.57735026f, 0.57735026f, 0.57735026f);
    auto ax = os.axis(u);
    assert(ax.dir.x == u.x && ax.dir.y == u.y && ax.dir.z == u.z);
    assert(ax.worldPerLocal == 1.0f);
    assert(os.toLocalDelta(p).y == p.y);
    assert(os.meanWorldPerLocal() == 1.0f);
}

unittest { // The gain is the axis's OWN scale, not the mean and not the determinant.
    // Two wrong-but-plausible implementations this separates:
    //   * `worldPerLocal = cbrt(|det L|)` = cbrt(30) = 3.107 for every axis;
    //   * `worldPerLocal = meanWorldPerLocal()` = (2+3+5)/3 = 3.333 for every axis.
    // The right answer differs per axis: 2, 3, 5.
    import std.math : abs;
    auto os = OverlaySpace(tiltedStand());
    assert(os.active);

    auto ax = os.axis(Vec3(1, 0, 0));
    assert(abs(ax.worldPerLocal - 2.0f) < 1e-5f);
    assert(abs(ax.dir.x - 0.0f) < 1e-6f && abs(ax.dir.y - 1.0f) < 1e-6f);

    auto ay = os.axis(Vec3(0, 1, 0));
    assert(abs(ay.worldPerLocal - 3.0f) < 1e-5f);
    assert(abs(ay.dir.x + 1.0f) < 1e-6f && abs(ay.dir.y - 0.0f) < 1e-6f);

    auto az = os.axis(Vec3(0, 0, 1));
    assert(abs(az.worldPerLocal - 5.0f) < 1e-5f);
    assert(abs(az.dir.z - 1.0f) < 1e-6f);

    assert(abs(os.meanWorldPerLocal() - 10.0f/3.0f) < 1e-5f);
}

unittest { // `pos` is the FULL affine; `axis`/`toLocalDelta` are the LINEAR part.
    // The wrong implementation this refuses is the one task 0649's
    // `conjugate` doc warns about from the other side: applying the
    // translation to a DIRECTION. `toWorldDir` of any vector must be
    // unaffected by the item's position, and only `pos` may move by it.
    import std.math : abs;
    auto os = OverlaySpace(tiltedStand());

    // pos: L*(1,0,0) + t = (0,2,0) + (7,-4,11)
    Vec3 p = os.pos(Vec3(1, 0, 0));
    assert(abs(p.x - 7.0f) < 1e-5f && abs(p.y + 2.0f) < 1e-5f && abs(p.z - 11.0f) < 1e-5f);

    // axis: the same input as a DIRECTION picks up no translation at all.
    auto ax = os.axis(Vec3(1, 0, 0));
    Vec3 d = ax.dir * ax.worldPerLocal;
    assert(abs(d.x - 0.0f) < 1e-5f && abs(d.y - 2.0f) < 1e-5f && abs(d.z - 0.0f) < 1e-5f);
}

unittest { // toLocal / toWorld invert each other, and toLocalDelta agrees with the axis gain.
    import std.math : abs;
    auto os = OverlaySpace(tiltedStand());
    auto az = os.axis(Vec3(0, 0, 1));

    // A drag that produced 5 world units along the drawn Z axis is 1 local unit.
    assert(abs(az.toLocal(5.0f) - 1.0f) < 1e-5f);
    assert(abs(az.toWorld(1.0f) - 5.0f) < 1e-5f);
    assert(abs(az.toLocal(az.toWorld(0.375f)) - 0.375f) < 1e-5f);

    // The vector conversion has to agree with the scalar one on the same axis.
    Vec3 localDelta = os.toLocalDelta(az.dir * 5.0f);
    assert(abs(localDelta.x) < 1e-5f && abs(localDelta.y) < 1e-5f
        && abs(localDelta.z - 1.0f) < 1e-5f);
}

unittest { // A degenerate axis falls back instead of producing a NaN handle.
    ModelSpace ms = tiltedStand();
    // Collapse Z: the third column becomes zero, so toWorldDir(z) has no
    // direction to report.
    ms.m[8] = 0; ms.m[9] = 0; ms.m[10] = 0;
    auto os = OverlaySpace(ms);
    auto az = os.axis(Vec3(0, 0, 1));
    assert(az.dir.z == 1.0f && az.worldPerLocal == 1.0f);
    // And the scalar conversion of a degenerate gain must not divide by it.
    auto bad = OverlayAxis(Vec3(0, 0, 1), 0.0f);
    assert(bad.toLocal(4.0f) == 4.0f);
}

unittest { // A non-invertible item matrix is "no conversion", everywhere or nowhere.
    // The wrong implementation: convert the handle position (which needs only
    // `m`) but not the drag gain back (which needs `mInv`). That is precisely
    // the half-conversion this task exists to refuse — the handle would move
    // and the drag would not follow it.
    ModelSpace ms = tiltedStand();
    ms.invertible = false;
    auto os = OverlaySpace(ms);
    assert(!os.active);
    Vec3 p = Vec3(1, 0, 0);
    assert(os.pos(p).x == p.x && os.pos(p).y == p.y && os.pos(p).z == p.z);
    assert(os.axis(Vec3(0, 0, 1)).worldPerLocal == 1.0f);
    assert(os.toLocalDelta(p).x == p.x);
}
