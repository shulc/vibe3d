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

/// One imported morph channel, SPARSE and point-domain (task 1069).
/// `verts` are indices into the part's own `vertices`; `values` carries three
/// floats per listed vertex. `absolute` selects the kind — the two are
/// different data models (a delta vs a position) and the wire format's tag is
/// the only thing that says which, so it is carried, never guessed.
struct PartMorph {
    string  name;
    bool    absolute;
    uint[]  verts;
    float[] values;    // length == verts.length * 3
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
    // Per-CORNER UV stream (the discontinuous `"uv"` PolyVertex map source).
    // Flat, parallel to the corners of `faces` in face-then-corner order, dim 2:
    // length == Σ faces[k].length * 2; corner `c` of face `k` is at
    // `(Σ faces[0..k].length + c) * 2 .. + 2`. EMPTY ⇒ no UV (the importer found
    // none) — the same empty-means-default convention as `faceSubpatch` /
    // `faceMaterial`. The assemblers carry this through the SAME skip-aware face
    // drop they apply to `faces`, so when a face is dropped its UV corners drop
    // too and the stream stays aligned with the emitted faces. After
    // `buildLoops`, it seeds the `"uv"` map via `faceCornerLoop`.
    float[]           uv;
    // Per-VERTEX morph channels (task 1069), sparse. Point-domain, so unlike
    // `uv` there is no corner bookkeeping — but the indices are into
    // `vertices`, so anything that RENUMBERS vertices must carry them. The
    // positional weld in `scene_import.d` is exactly such a step and does
    // carry them; see `weldPositional`.
    PartMorph[]       morphs;
    // Layer visibility, carried from the source format's hidden flag (Stage 5).
    // Additive default TRUE so every existing importer (and `flattenToMesh` /
    // `partToMesh`, which never read it) is unchanged: only the formats that
    // actually decode a hidden bit set this false (LWO `LAYR` flags bit 0; glTF
    // node `ml_visible` metadata). OBJ has no visibility channel ⇒ stays true.
    bool              visible = true;
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

/// Seed the `"uv"` PolyVertex map of `m` from a flat per-corner UV stream that is
/// already in faces-as-built corner order (the CSR loop order `buildLoops` laid
/// down). Called by every importer assembler AFTER `buildLoops`. A no-op when the
/// scene carried no UV (`hasUv == false`) so a UV-less import never grows a map.
/// The stream length is expected to be `loops.length * 2`; a defensive mismatch
/// (e.g. an upstream bug) drops the map rather than misaligning corners.
private void populateUvMap(ref Mesh m, const float[] uv, bool hasUv) {
    if (!hasUv) return;
    const size_t want = m.loops.length * 2;
    if (uv.length != want) return;                 // defensive: refuse a misaligned stream
    auto map = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    if (map is null) return;                        // name clash / empty mesh — leave UV-less
    map.data[] = uv[];                              // corner order == loop order, 1:1
}

/// Seed a mesh's morph maps from a part's sparse per-vertex morph channels
/// (task 1069). Called by every importer assembler after the vertices exist.
///
/// UNTRUSTED INDICES. These come out of a foreign file and address a dense
/// array directly, so every one is range-checked here and an out-of-range
/// entry is SKIPPED with a warning — never clamped (which would silently
/// relocate a morph onto the wrong vertex) and never fatal (which would make
/// one bad byte cost the whole import).
private void populateMorphMaps(ref Mesh m, const PartMorph[] morphs,
                               size_t vertexOffset = 0) {
    import mesh : MapKind;
    import log  : logWarn;
    foreach (ref pm; morphs) {
        if (pm.name.length == 0) continue;
        if (pm.values.length != pm.verts.length * 3) {
            try logWarn("io", "morph '" ~ pm.name
                            ~ "': values/verts length mismatch, skipped");
            catch (Exception) {}
            continue;
        }
        const kind = pm.absolute ? MapKind.morphAbsolute : MapKind.morphRelative;
        auto map = m.meshMap(pm.name);
        if (map is null) map = m.addMeshMapOfKind(kind, pm.name);
        if (map is null) continue;              // name clash with a non-morph map
        size_t skipped = 0;
        foreach (k, v; pm.verts) {
            const size_t vi = cast(size_t) v + vertexOffset;
            if (vi >= m.vertices.length) { ++skipped; continue; }
            if (!map.setEntry(vi, Vec3(pm.values[k * 3], pm.values[k * 3 + 1],
                                       pm.values[k * 3 + 2])))
                ++skipped;
        }
        if (skipped > 0) {
            try logWarn("io", "morph '" ~ pm.name ~ "': skipped out-of-range entries");
            catch (Exception) {}
        }
    }
}

/// A part's morph channel plus the vertex offset it acquires when parts are
/// merged into one mesh (task 1069).
private struct MergedMorph {
    PartMorph morph;
    uint      offset;
}

/// v1 adapter: merge every part of `scene` into a single Mesh.
///
/// Surfaces are deduped by name in first-seen order (an assimp scene with
/// per-part materials therefore collapses identical surfaces; our LWO reader
/// puts the same global surface table on every part, which collapses back to
/// one copy here). Vertices are concatenated with a running offset added to
/// every face index; subpatch + material flags carry over with a global face
/// counter keeping them aligned. An empty scene returns `Mesh.init`.
///
/// Corner-provenance (task 0901): verified NOT APPLICABLE. This function (and
/// `flattenDocument` / the per-part `Mesh` builders below) always starts from
/// a fresh `Mesh m = Mesh.init` and returns it BY VALUE — there is no
/// existing document mesh for a face rewrite to lose a map from. A "uv"
/// PolyVertex map may get SEEDED here from the imported per-corner data
/// (`faceCornerLoop`, after `buildLoops`), but that is populating a brand-new
/// map on a brand-new mesh, not carrying one forward across a rewrite — the
/// corner-provenance obligation has nothing to apply to. Every caller that
/// lands this into a document mesh does a whole-mesh replace (`*mesh =
/// flattenToMesh(...)` / `commands/scene/load_mesh.d`'s equivalent), same
/// shape as `commands/mesh/subdivide.d`.
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
    // Per-corner UV stream parallel to the SURVIVING corners of allFaces (dim 2),
    // accumulated through the SAME face-drop logic so it stays index-aligned. A
    // scene with no UV anywhere leaves this empty (no `"uv"` map is created).
    float[]  allUv;
    // Pre-scan (task 0678 D1): anyUv must be known BEFORE the first part is
    // walked. Discovering it mid-loop meant a leading UV-less part emitted no
    // zero-fill corners, leaving `allUv` short of the corner count — and
    // populateUvMap's length check then silently dropped the WHOLE map (the
    // zero-fill promised by the comment below never ran for those corners).
    // Mirrors partToMesh, which computes its partHasUv up front.
    bool anyUv = false;
    foreach (ref part; scene.parts)
        if (part.uv.length > 0) { anyUv = true; break; }

    uint vertexOffset = 0;
    MergedMorph[] mergedMorphs;   // task 1069
    foreach (pi, ref part; scene.parts) {
        const remap = surfRemap[pi];
        const bool partHasUv = part.uv.length > 0;
        // Running corner base into THIS part's uv stream (face-then-corner order),
        // advanced for EVERY local face (including dropped ones) so the slice for
        // a surviving face is read at the right offset.
        size_t cornerBase = 0;
        foreach (localFace, face; part.faces) {
            const size_t faceBase = cornerBase;
            cornerBase += face.length;                     // advance regardless of drop

            // Validate before appending so allFaces / allSubpatch / allMaterial /
            // allUv stay parallel. The LWO reader already validates upstream, but
            // this generic seam also serves assimp (Phase 4), whose parts are not
            // pre-checked. We extend it to out-of-range indices here.
            //
            // WHOSE THRESHOLD IS THIS (task 1290). Not the kernel's: the kernel
            // holds faces down to TWO corners, and the native `.v3d` reader was
            // lowered to two (task 1200) precisely so the lossless format
            // round-trips everything the kernel can represent. The line above
            // used to claim it "mirrors importLWO/native" — it no longer does,
            // and saying so was how three places came to pick a number
            // independently and disagree. THREE is deliberate HERE and at the
            // two sites below: interchange NORMALISES foreign data, and a
            // 1- or 2-index polygon in OBJ / glTF / FBX / LWO2 is a point or a
            // line primitive, not a face. Raising the kernel's floor to match,
            // or lowering this to two, are both real behaviour changes and
            // neither has been measured against real files.
            //
            // The drop is CLEAN, and that is the part that had to be checked
            // rather than assumed: every parallel per-face channel (subpatch,
            // material, per-corner UV) is appended INSIDE the surviving branch
            // below, and the UV corner cursor advances before the test — so a
            // dropped face shifts nothing after it. `io/native.d` had exactly
            // that shift and every face after a dropped one wore its
            // neighbour's attributes (fixed in task 1200).
            if (face.length < 3) continue;                 // drop degenerate (UV corners drop too)
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

            // UV corners for this surviving face. If THIS part has a UV stream,
            // copy its slice (guarded against a short stream); if it has none,
            // zero-fill so a multi-part scene where only some parts carry UV still
            // yields one aligned stream. Skipped entirely when no part has UV.
            if (anyUv) {
                foreach (k; 0 .. face.length) {
                    const size_t src = (faceBase + k) * 2;
                    if (partHasUv && src + 2 <= part.uv.length)
                        allUv ~= part.uv[src .. src + 2];
                    else
                        allUv ~= [0.0f, 0.0f];
                }
            }
        }
        // Task 1069 — remember each part's morph channels with the vertex
        // offset they must be shifted by in the merged mesh.
        foreach (ref pm; part.morphs)
            mergedMorphs ~= MergedMorph(
                PartMorph(pm.name, pm.absolute, pm.verts.dup, pm.values.dup),
                vertexOffset);
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

    // Per-corner UV → the `"uv"` PolyVertex map. `allUv` is in faces-as-emitted
    // corner order (face-then-corner), which is exactly the CSR loop order
    // `buildLoops` just laid down, so `faceCornerLoop(fi, c)` indexes it 1:1.
    populateUvMap(m, allUv, anyUv);

    // Sparse per-vertex morph channels, shifted into the merged index space.
    foreach (ref mm; mergedMorphs) populateMorphMaps(m, [mm.morph], mm.offset);

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
    float[]  uv;         // per-corner, parallel to SURVIVING corners of faces (dim 2)
    const bool partHasUv = part.uv.length > 0;
    size_t cornerBase = 0;
    foreach (localFace, face; part.faces) {
        const size_t faceBase = cornerBase;
        cornerBase += face.length;                     // advance regardless of drop

        // Three, not the kernel's two — see `flattenToMesh` above for whose
        // threshold this is and why interchange normalises above the kernel
        // floor (task 1290). Every parallel channel is appended after the
        // `continue`, so the drop shifts nothing.
        if (face.length < 3) continue;                 // drop degenerate (UV corners drop too)
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

        if (partHasUv) {
            foreach (k; 0 .. face.length) {
                const size_t src = (faceBase + k) * 2;
                if (src + 2 <= part.uv.length)
                    uv ~= part.uv[src .. src + 2];
                else
                    uv ~= [0.0f, 0.0f];                 // defensive: short stream
            }
        }
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

    // Per-corner UV → the `"uv"` PolyVertex map (corner order == loop order).
    populateUvMap(m, uv, partHasUv);

    // Sparse per-vertex morph channels (task 1069). Per-part, so no offset.
    populateMorphMaps(m, part.morphs);

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
        l.meshRef() = partToMesh(part);
        l.name       = part.name.length ? part.name
                                        : "Layer " ~ to!string(pi + 1);
        // Stage 5: visibility rides in from the source format's hidden flag
        // (default true). The `selected` bit (and hence the derived background)
        // is decided below by the primary-visible guard, not assumed to be part 0.
        l.visible    = part.visible;
        l.selected   = false;
        // Task 0615 (§Tier-2 :341-380): every interchange-imported layer is
        // mesh-kind — `l.kind` is left at its default (`ItemKind.Mesh`), never
        // set otherwise here. Assert it so a future change to this loop that
        // starts assigning `kind` cannot silently import a non-mesh layer.
        assert(l.hasMesh, "toLayers: imported layers are always mesh-kind (task 0615)");
        layers[pi] = l;
    }

    // -----------------------------------------------------------------------
    // Primary-visible guard (Stage 5). `setActive`/`setPrimary` require the
    // primary layer be selected+visible (document.d invariant). Part 0 is the
    // natural primary, but it may have come in HIDDEN. Resolve, in priority:
    //   (a) part 0 hidden but some OTHER part is visible → promote the FIRST
    //       VISIBLE part to primary; part 0 stays hidden + non-primary.
    //   (b) EVERY part hidden → no visible part to edit; un-hide part 0 (force
    //       it visible) so a representable edit target exists. A document whose
    //       edit target is invisible is not a valid state.
    // The chosen index is then the primary via `setActive`, which re-asserts the
    // SET-of-one (selected + visible) invariant.
    // -----------------------------------------------------------------------
    size_t primaryIdx = 0;
    if (!layers[0].visible) {
        size_t firstVisible = size_t.max;
        foreach (i, l; layers)
            if (l.visible) { firstVisible = i; break; }
        if (firstVisible != size_t.max)
            primaryIdx = firstVisible;          // (a) promote first visible
        else
            layers[0].visible = true;           // (b) all hidden → force part 0 visible
    }

    Document d;
    d.layers      = layers;
    // Stage-0 lockstep: set primary + selected + activeIndex together. The guard
    // above guarantees `layers[primaryIdx]` is visible, so the primary invariant
    // (selected + visible) holds.
    d.setActive(primaryIdx);
    return d;
}

// ---------------------------------------------------------------------------
// flattenDocument — merge VISIBLE layers for flat (interchange) export
// ---------------------------------------------------------------------------

/// Concatenate every VISIBLE layer's mesh into one flat Mesh for the
/// single-mesh interchange exporters (OBJ / glTF / FBX / LWO). The inverse seam
/// of `toLayers`: surfaces are deduped by name across visible layers (first-seen
/// order, same policy as `flattenToMesh`), vertices concatenated with a running
/// offset, subpatch + material carried over, and each layer's per-item xform
/// BAKED into its points (`composedMatrix()`, same convention as the LWO and
/// aiScene export walks). Hidden layers are skipped.
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
    // Per-corner UV stream parallel to the surviving corners of allFaces (dim 2),
    // read from each visible layer mesh's `"uv"` PolyVertex map and concatenated
    // through the SAME face-drop logic. Empty when no visible layer carries a UV
    // map — so a UV-less document flattens to a UV-less mesh (export unchanged).
    float[]  allUv;
    // Pre-scan (task 0678 D1) — same law as flattenToMesh: anyUv must be
    // known before the first layer is walked, or a leading UV-less layer
    // emits no zero-fill corners and the whole map is silently dropped.
    bool anyUv = false;
    foreach (l; doc.meshLayers) {
        if (!l.visible) continue;
        const(MeshMap)* mu = l.meshRef().meshMap(kUvMapName);
        if (mu !is null && mu.domain == MapDomain.PolyVertex && mu.dim == 2) {
            anyUv = true;
            break;
        }
    }

    uint vertexOffset = 0;
    MergedMorph[] mergedMorphs;   // task 1069
    // Task 0615 Stage 4: interchange export has no non-mesh concept — iterate
    // `doc.meshLayers`, not `doc.layers`, so a non-mesh layer is silently
    // skipped rather than reaching `meshRef()`.
    foreach (l; doc.meshLayers) {
        if (!l.visible) continue;
        const ref Mesh src = l.meshRef();
        const(MeshMap)* srcUv = src.meshMap(kUvMapName);
        const bool layerHasUv = srcUv !is null
            && srcUv.domain == MapDomain.PolyVertex && srcUv.dim == 2;

        // The layer's item matrix is BAKED into its points further down. A
        // NEGATIVE-determinant matrix (a mirror — `scl` with an odd number of
        // negative components, which `MIN_ITEM_SCALE_MAG` explicitly allows)
        // moves the points but leaves the index order alone, so every face of
        // that layer would come out wound inward. Emit its corners in REVERSE
        // order to compensate (task 0684; the same rule
        // `create_common.frameIsLeftHanded`/`reverseFaceWinding` applies when a
        // Create-tool builds through a left-handed workplane frame).
        const float[16] M = l.xform.composedMatrix();
        const bool flipWinding = matrixMirrorsWinding(M);

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
            // EXPORT side, and the same deliberate three — see `flattenToMesh`
            // (task 1290). A two-corner face the kernel legitimately holds does
            // NOT survive an interchange export; `.v3d` is the format that
            // keeps it.
            if (face.length < 3) continue;            // drop degenerate (UV corners drop too)
            // `srcCorner(k)` is THE corner-order mapping for this face: the
            // identity normally, reversed when the bake below mirrors. The index
            // array AND the per-corner UV stream both read through it, so a
            // corner keeps its own UV across the reversal (a reversal applied to
            // the indices alone would shear the per-corner plane by one face).
            uint srcCorner(size_t k) {
                return cast(uint) (flipWinding ? (face.length - 1 - k) : k);
            }
            uint[] offset;
            offset.length = face.length;
            foreach (k; 0 .. face.length)
                offset[k] = face[srcCorner(k)] + vertexOffset;
            allFaces ~= offset;

            allSubpatch ~= src.isFaceSubpatch(fi);

            const localMat = (fi < src.faceMaterial.length) ? src.faceMaterial[fi] : 0u;
            allMaterial ~= (localMat < remap.length) ? remap[localMat] : 0u;

            // UV corners for this surviving face, addressed through the source
            // mesh's own CSR layout (faceCornerLoop) — not a running counter,
            // because the source already has valid loops. Zero-fill when this
            // layer has no UV but another visible layer does.
            if (anyUv) {
                foreach (k; 0 .. face.length) {
                    if (layerHasUv) {
                        const size_t loop =
                            src.faceCornerLoop(cast(uint) fi, srcCorner(k));
                        if (loop != size_t.max && loop * 2 + 2 <= srcUv.data.length)
                            allUv ~= srcUv.data[loop * 2 .. loop * 2 + 2];
                        else
                            allUv ~= [0.0f, 0.0f];
                    } else {
                        allUv ~= [0.0f, 0.0f];
                    }
                }
            }
        }
        // BAKE the per-item xform into this layer's points (task 0678 D2) —
        // the other two export walks already carry the pose (LWO bakes
        // composedMatrix per layer, the aiScene path writes it into the node
        // transform); this flat path silently dropped it. A default ItemXform
        // composes to identity, so points are verbatim (same convention as
        // lwo_export). `M`/`flipWinding` are computed above the face loop
        // because a mirroring bake also has to reverse the winding emitted
        // there.
        auto baked = new Vec3[](src.vertices.length);
        foreach (i, v; src.vertices)
            baked[i] = transformPoint(M, v);
        allVerts ~= baked;
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

    // Per-corner UV → the flattened mesh's `"uv"` map (corner order == loop order).
    populateUvMap(m, allUv, anyUv);

    // Sparse per-vertex morph channels, shifted into the merged index space.
    foreach (ref mm; mergedMorphs) populateMorphMaps(m, [mm.morph], mm.offset);

    m.resizeSubpatch();
    foreach (fi, flag; allSubpatch)
        m.setFaceSubpatch(fi, flag);

    m.surfaces = mergedSurfaces;
    m.faceMaterial.length = m.faces.length;
    foreach (fi; 0 .. m.faces.length)
        m.faceMaterial[fi] = (fi < allMaterial.length) ? allMaterial[fi] : 0u;

    return m;
}

// ---------------------------------------------------------------------------
// Stage 5 — toLayers visibility + primary-visible guard (pure data invariants)
// ---------------------------------------------------------------------------

version (unittest) {
    /// A minimal valid part: one triangle (so `partToMesh` yields real
    /// geometry, never the empty-mesh path), with the given name + visibility.
    private ImportedPart triPart(string name, bool visible) {
        ImportedPart p;
        p.name     = name;
        p.visible  = visible;
        p.vertices = [ Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0) ];
        p.faces    = [ [0u, 1u, 2u] ];
        return p;
    }
}

unittest {
    // "first part hidden, others visible": toLayers must NOT make the hidden
    // part 0 primary; it promotes the first VISIBLE part. Part 0 stays
    // visible=false. Invariants hold (primary selected + visible + non-null).
    ImportedScene scene;
    scene.parts = [
        triPart("Hidden0",  false),
        triPart("Visible1", true),
        triPart("Visible2", true),
    ];

    Document d = toLayers(scene);

    assert(d.layers.length == 3);
    // The hidden part survived with visible=false (not silently un-hidden).
    assert(!d.layers[0].visible, "part 0 must stay hidden");
    assert(d.layers[1].visible && d.layers[2].visible);

    // Primary is the FIRST visible part (index 1), NOT the hidden part 0.
    assert(d.primary !is null);
    assert(d.primary is d.layers[1], "first visible part must be primary");
    assert(d.primary.selected, "primary must be selected");
    assert(d.primary.visible,  "primary must be visible");

    // Exactly the primary is selected (the SET-of-one setActive establishes).
    size_t selCount = 0;
    foreach (l; d.layers) if (l.selected) selCount++;
    assert(selCount == 1, "exactly one layer selected");
    assert(!d.layers[0].selected, "hidden part 0 is not selected");
}

unittest {
    // "all parts hidden": there is no visible part to promote, so the guard MUST
    // force at least one visible (part 0) so the primary invariant holds. A
    // document whose edit target is invisible is not representable.
    ImportedScene scene;
    scene.parts = [
        triPart("Hidden0", false),
        triPart("Hidden1", false),
    ];

    Document d = toLayers(scene);

    assert(d.layers.length == 2);
    // Guard forced part 0 visible; the other stays hidden.
    assert(d.layers[0].visible, "all-hidden guard forces part 0 visible");
    assert(!d.layers[1].visible, "non-promoted hidden part stays hidden");

    // Invariants: >=1 selected, primary selected + visible + non-null.
    assert(d.primary !is null);
    assert(d.primary is d.layers[0]);
    assert(d.primary.selected && d.primary.visible);
    size_t selCount = 0;
    foreach (l; d.layers) if (l.selected) selCount++;
    assert(selCount >= 1, "at least one layer selected");
}

// task 0678 D1 — a MIXED multi-part scene (leading part without UV, later part
// with UV) must still yield an aligned UV map: the leading part's corners are
// zero-filled.  Before the fix `anyUv` was discovered mid-loop, so the leading
// part emitted NO corners, the stream came up short, and populateUvMap
// silently dropped the whole map.
unittest {
    ImportedPart p0 = triPart("NoUv",   true);
    ImportedPart p1 = triPart("WithUv", true);
    p1.uv = [0.1f, 0.2f,  0.3f, 0.4f,  0.5f, 0.6f];   // 3 corners x dim 2

    ImportedScene scene;
    scene.parts = [p0, p1];
    Mesh m = flattenToMesh(scene);

    assert(m.faces.length == 2, "both tris must survive the flatten");
    const(MeshMap)* mu = m.meshMap(kUvMapName);
    assert(mu !is null, "mixed-part scene must keep its UV map");
    assert(mu.data.length == 12, "6 corners x dim 2 (zero-fill for part 0)");
    foreach (k; 0 .. 6)
        assert(mu.data[k] == 0.0f, "leading UV-less part must be zero-filled");
    assert(mu.data[6 .. 12] == p1.uv, "part 1 corners must carry its own UV");
}

// task 0678 D1+D2 — flattenDocument: (D1) same mixed-UV law across layers;
// (D2) each layer's ItemXform must be BAKED into the flattened points (the
// LWO and aiScene export walks already carry the pose; this flat path fed FBX/
// OBJ/glTF export and silently dropped it).
unittest {
    import std.math : abs;

    ImportedScene scene;
    scene.parts = [triPart("A", true), triPart("B", true)];
    Document d = toLayers(scene);
    assert(d.layers.length == 2);

    // Layer 0: posed, no UV. Layer 1: UV-mapped, identity pose.
    d.layers[0].xform.pos = Vec3(10, 0, 0);
    ref Mesh m1 = d.layers[1].meshRef();
    auto mu1 = m1.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    mu1.data = [0.1f, 0.2f,  0.3f, 0.4f,  0.5f, 0.6f];

    Mesh flat = flattenDocument(d);
    assert(flat.vertices.length == 6 && flat.faces.length == 2);

    // D2: layer 0's verts (the first three) carry the +10 X pose; layer 1's
    // verts are verbatim.
    foreach (i; 0 .. 3)
        assert(abs(flat.vertices[i].x - (d.layers[0].meshRef().vertices[i].x + 10.0f)) < 1e-5f,
               "layer 0 pose must be baked into flattened points");
    foreach (i; 3 .. 6)
        assert(abs(flat.vertices[i].x - d.layers[1].meshRef().vertices[i - 3].x) < 1e-5f,
               "identity-posed layer must flatten verbatim");

    // D1: UV map survives with layer 0's corners zero-filled.
    const(MeshMap)* mu = flat.meshMap(kUvMapName);
    assert(mu !is null, "mixed-UV document must keep its UV map");
    assert(mu.data.length == 12, "6 corners x dim 2");
    foreach (k; 0 .. 6)
        assert(mu.data[k] == 0.0f, "leading UV-less layer must be zero-filled");
    assert(mu.data[6 .. 12] == mu1.data, "layer 1 corners must carry its own UV");
}

// ---------------------------------------------------------------------------
// task 0684 — a MIRRORING layer transform (det(composedMatrix()) < 0) must come
// out of flattenDocument with reversed face winding, and its per-corner UV must
// reverse WITH it.
//
// A negative `scl` component is a legal item transform (`MIN_ITEM_SCALE_MAG`
// clamps magnitude only, never the sign), and the bake moves the POINTS while
// leaving the index order alone — so without the reversal every face of that
// layer leaves the editor wound inward.
//
// The load-bearing assertion is GEOMETRIC (the flattened face's Newell normal
// still points the way the source face did), not "the indices came out in this
// order": the point of the reversal is that the surface stays outward, and an
// index-order assertion alone would still pass if the reversal were applied to
// the wrong half of the problem.
// ---------------------------------------------------------------------------
version (unittest) {
    /// A unit quad in the Z=0 plane, wound CCW seen from +Z (Newell normal
    /// +Z), with one UV per corner so the corner plane is observable.
    private ImportedPart quadPart(string name) {
        ImportedPart p;
        p.name     = name;
        p.visible  = true;
        p.vertices = [ Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0) ];
        p.faces    = [ [0u, 1u, 2u, 3u] ];
        p.uv       = [ 0.0f, 0.0f,  1.0f, 0.0f,  1.0f, 1.0f,  0.0f, 1.0f ];
        return p;
    }

    /// Newell normal of `m`'s face `fi` — the same formula the face-orientation
    /// checks elsewhere use, kept local so this file needs no test helper.
    private Vec3 newellNormal(ref const Mesh m, size_t fi) {
        auto f = m.faces[fi];
        Vec3 n = Vec3(0, 0, 0);
        foreach (k; 0 .. f.length) {
            const a = m.vertices[f[k]];
            const b = m.vertices[f[(k + 1) % f.length]];
            n.x += (a.y - b.y) * (a.z + b.z);
            n.y += (a.z - b.z) * (a.x + b.x);
            n.z += (a.x - b.x) * (a.y + b.y);
        }
        return n;
    }

    /// The dim-2 UV of corner `k` of face `fi`, read through the CSR loop layout.
    private float[2] cornerUv(ref const Mesh m, uint fi, uint k) {
        const(MeshMap)* mu = m.meshMap(kUvMapName);
        assert(mu !is null, "mesh carries no uv map");
        const size_t loop = m.faceCornerLoop(fi, k);
        assert(loop != size_t.max && loop * 2 + 2 <= mu.data.length);
        return [ mu.data[loop * 2], mu.data[loop * 2 + 1] ];
    }
}

unittest {
    ImportedScene scene;
    scene.parts = [ quadPart("Mirrored") ];
    Document d = toLayers(scene);
    // scl.x = -1: one negative component => det < 0 => a mirror.
    d.layers[0].xform.scl = Vec3(-1, 1, 1);
    assert(d.layers[0].xform.modelSpace().mirrored, "fixture must actually mirror");

    Mesh flat = flattenDocument(d);
    assert(flat.faces.length == 1 && flat.vertices.length == 4);

    // The source quad's normal is +Z. The bake mirrors X, so an unreversed
    // index order would put the flattened normal at -Z (inside-out).
    import std.conv : to;
    const n = newellNormal(flat, 0);
    assert(n.z > 0.0f,
        "a mirrored layer must flatten with its faces still wound outward "
      ~ "(+Z here); got normal.z = " ~ n.z.to!string);

    // The winding correction is a corner-order reversal, so corner k of the
    // flattened face must carry the UV of source corner (n-1-k) — the whole
    // point of routing the UV stream through the same mapping. Reversing the
    // indices alone would leave corner 0 holding corner 0's UV over corner 3's
    // position, shearing the per-corner plane by one face.
    static immutable float[2][4] srcUv = [[0, 0], [1, 0], [1, 1], [0, 1]];
    foreach (uint k; 0 .. 4) {
        const got = cornerUv(flat, 0, k);
        const want = srcUv[3 - k];
        assert(got[0] == want[0] && got[1] == want[1],
            "corner UV must reverse together with the winding");
    }
}

unittest {
    // The control: an IDENTITY-posed layer is not touched — same winding, same
    // corner order. Without it, "always reverse" would pass the test above.
    ImportedScene scene;
    scene.parts = [ quadPart("Plain") ];
    Document d = toLayers(scene);
    assert(!d.layers[0].xform.modelSpace().mirrored);

    Mesh flat = flattenDocument(d);
    const n = newellNormal(flat, 0);
    assert(n.z > 0.0f, "an unmirrored layer keeps its outward winding");
    assert(flat.faces[0] == [0u, 1u, 2u, 3u], "no reversal without a mirror");

    static immutable float[2][4] srcUv = [[0, 0], [1, 0], [1, 1], [0, 1]];
    foreach (uint k; 0 .. 4) {
        const got = cornerUv(flat, 0, k);
        assert(got[0] == srcUv[k][0] && got[1] == srcUv[k][1],
            "corner UV order is untouched without a mirror");
    }
}

unittest {
    // TWO negative components is NOT a mirror (det > 0) — the reversal must not
    // fire. A rule written as "any negative scale" instead of det < 0 fails here.
    ImportedScene scene;
    scene.parts = [ quadPart("DoubleFlip") ];
    Document d = toLayers(scene);
    d.layers[0].xform.scl = Vec3(-1, -1, 1);
    assert(!d.layers[0].xform.modelSpace().mirrored, "two negatives cancel");

    Mesh flat = flattenDocument(d);
    assert(flat.faces[0] == [0u, 1u, 2u, 3u],
        "an even number of negative scale components must not reverse winding");
    // Rotating the quad 180deg about Z keeps its +Z normal.
    assert(newellNormal(flat, 0).z > 0.0f);
}
