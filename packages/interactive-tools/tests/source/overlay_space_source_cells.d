module overlay_space_source_cells;

import overlay_space : OverlaySpace, OverlayAxis;
import math : Vec3;
import vibe3d.util.spatial.spatial : ModelSpace;

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

unittest { // `toLocalPos` is the FULL affine inverse, not the linear one.
    // The wrong implementation this refuses (task 0660): reusing
    // `toLocalDelta` for a POINT, i.e. dropping the translation. It is the
    // mirror of the mistake the `pos`/`axis` test above refuses from the other
    // side, and it is easy to make because the two differ by nothing at the
    // call site — both take a Vec3 and return a Vec3.
    //
    // On this stand `pos(1,0,0) == (7,-2,11)`; carrying that world point back
    // with the LINEAR inverse alone yields (-1, -2.3333, 2.2), 3.78 away from
    // the point it came from.
    import std.math : abs;
    auto os = OverlaySpace(tiltedStand());

    Vec3 local = Vec3(1, 0, 0);
    Vec3 world = os.pos(local);
    Vec3 back  = os.toLocalPos(world);
    assert(abs(back.x - 1.0f) < 1e-5f && abs(back.y) < 1e-5f && abs(back.z) < 1e-5f);

    // The named wrong reading is a genuinely different point, not a rounding
    // term — so the round-trip above is a real assertion.
    Vec3 linearOnly = os.toLocalDelta(world);
    assert(abs(linearOnly.x + 1.0f)      < 1e-4f
        && abs(linearOnly.y + 7.0f/3.0f) < 1e-4f
        && abs(linearOnly.z - 2.2f)      < 1e-4f);

    // Identity hands a point back verbatim, exactly as `pos` does.
    auto id = OverlaySpace(ModelSpace.world());
    Vec3 p = Vec3(1.0e-8f, 3.3333333f, -7.7777777f);
    assert(id.toLocalPos(p).x == p.x && id.toLocalPos(p).y == p.y
        && id.toLocalPos(p).z == p.z);

    // ...and a non-invertible matrix declines the conversion on the same terms
    // `pos` does, so the round-trip identity survives in that branch too.
    ModelSpace dead = tiltedStand();
    dead.invertible = false;
    auto od = OverlaySpace(dead);
    assert(od.toLocalPos(od.pos(p)).x == p.x && od.toLocalPos(od.pos(p)).z == p.z);
}

unittest { // `rayModelSpace` honours `active`, it does not just hand out `ms`.
    // The wrong implementation this refuses: returning `ms` unconditionally.
    // A caller carrying a cursor ray into layer space would then use an `mInv`
    // that `active` has already declared meaningless — the half-conversion the
    // module header refuses everywhere else, arriving through the one accessor
    // that hands out the raw matrix.
    auto live = OverlaySpace(tiltedStand());
    assert(!live.rayModelSpace().isIdentity);

    ModelSpace dead = tiltedStand();
    dead.invertible = false;
    assert(OverlaySpace(dead).rayModelSpace().isIdentity);
    assert(OverlaySpace(ModelSpace.world()).rayModelSpace().isIdentity);
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
