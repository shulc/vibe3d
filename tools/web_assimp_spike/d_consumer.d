module d_consumer;

// A separate wasm/D runtime that validates the probe's compact scene wire.
// This is deliberately a second program, never linked with libassimp.
private uint parts_;
private uint vertices_;
private uint faces_;

void main() {}

export extern(C) int vibe_d_eh_probe() {
    try { throw new Exception("D exception stays in D wasm"); }
    catch (Exception) { return 11; }
}

export extern(C) uint vibe_d_parts() { return parts_; }
export extern(C) uint vibe_d_vertices() { return vertices_; }
export extern(C) uint vibe_d_faces() { return faces_; }

export extern(C) int vibe_consume_scene(const(ubyte)* data, uint length) {
    parts_ = vertices_ = faces_ = 0;
    if (data is null || length < 12 || data[0 .. 4] != cast(const(ubyte)[])"V3DI")
        return 0;
    size_t pos = 4;
    bool read(out uint value) {
        if (pos > length || length - pos < 4) return false;
        value = cast(uint)data[pos] | (cast(uint)data[pos+1] << 8) |
                (cast(uint)data[pos+2] << 16) | (cast(uint)data[pos+3] << 24);
        pos += 4;
        return true;
    }
    bool skip(ulong bytes) {
        if (bytes > length || pos > length - bytes) return false;
        pos += cast(size_t)bytes;
        return true;
    }
    uint version_, count;
    if (!read(version_) || version_ != 1 || !read(count) || count == 0 || count > 100_000)
        return 0;
    ulong totalVerts, totalFaces;
    foreach (partIndex; 0 .. count) {
        uint nameLen, verts, faceCount, corners;
        if (!read(nameLen) || !read(verts) || !read(faceCount) || !read(corners)) return 0;
        if (verts == 0 || faceCount == 0 || corners < faceCount * 3UL) return 0;
        if (!skip(nameLen) || !skip(cast(ulong)verts * 12)) return 0;
        uint offset;
        foreach (i; 0 .. faceCount + 1UL) {
            if (!read(offset)) return 0;
            if ((i == 0 && offset != 0) || (i == faceCount && offset != corners)) return 0;
        }
        foreach (cornerIndex; 0 .. corners) {
            uint index;
            if (!read(index) || index >= verts) return 0;
        }
        if (!skip(cast(ulong)corners * 8)) return 0;
        totalVerts += verts;
        totalFaces += faceCount;
        if (totalVerts > uint.max || totalFaces > uint.max) return 0;
    }
    if (pos != length) return 0;
    parts_ = count;
    vertices_ = cast(uint)totalVerts;
    faces_ = cast(uint)totalFaces;
    return 1;
}
