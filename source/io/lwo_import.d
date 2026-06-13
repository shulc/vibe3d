module io.lwo_import;

import std.file      : read, exists, getSize;
import std.algorithm : min;
import std.format    : format;

import mesh;
import math;
import io.scene_ir;
import log : logWarn, logInfo;

// Diagnostics for the LWO reader funnel through the "io" log subsystem; the
// "LWO" label stays in the message body (echoed as `[io] LWO: …`). Structural
// rejects / skips are warnings; path + progress lines are info.
private void lwoWarn(string msg) nothrow { try logWarn("io", "LWO: " ~ msg); catch (Exception) {} }
private void lwoInfo(string msg) nothrow { try logInfo("io", "LWO: " ~ msg); catch (Exception) {} }

// ---------------------------------------------------------------------------
// LWO2 import — our own reader, emitting an ImportedScene.
// ---------------------------------------------------------------------------
// assimp drops the PTCH subpatch flag, so .lwo keeps this in-tree parser
// (decision B1). PTCH polygons become `faceSubpatch=true`; FACE => false.
//
// Multi-layer correctness: LWO POLS indices are RELATIVE to the current
// layer's PNTS — each LAYR chunk resets the point base. We therefore start a
// fresh `ImportedPart` on every LAYR and keep that layer's PNTS/POLS/PTAG
// part-local (so indices stay valid). A file with no LAYR / a single layer
// yields a single part (back-compat).
//
// TAGS/SURF are GLOBAL in LWO (one table for the whole file); we parse them
// once and place the same surface list on every part. flattenToMesh's
// name-dedup collapses the duplicates back to one, and each part's PTAG
// tag-index then maps 1:1 onto the merged table.

/// Parse `path` into `scene`. Returns false (logging `[LWO] ...` to stderr) on
/// a missing file, bad header, or no geometry. The caller's `scene` is only
/// populated on success.
bool sceneFromLwo(string path, ref ImportedScene scene) {
    lwoInfo(format("sceneFromLwo: path=%s", path));

    if (!exists(path)) {
        lwoWarn("file does not exist");
        return false;
    }
    lwoInfo(format("file size = %d bytes", getSize(path)));

    ubyte[] data = cast(ubyte[]) read(path);
    lwoInfo(format("read %d bytes", data.length));

    if (data.length < 12) {
        lwoWarn(format("reject: file too small (%d < 12)", data.length));
        return false;
    }
    if (data[0..4] != "FORM") {
        lwoWarn(format("reject: missing FORM header, got %s",
                        cast(string) data[0..4].idup));
        return false;
    }
    if (data[8..12] != "LWO2") {
        lwoWarn(format("reject: not LWO2, header=%s",
                        cast(string) data[8..12].idup));
        return false;
    }

    uint   formSize = readU32(data, 4);
    size_t end      = min(cast(size_t)(8 + formSize), data.length);
    size_t pos      = 12;   // first sub-chunk starts after "LWO2"
    lwoInfo(format("formSize=%d, end=%d, parse from pos=%d",
                    formSize, end, pos));

    // -----------------------------------------------------------------------
    // One PartBuild per LAYR. PNTS/POLS/PTAG accumulate into the CURRENT part;
    // a new LAYR flushes the current part and opens a fresh one. We lazily
    // create the first part on the first geometry chunk so a LAYR-less file
    // still produces exactly one part.
    // -----------------------------------------------------------------------
    // One discontinuous (per-corner) UV override entry, layer-local.
    // `point` indexes the layer's PNTS; `globalPoly` is this part's `polys[]`
    // slot (the VMAD's POLS-local poly index already remapped through this
    // part's `localToGlobal`). `u`/`v` are the 2-D TXUV value.
    struct VmadEntry { uint point; uint globalPoly; float u, v; }

    struct PartBuild {
        Vec3[]   verts;
        uint[][] polys;
        bool[]   polyIsSubpatch;    // parallel to polys
        ubyte[][] ptagBodies;       // PTAG bodies (filtered to SURF later)
        string   name;

        // --- TXUV vertex maps, layer-local (resolved into ImportedPart.uv) ---
        // Continuous base (VMAP TXUV): point index -> (u,v). Last write wins if a
        // file repeats a point; that mirrors a single named TXUV channel.
        float[2][uint] vmapUv;
        bool           hasVmap;
        // Discontinuous overrides (VMAD TXUV): keyed (point, this-part poly slot).
        VmadEntry[]    vmadUv;
        bool           hasVmad;

        // Reader half of the LWO2 poly-index contract (D-2), PER PART: PTAG and
        // VMAD on-disk poly indices are POLS-LOCAL (0-based within the most-recent
        // POLS chunk of a given kind). `localToGlobal[kind][local]` is the slot in
        // THIS part's `polys[]` that the local poly was appended to, in on-disk
        // POLS order. `lastPolsKind` (0=FACE, 1=PTCH, -1=none) records which kind a
        // following VMAD binds to. PTAG above keys SURF off layer-local FACE
        // indices already (vibe3d appends FACE-then-PTCH per the chunk order), so
        // this table is used only by the VMAD remap.
        size_t[][2] localToGlobal;
        int         lastPolsKind = -1;
    }

    PartBuild[] parts;
    bool layerSeen = false;

    // GLOBAL tables (shared across all layers).
    string[]   tags;                // TAGS chunk → flat list of names
    SurfBody[] surfBodies;          // SURF chunk bodies

    // Ensure there is a current part to accumulate into.
    void ensurePart() {
        if (parts.length == 0)
            parts ~= PartBuild.init;
    }

    int faceChunks     = 0;
    int subpatchChunks = 0;
    int nonFaceChunks  = 0;
    int skippedByArity = 0;

    while (pos + 8 <= end) {
        ubyte[4] tagBytes = data[pos .. pos + 4];
        uint     sz       = readU32(data, pos + 4);
        pos += 8;
        size_t chunkEnd = pos + sz;
        if (chunkEnd > end) {
            lwoWarn(format("chunk %s size=%d overflows container " ~
                            "(pos=%d, end=%d), truncating",
                            cast(string) tagBytes[].idup, sz, pos, end));
            chunkEnd = end;
        }

        if (tagBytes == "LAYR") {
            // Start a new layer => new part. LAYR body: U2 number, U2 flags,
            // VEC12 pivot, then a null-terminated name. We only care about the
            // name (best-effort) — geometry indices reset regardless.
            string layerName;
            if (chunkEnd - pos >= 16) {
                size_t p = pos + 16;   // skip number(2)+flags(2)+pivot(12)
                size_t nameStart = p;
                while (p < chunkEnd && data[p] != 0) p++;
                layerName = cast(string) data[nameStart .. p].idup;
            }
            PartBuild pb;
            pb.name = layerName;
            // If the very first part was lazily created by an early geometry
            // chunk that preceded any LAYR (malformed), keep it; otherwise the
            // common case is LAYR-first, so we just append.
            if (!layerSeen && parts.length == 1 && parts[0].verts.length == 0
                && parts[0].polys.length == 0) {
                // Replace the empty placeholder created before the first LAYR.
                parts[0] = pb;
            } else {
                parts ~= pb;
            }
            layerSeen = true;
            lwoInfo(format("LAYR '%s' -> part %d",
                            layerName, parts.length - 1));
        } else if (tagBytes == "PNTS") {
            ensurePart();
            auto cur = &parts[$ - 1];
            size_t count0 = cur.verts.length;
            for (size_t i = pos; i + 12 <= chunkEnd; i += 12) {
                float x = readF32(data, i);
                float y = readF32(data, i + 4);
                float z = readF32(data, i + 8);
                cur.verts ~= Vec3(x, y, z);
            }
            lwoInfo(format("PNTS: part %d now %d verts (+%d)",
                            parts.length - 1, cur.verts.length,
                            cur.verts.length - count0));
        } else if (tagBytes == "POLS" && chunkEnd - pos >= 4) {
            ensurePart();
            auto cur = &parts[$ - 1];
            ubyte[4] polyType = data[pos .. pos + 4];
            size_t   p        = pos + 4;
            // FACE = ordinary polygons; PTCH = LightWave Catmull-Clark
            // subpatches (same on-disk format, interpreted as subpatches).
            bool isFace = (polyType == "FACE");
            bool isPtch = (polyType == "PTCH");
            if (isFace || isPtch) {
                if (isFace) ++faceChunks; else ++subpatchChunks;
                // POLS-local poly index space resets per POLS chunk of a kind; a
                // following VMAD (and PTAG) binds to the MOST-RECENT POLS chunk.
                const int kindIdx = isPtch ? 1 : 0;
                cur.lastPolsKind  = kindIdx;
                size_t count0 = cur.polys.length;
                while (p + 2 <= chunkEnd) {
                    ushort numVerts = readU16(data, p);
                    // Mask LWO2 poly-count flag bits (high 6) like the lib reader.
                    numVerts = cast(ushort)(numVerts & 0x03FF);
                    p += 2;
                    uint[] face;
                    face.reserve(numVerts);
                    for (int i = 0; i < numVerts && p < chunkEnd; i++)
                        face ~= readVX(data, p);
                    if (face.length >= 3) {
                        // Record (kind, POLS-local) -> this part's polys[] slot in
                        // on-disk POLS order, BEFORE the append, so the slot index
                        // is `cur.polys.length`. Only arity-valid polys are mapped;
                        // a VMAD entry for a skipped <3-vert poly is dropped (its
                        // local index never enters localToGlobal).
                        cur.localToGlobal[kindIdx] ~= cur.polys.length;
                        cur.polys          ~= face;
                        cur.polyIsSubpatch ~= isPtch;
                    } else {
                        ++skippedByArity;
                    }
                }
                lwoInfo(format("POLS(%s): part %d now %d polys (+%d, skipped %d < 3-vert)",
                                isPtch ? "PTCH" : "FACE", parts.length - 1,
                                cur.polys.length, cur.polys.length - count0, skippedByArity));
            } else {
                ++nonFaceChunks;
                lwoWarn(format("POLS: unsupported type %s, skipped",
                                cast(string) polyType[].idup));
            }
        } else if (tagBytes == "TAGS") {
            // TAGS body: a concatenation of null-terminated strings, each
            // padded to an even offset. GLOBAL — one table for the file.
            size_t p = pos;
            while (p < chunkEnd) {
                size_t nameStart = p;
                while (p < chunkEnd && data[p] != 0) p++;
                string name = cast(string) data[nameStart .. p].idup;
                if (p < chunkEnd) p++;             // consume null
                if (p < chunkEnd && (p & 1)) p++;  // pad to even
                tags ~= name;
            }
            lwoInfo(format("TAGS: %d tags", tags.length));
        } else if (tagBytes == "SURF") {
            // SURF body: surface name (null-terminated, even-padded), then a
            // source-name (same encoding, often empty), then a stream of
            // U2-sized sub-chunks. GLOBAL.
            size_t p = pos;
            size_t nameStart = p;
            while (p < chunkEnd && data[p] != 0) p++;
            string name = cast(string) data[nameStart .. p].idup;
            if (p < chunkEnd) p++;
            if (p < chunkEnd && (p & 1)) p++;
            // Skip the source-name field as well.
            while (p < chunkEnd && data[p] != 0) p++;
            if (p < chunkEnd) p++;
            if (p < chunkEnd && (p & 1)) p++;
            SurfBody sb;
            sb.name = name;
            sb.body = data[p .. chunkEnd].idup;
            surfBodies ~= sb;
            lwoInfo(format("SURF '%s' (body %d bytes)",
                            name, sb.body.length));
        } else if (tagBytes == "PTAG") {
            // Stash on the CURRENT part; face indices are layer-local.
            ensurePart();
            auto cur = &parts[$ - 1];
            auto body = data[pos .. chunkEnd].dup;
            cur.ptagBodies ~= body;
            lwoInfo(format("PTAG (part %d, size %d, type=%s)",
                            parts.length - 1, sz,
                            body.length >= 4
                                ? cast(string) body[0..4].idup
                                : "?"));
        } else if (tagBytes == "VMAP" && chunkEnd - pos >= 6) {
            // Continuous per-point vertex map. Body: type[ID4], dim[U2],
            // name[S0], then (point[VX] + f32 * dim)*. We consume only TXUV
            // (UV) maps and only their first two components (u, v); other map
            // types (weight, morph, …) and extra dims are ignored. Point
            // indices are LAYER-LOCAL (into this part's PNTS).
            ensurePart();
            auto cur = &parts[$ - 1];
            ubyte[4] mapType = data[pos .. pos + 4];
            ushort   dim     = readU16(data, pos + 4);
            size_t   p       = pos + 6;
            // S0 name: null-terminated, even-padded.
            while (p < chunkEnd && data[p] != 0) p++;
            if (p < chunkEnd) p++;             // consume null
            if (p < chunkEnd && (p & 1)) p++;  // pad to even
            if (mapType == "TXUV" && dim >= 1) {
                size_t entries = 0;
                while (p < chunkEnd) {
                    uint point = readVX(data, p);
                    // Read `dim` floats; keep [0..2] (default v=0 for a 1-D map).
                    float[2] uv = [0.0f, 0.0f];
                    bool short_ = false;
                    foreach (d; 0 .. dim) {
                        if (p + 4 > chunkEnd) { short_ = true; break; }
                        float f = readF32(data, p);
                        p += 4;
                        if (d < 2) uv[d] = f;
                    }
                    if (short_) break;
                    cur.vmapUv[point] = uv;
                    ++entries;
                }
                cur.hasVmap = cur.hasVmap || entries > 0;
                lwoInfo(format("VMAP TXUV: part %d, dim %d, %d point(s)",
                                parts.length - 1, dim, entries));
            } else {
                lwoInfo(format("skip VMAP type=%s dim=%d (not 2-D TXUV)",
                                cast(string) mapType[].idup, dim));
            }
        } else if (tagBytes == "VMAD" && chunkEnd - pos >= 6) {
            // Discontinuous per-corner vertex map. Body: type[ID4], dim[U2],
            // name[S0], then (point[VX] + poly[VX] + f32 * dim)*. `poly` is
            // POLS-LOCAL to the most-recent POLS chunk; remap it through this
            // part's localToGlobal[lastPolsKind] to a polys[] slot. TXUV only.
            ensurePart();
            auto cur = &parts[$ - 1];
            ubyte[4] mapType = data[pos .. pos + 4];
            ushort   dim     = readU16(data, pos + 4);
            size_t   p       = pos + 6;
            while (p < chunkEnd && data[p] != 0) p++;
            if (p < chunkEnd) p++;
            if (p < chunkEnd && (p & 1)) p++;
            if (mapType == "TXUV" && dim >= 1) {
                if (cur.lastPolsKind < 0) {
                    lwoWarn("VMAD TXUV with no preceding POLS in this layer, skipped");
                } else {
                    auto l2g = cur.localToGlobal[cur.lastPolsKind];
                    size_t entries = 0, dropped = 0;
                    while (p < chunkEnd) {
                        uint point     = readVX(data, p);
                        uint localPoly = readVX(data, p);
                        float[2] uv = [0.0f, 0.0f];
                        bool short_ = false;
                        foreach (d; 0 .. dim) {
                            if (p + 4 > chunkEnd) { short_ = true; break; }
                            float f = readF32(data, p);
                            p += 4;
                            if (d < 2) uv[d] = f;
                        }
                        if (short_) break;
                        if (localPoly < l2g.length) {
                            cur.vmadUv ~= VmadEntry(point,
                                cast(uint) l2g[localPoly], uv[0], uv[1]);
                            ++entries;
                        } else {
                            ++dropped;     // override for a skipped/curve poly
                        }
                    }
                    cur.hasVmad = cur.hasVmad || entries > 0;
                    lwoInfo(format("VMAD TXUV: part %d, dim %d, %d corner(s)%s",
                                    parts.length - 1, dim, entries,
                                    dropped ? format(", %d out-of-range dropped", dropped) : ""));
                }
            } else {
                lwoInfo(format("skip VMAD type=%s dim=%d (not 2-D TXUV)",
                                cast(string) mapType[].idup, dim));
            }
        } else {
            // Other chunks (CLIP, BBOX, ENVL, non-TXUV maps, …) are not part of
            // the geometry/UV model we round-trip; skip by size.
            lwoInfo(format("skip chunk %s (size %d)",
                            cast(string) tagBytes[].idup, sz));
        }

        pos = chunkEnd;
        if (pos & 1) pos++;   // IFF chunks are padded to even size
    }

    // Build the GLOBAL surface table once, in TAGS order (PTAG tag-indices are
    // 0-based into TAGS). This same list is placed on every part; flatten
    // dedups it back to one.
    ImportedSurface[] globalSurfaces;
    {
        ImportedSurface[string] surfByName;
        foreach (sb; surfBodies) {
            ImportedSurface s;
            s.name = sb.name;
            parseSurfBody(sb.body, s);
            surfByName[sb.name] = s;
        }
        globalSurfaces.length = tags.length;
        foreach (i, tname; tags) {
            if (auto sptr = tname in surfByName) {
                globalSurfaces[i] = *sptr;
            } else {
                ImportedSurface s;
                s.name = tname;
                globalSurfaces[i] = s;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Resolve each PartBuild into an ImportedPart.
    // -----------------------------------------------------------------------
    ImportedScene out_;
    size_t totalVerts = 0, totalPolys = 0;
    foreach (pi, ref pb; parts) {
        if (pb.verts.length == 0 || pb.polys.length == 0) {
            // Skip empty/degenerate layers (e.g. a LAYR with no geometry).
            lwoInfo(format("part %d empty (verts=%d polys=%d), skipped",
                            pi, pb.verts.length, pb.polys.length));
            continue;
        }

        // Validate face indices against this part's own vertex count.
        uint nv = cast(uint) pb.verts.length;
        bool badIndex = false;
        foreach (fi, face; pb.polys) {
            foreach (idx; face) {
                if (idx >= nv) {
                    lwoWarn(format("reject: part %d face %d references "
                                    ~ "vertex %d (only %d verts)", pi, fi, idx, nv));
                    badIndex = true;
                    break;
                }
            }
            if (badIndex) break;
        }
        if (badIndex) return false;

        ImportedPart ip;
        ip.name         = pb.name;
        ip.vertices     = pb.verts;
        ip.faces        = pb.polys;
        ip.faceSubpatch = pb.polyIsSubpatch;
        ip.surfaces     = globalSurfaces;

        // PTAG SURF -> faceMaterial (layer-local face indices).
        ip.faceMaterial.length = pb.polys.length;
        foreach (body; pb.ptagBodies) {
            if (body.length < 4 || body[0..4] != "SURF") continue;
            size_t p = 4;
            while (p < body.length) {
                uint faceIdx = readVX(body, p);
                if (p + 2 > body.length) break;
                ushort tagIdx = readU16(body, p);
                p += 2;
                if (faceIdx < ip.faceMaterial.length && tagIdx < tags.length)
                    ip.faceMaterial[faceIdx] = tagIdx;
            }
        }

        // TXUV VMAP/VMAD -> the flat per-corner ImportedPart.uv stream (dim 2),
        // in face-then-corner order parallel to EVERY corner of pb.polys (the same
        // layout flattenToMesh/partToMesh read; they advance their corner cursor
        // over all polys, dropping a face's corners with the face). For each
        // corner (poly p, point v): uv = VMAP[v] (continuous base) if present,
        // OVERRIDDEN by VMAD[(v, p)] (discontinuous) if present. A layer with no
        // TXUV map leaves uv EMPTY (empty-means-none, matching the assimp path).
        if (pb.hasVmap || pb.hasVmad) {
            // Build a (point,poly) -> (u,v) lookup for the overrides.
            float[2][ulong] overrideByCorner;
            foreach (e; pb.vmadUv) {
                const ulong key = (cast(ulong) e.globalPoly << 32) | e.point;
                overrideByCorner[key] = [e.u, e.v];
            }
            size_t totalCorners = 0;
            foreach (face; pb.polys) totalCorners += face.length;
            ip.uv.length = totalCorners * 2;
            size_t c = 0;
            foreach (fi_, face; pb.polys) {
                const uint fi = cast(uint) fi_;
                foreach (v; face) {
                    float u = 0.0f, vv = 0.0f;
                    if (auto base = v in pb.vmapUv) { u = (*base)[0]; vv = (*base)[1]; }
                    const ulong key = (cast(ulong) fi << 32) | v;
                    if (auto ov = key in overrideByCorner) { u = (*ov)[0]; vv = (*ov)[1]; }
                    ip.uv[c * 2]     = u;
                    ip.uv[c * 2 + 1] = vv;
                    ++c;
                }
            }
            lwoInfo(format("part %d: resolved %d UV corner(s) (VMAP=%d pt, VMAD=%d ovr)",
                            pi, c, pb.vmapUv.length, pb.vmadUv.length));
        }

        out_.parts ~= ip;
        totalVerts += pb.verts.length;
        totalPolys += pb.polys.length;
    }

    lwoInfo(format("parse done: %d part(s), verts=%d, polys=%d, "
                    ~ "face-chunks=%d, ptch-chunks=%d, other-POLS=%d, "
                    ~ "skipped-by-arity=%d, %d global surfaces",
                    out_.parts.length, totalVerts, totalPolys,
                    faceChunks, subpatchChunks, nonFaceChunks, skippedByArity,
                    globalSurfaces.length));

    if (out_.parts.length == 0) {
        lwoWarn("reject: no usable geometry");
        return false;
    }

    scene = out_;
    return true;
}

// ---------------------------------------------------------------------------
// Private helpers — big-endian I/O + SURF body parsing.
// ---------------------------------------------------------------------------

private:

/// Stashed SURF chunk body for resolution. `body` excludes the surface-name +
/// source-name prefix; it holds only the stream of U2-sized sub-chunks.
struct SurfBody {
    string             name;
    immutable(ubyte)[] body;
}

/// Parse a SURF sub-chunk stream into an ImportedSurface. Recognised
/// sub-chunks: COLR (RGB), DIFF, SPEC, GLOS, TRAN (inverted into opacity).
/// Each value-bearing sub-chunk has a trailing VX envelope reference we ignore.
void parseSurfBody(const ubyte[] body, ref ImportedSurface surf) {
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
            surf.diffuse = readF32(body, p);
        } else if (tag == "SPEC" && end - p >= 4) {
            surf.specular = readF32(body, p);
        } else if (tag == "GLOS" && end - p >= 4) {
            surf.glossiness = readF32(body, p);
        } else if (tag == "TRAN" && end - p >= 4) {
            // LWO2 TRAN is transparency (0 = opaque); our model stores opacity.
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
