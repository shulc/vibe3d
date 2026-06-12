module io.scene_import;

// ---------------------------------------------------------------------------
// assimp import — OBJ / glTF / FBX -> ImportedScene (Phase 4).
// ---------------------------------------------------------------------------
// Foreign formats are pulled in through the bindbc-assimp6 dynamic bindings
// and converted to the scene-IR seam (`ImportedScene`), which `flattenToMesh`
// then merges into one vibe3d Mesh. assimp normalises EVERY source format to
// its own internal coordinate system first (right-handed, +Y up, +Z toward the
// viewer, CCW front faces), so a single, format-independent set of choices is
// applied here.
//
// Handedness finding (decision B3):
//   vibe3d is RIGHT-HANDED, +Y up, CCW-front — matching assimp's internal
//   convention exactly:
//     * source/math.d `lookAt` writes -f into the third basis row and
//       `perspectiveMatrix` puts -1 in the w-row → the camera looks down -Z
//       (the OpenGL right-handed convention).
//     * source/mesh.d's front-face test is
//         fn = cross(v1-v0, v2-v0);  front  iff  dot(fn, v0-eye) < 0
//       i.e. a CCW-wound face whose normal points toward the camera is the
//       front face (makeOctahedron's comment: "Winding is CCW from outside").
//   Because both spaces agree, we pass NEITHER aiProcess_MakeLeftHanded nor
//   aiProcess_FlipWindingOrder — those would MIRROR a right-handed source and
//   invert winding, which is exactly wrong here.
//
// Exact aiImportFile flags (see `importFlags` below):
//   aiProcess_JoinIdenticalVertices  cheap pre-reduction (the authoritative
//                                    reduction is the positional weld in B5).
//   aiProcess_GlobalScale            honour the file's unit scale (FBX cm, etc.)
//                                    so a 100-unit FBX doesn't come in x100.
//                                    The scale FACTOR config defaults to 1, so
//                                    plain aiImportFile suffices — no property
//                                    store needed.
//   aiProcess_FindDegenerates +      drop zero-area / collinear faces and the
//   aiProcess_FindInvalidData        invalid-data they leave, so degenerate
//                                    geometry doesn't reach flattenToMesh.
//   (NO aiProcess_Triangulate — decision A3: keep n-gons.)
//   (NO aiProcess_PreTransformVertices — we bake transforms ourselves per part,
//    decision B2, to keep one part per node-referenced mesh for the proto-layer
//    model.)
//
// Materials (mirrors D-Lwo2Writer's assimp adapter): one ImportedSurface per
// `s.mMaterials[]` (the GLOBAL table, like LWO's TAGS), name via AI_MATKEY_NAME
// + aiGetMaterialString, diffuse via AI_MATKEY_COLOR_DIFFUSE + aiGetMaterialColor.
// The same global table is placed on every part; flattenToMesh dedups by name.

import std.string : toStringz, fromStringz;
import std.conv   : to;
import std.math   : abs;
import std.format : format;

import bindbc.assimp;
import log : logWarn;

import math;
import io.scene_ir;
import io.assimp_runtime : isAssimpAvailable;

/// Post-process flags handed to aiImportFile. See the module header for the
/// rationale behind each (and behind the flags deliberately NOT set).
private enum uint importFlags =
    aiProcess_JoinIdenticalVertices |
    aiProcess_GlobalScale           |
    aiProcess_FindDegenerates       |
    aiProcess_FindInvalidData;

/// Positional weld epsilon (decision B5). Vertices whose positions match to
/// within this distance collapse to one — undoing assimp's smoothing/UV splits
/// once normals/UVs are discarded (decision A4).
private enum float weldEpsilon = 1e-5f;

/// Import `path` through assimp into `scene`. Returns false (logging to stderr)
/// when assimp is unavailable or the import fails; `scene` is only populated on
/// success.
bool importViaAssimp(string path, ref ImportedScene scene) {
    if (!isAssimpAvailable()) {
        try logWarn("io", "assimp not loaded");
        catch (Exception) {}
        return false;
    }

    const(aiScene)* s = aiImportFile(path.toStringz, importFlags);
    if (s is null) {
        try logWarn("io", format("assimp import failed: %s",
                            aiGetErrorString().fromStringz));
        catch (Exception) {}
        return false;
    }
    scope(exit) aiReleaseImport(s);

    scene = sceneFromAssimp(s);
    return true;
}

/// Convert an in-memory aiScene to an `ImportedScene`. Factored out of
/// `importViaAssimp` so the conversion is unit-testable from a hand-built
/// scene without a file on disk.
///
/// Each (node, referenced-mesh) pair becomes ONE `ImportedPart`, with the
/// node's accumulated world transform baked into its vertices (B2) and a
/// positional weld applied (B5). The global material table is copied onto
/// every part (flattenToMesh dedups by name).
ImportedScene sceneFromAssimp(const(aiScene)* s) {
    ImportedScene scene;
    if (s is null) return scene;

    // --- global material table (LWO-style: same list on every part) ---
    ImportedSurface[] surfaces;
    foreach (i; 0 .. s.mNumMaterials) {
        const(aiMaterial)* m = s.mMaterials[i];
        ImportedSurface surf;
        surf.name      = materialName(m, i);
        surf.baseColor = materialDiffuse(m);
        surfaces ~= surf;
    }
    // A scene with no materials still wants one default surface so every part's
    // faceMaterial=0 has somewhere to land.
    if (surfaces.length == 0)
        surfaces ~= ImportedSurface();

    // --- walk the node tree, baking world transforms ---
    if (s.mRootNode !is null)
        walkNode(s, s.mRootNode, identity4(), surfaces, scene);

    return scene;
}

// ---------------------------------------------------------------------------
// node walk + transform bake (B2)
// ---------------------------------------------------------------------------

/// Recursively descend `node`, accumulating `parentWorld * node.mTransformation`
/// and emitting one part per mesh the node references.
private void walkNode(const(aiScene)* s, const(aiNode)* node,
                      const float[16] parentWorld,
                      const ImportedSurface[] surfaces,
                      ref ImportedScene scene) {
    const float[16] world = mul4(parentWorld, toMat16(node.mTransformation));

    foreach (mi; 0 .. node.mNumMeshes) {
        const uint meshIdx = node.mMeshes[mi];
        if (meshIdx >= s.mNumMeshes) continue;
        const(aiMesh)* mesh = s.mMeshes[meshIdx];
        if (mesh is null || mesh.mVertices is null || mesh.mNumVertices == 0)
            continue;

        ImportedPart part = partFromMesh(mesh, world, surfaces, node);
        if (part.vertices.length > 0 && part.faces.length > 0)
            scene.parts ~= part;
    }

    foreach (ci; 0 .. node.mNumChildren)
        walkNode(s, node.mChildren[ci], world, surfaces, scene);
}

/// Build one `ImportedPart` from a single aiMesh, applying the world transform
/// to every vertex (B2), then the positional weld (B5).
private ImportedPart partFromMesh(const(aiMesh)* mesh, const float[16] world,
                                  const ImportedSurface[] surfaces,
                                  const(aiNode)* node) {
    ImportedPart part;
    part.name = nodeOrMeshName(node, mesh);
    part.surfaces = surfaces.dup;

    // Vertices: bake the world transform (point, w=1).
    Vec3[] verts;
    verts.length = mesh.mNumVertices;
    foreach (vi; 0 .. mesh.mNumVertices) {
        const v = mesh.mVertices[vi];
        verts[vi] = transformPoint(world,
            Vec3(cast(float) v.x, cast(float) v.y, cast(float) v.z));
    }

    // Faces: keep arity (n-gon, A3); drop points / lines (< 3 indices).
    // Guard mFaces is null the way the vertex path guards mVertices: a
    // points-only / lines-only mesh can report mNumFaces but leave mFaces null.
    uint[][] faces;
    if (mesh.mFaces !is null)
    foreach (fi; 0 .. mesh.mNumFaces) {
        const aiFace f = mesh.mFaces[fi];
        if (f.mNumIndices < 3) continue;
        uint[] idx;
        idx.length = f.mNumIndices;
        foreach (k; 0 .. f.mNumIndices)
            idx[k] = f.mIndices[k];
        faces ~= idx;
    }

    // faceMaterial: every face shares this mesh's material index.
    uint[] faceMaterial;
    faceMaterial.length = faces.length;
    foreach (ref fm; faceMaterial)
        fm = mesh.mMaterialIndex;

    // B5 — positional weld: collapse coincident verts, remap face indices.
    weldPositional(verts, faces);

    part.vertices     = verts;
    part.faces        = faces;
    part.faceMaterial = faceMaterial;
    return part;
}

// ---------------------------------------------------------------------------
// positional weld (B5)
// ---------------------------------------------------------------------------

/// Collapse vertices whose positions match within `weldEpsilon` to a single
/// vertex, rewriting `faces` to reference the survivors. O(n) via a quantised
/// hash key (positions snapped to an epsilon grid). `verts` and `faces` are
/// replaced in place.
private void weldPositional(ref Vec3[] verts, ref uint[][] faces) {
    if (verts.length == 0) return;

    // Quantise to an integer grid one epsilon wide. Coincident verts (within
    // epsilon) land in the same cell key in the common case; the inverse-grid
    // hash trades the rare straddle-the-boundary miss for O(n) simplicity.
    enum float inv = 1.0f / weldEpsilon;
    struct Key { long x, y, z; }
    Key keyOf(Vec3 p) {
        import std.math : lround;
        return Key(lround(p.x * inv), lround(p.y * inv), lround(p.z * inv));
    }

    uint[] remap;                 // old index -> new (welded) index
    remap.length = verts.length;
    Vec3[] welded;
    uint[Key] seen;               // grid key -> welded index

    foreach (i, v; verts) {
        const k = keyOf(v);
        if (auto hit = k in seen) {
            remap[i] = *hit;
        } else {
            const ni = cast(uint) welded.length;
            welded ~= v;
            seen[k] = ni;
            remap[i] = ni;
        }
    }

    // Rewrite faces through the remap; collapse runs of the now-identical
    // index (a weld can fold two corners of one face together → drop the dup),
    // and drop faces that fall below 3 distinct corners.
    uint[][] out_;
    foreach (face; faces) {
        uint[] nf;
        foreach (idx; face) {
            const r = remap[idx];
            if (nf.length == 0 || nf[$ - 1] != r)
                nf ~= r;
        }
        // close the wrap-around (last == first)
        if (nf.length >= 2 && nf[0] == nf[$ - 1])
            nf = nf[0 .. $ - 1];
        if (nf.length >= 3)
            out_ ~= nf;
    }

    verts = welded;
    faces = out_;
}

// ---------------------------------------------------------------------------
// material readers (mirror D-Lwo2Writer/source/lwo2/assimp.d)
// ---------------------------------------------------------------------------

private string materialName(const(aiMaterial)* m, uint fallbackIndex) {
    aiString name;
    if (aiGetMaterialString(m, AI_MATKEY_NAME.key, AI_MATKEY_NAME.semantic,
                            AI_MATKEY_NAME.index, &name) == aiReturn.SUCCESS
        && name.length > 0)
        return cast(string) name.data[0 .. name.length].idup;
    return "Surface." ~ fallbackIndex.to!string;
}

private Vec3 materialDiffuse(const(aiMaterial)* m) {
    aiColor4D c;
    if (aiGetMaterialColor(m, AI_MATKEY_COLOR_DIFFUSE.key,
                           AI_MATKEY_COLOR_DIFFUSE.semantic,
                           AI_MATKEY_COLOR_DIFFUSE.index, &c) == aiReturn.SUCCESS)
        return Vec3(c.r, c.g, c.b);
    return Vec3(0.7f, 0.7f, 0.7f);
}

private string nodeOrMeshName(const(aiNode)* node, const(aiMesh)* mesh) {
    if (node !is null && node.mName.length > 0)
        return cast(string) node.mName.data[0 .. node.mName.length].idup;
    if (mesh !is null && mesh.mName.length > 0)
        return cast(string) mesh.mName.data[0 .. mesh.mName.length].idup;
    return "Mesh";
}

// ---------------------------------------------------------------------------
// 4x4 matrix helpers (column-major float[16], matching source/math.d)
// ---------------------------------------------------------------------------
// aiMatrix4x4 is ROW-major (a1..a4 = first row); source/math.d stores 4x4 as
// COLUMN-major float[16]. toMat16 transposes once on the way in, so mul4 /
// transformPoint can use the project's column-major convention throughout.

private float[16] identity4() {
    return [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
}

/// aiMatrix4x4 (row-major) -> column-major float[16].
private float[16] toMat16(const ref aiMatrix4x4 m) {
    return [
        cast(float) m.a1, cast(float) m.b1, cast(float) m.c1, cast(float) m.d1, // col 0
        cast(float) m.a2, cast(float) m.b2, cast(float) m.c2, cast(float) m.d2, // col 1
        cast(float) m.a3, cast(float) m.b3, cast(float) m.c3, cast(float) m.d3, // col 2
        cast(float) m.a4, cast(float) m.b4, cast(float) m.c4, cast(float) m.d4, // col 3
    ];
}

/// Column-major 4x4 multiply: returns a * b.
private float[16] mul4(const float[16] a, const float[16] b) {
    float[16] r;
    foreach (col; 0 .. 4)
        foreach (row; 0 .. 4) {
            float sum = 0;
            foreach (k; 0 .. 4)
                sum += a[k * 4 + row] * b[col * 4 + k];
            r[col * 4 + row] = sum;
        }
    return r;
}

/// Transform a point by a column-major 4x4 (w = 1; perspective divide skipped —
/// affine node transforms have d-row [0,0,0,1]).
private Vec3 transformPoint(const float[16] m, Vec3 p) {
    const float x = m[0]*p.x + m[4]*p.y + m[8] *p.z + m[12];
    const float y = m[1]*p.x + m[5]*p.y + m[9] *p.z + m[13];
    const float z = m[2]*p.x + m[6]*p.y + m[10]*p.z + m[14];
    return Vec3(x, y, z);
}
