// Module unittests for `io.image_decode`, moved verbatim out of source/io/image_decode.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.io.image_decode_test;

import std.string : fromStringz;
import std.format : format;
import log : logWarn;
import std.digest.crc : crc32Of;
import std.bitmanip : nativeToBigEndian;
import io.image_decode;

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
