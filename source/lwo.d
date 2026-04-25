module lwo;

import std.stdio     : File, stderr, writefln;
import std.file      : read, exists, getSize;
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

bool importLWO(string path, ref Mesh mesh)
{
    stderr.writefln("[LWO] importLWO: path=%s", path);

    if (!exists(path)) {
        stderr.writefln("[LWO] file does not exist");
        return false;
    }
    stderr.writefln("[LWO] file size = %d bytes", getSize(path));

    ubyte[] data = cast(ubyte[]) read(path);
    stderr.writefln("[LWO] read %d bytes", data.length);

    if (data.length < 12) {
        stderr.writefln("[LWO] reject: file too small (%d < 12)", data.length);
        return false;
    }
    if (data[0..4] != "FORM") {
        stderr.writefln("[LWO] reject: missing FORM header, got %s",
                        cast(string) data[0..4].idup);
        return false;
    }
    if (data[8..12] != "LWO2") {
        stderr.writefln("[LWO] reject: not LWO2, header=%s",
                        cast(string) data[8..12].idup);
        return false;
    }

    uint   formSize = readU32(data, 4);
    size_t end      = min(cast(size_t)(8 + formSize), data.length);
    size_t pos      = 12;   // first sub-chunk starts after "LWO2"
    stderr.writefln("[LWO] formSize=%d, end=%d, parse from pos=%d",
                    formSize, end, pos);

    Vec3[]   verts;
    uint[][] polys;
    bool[]   polyIsSubpatch;     // parallel to polys — true for PTCH entries
    int      faceChunks     = 0;
    int      subpatchChunks = 0;
    int      nonFaceChunks  = 0;
    int      skippedByArity = 0;

    while (pos + 8 <= end) {
        ubyte[4] tagBytes = data[pos .. pos + 4];
        uint     sz       = readU32(data, pos + 4);
        pos += 8;
        size_t chunkEnd = pos + sz;
        if (chunkEnd > end) {
            stderr.writefln("[LWO] chunk %s size=%d overflows container " ~
                            "(pos=%d, end=%d), truncating",
                            cast(string) tagBytes[].idup, sz, pos, end);
            chunkEnd = end;
        }

        if (tagBytes == "PNTS") {
            size_t count0 = verts.length;
            for (size_t i = pos; i + 12 <= chunkEnd; i += 12) {
                float x = readF32(data, i);
                float y = readF32(data, i + 4);
                float z = readF32(data, i + 8);
                verts ~= Vec3(x, y, z);
            }
            stderr.writefln("[LWO] PNTS: %d verts (+%d)",
                            verts.length, verts.length - count0);
        } else if (tagBytes == "POLS" && chunkEnd - pos >= 4) {
            ubyte[4] polyType = data[pos .. pos + 4];
            size_t   p        = pos + 4;
            // FACE = ordinary polygons; PTCH = LightWave Catmull-Clark
            // subpatches (same on-disk format, interpreted as subpatches).
            bool isFace = (polyType == "FACE");
            bool isPtch = (polyType == "PTCH");
            if (isFace || isPtch) {
                if (isFace) ++faceChunks; else ++subpatchChunks;
                size_t count0 = polys.length;
                while (p + 2 <= chunkEnd) {
                    ushort numVerts = readU16(data, p);
                    p += 2;
                    uint[] face;
                    face.reserve(numVerts);
                    for (int i = 0; i < numVerts && p < chunkEnd; i++)
                        face ~= readVX(data, p);
                    if (face.length >= 3) {
                        polys          ~= face;
                        polyIsSubpatch ~= isPtch;
                    } else {
                        ++skippedByArity;
                    }
                }
                stderr.writefln("[LWO] POLS(%s): %d polys (+%d, skipped %d < 3-vert)",
                                isPtch ? "PTCH" : "FACE",
                                polys.length, polys.length - count0, skippedByArity);
            } else {
                ++nonFaceChunks;
                stderr.writefln("[LWO] POLS: unsupported type %s, skipped",
                                cast(string) polyType[].idup);
            }
        } else {
            stderr.writefln("[LWO] skip chunk %s (size %d)",
                            cast(string) tagBytes[].idup, sz);
        }

        pos = chunkEnd;
        if (pos & 1) pos++;   // IFF chunks are padded to even size
    }

    stderr.writefln("[LWO] parse done: verts=%d, polys=%d, face-chunks=%d, " ~
                    "ptch-chunks=%d, other-POLS=%d, skipped-by-arity=%d",
                    verts.length, polys.length, faceChunks, subpatchChunks,
                    nonFaceChunks, skippedByArity);

    if (verts.length <= 0) {
        stderr.writefln("[LWO] reject: no vertices");
        return false;
    }
    if (polys.length <= 0) {
        stderr.writefln("[LWO] reject: no polygons");
        return false;
    }

    // Check for out-of-range vertex indices before committing.
    uint nv = cast(uint) verts.length;
    foreach (fi, face; polys) {
        foreach (idx; face) {
            if (idx >= nv) {
                stderr.writefln("[LWO] reject: face %d references vertex %d " ~
                                "(only %d verts)", fi, idx, nv);
                return false;
            }
        }
    }

    // Replace the scene rather than merge: clear prior topology, selection
    // and subpatch state so the new file is loaded onto a fresh mesh.
    mesh = Mesh.init;
    mesh.vertices = verts;
    uint[ulong] edgeLookup;
    foreach (face; polys)
        mesh.addFaceFast(edgeLookup, face);
    mesh.buildLoops();

    // Map PTCH polygons onto our isSubpatch flag so LightWave subpatches
    // render through the subdivision preview without requiring manual Tab.
    mesh.isSubpatch.length = mesh.faces.length;
    int subpatchCount = 0;
    foreach (fi, flag; polyIsSubpatch) {
        if (fi >= mesh.isSubpatch.length) break;
        mesh.isSubpatch[fi] = flag;
        if (flag) ++subpatchCount;
    }
    stderr.writefln("[LWO] mesh ready: %d verts, %d edges, %d faces, " ~
                    "%d marked subpatch",
                    mesh.vertices.length, mesh.edges.length,
                    mesh.faces.length, subpatchCount);
    return true;
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
