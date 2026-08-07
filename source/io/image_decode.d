module io.image_decode;

// Thin wrapper around the vendored single-header image decoder
// (third_party/stb_image). Nothing outside this module (and its unittests)
// calls into the decoder directly -- everything else in the editor reaches
// pixels through this file. It is not called from anywhere yet: this is the
// decoder stage only (task 0616), landing ahead of any consumer, the same
// way third_party/nfde landed ahead of the file-load command that first used
// it (task 0431).
//
// File I/O is deliberately NOT this module's job: callers read the file's
// bytes (typically `std.file.read`) and pass the buffer in. Two reasons,
// both load-bearing (see third_party/stb_image/PATCHES.md): the decoder is
// compiled with STBI_NO_STDIO, whose fopen()-based file path cannot open a
// non-ASCII path on Windows; and a missing file becomes a real D exception
// raised by the caller's own `std.file.read`, not a decoder-internal fopen()
// failure that degrades to a bare null.

import std.string : fromStringz;
import std.format : format;

import log : logWarn;

private void imgWarn(string msg) nothrow { try logWarn("io", "image: " ~ msg); catch (Exception) {} }

// ---------------------------------------------------------------------------
// extern(C) surface of the vendored decoder. STBI_NO_STDIO
// (third_party/stb_image/stb_image_impl.c) removes the file-path overloads
// from the compiled library entirely, so only the *_from_memory entry points
// are declared here -- there is nothing to link against for the others.
// ---------------------------------------------------------------------------
private extern (C) nothrow @nogc {
    int stbi_info_from_memory(const(ubyte)* buffer, int len, int* x, int* y, int* comp);
    ubyte* stbi_load_from_memory(const(ubyte)* buffer, int len, int* x, int* y, int* comp, int req_comp);
    void stbi_image_free(void* retval_from_stbi_load);
    const(char)* stbi_failure_reason();
}

/// Header-only metadata: dimensions and the channel count present in the
/// SOURCE file (1 = gray, 2 = gray+alpha, 3 = RGB, 4 = RGBA). Produced by
/// `imageInfo` without decoding a single pixel.
struct ImageInfo {
    int width;
    int height;
    int channels;
}

/// A decoded RGBA pixel buffer. The memory is owned by this struct until
/// `free()` releases it back to the decoder's allocator -- callers (and the
/// refcounted pixel cache a later stage builds on top of this) must call it
/// exactly once when the pixels are no longer needed.
///
/// Not copyable: this struct owns a raw pointer via `free()`'s
/// `stbi_image_free()` call, and a bitwise copy would let two owners free
/// (or one owner double-free) the same buffer. A refcounted wrapper can be
/// built on top of this by holding it inside something that itself has real
/// reference-counting, not by copying `DecodedImage` around.
struct DecodedImage {
    int width;
    int height;
    int channels; // always 4 -- imageDecode() always requests RGBA
    private ubyte* data_;
    private size_t length_;

    @disable this(this);

    @property inout(ubyte)[] pixels() inout return {
        return data_ is null ? null : data_[0 .. length_];
    }

    @property bool valid() const { return data_ !is null; }

    /// Releases the pixel buffer. Safe to call more than once, and a no-op
    /// on a struct that was never successfully decoded.
    void free() {
        if (data_ !is null) {
            stbi_image_free(cast(void*) data_);
            data_ = null;
            length_ = 0;
        }
    }
}

// ---------------------------------------------------------------------------
// The two-layer bound on the one file-supplied number that scales an
// allocation: image width/height, read from a file this process did not
// write.
//
// Layer 1 lives in the decoder itself (STBI_MAX_DIMENSIONS, compiled into
// third_party/stb_image via stb_image_impl.c) -- MAX_IMAGE_DIM below must be
// kept in sync with that define.
//
// Layer 2 is dimensionsInBounds(), run after the header is read and before
// any pixel decode. It is the layer that survives a re-vendor that forgets
// the compile define, and it is not redundant with layer 1: the two layers
// differ on AREA, not on aspect ratio -- an image whose width AND height are
// each individually within the per-axis cap (e.g. 16000x16000, comfortably
// under it on both axes) can still decode to a ~1 GiB RGBA buffer, which
// only the byte-budget check below catches; a genuinely wide-and-short
// image (large width, small height) passes both checks comfortably and is
// not the case that distinguishes the two layers. Proven against a crafted
// header in this module's unittests, not against the decoder's
// documentation.
// ---------------------------------------------------------------------------
enum MAX_IMAGE_DIM = 16_384;
enum size_t MAX_IMAGE_BYTES = 256UL * 1024 * 1024; // 256 MiB of decoded RGBA

private bool dimensionsInBounds(int w, int h) {
    if (w <= 0 || h <= 0) return false;
    if (w > MAX_IMAGE_DIM || h > MAX_IMAGE_DIM) return false;
    immutable ulong pixelCount = cast(ulong) w * cast(ulong) h;
    immutable ulong byteCount  = pixelCount * 4; // imageDecode always requests RGBA
    return byteCount <= MAX_IMAGE_BYTES;
}

/// Reads width/height/channel-count from a file already loaded into memory,
/// without decoding any pixel data -- no allocation proportional to image
/// size happens on this path. Returns false, with a reason logged, if the
/// header cannot be parsed, or if the declared dimensions fail the bound
/// above (in which case failure is reported before stbi even finishes
/// parsing far enough to attempt an allocation).
bool imageInfo(const(ubyte)[] fileBytes, out ImageInfo info) {
    if (fileBytes.length == 0 || fileBytes.length > int.max) {
        imgWarn(format("rejected: buffer length %d out of range", fileBytes.length));
        return false;
    }
    int w, h, comp;
    immutable ok = stbi_info_from_memory(fileBytes.ptr, cast(int) fileBytes.length, &w, &h, &comp);
    if (!ok) {
        imgWarn("header read failed: " ~ failureReason());
        return false;
    }
    if (!dimensionsInBounds(w, h)) {
        imgWarn(format("rejected %dx%d: exceeds the %dx%d / %d-byte decode bound",
            w, h, MAX_IMAGE_DIM, MAX_IMAGE_DIM, MAX_IMAGE_BYTES));
        return false;
    }
    info = ImageInfo(w, h, comp);
    return true;
}

/// Decodes pixel data as RGBA (4 bytes/pixel, row-major, top row first) from
/// a file already loaded into memory. Always runs the header + bound check
/// (imageInfo) first, so a header that fails the bound is rejected before
/// the decoder's allocating pixel path is ever reached. On success,
/// `img.pixels` is caller-owned until `img.free()` is called.
///
/// `img` is taken by `ref`, not `out`: D zero-initializes an `out`
/// parameter on entry regardless of what the callee does, which would
/// silently orphan any buffer a reused `DecodedImage` slot already owned
/// (exactly the shape a refcounted pixel cache writes into repeatedly).
/// Taking it by `ref` means the line below actually observes -- and frees
/// -- the caller's prior state before it's overwritten.
bool imageDecode(const(ubyte)[] fileBytes, ref DecodedImage img) {
    img.free(); // release whatever this slot already owned before reuse
    img = DecodedImage.init;

    ImageInfo info;
    if (!imageInfo(fileBytes, info)) return false; // layer 2 clamp fires here, before any decode

    int w, h, comp;
    ubyte* px = stbi_load_from_memory(fileBytes.ptr, cast(int) fileBytes.length, &w, &h, &comp, 4);
    if (px is null) {
        imgWarn("decode failed: " ~ failureReason());
        return false;
    }
    // Re-check against the dimensions the decode itself returned, not just
    // the ones imageInfo already validated above: w/h here come from a
    // second, independent parse (stbi_load_from_memory, not
    // stbi_info_from_memory), and nothing enforces that the two agree on
    // every possible decoder implementation. They do today, but the byte
    // budget is only actually meaningful if it is checked against the
    // buffer that was really allocated.
    if (!dimensionsInBounds(w, h)) {
        stbi_image_free(px);
        imgWarn(format("decoded %dx%d exceeds bounds after the fact (header reported %dx%d)",
            w, h, info.width, info.height));
        return false;
    }
    img = DecodedImage(w, h, 4, px, cast(size_t) w * cast(size_t) h * 4);
    return true;
}

private string failureReason() {
    const(char)* r = stbi_failure_reason();
    return r is null ? "(unknown)" : cast(string) fromStringz(r);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
    import std.digest.crc : crc32Of;
    import std.bitmanip : nativeToBigEndian;

    // A hand-rolled zlib (RFC 1950) stream wrapping one or more DEFLATE
    // (RFC 1951) "stored" (uncompressed) blocks -- deliberately not
    // `std.zlib.compress`: that pulls in Phobos's bundled zlib object, which
    // clashes (duplicate `inflate_copyright` / `z_errmsg` symbols at link
    // time) with the separate static zlib bundled by this build's assimp
    // dependency. A stored block needs no compression at all, so this is a
    // handful of RFC-defined bytes, not a reimplementation of deflate.
    private ubyte[] zlibStore(const(ubyte)[] raw) {
        ubyte[] out_ = [0x78, 0x01]; // CMF/FLG: deflate, 32K window, valid FCHECK
        size_t off = 0;
        do {
            immutable size_t n = raw.length - off > 65_535 ? 65_535 : raw.length - off;
            immutable bool last = (off + n) == raw.length;
            out_ ~= cast(ubyte)(last ? 1 : 0); // BFINAL | BTYPE(00), byte-aligned
            immutable ushort len  = cast(ushort) n;
            immutable ushort nlen = cast(ushort) ~len;
            out_ ~= [cast(ubyte)(len & 0xFF), cast(ubyte)(len >> 8)];
            out_ ~= [cast(ubyte)(nlen & 0xFF), cast(ubyte)(nlen >> 8)];
            out_ ~= raw[off .. off + n];
            off += n;
        } while (off < raw.length);

        uint a = 1, b = 0;
        foreach (v; raw) {
            a = (a + v) % 65_521;
            b = (b + a) % 65_521;
        }
        immutable uint adler = (b << 16) | a;
        out_ ~= nativeToBigEndian(adler)[];
        return out_;
    }

    // A minimal, valid, uncompressed-content PNG built byte-by-byte: 3 wide,
    // 2 tall, 8-bit RGBA, filter type 0 (None) on every scanline. Six pixels,
    // each with four distinct channel values, no two pixels equal, and
    // width != height -- see the discriminating-case note on T1 below.
    private ubyte[] chunk(string ctype, const(ubyte)[] data) {
        ubyte[] out_;
        out_ ~= nativeToBigEndian(cast(uint) data.length)[];
        auto typeBytes = cast(const(ubyte)[]) ctype;
        out_ ~= typeBytes;
        out_ ~= data;
        ubyte[] crcInput = typeBytes.dup ~ data;
        // PNG's chunk CRC is the same CRC-32 (IEEE 802.3) zlib/gzip use.
        // std.digest.crc returns bytes least-significant-first; PNG wants
        // the raw CRC-32 word big-endian, i.e. the digest bytes reversed.
        auto digest = crc32Of(crcInput);
        ubyte[4] crcBytes = [digest[3], digest[2], digest[1], digest[0]];
        out_ ~= crcBytes[];
        return out_;
    }

    private ubyte[] buildTestPng(int w, int h, const(ubyte)[4][] pixels) {
        ubyte[] png;
        png ~= [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        ubyte[] ihdrData;
        ihdrData ~= nativeToBigEndian(cast(uint) w)[];
        ihdrData ~= nativeToBigEndian(cast(uint) h)[];
        ihdrData ~= [ubyte(8), ubyte(6), ubyte(0), ubyte(0), ubyte(0)]; // 8-bit RGBA, no interlace
        png ~= chunk("IHDR", ihdrData);

        ubyte[] raw;
        foreach (y; 0 .. h) {
            raw ~= ubyte(0); // filter: None
            foreach (x; 0 .. w) raw ~= pixels[y * w + x][];
        }
        png ~= chunk("IDAT", zlibStore(raw));
        png ~= chunk("IEND", []);
        return png;
    }

    private ubyte[4][] sixDistinctPixels() {
        ubyte[4][] px;
        foreach (i; 0 .. 6) {
            px ~= [
                cast(ubyte)(10 + i * 40),
                cast(ubyte)(20 + i * 40),
                cast(ubyte)(30 + i * 40),
                cast(ubyte)(200 + i * 8),
            ];
        }
        return px;
    }
}

// T1 -- a real decode, checked against independently-stated pixel values.
// Discriminating: every one of the six pixels has four distinct channel
// values and no two pixels are equal, and width != height. A channel swap
// (RGBA<->BGRA), a row flip, a stride error and a transpose each read a
// different byte here -- a 1x1 white pixel would pass all four bugs.
unittest {
    const px = sixDistinctPixels();
    auto png = buildTestPng(3, 2, px);

    DecodedImage img;
    immutable ok = imageDecode(png, img);
    assert(ok, "expected the hand-built 3x2 PNG to decode");
    scope (exit) img.free();

    assert(img.width == 3);
    assert(img.height == 2);
    assert(img.width != img.height);
    assert(img.channels == 4);
    assert(img.pixels.length == 3 * 2 * 4);

    foreach (i; 0 .. 6) {
        immutable base = i * 4;
        // format("%d", i) -- NOT `i.stringof`, which is the compile-time
        // source text of the expression "i" (always the literal string
        // "i"), not its runtime value; every message below would otherwise
        // name the same pixel regardless of which iteration failed.
        assert(img.pixels[base + 0] == px[i][0], format("R mismatch at pixel %d", i));
        assert(img.pixels[base + 1] == px[i][1], format("G mismatch at pixel %d", i));
        assert(img.pixels[base + 2] == px[i][2], format("B mismatch at pixel %d", i));
        assert(img.pixels[base + 3] == px[i][3], format("A mismatch at pixel %d", i));
    }
}

// T1 (info half) -- imageInfo() alone reports the same dimensions as a full
// decode, and is a structurally separate call: its return type carries no
// pixel data at all, so there is nothing to decode-and-discard by accident.
unittest {
    const px = sixDistinctPixels();
    auto png = buildTestPng(3, 2, px);

    ImageInfo info;
    assert(imageInfo(png, info));
    assert(info.width == 3);
    assert(info.height == 2);
    assert(info.channels == 4);
}

// A second format, to catch a botched restricted-format compile define
// (e.g. a typo'd STBI_ONLY_TGA) independently of the PNG path above. TGA
// needs no compression or CRC, just a header: 32bpp, top-left origin (image
// descriptor bit 0x20), BGRA pixel storage -- confirmed against the vendored
// decoder offline before this file was written.
unittest {
    const px = sixDistinctPixels();
    ubyte[] tga;
    tga ~= [ubyte(0), ubyte(0), ubyte(2)]; // no id, no colormap, uncompressed truecolor
    tga ~= [ubyte(0), ubyte(0), ubyte(0), ubyte(0), ubyte(0)]; // colormap spec, unused
    tga ~= [ubyte(0), ubyte(0), ubyte(0), ubyte(0)]; // x/y origin
    ushort w = 3, h = 2;
    tga ~= [cast(ubyte)(w & 0xFF), cast(ubyte)(w >> 8), cast(ubyte)(h & 0xFF), cast(ubyte)(h >> 8)];
    tga ~= [ubyte(32), ubyte(0x28)]; // 32bpp, top-left origin + 8 alpha bits
    foreach (p; px) tga ~= [p[2], p[1], p[0], p[3]]; // BGRA on disk

    DecodedImage img;
    assert(imageDecode(tga, img));
    scope (exit) img.free();
    assert(img.width == 3 && img.height == 2);
    assert(img.channels == 4);
    assert(img.pixels.length == 3 * 2 * 4);
    foreach (i; 0 .. 6) {
        immutable base = i * 4;
        assert(img.pixels[base .. base + 4] == px[i][]);
    }
}

// S4 -- DecodedImage must not be copyable: it owns a raw pointer released by
// free()/stbi_image_free(), and a bitwise copy would let two owners each
// call free() on the same buffer (or a by-value pass free() it and leave
// the caller's copy pointing at freed memory). This is a compile-time
// property, not a runtime one -- a normal assert can't observe "was this
// struct copied", but __traits(compiles) can observe whether the copy is
// even legal to write, so that's what's checked here instead of a runtime
// unittest. Discriminating: temporarily deleting `@disable this(this);`
// from the struct definition and re-running `dub test` turns this from a
// pass into a compile-time error at the static assert below -- i.e. the
// same D language mechanism that would let a real copy-then-double-free bug
// through is exactly what this line refuses to compile.
unittest {
    static assert(!__traits(compiles, {
        DecodedImage a;
        DecodedImage b = a; // copy-construct from an lvalue -- must not compile
    }), "DecodedImage must not be copy-constructible (S4: prevents a double stbi_image_free)");
}

// T1c -- bounds, layer 2 catches what layer 1 (the compile-time per-axis
// cap) cannot by construction: a header whose width AND height each sit at
// or under the decoder's own STBI_MAX_DIMENSIONS, but whose product still
// implies a pixel buffer far past this wrapper's byte budget. Confirmed
// offline that the vendored decoder's own header parse accepts 16384x16384
// outright (its cap is a strict per-axis ">", not a product check) -- so if
// the check below were ever deleted, this exact input would sail past
// imageInfo and into a ~1 GiB stbi_load_from_memory allocation.
unittest {
    // Width/height claimed by the header; IDAT content is irrelevant here --
    // stbi_info_from_memory never reads past IHDR.
    ubyte[] ihdrData;
    ihdrData ~= nativeToBigEndian(cast(uint) MAX_IMAGE_DIM)[];
    ihdrData ~= nativeToBigEndian(cast(uint) MAX_IMAGE_DIM)[];
    ihdrData ~= [ubyte(8), ubyte(6), ubyte(0), ubyte(0), ubyte(0)];

    ubyte[] png;
    png ~= [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    png ~= chunk("IHDR", ihdrData);
    png ~= chunk("IDAT", zlibStore(cast(ubyte[])[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    png ~= chunk("IEND", []);

    ImageInfo info;
    assert(!imageInfo(png, info), "a 16384x16384 header must be rejected by the wrapper's byte budget");

    DecodedImage img;
    assert(!imageDecode(png, img), "imageDecode must refuse what imageInfo refused, without attempting a decode");
    assert(!img.valid);
}

// T1c -- bounds, layer 1: a header large on ONE axis only -- past the
// decoder's own per-axis compile-time cap (STBI_MAX_DIMENSIONS) -- and tiny
// on the other, so the decoder's OTHER, unconditional total-size guard
// (stb_image.h's PNG IHDR handler: `(1 << 30) / img_x / img_n < img_y`,
// nothing to do with STBI_MAX_DIMENSIONS) does not also reject it. A
// square header at (MAX_IMAGE_DIM+1) x MAX_IMAGE_DIM -- what an earlier
// version of this test used -- trips BOTH guards at once: with img_n == 4,
// that guard is `(1<<30)/img_x/4 < img_y`, which is already violated at
// img_x == img_y == MAX_IMAGE_DIM (both guards top out at essentially the
// same ~2^28-pixel area), so that input stayed rejected even if
// STBI_MAX_DIMENSIONS were deleted from stb_image_impl.c entirely -- the
// assertion held for a reason that had nothing to do with the thing it
// claimed to test. The asymmetric shape below keeps the total pixel count
// tiny (width * 4 * height is a few hundred thousand, nowhere near 2^30) so
// only the per-axis cap can be the reason for rejection.
//
// The assertion is against the raw decoder entry point
// (stbi_info_from_memory), not imageInfo(): imageInfo()'s own
// dimensionsInBounds() has an independent `w > MAX_IMAGE_DIM` check (layer
// 2 duplicating layer 1's per-axis shape), which would reject this same
// header on its own regardless of what the decoder does -- asserting
// through the wrapper would also prove nothing about layer 1.
//
// Break-and-restore: temporarily removing `#define STBI_MAX_DIMENSIONS
// 16384` from third_party/stb_image/stb_image_impl.c (falling back to the
// header's own default of `1 << 24`) and rebuilding the vendored static lib
// makes stbi_info_from_memory ACCEPT this exact header (reports width ==
// MAX_IMAGE_DIM + 1000, height == 4) -- i.e. the assertion below fails
// without the cap, and passes again once the define is restored.
unittest {
    enum w = MAX_IMAGE_DIM + 1_000; // past the per-axis cap...
    enum h = 4;                     // ...but tiny, so img_x*img_n*img_y is
                                     // far under the decoder's unconditional
                                     // total-size guard at this width.

    ubyte[] ihdrData;
    ihdrData ~= nativeToBigEndian(cast(uint) w)[];
    ihdrData ~= nativeToBigEndian(cast(uint) h)[];
    ihdrData ~= [ubyte(8), ubyte(6), ubyte(0), ubyte(0), ubyte(0)];

    ubyte[] png;
    png ~= [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    png ~= chunk("IHDR", ihdrData);
    png ~= chunk("IDAT", zlibStore(cast(ubyte[])[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    png ~= chunk("IEND", []);

    int ow, oh, ocomp;
    immutable ok = stbi_info_from_memory(png.ptr, cast(int) png.length, &ow, &oh, &ocomp);
    assert(!ok, "a header past STBI_MAX_DIMENSIONS on one axis, but tiny on the other, "
        ~ "must be rejected by the decoder's own per-axis cap -- its total pixel count "
        ~ "is nowhere near the decoder's other, unconditional size guard");
}

// A garbage buffer (not any recognisable format) is rejected cleanly, not
// crashed on -- imageInfo and imageDecode both hand back false with a
// logged reason rather than a null-pointer surprise further up the stack.
//
// PNG/JPEG/BMP reject this outright on their magic bytes (this buffer
// starts with neither `\x89PNG`, `\xFF\xD8`, nor `BM`). TGA carries no magic
// at all, so byte[1] is deliberately set past what stbi__tga_test accepts
// as a "color type" (0 or 1) -- that is its very first structural check, so
// this is rejected for TGA regardless of every other byte. An earlier
// version of this array (plain 0..9) happened to also fail TGA, but only
// because byte[1]==1 ("colormapped") paired with byte[2]==2 (not colormap
// image type 1 or 9) -- change either of those two bytes in isolation and a
// colormap-shaped TGA header could have been accepted instead.
unittest {
    ubyte[] junk = [0, 255, 2, 3, 4, 5, 6, 7, 8, 9];
    ImageInfo info;
    assert(!imageInfo(junk, info));
    DecodedImage img;
    assert(!imageDecode(junk, img));
    assert(!img.valid);
}
