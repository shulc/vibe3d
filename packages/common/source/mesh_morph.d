// Morph-map value arithmetic — the two pure functions the whole feature is
// built out of (task 1069).
//
// Neither takes a `Mesh`, deliberately: they are the measured LAW, and a
// failure in one of them is the law being wrong rather than the wiring being
// wrong. `tests/unit/morph_map_test.d` drives them straight from the frozen
// capture fixture with no vibe3d feature surface in the loop.
module mesh_morph;

import math : Vec3;
import mesh : MapKind;

/// Apply a stored morph value on top of a base position at `amount` strength.
///
///   relative:  p' = base + amount * stored          (stored is a DELTA)
///   absolute:  p' = base + amount * (stored - base) (stored is a POSITION,
///                                                    so this is lerp(base,
///                                                    stored, amount))
///
/// **`amount` is NOT clamped, and must never become clamped.** The capture
/// pins the law at −0.5 and at 100 (`apply_negative`, `apply_x100`), and the
/// deformer mechanism agrees at 2.0 and −1.0 (`deformer_strength_2`,
/// `deformer_strength_neg`). A clamp to [0,1] — the "obviously sensible"
/// default a later bounds sweep will reach for — is exactly what those four
/// cases exist to redden. The `amount` Param therefore carries no `.min()` /
/// `.max()` either; see `commands/mesh/morph.d`.
///
/// Two morphs COMPOSE by running this twice (`deformer_two_morphs_add`): the
/// second call's `base` is the first call's result, which for the relative
/// kind sums the deltas rather than overriding.
///
/// A non-morph kind returns `base` unchanged rather than inventing a rule.
Vec3 morphApply(Vec3 base, Vec3 stored, MapKind kind, float amount) pure nothrow @nogc @safe {
    final switch (kind) {
        case MapKind.morphRelative:
            return base + stored * amount;
        case MapKind.morphAbsolute:
            return base + (stored - base) * amount;
        case MapKind.unclassified:
        case MapKind.uv:
        case MapKind.vertexWeight:
        case MapKind.creaseWeight:
            return base;
    }
}

/// The inverse, and the routed write's whole content: given the TRUE base
/// position of a vertex and the position the transform kernel computed for it,
/// what goes in the map?
///
///   relative:  moved - base    (a displacement)
///   absolute:  moved           (a position)
///
/// `base` here is the TRUE base — `dragBaseline[vi]` / `route.base[vi]` — NOT
/// the run baseline the kernel evaluated from. Under an accumulating gesture
/// the kernel evaluates from `base + delta(at run start)`, so reading `base`
/// off the live `mesh.vertices` (which the routed path never writes) is the
/// same thing, but reading it off the RUN baseline would subtract the existing
/// delta out and every second gesture would silently overwrite the first.
///
/// `morphRoutedStore(base, morphApply(base, stored, kind, 1.0f), kind) == stored`
/// for both kinds — the round-trip identity `tests/unit/morph_map_test.d`
/// asserts, which is what makes "apply then re-store" a no-op.
Vec3 morphRoutedStore(Vec3 base, Vec3 moved, MapKind kind) pure nothrow @nogc @safe {
    final switch (kind) {
        case MapKind.morphRelative:
            return moved - base;
        case MapKind.morphAbsolute:
            return moved;
        case MapKind.unclassified:
        case MapKind.uv:
        case MapKind.vertexWeight:
        case MapKind.creaseWeight:
            return moved - base;
    }
}
