module io.scene_ir;

// ---------------------------------------------------------------------------
// Scene-IR seam — the proto-layer model for interchange IMPORT.
// ---------------------------------------------------------------------------
// Foreign formats are parsed into an `ImportedScene` (a list of parts, each a
// self-contained chunk of geometry with part-local face indices, subpatch
// flags, material indices and surfaces). `flattenToMesh` is the v1 adapter
// that merges every part into ONE vibe3d Mesh — the single piece that gets
// swapped for `toLayers` the day layers land.
//
// The native `.v3d` path deliberately bypasses this seam (it has nothing to
// normalize or lose); only the lossy interchange bridges (our LWO reader, and
// assimp in Phase 4) build an `ImportedScene`.

import mesh;
import math;
import document : Document, Layer;

/// A material as recovered from an interchange file, before mapping onto the
/// vibe3d `Surface`. Defaults mirror `mesh.Surface`'s defaults.
struct ImportedSurface {
    string name        = "Default";
    Vec3   baseColor   = Vec3(0.7f, 0.7f, 0.7f);
    float  diffuse     = 1.0f;
    float  specular    = 0.0f;
    float  glossiness  = 0.4f;
    float  opacity     = 1.0f;
}

/// One self-contained chunk of imported geometry. Face indices are LOCAL to
/// this part (`faces[k][j]` indexes `vertices`); `faceMaterial` indexes
/// `surfaces`. `faceSubpatch` / `faceMaterial` may be empty (⇒ all-FACE /
/// all-0 respectively — the lazy-resize convention the mesh already uses).
struct ImportedPart {
    Vec3[]            vertices;     // already in vibe3d space, world transform baked
    uint[][]          faces;        // n-gon, indices local to this part
    bool[]            faceSubpatch; // LWO PTCH; empty => all FACE
    uint[]            faceMaterial; // index into surfaces; empty => all 0
    ImportedSurface[] surfaces;
    string            name;
}

/// The proto-layer model: a list of parts. When layers land this becomes the
/// layer list and `flattenToMesh` is replaced by `toLayers`.
struct ImportedScene {
    ImportedPart[] parts;
}

/// Map an `ImportedSurface` onto a vibe3d `Surface` (field-by-field).
private Surface toSurface(const ref ImportedSurface s) {
    Surface o;
    o.name           = s.name;
    o.baseColor      = s.baseColor;
    o.diffuseAmount  = s.diffuse;
    o.specularAmount = s.specular;
    o.glossiness     = s.glossiness;
    o.opacity        = s.opacity;
    return o;
}

/// v1 adapter: merge every part of `scene` into a single Mesh.
///
/// Surfaces are deduped by name in first-seen order (an assimp scene with
/// per-part materials therefore collapses identical surfaces; our LWO reader
/// puts the same global surface table on every part, which collapses back to
/// one copy here). Vertices are concatenated with a running offset added to
/// every face index; subpatch + material flags carry over with a global face
/// counter keeping them aligned. An empty scene returns `Mesh.init`.
Mesh flattenToMesh(const ref ImportedScene scene) {
    // --- merge surfaces: dedup by name, first-seen order ---
    Surface[]   mergedSurfaces;
    size_t[string] nameToIndex;

    // Per-part: localSurfIdx -> mergedIdx remap.
    uint[][] surfRemap;
    surfRemap.length = scene.parts.length;
    foreach (pi, ref part; scene.parts) {
        uint[] remap;
        remap.length = part.surfaces.length;
        foreach (si, ref isurf; part.surfaces) {
            // Dedup is by NAME only: two genuinely-distinct materials that happen
            // to share a name intentionally collapse to the first-seen one. That
            // is an accepted loss for this lossy interchange seam (matches LWO's
            // TAG-name model), NOT a bug to "fix" by keying on color/params.
            if (auto idx = isurf.name in nameToIndex) {
                remap[si] = cast(uint) *idx;
            } else {
                const newIdx = cast(uint) mergedSurfaces.length;
                mergedSurfaces ~= toSurface(isurf);
                nameToIndex[isurf.name] = newIdx;
                remap[si] = newIdx;
            }
        }
        surfRemap[pi] = remap;
    }

    // --- concatenate geometry, offsetting face indices per part ---
    Vec3[]   allVerts;
    uint[][] allFaces;
    bool[]   allSubpatch;   // parallel to allFaces
    uint[]   allMaterial;   // parallel to allFaces (already remapped to merged surfaces)

    uint vertexOffset = 0;
    foreach (pi, ref part; scene.parts) {
        const remap = surfRemap[pi];
        foreach (localFace, face; part.faces) {
            // Validate before appending so allFaces / allSubpatch / allMaterial
            // stay parallel. The LWO reader already validates upstream, but this
            // generic seam also serves assimp (Phase 4), whose parts are not
            // pre-checked. Skip policy intentionally mirrors importLWO/native's
            // "drop < 3-vert faces"; we extend it to out-of-range indices here.
            if (face.length < 3) continue;                 // drop degenerate
            bool bad = false;
            foreach (idx; face)
                if (idx >= part.vertices.length) { bad = true; break; }
            if (bad) continue;                             // skip out-of-range face

            uint[] offset;
            offset.length = face.length;
            foreach (k, idx; face)
                offset[k] = idx + vertexOffset;
            allFaces ~= offset;

            // Subpatch flag (empty => false).
            allSubpatch ~= (localFace < part.faceSubpatch.length)
                ? part.faceSubpatch[localFace] : false;

            // Material: part-local index, remapped to the merged table.
            // Empty faceMaterial defaults to local 0 (lazy-resize convention).
            const localMat = (localFace < part.faceMaterial.length)
                ? part.faceMaterial[localFace] : 0u;
            const mergedMat = (localMat < remap.length) ? remap[localMat] : 0u;
            allMaterial ~= mergedMat;
        }
        allVerts ~= part.vertices;
        vertexOffset += cast(uint) part.vertices.length;
    }

    // Empty scene (no parts / no geometry) => fresh empty mesh.
    if (allVerts.length == 0)
        return Mesh.init;

    // --- commit: rebuild the mesh on a fresh struct (mirrors importLWO) ---
    Mesh m = Mesh.init;
    m.vertices = allVerts;
    uint[ulong] edgeLookup;
    foreach (face; allFaces)
        m.addFaceFast(edgeLookup, face);
    m.buildLoops();

    // Apply per-face subpatch flags (parallel to faces). After resizeSubpatch
    // the subpatch storage is sized to m.faces.length == allSubpatch.length, and
    // setFaceSubpatch is internally bounds-guarded. Never read the allocating
    // `isSubpatch` @property in a loop (O(n²)/GC — the known subpatch hazard).
    m.resizeSubpatch();
    foreach (fi, flag; allSubpatch)
        m.setFaceSubpatch(fi, flag);

    // Surfaces + per-face material. Grow faceMaterial to one entry per face;
    // entries beyond what we accumulated default to 0.
    m.surfaces = mergedSurfaces;
    m.faceMaterial.length = m.faces.length;
    foreach (fi; 0 .. m.faces.length)
        m.faceMaterial[fi] = (fi < allMaterial.length) ? allMaterial[fi] : 0u;

    return m;
}

// ---------------------------------------------------------------------------
// toLayers — the layered (non-flattening) adapter (layers Stage 3)
// ---------------------------------------------------------------------------

/// Build ONE Mesh from a SINGLE imported part. This is the per-part body of
/// `flattenToMesh` with the cross-part concatenation removed: no vertex offset
/// (face indices are already part-local), and surfaces are kept part-local
/// (deduped by name WITHIN the part, first-seen order — mirrors flattenToMesh's
/// dedup but scoped to one part). Validation (drop <3-vert / out-of-range
/// faces) and the subpatch / material carry-over match flattenToMesh exactly,
/// so a single-part scene routed through `toLayers` yields the SAME mesh that
/// `flattenToMesh` would have produced.
private Mesh partToMesh(const ref ImportedPart part) {
    // --- per-part surface dedup by name, first-seen order ---
    Surface[]       surfaces;
    size_t[string]  nameToIndex;
    uint[]          remap;
    remap.length = part.surfaces.length;
    foreach (si, ref isurf; part.surfaces) {
        if (auto idx = isurf.name in nameToIndex) {
            remap[si] = cast(uint) *idx;
        } else {
            const newIdx = cast(uint) surfaces.length;
            surfaces ~= toSurface(isurf);
            nameToIndex[isurf.name] = newIdx;
            remap[si] = newIdx;
        }
    }

    // --- collect valid faces (no vertex offset — indices are part-local) ---
    uint[][] faces;
    bool[]   subpatch;   // parallel to faces
    uint[]   material;   // parallel to faces (remapped to part-local surfaces)
    foreach (localFace, face; part.faces) {
        if (face.length < 3) continue;                 // drop degenerate
        bool bad = false;
        foreach (idx; face)
            if (idx >= part.vertices.length) { bad = true; break; }
        if (bad) continue;                             // skip out-of-range face

        faces ~= face.dup;

        subpatch ~= (localFace < part.faceSubpatch.length)
            ? part.faceSubpatch[localFace] : false;

        const localMat = (localFace < part.faceMaterial.length)
            ? part.faceMaterial[localFace] : 0u;
        material ~= (localMat < remap.length) ? remap[localMat] : 0u;
    }

    // Empty part => fresh empty mesh (mirrors flattenToMesh's empty-scene path).
    if (part.vertices.length == 0)
        return Mesh.init;

    Mesh m = Mesh.init;
    m.vertices = part.vertices.dup;
    uint[ulong] edgeLookup;
    foreach (face; faces)
        m.addFaceFast(edgeLookup, face);
    m.buildLoops();

    // Subpatch flags (never read the allocating `isSubpatch` @property in a loop).
    m.resizeSubpatch();
    foreach (fi, flag; subpatch)
        m.setFaceSubpatch(fi, flag);

    // Surfaces + per-face material.
    m.surfaces = surfaces;
    m.faceMaterial.length = m.faces.length;
    foreach (fi; 0 .. m.faces.length)
        m.faceMaterial[fi] = (fi < material.length) ? material[fi] : 0u;

    return m;
}

/// The layered adapter: one Layer per part — the replacement for
/// `flattenToMesh` "the day layers land". Each part keeps its own geometry,
/// surfaces and subpatch flags (no cross-part merge, no flattening). The part's
/// `name` becomes the layer name (empty ⇒ "Layer N"). The first part is the
/// ACTIVE foreground layer; every other part is `visible = true,
/// background = true` reference geometry, so the edit target is unambiguous and
/// the rest is immediately listed (drawn in a later stage).
///
/// `flattenToMesh` REMAINS for flat consumers (single-part fast path + flat
/// exporters via `flattenDocument`); this is the lossless import path.
///
/// An empty scene (no parts) returns a one-layer bootstrap document wrapping an
/// empty mesh, so the `layers.length >= 1` invariant always holds.
Document toLayers(const ref ImportedScene scene) {
    import std.conv : to;

    if (scene.parts.length == 0)
        return Document.bootstrap(Mesh.init);

    Layer[] layers;
    layers.length = scene.parts.length;
    foreach (pi, ref part; scene.parts) {
        auto l = new Layer;
        l.mesh       = partToMesh(part);
        l.name       = part.name.length ? part.name
                                        : "Layer " ~ to!string(pi + 1);
        l.visible    = true;
        l.background = (pi != 0);   // first part active/foreground; rest background
        layers[pi] = l;
    }

    Document d;
    d.layers      = layers;
    d.activeIndex = 0;
    return d;
}

// ---------------------------------------------------------------------------
// flattenDocument — merge VISIBLE layers for flat (interchange) export
// ---------------------------------------------------------------------------

/// Concatenate every VISIBLE layer's mesh into one flat Mesh for the
/// single-mesh interchange exporters (OBJ / glTF / FBX / LWO). The inverse seam
/// of `toLayers`: surfaces are deduped by name across visible layers (first-seen
/// order, same policy as `flattenToMesh`), vertices concatenated with a running
/// offset, subpatch + material carried over. Hidden layers are skipped.
///
/// A single-layer (visible) document flattens to a byte-identical copy of that
/// layer's mesh, so single-layer export is unchanged from pre-Stage-3 behavior.
Mesh flattenDocument(const ref Document doc) {
    // --- merge surfaces across visible layers: dedup by name, first-seen ---
    Surface[]      mergedSurfaces;
    size_t[string] nameToIndex;

    Vec3[]   allVerts;
    uint[][] allFaces;
    bool[]   allSubpatch;
    uint[]   allMaterial;

    uint vertexOffset = 0;
    foreach (l; doc.layers) {
        if (!l.visible) continue;
        const ref Mesh src = l.mesh;

        // Per-layer surface remap into the merged table.
        uint[] remap;
        remap.length = src.surfaces.length;
        foreach (si, ref s; src.surfaces) {
            if (auto idx = s.name in nameToIndex) {
                remap[si] = cast(uint) *idx;
            } else {
                const newIdx = cast(uint) mergedSurfaces.length;
                Surface cp = s;                       // value copy of the const Surface
                mergedSurfaces ~= cp;
                nameToIndex[s.name] = newIdx;
                remap[si] = newIdx;
            }
        }

        foreach (fi; 0 .. src.faces.length) {
            auto face = src.faces[fi];
            if (face.length < 3) continue;            // drop degenerate
            uint[] offset;
            offset.length = face.length;
            foreach (k, idx; face)
                offset[k] = idx + vertexOffset;
            allFaces ~= offset;

            allSubpatch ~= src.isFaceSubpatch(fi);

            const localMat = (fi < src.faceMaterial.length) ? src.faceMaterial[fi] : 0u;
            allMaterial ~= (localMat < remap.length) ? remap[localMat] : 0u;
        }
        allVerts ~= src.vertices.dup;
        vertexOffset += cast(uint) src.vertices.length;
    }

    if (allVerts.length == 0)
        return Mesh.init;

    Mesh m = Mesh.init;
    m.vertices = allVerts;
    uint[ulong] edgeLookup;
    foreach (face; allFaces)
        m.addFaceFast(edgeLookup, face);
    m.buildLoops();

    m.resizeSubpatch();
    foreach (fi, flag; allSubpatch)
        m.setFaceSubpatch(fi, flag);

    m.surfaces = mergedSurfaces;
    m.faceMaterial.length = m.faces.length;
    foreach (fi; 0 .. m.faces.length)
        m.faceMaterial[fi] = (fi < allMaterial.length) ? allMaterial[fi] : 0u;

    return m;
}
