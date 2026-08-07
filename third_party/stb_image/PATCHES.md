# Vendored `stb_image` — pin and local configuration

This directory is a **vendored** copy of a single-header image decoder
(`stb_image.h` by Sean Barrett, dual MIT / public-domain licensed), vendored
into vibe3d in task 0616 to give the editor a way to read pixels out of an
image file. Nothing in the editor calls it yet — it lands on its own, ahead
of any consumer, mirroring how `third_party/nfde` (task 0431) was vendored
independently of its first caller.

## Upstream pin

| Component | Upstream | Pin |
|-----------|----------|-----|
| `stb_image.h` | `github.com/nothings/stb` | commit `013ac3beddff3dbffafd5177e7972067cd2b5083` (in-file version tag `v2.30`); file unmodified, byte-identical to upstream |

Only `stb_image.h` was vendored — none of the other single-header libraries
in the same upstream repository, and none of its `tests/`, `tools/`, or other
unrelated headers.

## Why CMake+Ninja, the same as `third_party/nfde`

This decoder is a **single translation unit** — `stb_image_impl.c` `#define`s
the implementation macro and the local configuration, then `#include`s the
unmodified header — so the obvious first try was to skip a build system
entirely and list it as a plain `.c` entry in dub's own `sourceFiles`. That
does not work on this project's dev host: dub's built-in C-source compilation
routes through the D compiler's own C front end (DMD/LDC's ImportC), and
ImportC fails parsing this system's `<stddef.h>` — Fedora 43's glibc headers
(GCC 15) use a C23 `nullptr` construct ImportC does not understand:

```
/usr/lib/gcc/.../stddef.h(465,18): Error: undefined identifier `nullptr`, did
you mean alias `nullptr_t`?
```

That is not an `stb_image`-specific bug (a trivial one-line `.c` file with no
`#include`s compiles fine the same way); it is ImportC failing on real system
headers, which the previous vendoring decision anticipated is a landmine
(cf. `doc/image_clip_list_plan.md`, risk R4: "ImportC instead of a static lib
would avoid CMake but stakes the build on preprocessing a large single-header
C file — Rejected"). So this package uses a one-file `CMakeLists.txt` that
invokes the platform's real C compiler through CMake+Ninja, mirroring
`third_party/nfde`'s shape exactly (same `$<PACKAGE>_PACKAGE_DIR` env-var
convention, same `-DCMAKE_GENERATOR=Ninja` on all three platforms). That
prerequisite already exists in this build because of `nfde`, so this adds no
*new* system dependency, only a second (much smaller) user of the existing
one.

## Local configuration (`stb_image_impl.c`, not a patch to the header)

The header itself carries **zero modifications** — every `#define` that
shapes the build lives in `stb_image_impl.c`, ahead of the `#include`:

- `STBI_NO_STDIO` — the decoder's file-opening path is `fopen()`, which
  cannot open a non-ASCII path on Windows. vibe3d reads the file's bytes in D
  (`std.file.read`) and decodes from a memory buffer; a missing file is then
  a real error raised in D, not a decoder-internal `fopen()` failure.
- `STBI_ONLY_PNG` / `STBI_ONLY_JPEG` / `STBI_ONLY_TGA` / `STBI_ONLY_BMP` —
  restricts the compiled format set. PNG + JPEG match what vibe3d's image
  picker already advertises; TGA + BMP decode through the same code for free.
  HDR / EXR / PSD / GIF / WebP are not compiled in.
- `STBI_MAX_DIMENSIONS 16384` — the compile-time half of the two-layer bound
  on image width/height (a number that comes from a file vibe3d did not write
  and scales a pixel-buffer allocation). The wrapper
  (`source/io/image_decode.d`) re-checks width, height, **and** the resulting
  byte count after reading the header and before decoding pixels — the
  wrapper's check is the one that survives a re-vendor of this file that
  forgets this define, and it does independent work: the two layers differ
  on **area**, not aspect ratio. An image whose width and height are each
  individually within this per-axis cap (e.g. both axes near 16384, not a
  wide-and-short shape) can still sit inside the cap and fail the wrapper's
  byte-budget check. See that module's own comment for the numbers.

## Re-vendoring

To pick up a newer `stb_image.h`: replace the file verbatim, update the pin
above, and re-run the three crafted-header checks in
`source/io/image_decode.d`'s `unittest` blocks — they exercise both clamp
layers directly, not the decoder's documentation, and it matters which layer
each one exercises:

- The **layer-1** check calls the decoder's own `stbi_info_from_memory`
  directly (not through the `imageInfo()` wrapper) with a header that is
  large on one axis only, past `STBI_MAX_DIMENSIONS`, and small on the
  other. A header where both axes are near the cap (what an earlier version
  of this check used) also trips the decoder's *other*, unconditional
  total-size guard regardless of `STBI_MAX_DIMENSIONS`, so it can't tell you
  whether the compile-time cap still does anything — it doesn't discriminate.
  Going through `imageInfo()` doesn't discriminate either: the wrapper has
  its own independent per-axis check that rejects the same header on its
  own. If you change `STBI_MAX_DIMENSIONS`, sanity-check this one by
  temporarily removing the define here and confirming the check then fails
  (i.e. the decoder now accepts the header) before you restore it.
- The **layer-2** check goes through `imageInfo()` with a header at exactly
  `MAX_IMAGE_DIM` x `MAX_IMAGE_DIM` (both axes at, not past, the per-axis
  cap) and confirms the wrapper's byte-budget check still rejects it.

Also confirm the four `STBI_ONLY_*` macro names above still match the
upstream header — they are just C preprocessor tokens; a typo silently
disables that format's decoder with no compile error.
