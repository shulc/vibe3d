module vibe3d.documents.image_codec.io.image_decode;

// Thin wrapper around the single-header image decoder, which lives in the
// `d-stb-image` shim (task 0662; it was vendored under third_party/stb_image
// when it landed in task 0616). Nothing outside this module (and its
// unittests) calls into the decoder directly -- everything else in the editor
// reaches pixels through this file. It is not called from anywhere yet: this
// is the decoder stage only, landing ahead of any consumer, the same way
// third_party/nfde landed ahead of the file-load command that first used it
// (task 0431).
//
// File I/O is deliberately NOT this module's job: callers read the file's
// bytes (typically `std.file.read`) and pass the buffer in. Two reasons,
// both load-bearing (see the shim's PATCHES.md): the decoder is compiled with
// STBI_NO_STDIO, whose fopen()-based file path cannot open a non-ASCII path
// on Windows; and a missing file becomes a real D exception raised by the
// caller's own `std.file.read`, not a decoder-internal fopen() failure that
// degrades to a bare null.

import std.string : fromStringz;
import std.format : format;

import vibe3d.util.log.log : logWarn;

private void imgWarn(string msg) nothrow { try logWarn("io", "image: " ~ msg); catch (Exception) {} }

// ---------------------------------------------------------------------------
// extern(C) surface of the decoder. It is declared by the shim
// (d-stb-image, source/stb_image/c.d) rather than here, because the shim is
// what chooses which entry points exist: STBI_NO_STDIO removes the file-path
// overloads from the compiled library entirely, so only the *_from_memory
// ones are declared over there -- there is nothing to link against for the
// others, and the binding stopping where the compiled library stops is what
// turns "called a file-path overload" into a link error instead of a runtime
// surprise.
// ---------------------------------------------------------------------------
import stb_image.c : stbi_info_from_memory, stbi_load_from_memory,
    stbi_image_free, stbi_failure_reason, STBI_MAX_DIMENSIONS_COMPILED;

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
// Layer 1 lives in the decoder itself (STBI_MAX_DIMENSIONS, compiled in by
// the d-stb-image shim's csrc/stb_image_impl.c). MAX_IMAGE_DIM below no
// longer re-types that number: the shim mirrors it as
// STBI_MAX_DIMENSIONS_COMPILED and this names that, so the two cannot drift
// across the repository boundary -- which was the drift that had no way of
// being noticed here.
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
// Naming the shim's mirror rather than repeating 16_384 removes the
// cross-repository sync duty, NOT layer 2. A shim that raised its cap would
// raise this with it, and the byte budget below is what would still refuse
// the resulting allocation.
enum MAX_IMAGE_DIM = STBI_MAX_DIMENSIONS_COMPILED;
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

// The 16-bit PNG entry points. The linked shim archive exports both (native
// and wasm: `nm -g … | grep stbi_load_16_from_memory` → `T`); its D binding
// does not declare them, so they are declared here.
private extern (C) @nogc nothrow {
    ushort* stbi_load_16_from_memory(const(ubyte)* buffer, int len, int* x,
        int* y, int* channels_in_file, int desired_channels);
    int stbi_is_16_bit_from_memory(const(ubyte)* buffer, int len);
}

/// Decodes a 16-bit-per-channel PNG as RGBA16 (row-major, top row first;
/// alpha 65535 when the file has none) into a GC array, `w`/`h` set. Behind
/// the same header + bound check as `imageDecode`; refuses (null) an 8-bit
/// file instead of widening it. The viewport shading images
/// (`viewport_env`) are its consumer.
ushort[] decodePng16(const(ubyte)[] bytes, out int w, out int h) {
    ImageInfo info;
    if (!imageInfo(bytes, info)) return null;
    if (!stbi_is_16_bit_from_memory(bytes.ptr, cast(int) bytes.length)) {
        imgWarn("decodePng16: not a 16-bit image");
        return null;
    }
    int dw, dh, comp;
    ushort* px = stbi_load_16_from_memory(bytes.ptr, cast(int) bytes.length,
        &dw, &dh, &comp, 4);
    if (px is null) {
        imgWarn("decode16 failed: " ~ failureReason());
        return null;
    }
    scope (exit) stbi_image_free(px);
    if (!dimensionsInBounds(dw, dh)) return null;
    w = dw;
    h = dh;
    return px[0 .. cast(size_t) dw * dh * 4].dup;
}

private string failureReason() {
    const(char)* r = stbi_failure_reason();
    return r is null ? "(unknown)" : cast(string) fromStringz(r);
}

