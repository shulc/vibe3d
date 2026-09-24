module tests.unit.assimp_wire_test;

import document : Document;
import io.assimp_wire : decodeAssimpWire, encodeAssimpWire;
import io.scene_ir : ImportedScene;
import mesh : makeCube;

unittest {
    auto doc = Document.bootstrap(makeCube());
    auto wire = encodeAssimpWire(doc);
    assert(wire.length > 100);
    ImportedScene scene;
    assert(decodeAssimpWire(wire, scene));
    assert(scene.parts.length == 1);
    assert(scene.parts[0].vertices.length == 8);
    assert(scene.parts[0].faces.length == 6);
    assert(scene.parts[0].faceMaterial.length == 6);

    // A failed decode must neither accept a damaged header nor replace a
    // previous successful scene. This catches a decoder that only checks the
    // counts and a caller that loses its current document on refusal.
    wire[0] ^= 0xff;
    assert(!decodeAssimpWire(wire, scene));
    assert(scene.parts.length == 1 && scene.parts[0].faces.length == 6);

    wire[0] ^= 0xff;
    uint get32(size_t at) {
        return cast(uint)wire[at] | cast(uint)wire[at+1] << 8 |
               cast(uint)wire[at+2] << 16 | cast(uint)wire[at+3] << 24;
    }
    const nameLen = get32(12), verts = get32(16), faces = get32(20);
    const corners = get32(24), flags = get32(32);
    const materialAt = 12 + 24 + 64 + nameLen + verts*12 +
        (faces+1)*4 + corners*4 + ((flags & 2) ? corners*8 : 0) + faces*4;
    assert(materialAt + 4 + get32(materialAt) + 28 == wire.length);
    auto noMaterial = wire[0 .. materialAt].dup;
    foreach (i; 28 .. 32) noMaterial[i] = 0; // part's surface count
    assert(!decodeAssimpWire(noMaterial, scene));
    assert(scene.parts.length == 1 && scene.parts[0].faces.length == 6);
}
