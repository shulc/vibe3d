module lwo;

import std.stdio     : File;
import std.file      : read;
import std.exception : enforce;
import std.algorithm : min;
import mesh;
import math;

// ---------------------------------------------------------------------------
// LWO2 export
// ---------------------------------------------------------------------------
// Produces a minimal but valid LWO2 file:
//   FORM <size> LWO2
//     PNTS <size>          -- float32 BE x/y/z per vertex
//     POLS <size>          -- "FACE" tag + (uint16 numVerts + VX indices) per face
//
// VX encoding: index < 0xFF00  →  2 bytes (uint16 BE)
//              index >= 0xFF00 →  4 bytes (0xFF, then 3-byte index BE)

void exportLWO(ref const Mesh mesh, string path)
{
    ubyte[] pnts;
    foreach (v; mesh.vertices) {
        writeF32(pnts, v.x);
        writeF32(pnts, v.y);
        writeF32(pnts, v.z);
    }

    ubyte[] pols;
    writeTag(pols, "FACE");
    foreach (face; mesh.faces) {
        writeU16(pols, cast(ushort) face.length);
        foreach (idx; face)
            writeVX(pols, idx);
    }

    ubyte[] body;
    appendChunk(body, "PNTS", pnts);
    appendChunk(body, "POLS", pols);

    // FORM size = 4 bytes for "LWO2" + body length
    ubyte[] out_;
    writeTag(out_, "FORM");
    writeU32(out_, cast(uint)(4 + body.length));
    writeTag(out_, "LWO2");
    out_ ~= body;

    auto f = File(path, "wb");
    f.rawWrite(out_);
}

// ---------------------------------------------------------------------------
// LWO2 import
// ---------------------------------------------------------------------------
// Reads PNTS and POLS(FACE) chunks; ignores all other chunks (SURF, TAGS, …).
// Raises Exception on malformed input.

Mesh importLWO(string path)
{
    ubyte[] data = cast(ubyte[]) read(path);

    enforce(data.length >= 12,          "File too small to be LWO2");
    enforce(data[0..4] == "FORM",       "Not an IFF file (no FORM header)");
    enforce(data[8..12] == "LWO2",      "Not an LWO2 file");

    uint   formSize = readU32(data, 4);
    size_t end      = min(cast(size_t)(8 + formSize), data.length);
    size_t pos      = 12;   // first sub-chunk starts after "LWO2"

    Vec3[]   verts;
    uint[][] polys;

    while (pos + 8 <= end) {
        ubyte[4] tagBytes = data[pos .. pos + 4];
        uint     sz       = readU32(data, pos + 4);
        pos += 8;
        size_t chunkEnd = pos + sz;

        if (tagBytes == "PNTS") {
            for (size_t i = pos; i + 12 <= chunkEnd; i += 12) {
                float x = readF32(data, i);
                float y = readF32(data, i + 4);
                float z = readF32(data, i + 8);
                verts ~= Vec3(x, y, z);
            }
        } else if (tagBytes == "POLS" && chunkEnd - pos >= 4) {
            ubyte[4] polyType = data[pos .. pos + 4];
            size_t   p        = pos + 4;
            if (polyType == "FACE") {
                while (p + 2 <= chunkEnd) {
                    ushort numVerts = readU16(data, p);
                    p += 2;
                    uint[] face;
                    face.reserve(numVerts);
                    for (int i = 0; i < numVerts && p < chunkEnd; i++)
                        face ~= readVX(data, p);
                    if (face.length >= 3)
                        polys ~= face;
                }
            }
        }

        pos = chunkEnd;
        if (pos & 1) pos++;   // IFF chunks are padded to even size
    }

    enforce(verts.length > 0, "LWO2 file contains no vertices");
    enforce(polys.length > 0, "LWO2 file contains no polygons");

    Mesh m;
    m.vertices = verts;
    uint[ulong] edgeLookup;
    foreach (face; polys)
        m.addFaceFast(edgeLookup, face);
    return m;
}

// ---------------------------------------------------------------------------
// Private helpers — big-endian I/O
// ---------------------------------------------------------------------------

private:

void writeU16(ref ubyte[] buf, ushort v) {
    buf ~= cast(ubyte)(v >> 8);
    buf ~= cast(ubyte)(v);
}

void writeU32(ref ubyte[] buf, uint v) {
    buf ~= cast(ubyte)(v >> 24);
    buf ~= cast(ubyte)(v >> 16);
    buf ~= cast(ubyte)(v >>  8);
    buf ~= cast(ubyte)(v);
}

void writeF32(ref ubyte[] buf, float v) {
    writeU32(buf, *cast(uint*)&v);
}

void writeTag(ref ubyte[] buf, string tag)
in (tag.length == 4)
{
    foreach (c; tag) buf ~= cast(ubyte) c;
}

// Variable-length index
void writeVX(ref ubyte[] buf, uint idx) {
    if (idx < 0xFF00) {
        writeU16(buf, cast(ushort) idx);
    } else {
        buf ~= 0xFF;
        buf ~= cast(ubyte)(idx >> 16);
        buf ~= cast(ubyte)(idx >>  8);
        buf ~= cast(ubyte)(idx);
    }
}

void appendChunk(ref ubyte[] out_, string tag, const ubyte[] data) {
    writeTag(out_, tag);
    writeU32(out_, cast(uint) data.length);
    out_ ~= data;
    if (data.length & 1) out_ ~= 0;   // pad to even
}

ushort readU16(const ubyte[] buf, size_t off) {
    return cast(ushort)((cast(ushort) buf[off] << 8) | buf[off + 1]);
}

uint readU32(const ubyte[] buf, size_t off) {
    return (cast(uint) buf[off]     << 24)
         | (cast(uint) buf[off + 1] << 16)
         | (cast(uint) buf[off + 2] <<  8)
         |  cast(uint) buf[off + 3];
}

float readF32(const ubyte[] buf, size_t off) {
    uint bits = readU32(buf, off);
    return *cast(float*)&bits;
}

uint readVX(const ubyte[] buf, ref size_t pos) {
    if (buf[pos] == 0xFF) {
        uint idx = (cast(uint) buf[pos + 1] << 16)
                 | (cast(uint) buf[pos + 2] <<  8)
                 |  cast(uint) buf[pos + 3];
        pos += 4;
        return idx;
    } else {
        uint idx = readU16(buf, pos);
        pos += 2;
        return idx;
    }
}
