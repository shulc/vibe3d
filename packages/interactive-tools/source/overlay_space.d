module overlay_space;

import std.math : sqrt, isNaN;

import math : Vec3;
import vibe3d.util.spatial.spatial : ModelSpace;
import vibe3d.documents.model.document : primaryModelSpace;
import tools.create.create_common : axisUnit;

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

    /// A WORLD point -> the local point that is DRAWN at it. The exact inverse
    /// of `pos`, and the half of this seam 0645 had no call for (task 0660).
    ///
    /// This is the direction a CLICK travels, and it is the one place the two
    /// sides of the seam are easy to confuse. A screen gesture resolves against
    /// a WORLD construct — the construction plane, a world ray/plane hit
    /// — so the point it produces is a world point; the parameter it writes is
    /// then read by a kernel that addresses the layer's OWN stored vertex
    /// coordinates. Writing the world point straight into that parameter builds
    /// the result around the point's image under the identity matrix, which is
    /// the same defect `pos`'s absence causes, pointing the other way.
    ///
    /// Guarded by `active` on exactly the same terms as `pos`: a non-invertible
    /// item matrix hands the point back verbatim rather than pushing it through
    /// an `mInv` that means nothing, so `toLocalPos(pos(p)) == p` holds in both
    /// branches.
    Vec3 toLocalPos(Vec3 world) const @safe pure nothrow @nogc {
        return active ? ms.toLocalPoint(world) : world;
    }

    /// The `ModelSpace` to carry a whole RAY into (`spatial.screenPointToLocalRay`),
    /// honouring the same `active` gate every accessor here does — identity
    /// whenever this space declines to convert, so a caller cannot pick up an
    /// `mInv` that `active` has already declared meaningless. At identity the
    /// carried ray is byte-identical to the world one, since `applyAffine` and
    /// `toLocalDir` against the identity matrix are exact.
    ModelSpace rayModelSpace() const @safe pure nothrow @nogc {
        return active ? ms : ModelSpace.world();
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
            Vec3 u = axisUnit(i);
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

















