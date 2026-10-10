// I0 (viewport shading S4b, task 9250): the Reflection lookups `envUv` /
// `matcapUv` at literal cells, the source ids, the bilinear sampler's texel
// convention, and the 16-bit decode of one vendored image. The GLSL arm in
// `shader.d` mirrors the two lookups expression for expression; the suite
// `tests/test_viewport_reflection.d` holds the GPU side to them.
module tests.unit.viewport_env_test;

import viewport_env;
import display_state : ReflectionKind, ReflectionSource;
import io.image_decode : decodePng16;
import math : Vec3;
import std.format : format;
import std.math : abs;

private bool near(float a, float b) { return abs(a - b) < 1e-6f; }

/// envUv literal cells: centre (+Z, toward the viewer) at u = 0.5, +X a quarter
/// turn right, −X left, the poles at v = 0 / 1, the wrap at −Z.
unittest {
    struct Cell { Vec3 r; float u, v; string what; }
    immutable Cell[5] cells = [
        Cell(Vec3(0, 0, 1),  0.5f,  0.5f, "+Z (back at the viewer)"),
        Cell(Vec3(1, 0, 0),  0.75f, 0.5f, "+X"),
        Cell(Vec3(-1, 0, 0), 0.25f, 0.5f, "-X"),
        Cell(Vec3(0, 1, 0),  0.5f,  0.0f, "+Y (the first row)"),
        Cell(Vec3(0, -1, 0), 0.5f,  1.0f, "-Y (the last row)"),
    ];
    size_t n;
    foreach (c; cells) {
        immutable uv = envUv(c.r);
        assert(near(uv[0], c.u) && near(uv[1], c.v),
            format("envUv(%s) = (%s, %s), expected (%s, %s)", c.what, uv[0], uv[1], c.u, c.v));
        ++n;
    }
    assert(n == 5, "population floor: 5 envUv cells");
    // The wrap column: −Z lands on the seam, u = 0 or 1 (either edge is the
    // same texel column under GL_REPEAT).
    immutable w = envUv(Vec3(0, 0, -1));
    assert(near(w[0], 0) || near(w[0], 1), format("envUv(-Z).u = %s, expected 0 or 1", w[0]));
}

/// The pole guard: at R.x = R.z = 0 the D and GLSL lookups both take u = 0.5.
/// The −0 cell is the one that discriminates: unguarded, atan2(0, −0) = π ⇒
/// u = 1.0, while atan2(0, +0) = 0 gives 0.5 by accident.
unittest {
    immutable a = envUv(Vec3(0, 1, -0.0f));
    assert(near(a[0], 0.5f), format("envUv(0, 1, -0).u = %s: the pole guard must give 0.5", a[0]));
    immutable b = envUv(Vec3(0, -1, -0.0f));
    assert(near(b[0], 0.5f), format("envUv(0, -1, -0).u = %s: the pole guard must give 0.5", b[0]));
}

/// matcapUv literal cells: the eye normal's x right, y UP (v = 0 is the first
/// row, the top of the image).
unittest {
    struct Cell { Vec3 n; float u, v; }
    immutable Cell[3] cells = [
        Cell(Vec3(0, 0, 1), 0.5f, 0.5f),
        Cell(Vec3(0, 1, 0), 0.5f, 0.0f),
        Cell(Vec3(1, 0, 0), 1.0f, 0.5f),
    ];
    foreach (c; cells) {
        immutable uv = matcapUv(c.n);
        assert(near(uv[0], c.u) && near(uv[1], c.v),
            format("matcapUv(%s) = (%s, %s), expected (%s, %s)", c.n, uv[0], uv[1], c.u, c.v));
    }
}

/// Source ids: every offered source round-trips; an unknown name, an empty
/// id and a kind prefix alone are refused and leave the source untouched.
unittest {
    size_t n;
    foreach (s; allReflectionSources()) {
        ReflectionSource back;
        assert(parseReflectionSource(reflectionSourceId(s), back) && back == s,
            format("source %s (%s) did not round-trip", s, reflectionSourceId(s)));
        ++n;
    }
    assert(n == 11, format("population floor: 3 environments + 8 MatCaps, swept %d", n));
    assert(reflectionSourceId(ReflectionSource.init) == "env:kloofendal_48d_partly_cloudy_puresky",
        "the default source is the outdoor sky environment (owner 2026-10-03), got "
        ~ reflectionSourceId(ReflectionSource.init));
    foreach (bad; ["env:nope", "", "env:", "matcap:", "studio_small_09", "matcap:studio_small_09",
                   "env:basic_grey", "env:studio_small_09x", "vne:studio_small_09",
                   "matcaq:basic_grey"]) {
        ReflectionSource s = ReflectionSource(ReflectionKind.MatCap, 7);
        assert(!parseReflectionSource(bad, s), "accepted the unknown source '" ~ bad ~ "'");
        assert(s == ReflectionSource(ReflectionKind.MatCap, 7), "a refused parse wrote the source");
    }
}

/// The bilinear sampler uses GL_LINEAR's texel-centre convention: at a texel
/// centre it reads that texel exactly; half-way between two it averages them;
/// u wraps when asked and clamps otherwise.
unittest {
    LinearImage img;
    img.w = 4; img.h = 2;
    img.rgba = new float[4 * 2 * 4];
    foreach (i; 0 .. 8) img.rgba[i * 4] = i;            // red = texel index
    immutable c = sampleBilinear(img, 1.5f / 4, 0.5f / 2, false);
    assert(near(c[0], 1), format("texel (1,0) centre read %s, expected 1", c[0]));
    immutable m = sampleBilinear(img, 2.0f / 4, 0.5f / 2, false);
    assert(near(m[0], 1.5f), format("between texels 1 and 2 read %s, expected 1.5", m[0]));
    immutable wrapped = sampleBilinear(img, 0.0f, 0.5f / 2, true);
    assert(near(wrapped[0], 1.5f), format("u = 0 wrapped read %s, expected (3 + 0) / 2", wrapped[0]));
    immutable clamped = sampleBilinear(img, 0.0f, 0.5f / 2, false);
    assert(near(clamped[0], 0), format("u = 0 clamped read %s, expected texel 0", clamped[0]));
}

/// One vendored image decodes through `decodePng16` to its size, alpha 65535;
/// `decodeShadingImage` multiplies the linear scale back (alpha stays 1).
unittest {
    int w, h;
    auto px = decodePng16(kEnvAssets[0].png, w, h);
    assert(px !is null && w == 512 && h == 256 && px.length == 512 * 256 * 4,
        format("env_" ~ kEnvAssets[0].name ~ ".png decoded to %dx%d (%d values), expected 512x256", w, h, px.length));
    size_t opaque;
    foreach (i; 0 .. w * h) if (px[i * 4 + 3] == 65535) ++opaque;
    assert(opaque == w * h, format("%d of %d pixels opaque, expected all", opaque, w * h));
    auto li = decodeShadingImage(kEnvAssets[0].png);
    assert(li.w == 512 && li.h == 256);
    foreach (i; [0, 1, 2, 1000, 512 * 256 * 4 - 2])
        assert(near(li.rgba[i], (i & 3) == 3 ? 1.0f : px[i] / 65535.0f * kShadingImageLinearScale),
            format("linear value %d is %s, expected stored/65535 × %s", i, li.rgba[i],
                   kShadingImageLinearScale));
    // An 8-bit PNG is refused, not widened — the 16-bit guard, reached with
    // a valid header (the dimension check passes it first).
    immutable icon = cast(immutable(ubyte)[]) import("png/vibe3d_16.png");
    int iw, ih;
    import io.image_decode : ImageInfo, imageInfo;
    ImageInfo info;
    assert(imageInfo(icon, info) && info.width == 16, "control: the 8-bit icon header must read");
    assert(decodePng16(icon, iw, ih) is null, "an 8-bit PNG must be refused, not widened");
}
