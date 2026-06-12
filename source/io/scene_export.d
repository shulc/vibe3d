module io.scene_export;

// ---------------------------------------------------------------------------
// assimp export — editor Mesh -> OBJ / glTF (Phase 5).
// ---------------------------------------------------------------------------
// The mirror of `io.scene_import`: we build an in-memory `aiScene` from the
// flat editor Mesh and hand it to assimp's exporter (`aiExportScene`). The
// caller picks the target with a format id: "obj" (.obj), "gltf2" (.gltf),
// "glb2" (.glb). FBX write is DEFERRED (decision B4) — fragile in assimp and
// not worth the burn-in for v1.
//
// Handedness (decision B3, established in Phase 4): vibe3d is RIGHT-handed,
// +Y up, CCW-front — identical to assimp's internal space. So vertices are
// copied VERBATIM on export, with NO winding flip and NO handedness mirror.
// Our own export->import round-trip is the 1e-6 gate (tests/test_export_roundtrip.d).
//
// N-gons (decision A3): we set the POLYGON primitive bit and emit one aiFace
// per polygon at its native arity. The OBJ exporter writes n-gons faithfully
// (`f a b c d ...`); the glTF exporter triangulates internally (glTF only
// supports triangles), so glTF output loses face arity — that's glTF-inherent,
// not a vibe3d bug. OBJ round-trips arity exactly.
//
// Materials (decision A4 — interchange is lossy; fidelity lives in `.v3d`):
// we attach exactly ONE default material so the OBJ / glTF exporters are
// happy (both want at least one material the mesh can reference). We give it
// a NAME (cheap via aiGetMaterialString's writer counterpart, the property
// blob), but per-surface color / per-face material assignment is NOT exported
// here — that round-trips only through the native `.v3d` format. Building a
// fully-populated aiMaterial through the C-only binding means hand-laying a
// typed property blob; we deliberately set just the name and stop.
//
// GC-liveness of the built aiScene: we allocate every array and struct the
// aiScene points into with the D GC and keep them referenced in LOCALS that
// stay in scope across the (synchronous) `aiExportScene` call. D's GC is
// non-moving, assimp does not retain any pointer past the call, and we built
// the scene ourselves so we must NOT call aiReleaseImport / aiFreeScene on it.
// Once `exportViaAssimp` returns, the locals go out of scope and the GC is
// free to reclaim everything.

import std.stdio  : stderr;
import std.string : toStringz, fromStringz;
import std.array  : appender;

import bindbc.assimp;

import mesh : Mesh;
import math : Vec3;
import io.assimp_runtime : isAssimpAvailable;

/// Export `mesh` to `path` using assimp's exporter for `formatId`.
///
/// `formatId` is an assimp export-format id, NOT an extension — the caller
/// maps `.obj`->"obj", `.gltf`->"gltf2", `.glb`->"glb2" (see the mapping in
/// commands/file/save.d). Returns false (logging to stderr) when assimp is
/// unavailable, the format id is not supported by the loaded library, or the
/// export itself fails.
bool exportViaAssimp(ref const Mesh mesh, string path, string formatId) {
    if (!isAssimpAvailable()) {
        try stderr.writeln("[io] assimp not loaded — cannot export ", path);
        catch (Exception) {}
        return false;
    }

    if (!isExportFormatSupported(formatId)) {
        logSupportedFormats(formatId);
        return false;
    }

    // --- build the aiScene from GC-allocated, locally-rooted storage ---
    // Every array / struct below is held in a local that outlives the
    // aiExportScene call (see module header on GC-liveness).
    SceneStorage st = buildScene(mesh, unitScaleFor(formatId));

    const aiReturn rc = aiExportScene(
        st.scene, formatId.toStringz, path.toStringz, 0u);

    // `st` (and everything it roots) stays alive until here — past the
    // synchronous export call.
    if (rc != aiReturn.SUCCESS) {
        try stderr.writefln("[io] assimp export failed (%s -> %s): %s",
                            formatId, path, aiGetErrorString().fromStringz);
        catch (Exception) {}
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// export-format-id validation against the LIVE library
// ---------------------------------------------------------------------------

/// True if the loaded libassimp advertises `formatId` as an export format.
/// Queried live (not hardcoded) so a stripped-down bundled build that omits an
/// exporter is detected rather than silently producing a failed export.
private bool isExportFormatSupported(string formatId) {
    const size_t n = aiGetExportFormatCount();
    foreach (i; 0 .. n) {
        const(aiExportFormatDesc)* d = aiGetExportFormatDescription(i);
        if (d is null || d.id is null) continue;
        if (d.id.fromStringz == formatId) return true;
    }
    return false;
}

private void logSupportedFormats(string requested) {
    try {
        auto buf = appender!string;
        const size_t n = aiGetExportFormatCount();
        foreach (i; 0 .. n) {
            const(aiExportFormatDesc)* d = aiGetExportFormatDescription(i);
            if (d is null || d.id is null) continue;
            if (i > 0) buf.put(", ");
            buf.put(d.id.fromStringz);
        }
        stderr.writefln(
            "[io] export format id '%s' not supported by this libassimp; "
            ~ "available: %s", requested, buf.data);
    } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// unit normalization (FBX is centimetre-based; OBJ/glTF are unit=1)
// ---------------------------------------------------------------------------

/// Geometry scale to apply to exported vertex positions for `formatId`.
///
/// FBX convention: an FBX file carries a `UnitScaleFactor` in its global
/// metadata, and the de-facto unit for FBX produced by every major DCC
/// (Blender / Maya / Unreal) is the CENTIMETRE. assimp's FBX *exporter*
/// likewise writes into a centimetre unit context but does NOT rescale the
/// geometry we hand it — it copies our metre-space vertices verbatim into a
/// file that *declares* centimetres. So a 1 m cube (±0.5) would land as a file
/// claiming a ±0.5 cm model: ANY cm-honouring reader (Blender/Maya/Unreal) sees
/// a 1 cm cube, and our own importer — which runs aiProcess_GlobalScale and
/// honours the declared cm unit — shrinks it ×0.01 back to ±0.005 (the observed
/// ×100 round-trip discrepancy).
///
/// The conventional, correct fix every DCC uses: scale geometry metres→cm (×100)
/// on FBX export, so the WRITTEN values match the cm unit the file declares.
/// Then external cm-readers get the right real-world size, and our import
/// (×0.01 via GlobalScale) round-trips exactly (×100 export · ×0.01 import = 1).
/// This is unit normalization, not a geometry hack, and is localized to the FBX
/// export path only — OBJ/glTF declare unit=1 and already round-trip exact, so
/// they get ×1.
///
/// NOTE (long-term): the cleaner fix is to have assimp *declare metres* via an
/// export property (Exporter::SetPropertyFloat AI_CONFIG_GLOBAL_SCALE / a
/// hypothetical `aiExportSceneWithProperties`), so no geometry rescale is
/// needed. The bindbc-assimp6 C binding exposes no export-property API today
/// (only aiExportScene), so the ×100 cm normalization here is the correct
/// behaviour until that binding/upstream work lands.
private double unitScaleFor(string formatId) {
    return (formatId == "fbx" || formatId == "fbxa") ? 100.0 : 1.0;
}

// ---------------------------------------------------------------------------
// aiScene construction
// ---------------------------------------------------------------------------

/// Owns every heap allocation the built aiScene points into. Keeping ONE of
/// these in a local across `aiExportScene` keeps the whole graph reachable.
///
/// The aggregates assimp dereferences by address (scene/mesh/root/material/
/// nameProp) are HEAP-allocated via `new`, so their addresses are stable across
/// a by-value return/assignment of this POD struct. Storing `&st.someValueField`
/// here would be a latent freed-stack read: `SceneStorage` has no postblit, so a
/// return move is a raw byte blit that does NOT fix up interior self-pointers.
/// The remaining GC-slice fields already point to GC heap and survive a move.
private struct SceneStorage {
    aiScene*    scene;           // new aiScene
    aiMesh*     mesh;            // new aiMesh
    aiMesh*[]   meshPtrs;        // scene.mMeshes
    aiVector3D[] verts;          // mesh.mVertices
    aiFace[]    faces;           // mesh.mFaces
    uint[][]    faceIndices;     // each aiFace.mIndices backing store
    aiNode*     root;            // new aiNode
    uint[]      rootMeshes;      // root.mMeshes (just [0])
    aiMaterial* material;        // new aiMaterial
    aiMaterial*[] materialPtrs;  // scene.mMaterials
    aiMaterialProperty*  nameProp;       // new aiMaterialProperty ($mat.name)
    aiMaterialProperty*[] matPropPtrs;   // material.mProperties
    char[]      namePropData;    // the aiString blob the name property points at
}

/// Build a single-mesh aiScene mirroring `mesh`. All storage lives in the
/// returned `SceneStorage`; the embedded `aiScene` references into it.
///
/// `unitScale` rescales the exported vertex positions for the target format's
/// unit convention (see `unitScaleFor`): 100.0 for FBX (metres→centimetres),
/// 1.0 for OBJ/glTF.
private SceneStorage buildScene(ref const Mesh mesh, double unitScale) {
    SceneStorage st;

    // Heap-allocate every aggregate assimp dereferences by address, so the
    // pointers we wire below stay valid across a by-value return of `st`.
    st.scene    = new aiScene;
    st.mesh     = new aiMesh;
    st.root     = new aiNode;
    st.material = new aiMaterial;
    st.nameProp = new aiMaterialProperty;

    // --- vertices: verbatim copy, no flip (B3), scaled to the format unit ---
    // unitScale is 1.0 for OBJ/glTF (unit=1) and 100.0 for FBX (metres→cm) so
    // the written values match the cm unit the FBX file declares.
    const float s = cast(float) unitScale;
    st.verts.length = mesh.vertices.length;
    foreach (i, v; mesh.vertices)
        st.verts[i] = aiVector3D(v.x * s, v.y * s, v.z * s);

    // --- faces: one aiFace per polygon, native arity (A3) ---
    // Drop degenerate faces (<3 verts) — mirrors the importer/native policy and
    // keeps the prim-type shift `1u << (len-1)` from underflowing on len==0.
    uint primTypes = 0;
    auto faces       = appender!(aiFace[]);
    auto faceIndices = appender!(uint[][]);
    foreach (face; mesh.faces.range) {
        if (face.length < 3) continue;     // skip degenerate face; emit nothing
        uint[] idx;
        idx.length = face.length;
        foreach (k, vi; face)
            idx[k] = vi;
        faceIndices.put(idx);              // keep the backing store rooted
        aiFace af;
        af.mNumIndices = cast(uint) idx.length;
        af.mIndices    = idx.ptr;
        faces.put(af);
        primTypes |= (idx.length > 3)
            ? aiPrimitiveType.POLYGON
            : cast(uint)(1u << (idx.length - 1));  // 3 verts -> TRIANGLE
    }
    st.faces       = faces.data;
    st.faceIndices = faceIndices.data;
    // Always advertise POLYGON so exporters accept >3-vert faces even if the
    // current mesh happens to be all-triangle.
    primTypes |= aiPrimitiveType.POLYGON;

    // --- the single aiMesh ---
    st.mesh.mPrimitiveTypes = primTypes;
    st.mesh.mNumVertices    = cast(uint) st.verts.length;
    st.mesh.mVertices       = st.verts.ptr;
    st.mesh.mNumFaces       = cast(uint) st.faces.length;
    st.mesh.mFaces          = st.faces.ptr;
    st.mesh.mMaterialIndex  = 0;
    setAiString(st.mesh.mName, "Mesh");

    st.meshPtrs = [ st.mesh ];

    // --- the single default material (name only; color/per-face DEFERRED A4) ---
    buildDefaultMaterial(st);

    // --- root node referencing mesh 0 ---
    st.rootMeshes = [ 0u ];
    aiIdentityMatrix4(&st.root.mTransformation);
    st.root.mNumMeshes = 1;
    st.root.mMeshes    = st.rootMeshes.ptr;
    setAiString(st.root.mName, "Root");

    // --- scene ---
    st.scene.mFlags        = 0;
    st.scene.mRootNode     = st.root;
    st.scene.mNumMeshes    = 1;
    st.scene.mMeshes       = st.meshPtrs.ptr;
    st.scene.mNumMaterials = cast(uint) st.materialPtrs.length;
    st.scene.mMaterials    = st.materialPtrs.ptr;
    setAiString(st.scene.mName, "vibe3d");

    return st;
}

/// Lay down a minimal aiMaterial carrying just AI_MATKEY_NAME. A material with
/// zero properties trips the OBJ/glTF exporters (they read the name to label
/// the surface), so we hand-build the one $mat.name property blob — an aiString
/// (uint32 length + char[length]) — and leave it at that (A4: color deferred).
private void buildDefaultMaterial(ref SceneStorage st) {
    enum string matName = "DefaultMaterial";

    // aiString wire layout assimp's reader expects in a property blob (see
    // MaterialSystem.cpp aiGetMaterialString, which asserts
    //   pOut->length + 1 + 4 == prop->mDataLength):
    //   uint32 length  ||  char[length]  ||  '\0'   (NUL counted in mDataLength,
    //   NOT in `length`). So mDataLength = 4 + length + 1.
    st.namePropData.length = uint.sizeof + matName.length + 1;
    *(cast(uint*) st.namePropData.ptr) = cast(uint) matName.length;
    st.namePropData[uint.sizeof .. uint.sizeof + matName.length]
        = cast(const(char)[]) matName;
    st.namePropData[$ - 1] = '\0';

    setAiString(st.nameProp.mKey, "?mat.name");   // AI_MATKEY_NAME key
    st.nameProp.mSemantic   = 0;
    st.nameProp.mIndex      = 0;
    st.nameProp.mDataLength = cast(uint) st.namePropData.length;
    st.nameProp.mType       = aiPropertyTypeInfo.String;
    st.nameProp.mData       = st.namePropData.ptr;

    st.matPropPtrs = [ st.nameProp ];

    st.material.mProperties   = st.matPropPtrs.ptr;
    st.material.mNumProperties = 1;
    st.material.mNumAllocated  = 1;

    st.materialPtrs = [ st.material ];
}

/// Copy a D string into an aiString (fixed-capacity, length-prefixed). Truncates
/// to AI_MAXLEN-1 (our names are short literals, so truncation never fires).
private void setAiString(ref aiString s, string v) {
    import std.algorithm : min;
    const n = min(v.length, AI_MAXLEN - 1);
    s.length = cast(uint) n;
    s.data[0 .. n] = v[0 .. n];
    s.data[n] = '\0';
}
