module item_xform;

import math : Vec3, identityMatrix, translationMatrix, matrixFromEulerZYX,
              pivotScaleMatrix, matMul4, ModelSpace;

// ---------------------------------------------------------------------------
// THE ITEM TRANSFORM (task 0721, audit №4 item D10 — the `xform` stratum).
//
// The per-item transform value and the ONE repair that every write path to it
// ends in. Split out of `document.d` whole, verbatim, prose included: it
// depends on `math` and on nothing else in the document model — not on
// `Layer`, not on `Document`, not on the kind table — which is what makes it
// a stratum rather than a slice.
//
// `document.d` re-exports all four names with a `public import`, so every
// existing `import document : ItemXform;` and every `document.ItemXform`
// keeps resolving. The public surface is byte-for-byte what it was.
//
// The pairing this file must not break: `MIN_ITEM_SCALE_MAG` is a TWO-LAYER
// guard whose two enforcement points (the gesture kernel and the authored
// param path) each re-export it from here rather than declaring their own —
// see the constant's own comment, which travelled with it.
// ---------------------------------------------------------------------------

/// Degenerate-scale floor for `ItemXform.scl` (task 0614, R7). A `scl`
/// component whose MAGNITUDE falls below this makes `composedMatrix()`
/// singular, which poisons every consumer that inverts or normalises it
/// (action-centre, axis basis, snap frames, export). The sign is NOT part of
/// the floor — a negative scale is a legitimate mirror, so the guard clamps
/// `|scl|` and preserves the sign.
///
/// This constant lives HERE, next to `ItemXform`, rather than in either of the
/// two places that enforce it, because R7 is a TWO-LAYER guard and the two
/// layers must agree by construction: the gesture kernel
/// (`tools/transform/item_xform_kernels.d`, which re-exports this symbol) and
/// the authored-param write path (`layer_params.d`). Two independently
/// declared floors would be a latent divergence, not a redundancy.
enum float MIN_ITEM_SCALE_MAG = 1e-4f;

/// Magnitude ceiling for `ItemXform.scl` (task 0614, R7 — the other end of the
/// same guard). A finite but absurd scale (`1e30`) does not make the matrix
/// singular, but it overflows to infinity the moment it is composed with
/// anything else, which reintroduces the non-finite state the floor exists to
/// prevent. `1e6` is far beyond any modelling use and still leaves ~30 bits of
/// float headroom for a matrix product.
enum float MAX_ITEM_SCALE_MAG = 1e6f;

/// A per-layer (item) transform: position / euler-rotation-in-degrees / scale,
/// about a pivot. Authored as four separate `Vec3` channels (the source of
/// truth); the world matrix is a DERIVED runtime value composed on demand by
/// `composedMatrix()` and is never itself an authored field.
///
/// Survey #3 Phase 0: this is the data model only. No render / IO / forms /
/// command wiring yet (those are P1-P4); the field is unused by the rest of the
/// app after P0 — that is expected.
struct ItemXform {
    // NOTE: Vec3's components are plain `float`, so their `.init` is NaN, not 0.
    // Every field needs an explicit zero/unit initialiser so a default-
    // constructed ItemXform composes to identity (not a NaN matrix).
    Vec3 pos   = Vec3(0, 0, 0); ///< translation
    Vec3 rot   = Vec3(0, 0, 0); ///< euler rotation in DEGREES (applied ZYX)
    Vec3 scl   = Vec3(1, 1, 1); ///< per-axis scale (default = unit)
    Vec3 pivot = Vec3(0, 0, 0); ///< pivot point for rotation + scale

    /// The composed world matrix (column-major `float[16]`), in the exact
    /// order declared by the plan:
    ///
    ///     M = T(pos) · T(pivot) · Rz·Ry·Rx · S · T(-pivot)
    ///
    /// ZYX euler, rotations in degrees. The rotation block is built by
    /// `matrixFromEulerZYX` (R = Rz·Ry·Rx), the scale block by an origin-pivot
    /// `pivotScaleMatrix` (pure `diag(scl)`), and the pivot is bracketed by
    /// `T(pivot) … T(-pivot)` so rotation + scale fix the pivot point. The
    /// default `ItemXform` (pos=0, rot=0, scl=1, pivot=0) yields identity.
    ///
    /// Pure: composes from the matrix helpers in `math.d`; no hand-rolled matrix.
    float[16] composedMatrix() const {
        float[16] T    = translationMatrix(pos);
        float[16] Tp   = translationMatrix(pivot);
        float[16] R    = matrixFromEulerZYX(rot);
        float[16] S    = pivotScaleMatrix(Vec3(0, 0, 0), scl.x, scl.y, scl.z);
        float[16] Tpi  = translationMatrix(Vec3(-pivot.x, -pivot.y, -pivot.z));
        // M = T · Tp · R · S · Tpi  (left-to-right composition order)
        return matMul4(T,
               matMul4(Tp,
               matMul4(R,
               matMul4(S, Tpi))));
    }

    /// The `ModelSpace` (task 0617, doc/picking_item_transform_plan.md §3.1)
    /// packaging this transform for picking: `m` == `composedMatrix()`, plus
    /// its ANALYTIC inverse and the `isIdentity`/`invertible`/`mirrored`
    /// flags every picking entry point gates on.
    ///
    /// Exact identity fast path (§3.5, a HARD requirement): `pos`/`rot`/`scl`
    /// compared by EXACT float equality against their defaults, not
    /// `isClose` — the existing test suite is the neutrality proof for every
    /// picking stage built on this, and a float-epsilon "close enough" would
    /// turn that proof into noise. `pivot` is deliberately excluded from the
    /// check: at rot=0/scl=1, `T(pivot)·I·T(-pivot) == I` for ANY pivot, so a
    /// non-zero pivot alone never makes the composed matrix non-identity.
    ///
    /// `mInv` is analytic, not a general 4×4 inverse (`math.d` has none, and
    /// this composition order never needs one — §3.1):
    ///
    ///     M⁻¹ = T(pivot) · S⁻¹ · Rᵀ · T(-pivot) · T(-pos)
    ///
    /// `S⁻¹ = diag(1/scl)`. `Rᵀ` is the TRANSPOSE of `matrixFromEulerZYX(rot)`
    /// — NOT `matrixFromEulerZYX(-rot)`, which composes to `Rz(-)·Ry(-)·Rx(-)`,
    /// the reverse-order product and NOT the inverse of `Rz·Ry·Rx` (pinned by
    /// the unittest below; this is the trap the plan calls out by name).
    /// Since `matrixFromEulerZYX` already returns a matrix with zero
    /// translation and bottom row `(0,0,0,1)`, transposing the FULL `float[16]`
    /// gives exactly the transpose of its 3×3 rotation block (the swapped
    /// translation/bottom-row entries are all zero either way), so no
    /// separate 3×3-only transpose helper is needed.
    ///
    /// Degenerate in exactly one place (§3.1): any `scl` component `== 0`
    /// has no inverse — `invertible` is set false and `mInv` is left at
    /// identity (meaningless; callers MUST check `invertible` first, per R2).
    ///
    /// `mirrored = det(M) < 0`. For this composition order
    /// `det(M) = det(R)·det(S) = 1 · (scl.x·scl.y·scl.z)` (translations are
    /// unit-determinant, `matrixFromEulerZYX` is a proper rotation) — so the
    /// PRODUCT of the three scale components, not "any component negative"
    /// (§3.7). No general 3×3 determinant helper is added; none is needed.
    ModelSpace modelSpace() const {
        immutable bool isId =
               pos.x == 0 && pos.y == 0 && pos.z == 0
            && rot.x == 0 && rot.y == 0 && rot.z == 0
            && scl.x == 1 && scl.y == 1 && scl.z == 1;
        if (isId) return ModelSpace.world();

        immutable float det = scl.x * scl.y * scl.z; // §3.7 — no det3 helper

        ModelSpace ms;
        ms.m          = composedMatrix();
        ms.isIdentity = false;
        ms.mirrored   = det < 0;

        if (scl.x == 0 || scl.y == 0 || scl.z == 0) {
            ms.invertible = false;
            ms.mInv       = identityMatrix; // meaningless; callers check `invertible` first
            return ms;
        }

        float[16] R  = matrixFromEulerZYX(rot);
        // R^T: matrixFromEulerZYX has zero translation + bottom row (0,0,0,1),
        // so a full-matrix transpose IS the 3x3 rotation-block transpose.
        float[16] Rt = [
            R[0], R[4], R[ 8], 0,
            R[1], R[5], R[ 9], 0,
            R[2], R[6], R[10], 0,
            0,    0,    0,     1,
        ];
        float[16] Sinv       = pivotScaleMatrix(Vec3(0, 0, 0), 1.0f/scl.x, 1.0f/scl.y, 1.0f/scl.z);
        float[16] Tpiv       = translationMatrix(pivot);
        float[16] TpivNeg    = translationMatrix(Vec3(-pivot.x, -pivot.y, -pivot.z));
        float[16] TposNeg    = translationMatrix(Vec3(-pos.x, -pos.y, -pos.z));

        // M^-1 = T(pivot) . S^-1 . R^T . T(-pivot) . T(-pos)
        ms.mInv = matMul4(Tpiv,
                  matMul4(Sinv,
                  matMul4(Rt,
                  matMul4(TpivNeg, TposNeg))));
        ms.invertible = true;
        return ms;
    }
}

/// Repair an `ItemXform` in place and report whether anything had to be
/// repaired. This is THE statement of the R7 value policy (task 0614): every
/// write path that can introduce a NEW `ItemXform` value ends here, so the
/// invalid state is impossible rather than merely rare.
///
/// Two hazards, two different policies:
///
///  * **Non-finite, on any of the 12 components.** A NaN anywhere makes
///    `composedMatrix()` all-NaN, which propagates into the action centre, the
///    axis basis, every snap frame and the exported file. Policy: **reject** —
///    restore the component's value from `before`, exactly like a command that
///    declines an out-of-domain argument. There is no "nearest legal value"
///    for a NaN, so any number invented here would be an edit nobody asked
///    for. If `before`'s own component is ALSO non-finite (a document written
///    before this guard existed), fall back to the channel's identity element
///    so the repair always terminates in a composable xform. A caller with no
///    meaningful prior value (a fresh file load) passes `ItemXform.init`,
///    which makes the identity fallback the whole rule.
///  * **A `scl` component outside `[MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG]`
///    in MAGNITUDE.** Below the floor the matrix is singular; above the
///    ceiling it overflows to infinity at the first product. Policy:
///    **clamp**, sign preserved — a negative scale is a legitimate mirror, and
///    unlike the NaN case the nearest legal value is well defined (`scl.x 0`
///    is an ordinary keystroke on the way to `0.5`).
///
/// Deliberately NOT a method on `ItemXform`: it is a repair applied by the
/// write paths, not a property of the value, and keeping it free makes the
/// call sites read as the enforcement points they are.
bool sanitizeItemXform(ref ItemXform x, ref const ItemXform before) {
    import std.math : isFinite, fabs;

    bool repaired = false;

    void finite(ref float v, float prior, float identity) {
        if (isFinite(v)) return;
        v = isFinite(prior) ? prior : identity;
        repaired = true;
    }
    finite(x.pos.x,   before.pos.x,   0.0f);
    finite(x.pos.y,   before.pos.y,   0.0f);
    finite(x.pos.z,   before.pos.z,   0.0f);
    finite(x.rot.x,   before.rot.x,   0.0f);
    finite(x.rot.y,   before.rot.y,   0.0f);
    finite(x.rot.z,   before.rot.z,   0.0f);
    finite(x.scl.x,   before.scl.x,   1.0f);
    finite(x.scl.y,   before.scl.y,   1.0f);
    finite(x.scl.z,   before.scl.z,   1.0f);
    finite(x.pivot.x, before.pivot.x, 0.0f);
    finite(x.pivot.y, before.pivot.y, 0.0f);
    finite(x.pivot.z, before.pivot.z, 0.0f);

    void band(ref float v) {
        immutable float m = fabs(v);
        if (m < MIN_ITEM_SCALE_MAG) {
            v = v < 0 ? -MIN_ITEM_SCALE_MAG : MIN_ITEM_SCALE_MAG;
            repaired = true;
        } else if (m > MAX_ITEM_SCALE_MAG) {
            v = v < 0 ? -MAX_ITEM_SCALE_MAG : MAX_ITEM_SCALE_MAG;
            repaired = true;
        }
    }
    band(x.scl.x);
    band(x.scl.y);
    band(x.scl.z);

    return repaired;
}
