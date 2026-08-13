// Task 0691 — a foreign file whose NODE mirrors must import outward-facing.
//
// The mirror half of task 0684 (which fixed the same class on EXPORT). Our
// importer bakes each node's accumulated world matrix into the part's points
// (`io/scene_import.d`, decision B2). Baking a NEGATIVE-determinant matrix
// moves the points and leaves the face index order alone, so every face of
// that node comes in wound INWARD — the model renders inside-out. A mirrored
// node is an ordinary instancing idiom in other editors, so this arrives in
// real third-party glTF/FBX.
//
// Nothing upstream compensates, measured on this build (assimp 6.0.5) BEFORE
// the fix: a mirrored-node cube imported with 12 of 12 faces inward through
// glTF `matrix` form, glTF TRS `scale` form and ASCII FBX `Lcl Scaling` form
// alike. Neither the glTF2 nor the FBX reader carries a determinant/winding
// term, and we deliberately pass neither `aiProcess_MakeLeftHanded` nor
// `aiProcess_FlipWindingOrder` (they are SCENE-wide and would flip the
// un-mirrored nodes too). The compensation is per node, in `partFromMesh`.
//
// THE ASSERTION is geometric, not index-order (same shape as
// tests/test_mirror_export_winding.d): for every face, the Newell normal must
// point AWAY from the mesh centroid. The fixture box is convex and contains its
// own centroid, so "outward" is unambiguous — and it is the property a user
// actually loses.
//
// FIXTURE NOTE — the box is ASYMMETRIC in x (local x in [0, 2], y and z in
// [-1, 1]) and every mirroring node also TRANSLATES. A box mirrored about its
// own centre is the same point set, so a symmetric fixture cannot tell "winding
// reversed" from "the bake was dropped entirely". With mirror-x + translate 3
// the imported x-range must be [1, 3]; a dropped bake leaves [0, 2] and a
// dropped MIRROR leaves [3, 5]. That range check is what keeps every winding
// assertion below non-vacuous.
//
// This is a SOURCE-BACKED test (it imports `mesh` / `math` / `document`), not an
// HTTP driver, for two reasons: the per-corner UV half of the fix has no HTTP
// surface (mesh maps are not serialised by /api/model), and driving
// `importViaAssimp` directly pins the exact seam that carries the defect.

import std.math    : fabs;
import std.file    : write, remove, exists;
import std.format  : format;
import std.process : thisProcessID;
import std.conv    : to;

import math            : Vec3;
import mesh            : Mesh, kUvMapName;
import document        : Document;
import io.scene_ir     : ImportedScene, flattenToMesh, toLayers;
import io.scene_import : importViaAssimp;
import io.assimp_runtime : initAssimp, isAssimpAvailable;

void main() {}

private bool feq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// geometry: Newell normal vs the mesh centroid, and the bake witness
// ---------------------------------------------------------------------------

/// How many faces of `m` point AWAY from the mesh centroid, and how many point
/// into it. A correctly wound closed convex mesh is (faceCount, 0).
private size_t[2] outwardInward(const ref Mesh m) {
    Vec3 c = Vec3(0, 0, 0);
    foreach (v; m.vertices) { c.x += v.x; c.y += v.y; c.z += v.z; }
    const double n = cast(double) m.vertices.length;
    c = Vec3(cast(float)(c.x / n), cast(float)(c.y / n), cast(float)(c.z / n));

    size_t outward = 0, inward = 0;
    foreach (fi; 0 .. m.faces.length) {
        const face = m.faces[fi];
        double nx = 0, ny = 0, nz = 0, fx = 0, fy = 0, fz = 0;
        foreach (k; 0 .. face.length) {
            const a = m.vertices[face[k]];
            const b = m.vertices[face[(k + 1) % face.length]];
            nx += (a.y - b.y) * (a.z + b.z);
            ny += (a.z - b.z) * (a.x + b.x);
            nz += (a.x - b.x) * (a.y + b.y);
            fx += a.x; fy += a.y; fz += a.z;
        }
        const double kk = cast(double) face.length;
        const double dx = fx / kk - c.x, dy = fy / kk - c.y, dz = fz / kk - c.z;
        if (nx * dx + ny * dy + nz * dz > 0) outward++; else inward++;
    }
    return [outward, inward];
}

private void assertAllOutward(const ref Mesh m, string ctx) {
    assert(m.faces.length > 0, ctx ~ ": imported mesh has no faces");
    const oi = outwardInward(m);
    assert(oi[1] == 0,
        format("%s: %d of %d faces imported wound INWARD — a mirroring node "
             ~ "must import with reversed winding", ctx, oi[1], oi[0] + oi[1]));
}

/// [min, max] of one axis (0=x, 1=y, 2=z) over the imported points — the bake
/// witness described in the header.
private double[2] axisRange(const ref Mesh m, int axis) {
    double lo = double.max, hi = -double.max;
    foreach (v; m.vertices) {
        const double c = axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
        if (c < lo) lo = c;
        if (c > hi) hi = c;
    }
    return [lo, hi];
}

private void assertRange(const ref Mesh m, int axis, double lo, double hi,
                         string ctx, double eps = 1e-4) {
    const r = axisRange(m, axis);
    static immutable string[3] names = ["x", "y", "z"];
    assert(feq(r[0], lo, eps) && feq(r[1], hi, eps),
        format("%s: %s-range is [%g, %g], expected [%g, %g] — the node "
             ~ "transform bake did not land as authored, so the winding "
             ~ "assertion around it would be vacuous",
               ctx, names[axis], r[0], r[1], lo, hi));
}

// ---------------------------------------------------------------------------
// fixture plumbing
// ---------------------------------------------------------------------------

/// Unique per test process (the runner runs up to 8 in parallel) AND per stem.
private string tmpPath(string stem, string ext) {
    return format("/tmp/vibe3d-0691-%s-%d%s", stem, thisProcessID, ext);
}

private ImportedScene importScene(string text, string stem, string ext) {
    const path = tmpPath(stem, ext);
    write(path, text);
    scope(exit) if (exists(path)) remove(path);
    ImportedScene s;
    assert(importViaAssimp(path, s),
        "importViaAssimp failed for " ~ stem ~ ext);
    return s;
}

private Mesh importOne(string text, string stem, string ext) {
    auto s = importScene(text, stem, ext);
    return flattenToMesh(s);
}

// ---------------------------------------------------------------------------
// glTF fixtures — hand-authored, data-URI buffer, no sidecar
// ---------------------------------------------------------------------------
//
// The mesh: a box with local x in [0, 2], y in [-1, 1], z in [-1, 1], authored
// as 8 shared vertices and 6 outward quads split into 12 triangles (glTF is
// triangle-only). Vertex index vi = ix + 2*iy + 4*iz over the corner lattice.
//
// `cubeB64`   = 8 VEC3 positions (96 B) + 36 ushort indices (72 B).
// `cubeUvB64` = the same with 8 VEC2 UVs (64 B) spliced in between; the UV
//               authored for vertex vi is (vi/10, 0.5) — distinct per vertex so
//               a sheared corner/UV pairing is detectable, and V = 0.5 so the
//               check survives any importer's V-flip convention.

private enum string cubeB64 =
    `AAAAAAAAgL8AAIC/AAAAQAAAgL8AAIC/AAAAAAAAgD8AAIC/AAAAQAAAgD8AAIC/AAAAAAAAgL8A`
  ~ `AIA/AAAAQAAAgL8AAIA/AAAAAAAAgD8AAIA/AAAAQAAAgD8AAIA/AAAEAAYAAAAGAAIAAQADAAcA`
  ~ `AQAHAAUAAAABAAUAAAAFAAQAAgAGAAcAAgAHAAMAAAACAAMAAAADAAEABAAFAAcABAAHAAYA`;

private enum string cubeUvB64 =
    `AAAAAAAAgL8AAIC/AAAAQAAAgL8AAIC/AAAAAAAAgD8AAIC/AAAAQAAAgD8AAIC/AAAAAAAAgL8A`
  ~ `AIA/AAAAQAAAgL8AAIA/AAAAAAAAgD8AAIA/AAAAQAAAgD8AAIA/AAAAAAAAAD/NzMw9AAAAP83M`
  ~ `TD4AAAA/mpmZPgAAAD/NzMw+AAAAPwAAAD8AAAA/mpkZPwAAAD8zMzM/AAAAPwAABAAGAAAABgAC`
  ~ `AAEAAwAHAAEABwAFAAAAAQAFAAAABQAEAAIABgAHAAIABwADAAAAAgADAAAAAwABAAQABQAHAAQA`
  ~ `BwAGAA==`;

/// Assemble a glTF 2.0 document: `roots` is the scene's root node index list,
/// `nodes` the `"nodes"` array body.
private string gltf(string roots, string nodes) {
    return format(`{
  "asset": { "version": "2.0" },
  "scene": 0,
  "scenes": [ { "nodes": [ %s ] } ],
  "nodes": [ %s ],
  "meshes": [
    { "primitives": [ { "attributes": { "POSITION": 0 }, "indices": 1, "mode": 4 } ] }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3",
      "min": [ 0.0, -1.0, -1.0 ], "max": [ 2.0, 1.0, 1.0 ] },
    { "bufferView": 1, "componentType": 5123, "count": 36, "type": "SCALAR" }
  ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,  "byteLength": 96, "target": 34962 },
    { "buffer": 0, "byteOffset": 96, "byteLength": 72, "target": 34963 }
  ],
  "buffers": [
    { "byteLength": 168,
      "uri": "data:application/octet-stream;base64,%s" }
  ]
}`, roots, nodes, cubeB64);
}

/// The same document with a TEXCOORD_0 channel.
private string gltfUv(string nodes) {
    return format(`{
  "asset": { "version": "2.0" },
  "scene": 0,
  "scenes": [ { "nodes": [ 0 ] } ],
  "nodes": [ %s ],
  "meshes": [
    { "primitives": [ { "attributes": { "POSITION": 0, "TEXCOORD_0": 1 },
                        "indices": 2, "mode": 4 } ] }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3",
      "min": [ 0.0, -1.0, -1.0 ], "max": [ 2.0, 1.0, 1.0 ] },
    { "bufferView": 1, "componentType": 5126, "count": 8, "type": "VEC2",
      "min": [ 0.0, 0.5 ], "max": [ 0.7, 0.5 ] },
    { "bufferView": 2, "componentType": 5123, "count": 36, "type": "SCALAR" }
  ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,   "byteLength": 96, "target": 34962 },
    { "buffer": 0, "byteOffset": 96,  "byteLength": 64, "target": 34962 },
    { "buffer": 0, "byteOffset": 160, "byteLength": 72, "target": 34963 }
  ],
  "buffers": [
    { "byteLength": 232,
      "uri": "data:application/octet-stream;base64,%s" }
  ]
}`, nodes, cubeUvB64);
}

// Node bodies. glTF matrices are COLUMN-major, so the translation is the last
// four entries; `scl.x = -1` puts the mirror in the first.
private enum string nodeMirror =
    `{ "mesh": 0, "name": "MirrorNode",
       "matrix": [ -1,0,0,0,  0,1,0,0,  0,0,1,0,  3,0,0,1 ] }`;
private enum string nodePlain =
    `{ "mesh": 0, "name": "PlainNode",
       "matrix": [  1,0,0,0,  0,1,0,0,  0,0,1,0,  3,0,0,1 ] }`;
// The same mirror spelled as TRS instead of a matrix — a file is free to write
// either, and the predicate must see the COMPOSED transform in both cases.
private enum string nodeMirrorTrs =
    `{ "mesh": 0, "name": "MirrorTrsNode",
       "scale": [ -1, 1, 1 ], "translation": [ 3, 0, 0 ] }`;

// ---------------------------------------------------------------------------
// 1. a mirroring node imports outward — matrix form and TRS form
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;   // static link: shouldn't happen

    foreach (i, node; [nodeMirror, nodeMirrorTrs]) {
        const label = i == 0 ? "glTF mirrored node (matrix)"
                             : "glTF mirrored node (TRS scale)";
        auto m = importOne(gltf("0", node), "mirror" ~ i.to!string, ".gltf");

        assert(m.vertices.length == 8,
            format("%s: expected the 8 box corners, got %d",
                   label, m.vertices.length));
        // Bake witness FIRST: mirror-x + translate 3 maps local [0,2] to [1,3].
        // Un-baked would be [0,2]; baked without the mirror would be [3,5].
        assertRange(m, 0, 1.0, 3.0, label);
        assertAllOutward(m, label);
    }
}

// ---------------------------------------------------------------------------
// 2. the control: a NON-mirroring node must be left alone
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    // Same translation, positive determinant. This is what makes case 1
    // meaningful: a "fix" that reversed EVERY imported face would pass case 1
    // and fail here.
    auto m = importOne(gltf("0", nodePlain), "plain", ".gltf");
    assertRange(m, 0, 3.0, 5.0, "glTF plain node");
    assertAllOutward(m, "glTF plain node");
}

// ---------------------------------------------------------------------------
// 3. the mirror is a property of the ACCUMULATED world matrix, not of one node
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    // (a) The MESH-carrying node's own matrix is a plain translation; the
    //     mirror is inherited from its parent. A predicate that looked at the
    //     local matrix would not flip here, and the box would come in inward.
    enum string inherited =
        `{ "name": "MirrorParent",
           "matrix": [ -1,0,0,0,  0,1,0,0,  0,0,1,0,  3,0,0,1 ],
           "children": [ 1 ] },
         { "mesh": 0, "name": "ChildNode",
           "matrix": [  1,0,0,0,  0,1,0,0,  0,0,1,0,  0,4,0,1 ] }`;
    auto a = importOne(gltf("0", inherited), "inherited", ".gltf");
    assertRange(a, 0, 1.0, 3.0, "glTF inherited mirror");   // parent mirror+translate
    assertRange(a, 1, 3.0, 5.0, "glTF inherited mirror");   // child translate (y)
    assertAllOutward(a, "glTF inherited mirror");

    // (b) TWO mirrors in one chain CANCEL: mirror-x under mirror-y composes to a
    //     180-degree turn about z, determinant +1, geometry NOT mirrored — so
    //     the winding must be left alone. This fails if the rule degrades into
    //     "flip when any node in the chain mirrors". The y-translate on the
    //     child is the witness that its matrix was applied at all (y in [-1,1]
    //     is mirror-symmetric on its own and would prove nothing).
    enum string cancelling =
        `{ "name": "MirrorParent",
           "matrix": [ -1,0,0,0,  0,1,0,0,  0,0,1,0,  3,0,0,1 ],
           "children": [ 1 ] },
         { "mesh": 0, "name": "MirrorChild",
           "matrix": [  1,0,0,0,  0,-1,0,0, 0,0,1,0,  0,4,0,1 ] }`;
    auto b = importOne(gltf("0", cancelling), "cancelling", ".gltf");
    assertRange(b, 0, 1.0, 3.0, "glTF cancelling mirrors");
    assertRange(b, 1, 3.0, 5.0, "glTF cancelling mirrors");
    assertAllOutward(b, "glTF cancelling mirrors");
}

// ---------------------------------------------------------------------------
// 4. multi-part import (one part per node) -> one LAYER per part
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    // Two sibling nodes on the same mesh: one mirroring at +3, one plain at -6.
    // A multi-part scene takes `toLayers` (commands/file/load.d), not
    // `flattenToMesh` — the per-layer meshes must each come in outward.
    enum string siblings =
        `{ "mesh": 0, "name": "MirrorNode",
           "matrix": [ -1,0,0,0,  0,1,0,0,  0,0,1,0,   3,0,0,1 ] },
         { "mesh": 0, "name": "PlainNode",
           "matrix": [  1,0,0,0,  0,1,0,0,  0,0,1,0,  -6,0,0,1 ] }`;
    auto sc = importScene(gltf("0, 1", siblings), "siblings", ".gltf");
    assert(sc.parts.length == 2,
        format("expected one part per node, got %d", sc.parts.length));

    Document doc = toLayers(sc);
    assert(doc.layers.length == 2,
        format("expected 2 layers from a 2-part import, got %d",
               doc.layers.length));

    bool sawMirrored = false, sawPlain = false;
    foreach (li, l; doc.layers) {
        const ref Mesh lm = l.meshRef();
        const r = axisRange(lm, 0);
        // The mirrored layer is the one that baked to x in [1,3]; the plain one
        // sits at [-6,-4].
        const bool isMirrored = r[0] > 0;
        if (isMirrored) {
            sawMirrored = true;
            assertRange(lm, 0, 1.0, 3.0, "layer (mirrored)");
        } else {
            sawPlain = true;
            assertRange(lm, 0, -6.0, -4.0, "layer (plain)");
        }
        assertAllOutward(lm, format("layer %d (%s)", li,
            isMirrored ? "mirrored" : "plain"));
    }
    assert(sawMirrored && sawPlain,
        "both the mirrored and the plain node must survive as layers");
}

// ---------------------------------------------------------------------------
// 5. per-corner UV rides the reversal WITH the indices
// ---------------------------------------------------------------------------

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    // The fixture authors uv = (vi/10, 0.5) on source vertex vi, so every
    // vertex carries a DISTINCT u. After the import, each surviving corner must
    // still carry the u of the vertex IT references — reversing the index array
    // without reversing the per-corner UV stream shears the pairing by one
    // corner and this fails.
    //
    // `vi` is recovered from the imported (world) position: the mirroring node
    // maps local x to 3 - x, the plain node to x + 3; y and z are untouched.
    static struct Case { string node; string label; bool mirrored; }
    foreach (c; [Case(nodeMirror, "glTF mirrored node + UV", true),
                 Case(nodePlain,  "glTF plain node + UV",    false)]) {
        auto m = importOne(gltfUv(c.node), c.mirrored ? "uvmirror" : "uvplain",
                           ".gltf");

        assert(m.vertices.length == 8,
            format("%s: expected 8 corners, got %d", c.label, m.vertices.length));
        assertRange(m, 0, c.mirrored ? 1.0 : 3.0, c.mirrored ? 3.0 : 5.0, c.label);
        assertAllOutward(m, c.label);

        auto map = m.meshMap(kUvMapName);
        assert(map !is null, c.label ~ ": the UV channel must survive the import");
        assert(map.data.length == m.loops.length * 2,
            format("%s: UV map has %d floats for %d corners",
                   c.label, map.data.length, m.loops.length));

        size_t checked = 0;
        foreach (uint fi; 0 .. cast(uint) m.faces.length) {
            const face = m.faces[fi];
            foreach (uint k; 0 .. cast(uint) face.length) {
                const v = m.vertices[face[k]];
                const double localX = c.mirrored ? (3.0 - v.x) : (v.x - 3.0);
                const size_t vi = (localX > 1.0 ? 1 : 0)
                                + (v.y > 0 ? 2 : 0)
                                + (v.z > 0 ? 4 : 0);
                const size_t loop = m.faceCornerLoop(fi, k);
                assert(loop != size_t.max,
                    format("%s: face %d corner %d has no loop", c.label, fi, k));
                const double u = map.data[loop * 2];
                const double vv = map.data[loop * 2 + 1];
                assert(feq(u, vi / 10.0) && feq(vv, 0.5),
                    format("%s: face %d corner %d sits on source vertex %d "
                         ~ "(uv should be %g, 0.5) but carries (%g, %g) — the "
                         ~ "per-corner UV stream did not follow the index "
                         ~ "reversal", c.label, fi, k, vi, vi / 10.0, u, vv));
                checked++;
            }
        }
        assert(checked == m.loops.length,
            format("%s: checked %d corners of %d", c.label, checked, m.loops.length));
    }
}

// ---------------------------------------------------------------------------
// 6. the FBX path carries the same node transform — and the same defect
// ---------------------------------------------------------------------------
//
// Hand-authored ASCII FBX (assimp reads it): the same 8-corner box under one
// Model whose `Lcl Scaling` is the mirror. Written out rather than exported
// from vibe3d on purpose — since task 0684 our own writers bake a mirroring
// layer in place and emit an IDENTITY node, so no vibe3d-produced file can
// exercise this.
//
// The FBX importer applies its own unit normalisation (a positive uniform
// scale, ~0.01 here), which no assertion may depend on. So the FBX bake witness
// is the scale-INVARIANT ratio max(x)/min(x): the mirror maps local [0,2] to
// [1,3] (ratio 3), the plain node to [3,5] (ratio 5/3), an un-baked import
// leaves [0,2] (min 0).

private string fbxDoc(string lclScaling) {
    return format(`; FBX 7.4.0 project file
; hand-authored minimal scene: one box under a node whose Lcl Scaling is %s

FBXHeaderExtension:  {
	FBXHeaderVersion: 1003
	FBXVersion: 7400
	Creator: "vibe3d test fixture (task 0691)"
}
GlobalSettings:  {
	Version: 1000
	Properties70:  {
		P: "UpAxis", "int", "Integer", "",1
		P: "UpAxisSign", "int", "Integer", "",1
		P: "FrontAxis", "int", "Integer", "",2
		P: "FrontAxisSign", "int", "Integer", "",1
		P: "CoordAxis", "int", "Integer", "",0
		P: "CoordAxisSign", "int", "Integer", "",1
		P: "UnitScaleFactor", "double", "Number", "",1
	}
}
Definitions:  {
	Version: 100
	Count: 2
	ObjectType: "Geometry" {
		Count: 1
	}
	ObjectType: "Model" {
		Count: 1
	}
}
Objects:  {
	Geometry: 1000, "Geometry::Box", "Mesh" {
		Vertices: *24 {
			a: 0,-1,-1,2,-1,-1,0,1,-1,2,1,-1,0,-1,1,2,-1,1,0,1,1,2,1,1
		}
		PolygonVertexIndex: *24 {
			a: 0,4,6,-3,1,3,7,-6,0,1,5,-5,2,6,7,-4,0,2,3,-2,4,5,7,-7
		}
		GeometryVersion: 124
	}
	Model: 2000, "Model::BoxNode", "Mesh" {
		Version: 232
		Properties70:  {
			P: "Lcl Translation", "Lcl Translation", "", "A",3,0,0
			P: "Lcl Scaling", "Lcl Scaling", "", "A",%s
		}
		Shading: T
		Culling: "CullingOff"
	}
}
Connections:  {
	C: "OO",2000,0
	C: "OO",1000,2000
}
`, lclScaling, lclScaling);
}

unittest {
    initAssimp();
    if (!isAssimpAvailable()) return;

    static struct Case { string scaling; string label; double ratio; }
    foreach (c; [Case("-1,1,1", "FBX mirrored node", 3.0),
                 Case( "1,1,1", "FBX plain node",    5.0 / 3.0)]) {
        auto m = importOne(fbxDoc(c.scaling),
                           c.ratio > 2 ? "fbxmirror" : "fbxplain", ".fbx");

        assert(m.vertices.length == 8,
            format("%s: expected 8 corners, got %d", c.label, m.vertices.length));
        // FBX keeps the authored quads (we ask assimp for no triangulation).
        assert(m.faces.length == 6,
            format("%s: expected the 6 authored quads, got %d",
                   c.label, m.faces.length));

        const r = axisRange(m, 0);
        assert(r[0] > 1e-6,
            format("%s: x-range [%g, %g] touches 0 — the node translation was "
                 ~ "not baked, so the winding check would be vacuous",
                   c.label, r[0], r[1]));
        assert(feq(r[1] / r[0], c.ratio, 1e-3),
            format("%s: x-range [%g, %g] has ratio %g, expected %g — the node "
                 ~ "transform did not bake as authored",
                   c.label, r[0], r[1], r[1] / r[0], c.ratio));

        assertAllOutward(m, c.label);
    }
}
