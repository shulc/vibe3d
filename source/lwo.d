module lwo;

import std.stdio     : stderr, writefln;
import std.file      : read, exists, getSize;
import std.exception : enforce;
import std.algorithm : min;

import mesh;
import math;

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

    // Material Groups (MG2): collect surface chunks during the main pass
    // so we can resolve `mesh.surfaces` + `mesh.faceMaterial` once the
    // geometry has been committed.
    string[]  tags;                  // TAGS chunk → flat list of names
    SurfBody[] surfBodies;           // SURF chunk bodies, indexed lookup by name
    ubyte[][] ptagBodies;            // PTAG bodies (may be several; we filter by type=SURF in pass 2)

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
        } else if (tagBytes == "TAGS") {
            // TAGS body: a concatenation of null-terminated strings, each
            // padded to an even offset. PTAG and SURF chunks both
            // reference these by index.
            size_t p = pos;
            while (p < chunkEnd) {
                size_t nameStart = p;
                while (p < chunkEnd && data[p] != 0) p++;
                string name = cast(string) data[nameStart .. p].idup;
                if (p < chunkEnd) p++;             // consume null
                if (p < chunkEnd && (p & 1)) p++;  // pad to even
                tags ~= name;
            }
            stderr.writefln("[LWO] TAGS: %d tags", tags.length);
        } else if (tagBytes == "SURF") {
            // SURF body starts with the surface name (null-terminated,
            // even-padded), then a source-name (same encoding, often
            // empty), then a stream of U2-sized sub-chunks (COLR, DIFF,
            // SPEC, GLOS, TRAN, ...). Stash the raw body for pass-2
            // resolution into `mesh.surfaces`.
            size_t p = pos;
            size_t nameStart = p;
            while (p < chunkEnd && data[p] != 0) p++;
            string name = cast(string) data[nameStart .. p].idup;
            if (p < chunkEnd) p++;
            if (p < chunkEnd && (p & 1)) p++;
            // Skip the source-name field as well — we don't track surface
            // inheritance yet.
            while (p < chunkEnd && data[p] != 0) p++;
            if (p < chunkEnd) p++;
            if (p < chunkEnd && (p & 1)) p++;
            SurfBody sb;
            sb.name = name;
            sb.body = data[p .. chunkEnd].idup;
            surfBodies ~= sb;
            stderr.writefln("[LWO] SURF '%s' (body %d bytes)",
                            name, sb.body.length);
        } else if (tagBytes == "PTAG") {
            // Stash the body; pass-2 inspects the leading 4-byte type
            // and dispatches only on type=SURF for material assignments.
            auto body = data[pos .. chunkEnd].idup;
            ptagBodies ~= body.dup;
            stderr.writefln("[LWO] PTAG (size %d, type=%s)", sz,
                            body.length >= 4
                                ? cast(string) body[0..4].idup
                                : "?");
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
    mesh.resizeSubpatch();
    int subpatchCount = 0;
    foreach (fi, flag; polyIsSubpatch) {
        if (fi >= mesh.isSubpatch.length) break;
        mesh.setFaceSubpatch(fi, flag);
        if (flag) ++subpatchCount;
    }

    // Pass 2 (Material Groups MG2): resolve SURF chunks against TAGS into
    // mesh.surfaces, then walk PTAG type=SURF into mesh.faceMaterial.
    // Index 0 in mesh.surfaces is the LightWave convention — PTAG indices
    // are 0-based into the TAGS array — so we keep them aligned by
    // emitting one Surface per TAGS entry in TAGS order.
    Surface[string] surfByName;
    foreach (sb; surfBodies) {
        Surface s;
        s.name = sb.name;
        parseSurfBody(sb.body, s);
        surfByName[sb.name] = s;
    }
    if (tags.length > 0) {
        mesh.surfaces.length = tags.length;
        foreach (i, tname; tags) {
            if (auto sptr = tname in surfByName) {
                mesh.surfaces[i] = *sptr;
            } else {
                Surface s;
                s.name = tname;
                mesh.surfaces[i] = s;
            }
        }
    }
    mesh.faceMaterial.length = mesh.faces.length;
    int ptagAssigned = 0;
    foreach (body; ptagBodies) {
        if (body.length < 4 || body[0..4] != "SURF") continue;
        size_t p = 4;
        while (p < body.length) {
            uint faceIdx = readVX(body, p);
            if (p + 2 > body.length) break;
            ushort tagIdx = readU16(body, p);
            p += 2;
            if (faceIdx < mesh.faceMaterial.length && tagIdx < tags.length) {
                mesh.faceMaterial[faceIdx] = tagIdx;
                ++ptagAssigned;
            }
        }
    }

    stderr.writefln("[LWO] mesh ready: %d verts, %d edges, %d faces, " ~
                    "%d marked subpatch, %d surfaces, %d PTAG assignments",
                    mesh.vertices.length, mesh.edges.length,
                    mesh.faces.length, subpatchCount,
                    mesh.surfaces.length, ptagAssigned);
    return true;
}

// ---------------------------------------------------------------------------
// Private helpers — big-endian I/O
// ---------------------------------------------------------------------------

private:

/// Stashed SURF chunk body for pass-2 resolution. `body` excludes the
/// surface-name + source-name prefix (those have already been consumed
/// by the main parse loop); it holds only the stream of U2-sized
/// sub-chunks (COLR / DIFF / SPEC / GLOS / TRAN / ...).
struct SurfBody {
    string         name;
    immutable(ubyte)[] body;
}

/// Parse a SURF sub-chunk stream into a Surface. Recognised sub-chunks:
///   COLR — RGB triplet (the LWO2 COL12 format; alpha is implicit)
///   DIFF — diffuse amount (F4)
///   SPEC — specular amount (F4)
///   GLOS — glossiness (F4)
///   TRAN — transparency (F4); inverted into Surface.opacity
/// Each value-bearing sub-chunk also has a trailing VX "envelope"
/// reference for animation; we ignore that and trust the static value.
/// Unknown sub-chunks are skipped via their U2 size.
void parseSurfBody(const ubyte[] body, ref Surface surf)
{
    size_t p = 0;
    while (p + 6 <= body.length) {
        ubyte[4] tag = body[p .. p + 4];
        ushort   sz  = readU16(body, p + 4);
        p += 6;
        size_t end = p + sz;
        if (end > body.length) end = body.length;

        if (tag == "COLR" && end - p >= 12) {
            surf.baseColor = Vec3(
                readF32(body, p),
                readF32(body, p + 4),
                readF32(body, p + 8));
        } else if (tag == "DIFF" && end - p >= 4) {
            surf.diffuseAmount = readF32(body, p);
        } else if (tag == "SPEC" && end - p >= 4) {
            surf.specularAmount = readF32(body, p);
        } else if (tag == "GLOS" && end - p >= 4) {
            surf.glossiness = readF32(body, p);
        } else if (tag == "TRAN" && end - p >= 4) {
            // LWO2 TRAN is transparency (0 = opaque, 1 = transparent);
            // our Surface stores opacity (the complement).
            surf.opacity = 1.0f - readF32(body, p);
        }
        p = end;
        if (p & 1) p++;
    }
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
