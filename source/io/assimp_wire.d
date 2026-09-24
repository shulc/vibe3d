module io.assimp_wire;

// Task 7640: the byte boundary between the editor wasm and the independent
// C++ Assimp wasm. Nothing on this side references a C++ symbol or runtime.
// V3DI v2 is little-endian and versioned; every count and index is checked
// before it can reach ImportedScene or an aiScene builder.

import core.stdc.string : memcpy;
import document : Document;
import io.scene_ir : ImportedPart, ImportedScene, ImportedSurface;
import math : Vec3, identityMatrix, matrixMirrorsWinding, transformPoint;
import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
import std.conv : to;

private struct Reader {
    const(ubyte)[] data;
    size_t pos;
    bool valid = true;

    uint u32() {
        if (!valid || pos > data.length || data.length - pos < 4) {
            valid = false;
            return 0;
        }
        const uint n = cast(uint)data[pos] | cast(uint)data[pos+1] << 8 |
                       cast(uint)data[pos+2] << 16 | cast(uint)data[pos+3] << 24;
        pos += 4;
        return n;
    }
    float f32() {
        uint bits = u32();
        float value;
        memcpy(&value, &bits, 4);
        return value;
    }
    const(ubyte)[] bytes(size_t count) {
        if (!valid || pos > data.length || count > data.length - pos) {
            valid = false;
            return null;
        }
        auto result = data[pos .. pos + count];
        pos += count;
        return result;
    }
    string str() {
        const count = u32();
        return cast(string)bytes(count).dup;
    }
}

private struct Writer {
    ubyte[] data;
    void u32(uint n) {
        data ~= cast(ubyte)n;
        data ~= cast(ubyte)(n >> 8);
        data ~= cast(ubyte)(n >> 16);
        data ~= cast(ubyte)(n >> 24);
    }
    void f32(float f) {
        uint bits;
        memcpy(&bits, &f, 4);
        u32(bits);
    }
    void str(string s) {
        u32(cast(uint)s.length);
        data ~= cast(const(ubyte)[])s;
    }
}

/// Decode a complete import result. False leaves `scene` unchanged.
bool decodeAssimpWire(const(ubyte)[] input, ref ImportedScene scene) {
    ImportedScene parsed;
    Reader r = Reader(input);
    if (r.bytes(4) != cast(const(ubyte)[])"V3DI" || r.u32() != 2) return false;
    const partCount = r.u32();
    if (!r.valid || partCount == 0 || partCount > 100_000) return false;
    foreach (_; 0 .. partCount) {
        const nameBytes = r.u32();
        const verts = r.u32();
        const faces = r.u32();
        const corners = r.u32();
        const surfaceCount = r.u32();
        const flags = r.u32();
        if (!r.valid || verts == 0 || faces == 0 || corners < cast(ulong)faces * 3 ||
            surfaceCount == 0 || surfaceCount > 100_000 || verts > input.length / 12 ||
            corners > input.length / 4 || faces > input.length / 4)
            return false;
        float[16] matrix;
        foreach (i; 0 .. 16) matrix[i] = r.f32();
        const name = r.bytes(nameBytes);
        if (!r.valid) return false;
        ImportedPart part;
        part.name = cast(string)name.dup;
        part.visible = (flags & 1) != 0;
        const hasUv = (flags & 2) != 0;
        const mirrored = matrixMirrorsWinding(matrix);
        foreach (i; 0 .. verts) {
            const p = Vec3(r.f32(), r.f32(), r.f32());
            part.vertices ~= transformPoint(matrix, p);
        }
        uint[] offsets;
        offsets.length = cast(size_t)faces + 1;
        foreach (ref o; offsets) o = r.u32();
        if (!r.valid || offsets[0] != 0 || offsets[$-1] != corners) return false;
        foreach (i; 0 .. faces)
            if (offsets[i+1] < offsets[i] + 3 || offsets[i+1] > corners) return false;
        uint[] indices;
        indices.length = corners;
        foreach (ref index; indices) {
            index = r.u32();
            if (index >= verts) return false;
        }
        float[] uv;
        if (hasUv) {
            uv.length = cast(size_t)corners * 2;
            foreach (ref value; uv) value = r.f32();
        }
        foreach (fi; 0 .. faces) {
            const start = offsets[fi], end = offsets[fi+1];
            uint[] ring = indices[start .. end].dup;
            if (mirrored) {
                import std.algorithm.mutation : reverse;
                ring.reverse();
                if (hasUv) {
                    float[] flipped;
                    foreach_reverse (k; start .. end)
                        flipped ~= uv[cast(size_t)k*2 .. cast(size_t)k*2+2];
                    uv[cast(size_t)start*2 .. cast(size_t)end*2] = flipped[];
                }
            }
            part.faces ~= ring;
        }
        if (hasUv) part.uv = uv;
        foreach (fi; 0 .. faces) part.faceMaterial ~= r.u32();
        foreach (si; 0 .. surfaceCount) {
            ImportedSurface s;
            s.name = r.str();
            s.baseColor = Vec3(r.f32(), r.f32(), r.f32());
            s.diffuse = r.f32();
            s.specular = r.f32();
            s.glossiness = r.f32();
            s.opacity = r.f32();
            part.surfaces ~= s;
        }
        if (!r.valid) return false;
        foreach (index; part.faceMaterial)
            if (index >= surfaceCount) return false;
        // Assimp splits vertices at smoothing and UV seams. Mesh geometry is
        // positional in vibe3d; the UV stream remains per corner after weld.
        struct Key { long x, y, z; }
        uint[Key] seen;
        uint[] remap;
        remap.length = part.vertices.length;
        Vec3[] welded;
        import std.math : lround;
        foreach (i, v; part.vertices) {
            const key = Key(lround(v.x * 100_000), lround(v.y * 100_000),
                            lround(v.z * 100_000));
            if (auto found = key in seen) remap[i] = *found;
            else {
                const index = cast(uint)welded.length;
                welded ~= v;
                seen[key] = index;
                remap[i] = index;
            }
        }
        uint[][] weldedFaces;
        uint[] weldedMaterial;
        float[] weldedUv;
        size_t uvCursor;
        foreach (fi, face; part.faces) {
            uint[] ring;
            float[] ringUv;
            foreach (index; face) {
                const mapped = remap[index];
                if (ring.length == 0 || ring[$-1] != mapped) {
                    ring ~= mapped;
                    if (hasUv) ringUv ~= part.uv[uvCursor .. uvCursor+2];
                }
                if (hasUv) uvCursor += 2;
            }
            if (ring.length >= 2 && ring[0] == ring[$-1]) {
                ring.length--;
                if (hasUv) ringUv.length -= 2;
            }
            if (ring.length >= 3) {
                weldedFaces ~= ring;
                weldedMaterial ~= part.faceMaterial[fi];
                if (hasUv) weldedUv ~= ringUv;
            }
        }
        part.vertices = welded;
        part.faces = weldedFaces;
        part.faceMaterial = weldedMaterial;
        if (hasUv) part.uv = weldedUv;
        if (part.faces.length == 0) continue;
        parsed.parts ~= part;
    }
    if (!r.valid || r.pos != input.length) return false;
    if (parsed.parts.length == 0) return false;
    scene = parsed;
    return true;
}

/// Encode all mesh layers for a foreign exporter. The foreign format remains
/// lossy by the same policy as desktop: one default material per mesh.
ubyte[] encodeAssimpWire(ref const Document doc) {
    Writer w;
    w.data ~= cast(const(ubyte)[])"V3DI";
    w.u32(2);
    size_t countAt = w.data.length;
    w.u32(0);
    uint count;
    foreach (l; doc.meshLayers) {
        ref const(Mesh) mesh = l.meshRef();
        uint faceCount, cornerCount;
        foreach (face; mesh.faces.range) {
            if (face.length < 3) continue;
            ++faceCount;
            cornerCount += cast(uint)face.length;
        }
        if (faceCount == 0 || mesh.vertices.length == 0) continue;
        ++count;
        const float[16] M = l.xform.composedMatrix();
        const bool mirrored = matrixMirrorsWinding(M);
        const float[16] writeM = mirrored ? identityMatrix : M;
        const(MeshMap)* uvMap = mesh.meshMap(kUvMapName);
        const bool hasUv = uvMap !is null && uvMap.domain == MapDomain.PolyVertex && uvMap.dim == 2;
        const name = l.name.length ? l.name : "Mesh";
        w.u32(cast(uint)name.length);
        w.u32(cast(uint)mesh.vertices.length);
        w.u32(faceCount);
        w.u32(cornerCount);
        w.u32(1); // default material
        w.u32((l.visible ? 1u : 0u) | (hasUv ? 2u : 0u));
        foreach (v; writeM) w.f32(v);
        w.data ~= cast(const(ubyte)[])name;
        foreach (v; mesh.vertices) {
            const p = mirrored ? transformPoint(M, v) : v;
            w.f32(p.x); w.f32(p.y); w.f32(p.z);
        }
        w.u32(0);
        uint offset;
        foreach (face; mesh.faces.range) {
            if (face.length < 3) continue;
            offset += cast(uint)face.length;
            w.u32(offset);
        }
        foreach (face; mesh.faces.range) {
            if (face.length < 3) continue;
            foreach (k; 0 .. face.length) {
                const source = mirrored ? face.length - 1 - k : k;
                w.u32(face[source]);
            }
        }
        if (hasUv) {
            foreach (uint fi; 0 .. cast(uint)mesh.faces.length) {
                const face = mesh.faces[fi];
                if (face.length < 3) continue;
                foreach (k; 0 .. face.length) {
                    const source = mirrored ? face.length - 1 - k : k;
                    const loop = mesh.faceCornerLoop(fi, cast(uint)source);
                    const u = loop != size_t.max && loop*2+1 < uvMap.data.length
                        ? uvMap.data[loop*2] : 0.0f;
                    const v = loop != size_t.max && loop*2+1 < uvMap.data.length
                        ? uvMap.data[loop*2+1] : 0.0f;
                    w.f32(u); w.f32(v);
                }
            }
        }
        foreach (i; 0 .. faceCount) w.u32(0);
        w.str("Default");
        w.f32(0.7f); w.f32(0.7f); w.f32(0.7f);
        w.f32(1.0f); w.f32(0.0f); w.f32(0.4f); w.f32(1.0f);
    }
    if (count == 0) return null;
    foreach (i; 0 .. 4) w.data[countAt+i] = cast(ubyte)(count >> (8*i));
    return w.data;
}
