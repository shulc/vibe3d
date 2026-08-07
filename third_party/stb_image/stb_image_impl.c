/* Vendored into vibe3d (task 0616). See PATCHES.md for the upstream pin and
 * the reasoning behind each #define below. stb_image.h itself is unmodified
 * upstream source; this is the one translation unit that instantiates the
 * implementation with vibe3d's chosen configuration. */

#define STB_IMAGE_IMPLEMENTATION

/* File I/O is disabled on purpose: vibe3d reads the file's bytes in D and
 * decodes from memory. Two reasons, not one: the decoder's stdio path is
 * fopen(), which cannot open a non-ASCII path on Windows; and a missing file
 * is then a real error raised by our own code (source/io/image_decode.d),
 * not a decoder-internal fopen() failure reported as a bare null. Only the
 * *_from_memory entry points are compiled in. */
#define STBI_NO_STDIO

/* Restricted format set: PNG and JPEG are the pair vibe3d's image picker
 * already advertises; TGA and BMP decode with the same code and cost nothing
 * extra. HDR/EXR/PSD/GIF/WebP are deliberately not compiled in. */
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_TGA
#define STBI_ONLY_BMP

/* Compile-time layer of the two-layer bound on the one file-supplied number
 * that scales an allocation (image width/height, read from a file vibe3d did
 * not write). This makes a header claiming an enormous image fail inside the
 * decoder before any pixel buffer is allocated. The wrapper
 * (source/io/image_decode.d) re-checks width/height AND the resulting byte
 * count after reading the header and before decoding pixels -- that second
 * check is the one that survives a re-vendor of this file that forgets this
 * define; it does real, independent work (an image whose width AND height
 * are each individually within this per-axis cap -- large AREA, not a wide
 * aspect ratio -- can still pass this cap and fail the wrapper's byte-budget
 * check). Keep the two numbers in sync; if they drift, the wrapper's check
 * is the one load-bearing bound, this one is defense in depth. */
#define STBI_MAX_DIMENSIONS 16384

#include "stb_image.h"
