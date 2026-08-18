module io.lwo_import;

// ---------------------------------------------------------------------------
// The interchange format's two MORPH map tags (task 1069).
//
// Four-character map-type tags in the file's own vertex-map type space, the
// same class of constant as `"TXUV"` a few hundred lines below. Their basis
// for living in `source/` is that they are ABSENT FROM BOTH neutrality
// dictionaries -- checked by running the project's own lint over a fixture
// containing them, which produced no finding -- and that `"TXUV"` is already
// public in this file and in `lwo_export.d`. They name no vendor, no product
// and no SDK symbol.
//
// Both are point-domain, dimension 3, many-named. They differ in what the
// three floats MEAN: one stores a displacement from the base position, the
// other an absolute position. Nothing about their shape distinguishes them,
// which is precisely why the tag has to be carried through to the map's kind
// instead of being inferred.
// ---------------------------------------------------------------------------
enum string kMorphRelativeTag = "MORF";   // stores a DELTA
enum string kMorphAbsoluteTag = "SPOT";   // stores a POSITION

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

    // One captured PTAG chunk plus the POLS window its poly indices are local
    // to. A PTAG binds to the MOST-RECENT POLS chunk, and `localToGlobal[kind]`
    // accumulates across every POLS chunk of that kind, so the kind alone is not
    // enough to resolve: `[POLS FACE(a)][PTAG][POLS FACE(b)][PTAG]` is legal and
    // the second PTAG's local 0 means chunk b's first poly. Remembering the
    // window `localToGlobal[kind][base .. limit]` (the extent of that one chunk,
    // frozen at capture) is what keeps it out of chunk a (task 0683 D2).
    struct PtagCapture {
        ubyte[] body;
        int     kind = -1;          // lastPolsKind at capture (0=FACE, 1=PTCH, -1=none)
        size_t  base, limit;        // window into localToGlobal[kind]
    }

    // One decoded morph channel, layer-local. `absolute` is the map's KIND,
    // which the tag carries and nothing else can supply: both kinds are
    // point-domain dim-3, so shape cannot tell them apart.
    struct MorphBuild {
        string  name;
        bool    absolute;
        uint[]  verts;
        float[] values;   // 3 per listed vertex
    }

    struct PartBuild {
        Vec3[]   verts;
        uint[][] polys;
        bool[]   polyIsSubpatch;    // parallel to polys
        PtagCapture[] ptags;        // PTAG chunks + their POLS window (filtered to SURF later)
        string   name;
        bool     hidden;            // LAYR flags bit 0 (1 => layer hidden)

        // --- morph vertex maps, layer-local (task 1069) ---
        // Sparse per-point 3-component channels, keyed by the map's S0 NAME.
        // Until this task these were parsed and thrown away: the file carried
        // them, the reader logged "skip VMAP", and the data was gone. Two
        // things had to change beyond widening the type gate — the S0 name was
        // scanned PAST and never captured (a morph channel is name-keyed, so
        // without it every map lands under one empty name), and the two
        // interchange map tags had to be recognised.
        MorphBuild[]   morphs;

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
        // POLS order — or `size_t.max` when that poly has NO slot because we
        // dropped it (a legal 1- or 2-point POLS entry: a point or a line). The
        // table has one entry per ON-DISK poly, dropped ones included, because
        // that is the index space the file numbers in; skipping them instead
        // would shift every later PTAG and VMAD index by one (task 0683 D1).
        // `polsBase[kind]` is the table length at the start of the most-recent
        // POLS chunk of that kind, i.e. where that chunk's local 0 lives.
        // `lastPolsKind` (0=FACE, 1=PTCH, -1=none) records which kind a following
        // VMAD — or PTAG (task 0678 D3) — binds to. The pre-fix code read PTAG
        // indices as FLAT slots, which is only right for a single-kind layer: on
        // a mixed FACE+PTCH layer the second kind's locals also number 0..M-1 and
        // landed on (and clobbered) the first kind's slots.
        // `polsFlatOrder` is the same mapping without the per-kind split: the
        // k-th on-disk poly of the layer (all POLS chunks, in file order) -> slot
        // or sentinel. Only the LEGACY positional PTAG decode below reads it.
        size_t[][2] localToGlobal;
        size_t[2]   polsBase;
        size_t[]    polsFlatOrder;
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
            // VEC12 pivot, then a null-terminated name. We read the name plus
            // the `flags` U2: bit 0 (0x0001) marks the layer hidden, so it
            // round-trips a layer exported with visible=false. Geometry indices
            // reset regardless.
            string layerName;
            bool   layerHidden = false;
            if (chunkEnd - pos >= 16) {
                const ushort flags = readU16(data, pos + 2);   // U2 after the layer number
                layerHidden = (flags & 0x0001) != 0;
                size_t p = pos + 16;   // skip number(2)+flags(2)+pivot(12)
                size_t nameStart = p;
                while (p < chunkEnd && data[p] != 0) p++;
                layerName = cast(string) data[nameStart .. p].idup;
            }
            PartBuild pb;
            pb.name = layerName;
            pb.hidden = layerHidden;
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
            // FACE = ordinary polygons; PTCH = the format's SUBPATCH face
            // kind (same on-disk format, interpreted as subpatches).
            //
            // CORRECTED (task 1100): this comment used to call PTCH a
            // "Catmull-Clark subpatch", and that conflates two independent
            // things. The face TYPE is what PTCH names, and we have exactly one
            // of them — `Marks.Subpatch`. The subdivision ALGORITHM is
            // Catmull-Clark, which we do implement (`source/mesh.d`), and which
            // says nothing about what kind of face a chunk carries. The
            // reference format has both as SEPARATE polygon types; the wrong
            // wording here is what would send a reader building the Statistics
            // panel's type list to the wrong row (owner decision Р10: our
            // subpatch faces are counted in the FIRST subdivision row, and the
            // Catmull-Clark row is a structural zero — one predicate never
            // populates both).
            bool isFace = (polyType == "FACE");
            bool isPtch = (polyType == "PTCH");
            if (isFace || isPtch) {
                if (isFace) ++faceChunks; else ++subpatchChunks;
                // POLS-local poly index space resets per POLS chunk of a kind; a
                // following VMAD (and PTAG) binds to the MOST-RECENT POLS chunk.
                // Record where this chunk's local 0 lands in the accumulated
                // per-kind table so a consumer can address THIS chunk's window
                // rather than everything seen so far (task 0683 D2).
                const int kindIdx = isPtch ? 1 : 0;
                cur.lastPolsKind  = kindIdx;
                cur.polsBase[kindIdx] = cur.localToGlobal[kindIdx].length;
                size_t count0 = cur.polys.length;
                while (p + 2 <= chunkEnd) {
                    ushort numVerts = readU16(data, p);
                    // Mask LWO2 poly-count flag bits (high 6) like the lib reader.
                    numVerts = cast(ushort)(numVerts & 0x03FF);
                    p += 2;
                    uint[] face;
                    face.reserve(numVerts);
                    for (int i = 0; i < numVerts && p < chunkEnd; i++) {
                        uint vx;
                        if (!readVX(data, p, chunkEnd, vx)) break;
                        face ~= vx;
                    }
                    // Record (kind, POLS-local) -> this part's polys[] slot in
                    // on-disk POLS order, BEFORE the append, so the slot index is
                    // `cur.polys.length`. EVERY on-disk poly gets an entry: a
                    // 1-point (point) or 2-point (line) POLS entry is legal LWO2
                    // and counts in the file's local numbering even though we keep
                    // no polygon for it, so it takes a SENTINEL instead of being
                    // skipped — skipping shifted every later PTAG/VMAD index by
                    // one (task 0683 D1). Consumers drop sentinel hits.
                    //
                    // The threshold is THREE and the kernel's floor is TWO —
                    // deliberately, not by oversight (task 1290): a 2-point
                    // POLS entry is an LWO2 line, and interchange normalises it
                    // away. `io/scene_ir.d`'s `flattenToMesh` carries the full
                    // statement; the sentinel above is what keeps the drop free
                    // of the positional-attribute shift that class of filter
                    // otherwise brings with it.
                    const size_t slot = (face.length >= 3) ? cur.polys.length : size_t.max;
                    cur.localToGlobal[kindIdx] ~= slot;
                    cur.polsFlatOrder          ~= slot;
                    if (face.length >= 3) {
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
            PtagCapture pt;
            pt.body = data[pos .. chunkEnd].dup;
            pt.kind = cur.lastPolsKind;
            if (pt.kind >= 0) {
                // Freeze the window this PTAG's locals index into: the extent of
                // the POLS chunk it binds to. Resolution happens after the whole
                // file is read, by which time the per-kind table may have grown
                // past this chunk (task 0683 D2).
                pt.base  = cur.polsBase[pt.kind];
                pt.limit = cur.localToGlobal[pt.kind].length;
            }
            cur.ptags ~= pt;
            lwoInfo(format("PTAG (part %d, size %d, type=%s, kind=%d, window=%d..%d)",
                            parts.length - 1, sz,
                            pt.body.length >= 4
                                ? cast(string) pt.body[0..4].idup
                                : "?",
                            pt.kind, pt.base, pt.limit));
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
            // S0 name: null-terminated, even-padded. Task 1069 — the name is
            // now CAPTURED, not just skipped: morph channels are name-keyed,
            // so without this every one of them would land under a single
            // empty name and the last would win.
            const size_t nameStart = p;
            while (p < chunkEnd && data[p] != 0) p++;
            const string vmapName =
                (p > nameStart) ? cast(string) data[nameStart .. p].idup : "";
            if (p < chunkEnd) p++;             // consume null
            if (p < chunkEnd && (p & 1)) p++;  // pad to even
            if ((mapType == kMorphRelativeTag || mapType == kMorphAbsoluteTag)
                && dim == 3) {
                // A morph channel. Sparse: one (point, x, y, z) per entry.
                //
                // UNTRUSTED INPUT: `point` is decoded from a foreign file and
                // will index a dense array downstream, so it is range-checked
                // against THIS part's own point count, an out-of-range one is
                // skipped with a warning, and the rest of the chunk keeps
                // parsing. A truncated entry ends the chunk cleanly. Never a
                // throw: one bad byte must not cost the whole load.
                MorphBuild mb;
                mb.name     = vmapName.length ? vmapName : "morph";
                mb.absolute = (mapType == kMorphAbsoluteTag);
                size_t entries = 0, dropped = 0;
                while (p < chunkEnd) {
                    uint point;
                    // A truncated VX ends the chunk cleanly — it used to read
                    // past the buffer instead (review SF1).
                    if (!readVX(data, p, chunkEnd, point)) break;
                    float[3] xyz = [0.0f, 0.0f, 0.0f];
                    bool short_ = false;
                    foreach (d; 0 .. 3) {
                        if (p + 4 > chunkEnd) { short_ = true; break; }
                        xyz[d] = readF32(data, p);
                        p += 4;
                    }
                    if (short_) break;
                    if (point >= cur.verts.length) { ++dropped; continue; }
                    mb.verts  ~= point;
                    mb.values ~= xyz[0];
                    mb.values ~= xyz[1];
                    mb.values ~= xyz[2];
                    ++entries;
                }
                if (dropped > 0)
                    lwoWarn(format("VMAP morph '%s': %d entry/entries with an "
                                  ~ "out-of-range point index dropped (part has "
                                  ~ "%d points)", mb.name, dropped, cur.verts.length));
                cur.morphs ~= mb;
                lwoInfo(format("VMAP morph '%s' (%s): part %d, %d point(s)",
                                mb.name, mb.absolute ? "absolute" : "relative",
                                parts.length - 1, entries));
            } else if (mapType == "TXUV" && dim >= 1) {
                size_t entries = 0;
                while (p < chunkEnd) {
                    uint point;
                    if (!readVX(data, p, chunkEnd, point)) break;
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
                    // Locals are relative to the START of the most-recent POLS
                    // chunk of this kind, not to everything of that kind seen so
                    // far — take that chunk's window (task 0683 D2).
                    const kind = cur.lastPolsKind;
                    auto l2g = cur.localToGlobal[kind][cur.polsBase[kind] .. $];
                    size_t entries = 0, dropped = 0;
                    while (p < chunkEnd) {
                        uint point, localPoly;
                        if (!readVX(data, p, chunkEnd, point))     break;
                        if (!readVX(data, p, chunkEnd, localPoly)) break;
                        float[2] uv = [0.0f, 0.0f];
                        bool short_ = false;
                        foreach (d; 0 .. dim) {
                            if (p + 4 > chunkEnd) { short_ = true; break; }
                            float f = readF32(data, p);
                            p += 4;
                            if (d < 2) uv[d] = f;
                        }
                        if (short_) break;
                        if (localPoly < l2g.length && l2g[localPoly] != size_t.max) {
                            cur.vmadUv ~= VmadEntry(point,
                                cast(uint) l2g[localPoly], uv[0], uv[1]);
                            ++entries;
                        } else {
                            // Out of range, or an override for a poly we kept no
                            // slot for (a <3-vert point/line entry — sentinel).
                            ++dropped;
                        }
                    }
                    cur.hasVmad = cur.hasVmad || entries > 0;
                    lwoInfo(format("VMAD TXUV: part %d, dim %d, %d corner(s)%s",
                                    parts.length - 1, dim, entries,
                                    dropped ? format(", %d out-of-range dropped", dropped) : ""));
                }
            } else {
                // VMAD morph overrides are deliberately OUT OF SCOPE (task
                // 1069): a morph is a per-POINT channel, and a discontinuous
                // per-corner morph is not something the measured law covers.
                // Dropped, and said out loud rather than silently.
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
        ip.visible      = !pb.hidden;     // LAYR flags bit 0 (hidden) -> visible=false
        ip.vertices     = pb.verts;
        ip.faces        = pb.polys;
        ip.faceSubpatch = pb.polyIsSubpatch;
        ip.surfaces     = globalSurfaces;

        // PTAG SURF -> faceMaterial. On-disk poly indices are POLS-LOCAL to
        // the most-recent POLS chunk at the point the PTAG appeared (the same
        // binding rule as VMAD; the writer emits one PTAG per kind right
        // after that kind's POLS chunk), so remap (window, local) -> this
        // part's polys[] slot via localToGlobal — flat interpretation only
        // coincides on a single-kind layer (task 0678 D3), and the window is
        // that ONE chunk, not the kind's whole accumulated table (0683 D2).
        ip.faceMaterial.length = pb.polys.length;
        foreach (ref pt; pb.ptags) {
            const body = pt.body;
            if (body.length < 4 || body[0..4] != "SURF") continue;
            // The window is THAT PTAG's POLS chunk, not the whole per-kind table.
            const l2g = (pt.kind >= 0)
                ? pb.localToGlobal[pt.kind][pt.base .. pt.limit]
                : null;

            // Count entries first — the count is what tells the two on-disk
            // layouts apart (task 0678 D3 follow-up; the per-kind remap alone
            // was a REGRESSION on legacy files, see below).
            size_t entryCount = 0;
            for (size_t q = 4; q < body.length; ) {
                uint skipped;
                if (!readVX(body, q, body.length, skipped)) break;
                if (q + 2 > body.length) break;
                q += 2;
                ++entryCount;
            }

            // TWO layouts exist in the wild and they need different decoding:
            //
            //  * CONFORMANT (this package since the per-kind fix): one PTAG per
            //    POLS chunk, entries POLS-LOCAL to THAT chunk ⇒ remap through
            //    that chunk's window of `localToGlobal[kind]`. Its entry count
            //    can never exceed the window's poly count — which is why the
            //    window has an entry for every ON-DISK poly, dropped ones
            //    included: without the sentinels a file that tags a point/line
            //    poly would overflow the window and be misread as legacy.
            //  * LEGACY (everything vibe3d exported before that fix, and any
            //    writer emitting a single trailing PTAG): ONE chunk covering
            //    BOTH kinds, entries in emit order — all FACE, then all PTCH —
            //    each carrying its own per-kind local index. Remapping those
            //    through the LAST POLS chunk's table (PTCH) sends every FACE
            //    entry to a PTCH slot: subpatches come out right and EVERY
            //    ordinary polygon loses its surface. On the common layer (many
            //    FACE, few PTCH) that is far worse than the flat read it
            //    replaced — a regression this decode exists to undo.
            //
            // The legacy layout is decodable EXACTLY, not by heuristic: this
            // importer appends polys in POLS-chunk order (FACE chunk first,
            // then PTCH), the same order the legacy writer emitted entries in,
            // so the k-th entry is the k-th ON-DISK poly — `polsFlatOrder[k]`,
            // which carries the sentinel for any poly we kept no slot for. A
            // PTAG arriving before any POLS (`kind < 0` — non-conformant, but
            // read correctly by the pre-D3 flat path) takes the same route
            // rather than being dropped.
            const bool positional = (pt.kind < 0) || (entryCount > l2g.length);
            size_t ordinal = 0;
            size_t p = 4;
            while (p < body.length) {
                uint localIdx;
                if (!readVX(body, p, body.length, localIdx)) break;
                if (p + 2 > body.length) break;
                ushort tagIdx = readU16(body, p);
                p += 2;
                const size_t slot = positional
                    ? (ordinal   < pb.polsFlatOrder.length ? pb.polsFlatOrder[ordinal] : size_t.max)
                    : (localIdx  < l2g.length              ? l2g[localIdx]             : size_t.max);
                ++ordinal;
                // size_t.max = the on-disk poly this entry names has no slot of
                // ours (a dropped <3-vert entry). Never assign through it.
                if (slot != size_t.max && slot < ip.faceMaterial.length
                        && tagIdx < tags.length)
                    ip.faceMaterial[slot] = tagIdx;
            }
        }

        // Morph VMAPs -> the part's sparse per-vertex morph channels
        // (task 1069). Point-domain, so unlike UV there is no corner
        // bookkeeping: the indices are already this part's own point indices,
        // range-checked at decode time.
        foreach (ref mb; pb.morphs) {
            if (mb.verts.length == 0) continue;
            ip.morphs ~= PartMorph(mb.name, mb.absolute,
                                   mb.verts.dup, mb.values.dup);
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

/// Read a variable-length index (VX) at `pos`, advancing `pos` past it.
///
/// `limit` is the EXCLUSIVE end of the readable window — the enclosing
/// chunk's end, which every caller already carries — and is clamped to
/// `buf.length` here so a chunk header that overruns the file cannot widen
/// it. Returns false, leaves `idx` at 0 and parks `pos` AT `limit` when the
/// index does not fit; since every caller loop is `while (pos < limit)`,
/// parking at the limit terminates the loop even for a caller that drops the
/// bool on the floor.
///
/// UNTRUSTED INPUT (task 1073, review SF1). This used to read `buf[pos + 1]`
/// (2-byte form) or `buf[pos + 3]` (4-byte form) with no bound of its OWN,
/// while every caller guarded only `pos < chunkEnd`. A VMAP truncated
/// mid-entry — one trailing byte at the very end of the file is enough —
/// therefore indexed past `buf`: a `RangeError` in the default build, which
/// is an `Error` and so is NOT caught by the `catch (Exception)` this reader
/// wraps itself in, and a real out-of-bounds READ under `--build=perf` where
/// bounds checks are off. It falsified the "Never a throw: one bad byte must
/// not cost the whole load" contract stated at the morph call site. Fixed
/// once HERE rather than at each of the six call sites, because "the caller
/// checked the byte count" is exactly the assumption that was wrong.
bool readVX(const ubyte[] buf, ref size_t pos, size_t limit, out uint idx) {
    if (limit > buf.length) limit = buf.length;
    if (pos >= limit) { pos = limit; return false; }
    if (buf[pos] == 0xFF) {
        if (pos + 4 > limit) { pos = limit; return false; }
        idx = (cast(uint) buf[pos + 1] << 16)
            | (cast(uint) buf[pos + 2] <<  8)
            |  cast(uint) buf[pos + 3];
        pos += 4;
    } else {
        if (pos + 2 > limit) { pos = limit; return false; }
        idx = readU16(buf, pos);
        pos += 2;
    }
    return true;
}


// task 0678 D3 follow-up — LEGACY layout: ONE trailing PTAG covering BOTH
// kinds. Every .lwo vibe3d exported before the per-kind writer fix looks like
// this, so the per-kind remap alone was a REGRESSION: it routed the FACE
// entries through the PTCH table and every ordinary polygon lost its surface.
// A round-trip test cannot see this — the current writer never emits the
// layout — so the fixture is hand-built bytes.
unittest {
    import std.file : tempDir, write, remove, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;

    ubyte[] body_;
    // TAGS → tag 0 = Body, tag 1 = Roof
    body_ ~= tagsChunk(["Body", "Roof"]);
    body_ ~= pntsChunk([[0f,0f,0f],[1f,0f,0f],[1f,1f,0f],[0f,1f,0f],[0.5f,2f,0f]]);
    body_ ~= polsChunk("FACE", [[0u,1u,2u], [0u,2u,3u]]);   // locals 0, 1
    body_ ~= polsChunk("PTCH", [[3u,2u,4u]]);               // local 0
    // ONE trailing PTAG SURF — the legacy shape. Emit order with PER-KIND
    // locals: FACE 0→Roof, FACE 1→Roof, PTCH 0→Body.
    body_ ~= ptagSurfChunk([[0, 1], [1, 1], [0, 0]]);

    ubyte[] file = lwoContainer(body_);

    const string path = buildPath(tempDir,
        format("vibe3d_0678_d3_legacy_ptag_%d.lwo", thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    write(path, file);

    ImportedScene scene;
    assert(sceneFromLwo(path, scene), "legacy-layout LWO must import");
    assert(scene.parts.length == 1);
    auto part = scene.parts[0];
    assert(part.faces.length == 3, "two FACE + one PTCH must survive");
    assert(!part.faceSubpatch[0] && !part.faceSubpatch[1] && part.faceSubpatch[2],
           "poly kinds must be read in POLS order");

    // The point: FACE polys keep THEIR surface. Before the fix both read back
    // as tag 0 because the per-kind remap sent them through the PTCH table.
    assert(part.faceMaterial[0] == 1, "legacy FACE poly 0 must keep its surface");
    assert(part.faceMaterial[1] == 1, "legacy FACE poly 1 must keep its surface");
    assert(part.faceMaterial[2] == 0, "legacy PTCH poly must keep its surface");
}

// task 0683 D1 — a POLS chunk may carry polys we keep no polygon for: LWO2
// 1-point (point) and 2-point (line) entries are legal and writers in the wild
// emit them (curves, guides, single-point props). They still OCCUPY a
// POLS-local index, so a table that only maps the >=3-vert ones shifts every
// later PTAG and VMAD entry by one. Hand-built bytes: our writer emits no such
// poly, so a round-trip cannot reach this input.
unittest {
    import std.file : tempDir, write, remove, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;

    // POLS FACE, SIX on-disk polys: tri, LINE, tri, tri, tri, tri. Each tri
    // sits at its own x so the imported poly's source is recoverable from its
    // first vertex. The PTAG tags the first five (locals 0..4) and leaves the
    // last untagged, so its entry count stays within the chunk's poly count
    // with or without the line's table slot — the decode takes the conformant
    // route either way and the assertions below measure the REMAP, not the
    // layout classifier.
    ubyte[] body_;
    body_ ~= tagsChunk(["T0", "T1", "T2", "T3", "T4"]);
    body_ ~= pntsChunk([
        [ 0f,0f,0f], [ 1f,0f,0f], [ 0f,1f,0f],   //  0..2   local 0: tri @ x=0
        [10f,0f,0f], [11f,0f,0f],                //  3..4   local 1: LINE
        [20f,0f,0f], [21f,0f,0f], [20f,1f,0f],   //  5..7   local 2: tri @ x=20
        [30f,0f,0f], [31f,0f,0f], [30f,1f,0f],   //  8..10  local 3: tri @ x=30
        [40f,0f,0f], [41f,0f,0f], [40f,1f,0f],   // 11..13  local 4: tri @ x=40
        [50f,0f,0f], [51f,0f,0f], [50f,1f,0f]]); // 14..16  local 5: tri @ x=50
    body_ ~= polsChunk("FACE", [[0u,1u,2u], [3u,4u], [5u,6u,7u],
                                [8u,9u,10u], [11u,12u,13u], [14u,15u,16u]]);
    // A tag per on-disk poly for locals 0..4 — including the LINE's own entry,
    // which has nowhere to go and must be dropped, not applied to the poly that
    // follows it. Local 5 is deliberately untagged (legal; it keeps tag 0).
    body_ ~= ptagSurfChunk([[0, 0], [1, 1], [2, 2], [3, 3], [4, 4]]);
    // Discontinuous UV on two polys AFTER the line — the entries whose local
    // index the missing table slot used to shift.
    body_ ~= vmadTxuvChunk("uv", [
        VmadFix( 5, 2, 0.25f, 0.75f),      // local 2 => tri @ x=20, corner 0
        VmadFix(14, 5, 0.5f,  0.125f)]);   // local 5 => tri @ x=50, corner 0

    const string path = buildPath(tempDir,
        format("vibe3d_0683_d1_line_poly_%d.lwo", thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    write(path, lwoContainer(body_));

    ImportedScene scene;
    assert(sceneFromLwo(path, scene), "LWO with a line poly must import");
    assert(scene.parts.length == 1);
    auto part = scene.parts[0];
    assert(part.faces.length == 5, "the 2-point poly is dropped, the tris stay");
    const float[5] wantX = [0f, 20f, 30f, 40f, 50f];
    foreach (i, face; part.faces)
        assert(part.vertices[face[0]].x == wantX[i],
               "kept polys keep their on-disk order");

    // PTAG: locals 2..4 name the tris at x=20, 30, 40. Reading the table
    // without the line's sentinel shifted each of them one poly along — and
    // handed the LINE's tag to the tri at x=20.
    const string[5] wantTag = ["T0", "T2", "T3", "T4", "T0"];
    foreach (i, m; part.faceMaterial) {
        assert(m < part.surfaces.length, "material index must be in range");
        assert(part.surfaces[m].name == wantTag[i],
               "PTAG local index must count the <3-vert poly");
    }

    // VMAD: same shift, same table. Corner cursor runs face-then-corner over
    // the KEPT polys: face k owns corners 3k .. 3k+2.
    assert(part.uv.length == 5 * 3 * 2, "one (u,v) per kept corner");
    assert(part.uv[3 * 2] == 0.25f && part.uv[3 * 2 + 1] == 0.75f,
           "VMAD local 2 must land on the tri after the line");
    assert(part.uv[12 * 2] == 0.5f && part.uv[12 * 2 + 1] == 0.125f,
           "VMAD local 5 must land on the last tri");
    foreach (c; [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14])
        assert(part.uv[c * 2] == 0f && part.uv[c * 2 + 1] == 0f,
               "no other corner may pick up an override");
}

// task 0683 D2 — two POLS chunks of the SAME kind, each followed by its own
// PTAG. The binding rule is "the most-recent POLS chunk", so the second PTAG's
// local 0 is the second chunk's first poly. Resolving it against the kind's
// whole accumulated table pointed it back into chunk a — clobbering a's tags
// and leaving b's polys untagged. Our writer emits one POLS per kind, so this
// input too is hand-built bytes.
unittest {
    import std.file : tempDir, write, remove, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;

    ubyte[] body_;
    body_ ~= tagsChunk(["T0", "T1", "T2", "T3"]);
    body_ ~= pntsChunk([
        [ 0f,0f,0f], [ 1f,0f,0f], [ 0f,1f,0f],   // 0..2    chunk a, local 0
        [10f,0f,0f], [11f,0f,0f], [10f,1f,0f],   // 3..5    chunk a, local 1
        [20f,0f,0f], [21f,0f,0f], [20f,1f,0f],   // 6..8    chunk b, local 0
        [30f,0f,0f], [31f,0f,0f], [30f,1f,0f]]); // 9..11   chunk b, local 1
    body_ ~= polsChunk("FACE", [[0u,1u,2u], [3u,4u,5u]]);   // chunk a
    body_ ~= ptagSurfChunk([[0, 0], [1, 1]]);               // a: T0, T1
    body_ ~= polsChunk("FACE", [[6u,7u,8u], [9u,10u,11u]]); // chunk b
    body_ ~= ptagSurfChunk([[0, 2], [1, 3]]);               // b: T2, T3
    // VMAD binds to the most-recent POLS too: local 0 is chunk b's first poly.
    body_ ~= vmadTxuvChunk("uv", [VmadFix(6, 0, 0.25f, 0.75f)]);

    const string path = buildPath(tempDir,
        format("vibe3d_0683_d2_two_pols_%d.lwo", thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    write(path, lwoContainer(body_));

    ImportedScene scene;
    assert(sceneFromLwo(path, scene), "two-POLS-chunk LWO must import");
    assert(scene.parts.length == 1);
    auto part = scene.parts[0];
    assert(part.faces.length == 4, "both chunks' polys must survive, in file order");

    const string[4] wantTag = ["T0", "T1", "T2", "T3"];
    foreach (i, m; part.faceMaterial) {
        assert(m < part.surfaces.length, "material index must be in range");
        assert(part.surfaces[m].name == wantTag[i],
               "each PTAG binds to ITS OWN POLS chunk, not to the kind's whole table");
    }

    // Corner cursor: faces 0..3 own corners 0..2, 3..5, 6..8, 9..11.
    assert(part.uv.length == 4 * 3 * 2);
    assert(part.uv[6 * 2] == 0.25f && part.uv[6 * 2 + 1] == 0.75f,
           "VMAD local 0 must land on the SECOND chunk's first poly");
    foreach (c; [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11])
        assert(part.uv[c * 2] == 0f && part.uv[c * 2 + 1] == 0f,
               "no other corner may pick up an override");
}

// task 0683 D1, legacy layout — the positional decode counts entries against
// polys, so a dropped <3-vert poly shifts it exactly like the per-kind table.
// One trailing PTAG (the legacy shape, see above) over a FACE chunk that
// carries a line.
unittest {
    import std.file : tempDir, write, remove, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;

    ubyte[] body_;
    body_ ~= tagsChunk(["Body", "Roof"]);
    body_ ~= pntsChunk([
        [ 0f,0f,0f], [ 1f,0f,0f], [ 0f,1f,0f],   // 0..2   FACE local 0: tri @ x=0
        [10f,0f,0f], [11f,0f,0f],                // 3..4   FACE local 1: LINE
        [20f,0f,0f], [21f,0f,0f], [20f,1f,0f],   // 5..7   FACE local 2: tri @ x=20
        [30f,0f,0f], [31f,0f,0f], [30f,1f,0f]]); // 8..10  PTCH local 0: tri @ x=30
    body_ ~= polsChunk("FACE", [[0u,1u,2u], [3u,4u], [5u,6u,7u]]);
    body_ ~= polsChunk("PTCH", [[8u,9u,10u]]);
    // ONE trailing PTAG covering both kinds, entries in emit order (all FACE,
    // then PTCH) — more entries than the last chunk has polys, so this decodes
    // positionally: the k-th entry is the k-th ON-DISK poly, line included.
    body_ ~= ptagSurfChunk([[0, 1], [1, 0], [2, 1], [0, 0]]);

    const string path = buildPath(tempDir,
        format("vibe3d_0683_d1_legacy_line_%d.lwo", thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    write(path, lwoContainer(body_));

    ImportedScene scene;
    assert(sceneFromLwo(path, scene), "legacy-layout LWO with a line must import");
    assert(scene.parts.length == 1);
    auto part = scene.parts[0];
    assert(part.faces.length == 3);
    assert(!part.faceSubpatch[0] && !part.faceSubpatch[1] && part.faceSubpatch[2],
           "poly kinds must be read in POLS order");
    assert(part.vertices[part.faces[1][0]].x == 20f, "slot 1 is the tri after the line");

    assert(part.surfaces[part.faceMaterial[0]].name == "Roof");
    assert(part.surfaces[part.faceMaterial[1]].name == "Roof",
           "the line's entry must be dropped, not applied to the next tri");
    assert(part.surfaces[part.faceMaterial[2]].name == "Body");
}

version (unittest) {
    // -----------------------------------------------------------------------
    // Byte-fixture builders for the hand-assembled LWO2 files above.
    // -----------------------------------------------------------------------
    // These inputs are unreachable through a round-trip: our writer emits none
    // of these layouts (no <3-vert polys, one POLS per kind, one PTAG per
    // chunk), so the container is assembled by hand — big-endian scalars, IFF
    // chunks padded to even size.

    void putU2(ref ubyte[] b, ushort v) {
        b ~= cast(ubyte)(v >> 8);
        b ~= cast(ubyte)(v & 0xFF);
    }

    void putU4(ref ubyte[] b, uint v) {
        b ~= cast(ubyte)(v >> 24); b ~= cast(ubyte)((v >> 16) & 0xFF);
        b ~= cast(ubyte)((v >> 8) & 0xFF); b ~= cast(ubyte)(v & 0xFF);
    }

    void putF4(ref ubyte[] b, float f) {
        import std.bitmanip : nativeToBigEndian;
        b ~= nativeToBigEndian(f)[];
    }

    /// S0: null-terminated, padded to an even total length.
    void putName(ref ubyte[] b, string s) {
        b ~= cast(const(ubyte)[]) s;
        b ~= cast(ubyte) 0;
        if (s.length % 2 == 0) b ~= cast(ubyte) 0;
    }

    ubyte[] iffChunk(string id, const(ubyte)[] payload) {
        ubyte[] c;
        c ~= cast(const(ubyte)[]) id;
        putU4(c, cast(uint) payload.length);
        c ~= payload;
        if (payload.length % 2) c ~= cast(ubyte) 0;   // IFF pad
        return c;
    }

    /// FORM + size + "LWO2" around a body of chunks.
    ubyte[] lwoContainer(const(ubyte)[] body_) {
        ubyte[] file;
        file ~= cast(const(ubyte)[]) "FORM";
        putU4(file, cast(uint)(4 + body_.length));
        file ~= cast(const(ubyte)[]) "LWO2";
        file ~= body_;
        return file;
    }

    ubyte[] tagsChunk(const string[] names) {
        ubyte[] t;
        foreach (n; names) putName(t, n);
        return iffChunk("TAGS", t);
    }

    ubyte[] pntsChunk(const float[3][] pts) {
        ubyte[] p;
        foreach (v; pts) foreach (c; v) putF4(p, c);
        return iffChunk("PNTS", p);
    }

    /// POLS chunk of `type` ("FACE" / "PTCH"); point indices as 2-byte VX.
    ubyte[] polsChunk(string type, const uint[][] polys) {
        ubyte[] p;
        p ~= cast(const(ubyte)[]) type;
        foreach (poly; polys) {
            putU2(p, cast(ushort) poly.length);
            foreach (v; poly) putU2(p, cast(ushort) v);
        }
        return iffChunk("POLS", p);
    }

    /// PTAG SURF from (poly index, tag index) pairs, written verbatim.
    ubyte[] ptagSurfChunk(const ushort[2][] entries) {
        ubyte[] p;
        p ~= cast(const(ubyte)[]) "SURF";
        foreach (e; entries) { putU2(p, e[0]); putU2(p, e[1]); }
        return iffChunk("PTAG", p);
    }

    /// One discontinuous UV entry: (point, POLS-local poly, u, v).
    struct VmadFix { ushort point, poly; float u, v; }

    ubyte[] vmadTxuvChunk(string name, const VmadFix[] entries) {
        ubyte[] p;
        p ~= cast(const(ubyte)[]) "TXUV";
        putU2(p, 2);                 // dim
        putName(p, name);
        foreach (e; entries) {
            putU2(p, e.point); putU2(p, e.poly);
            putF4(p, e.u);     putF4(p, e.v);
        }
        return iffChunk("VMAD", p);
    }

    /// One sparse morph entry: (point, dx, dy, dz). 14 bytes on the wire —
    /// a 2-byte VX plus three big-endian f32.
    struct MorphFix { ushort point; float x, y, z; }

    /// VMAP MORF (relative morph). Payload = type(4) + dim(2) + S0 name
    /// (even) + 14 per entry, so the payload length is EVEN and `iffChunk`
    /// appends no pad byte — which is what lets the truncation test below put
    /// the parse position at the very last byte of the file.
    ubyte[] vmapMorphChunk(string name, const MorphFix[] entries) {
        ubyte[] p;
        p ~= cast(const(ubyte)[]) kMorphRelativeTag;
        putU2(p, 3);                 // dim
        putName(p, name);
        foreach (e; entries) {
            putU2(p, e.point);
            putF4(p, e.x); putF4(p, e.y); putF4(p, e.z);
        }
        return iffChunk("VMAP", p);
    }
}

// TASK 1073, review SF1 — a morph VMAP truncated MID-ENTRY must end the chunk,
// not read past the buffer.
//
// The morph decode loop guards only `p < chunkEnd`, and `readVX` used to have
// no bound of its own: it reads a second byte (2-byte form) or a fourth
// (4-byte form) unconditionally. With the VMAP as the file's LAST chunk and
// its final entry cut to a single byte, `p == data.length - 1 < chunkEnd`, so
// the read went one past the array. That is a `RangeError` in the default
// build — an `Error`, so the `catch (Exception)` this reader wraps itself in
// does NOT save it — and a genuine out-of-bounds read under `--build=perf`,
// where bounds checks are compiled out. Either way it falsifies the reader's
// own "Never a throw: one bad byte must not cost the whole load" contract.
//
// The file is truncated by 13 of the last entry's 14 bytes, leaving exactly
// one — `end` is `min(8 + formSize, data.length)`, so a short file pulls the
// container end down to the real length and the clamp on `chunkEnd` follows,
// which is what puts the parse position on the last byte rather than safely
// inside an IFF pad.
//
// Mutation: restore the unbounded `readVX` (drop the `pos + 2 > limit` /
// `pos + 4 > limit` guards) -> this unittest dies with `core.exception.
// RangeError` instead of asserting (verified). Note the SECOND assertion is
// what makes this more than a crash test: the two SOUND entries must still
// import, i.e. the fix must end the chunk cleanly rather than discard the
// whole VMAP or the whole load.
unittest {
    import std.file : tempDir, write, remove, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;

    ubyte[] body_;
    body_ ~= pntsChunk([[0f,0f,0f],[1f,0f,0f],[1f,1f,0f],[0f,1f,0f]]);
    body_ ~= polsChunk("FACE", [[0u,1u,2u,3u]]);
    // Three entries; the third is the one the truncation eats.
    body_ ~= vmapMorphChunk("mm", [
        MorphFix(0, 0.5f, 0f,    0f),
        MorphFix(1, 0f,   0.25f, 0f),
        MorphFix(2, 0f,   0f,    0.125f)]);

    ubyte[] file = lwoContainer(body_);
    assert(file.length > 13);
    // Chop 13 of the last entry's 14 bytes: one byte of its 2-byte VX
    // survives, so the loop enters `readVX` with a single readable byte left.
    ubyte[] truncated = file[0 .. $ - 13];

    const string path = buildPath(tempDir,
        format("vibe3d_1073_sf1_trunc_vmap_%d.lwo", thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    write(path, truncated);

    ImportedScene scene;
    assert(sceneFromLwo(path, scene),
        "a VMAP truncated mid-entry must still import the file -- one bad "
      ~ "byte must not cost the whole load");
    assert(scene.parts.length == 1);
    auto part = scene.parts[0];
    assert(part.morphs.length == 1, "the morph channel survives the truncation");
    assert(part.morphs[0].verts.length == 2,
        "the two COMPLETE entries must land and the truncated one must be "
      ~ "dropped -- a reader that bails on the whole chunk loses data it "
      ~ "already read correctly");
    assert(part.morphs[0].verts[0] == 0 && part.morphs[0].verts[1] == 1);
    assert(part.morphs[0].values.length == 6);
    assert(part.morphs[0].values[0] == 0.5f && part.morphs[0].values[4] == 0.25f,
        "and their VALUES are the ones written, not shifted by a half-read "
      ~ "entry");
}
