module vibe3d.documents.image_codec.tests.unit.io.image_decode_source_cells_test;

import vibe3d.documents.image_codec.io.image_decode;
import std.format;
import stb_image.c;

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
// descriptor bit 0x20), BGRA pixel storage -- confirmed against the shim's
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


// T1c -- bounds, layer 2 catches what layer 1 (the compile-time per-axis
// cap) cannot by construction: a header whose width AND height each sit at
// or under the decoder's own STBI_MAX_DIMENSIONS, but whose product still
// implies a pixel buffer far past this wrapper's byte budget. Confirmed
// offline that the shim's decoder's own header parse accepts 16384x16384
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
// 16384` from the d-stb-image shim's csrc/stb_image_impl.c (falling back to
// the header's own default of `1 << 24`) and rebuilding its static lib makes
// stbi_info_from_memory ACCEPT this exact header (reports width ==
// MAX_IMAGE_DIM + 1000, height == 4) -- i.e. the assertion below fails
// without the cap, and passes again once the define is restored. Note that
// MAX_IMAGE_DIM here is the shim's own mirrored constant, so it does NOT
// move when the define is deleted; the input stays the same and only the
// decoder's answer changes, which is what makes this discriminating.
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
