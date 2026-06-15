module io.lwo_export;

import lwo2;   // lwo2-writer (core config): Lwo2Object / Lwo2Layer / Lwo2Polygon
               //   Lwo2Surface / Lwo2VertexMap / Lwo2VertexMapD / writeLwo2File

import mesh;
import document : Document, Layer;
import math     : Vec3, transformPoint;

// ---------------------------------------------------------------------------
// LWO2 export via the lwo2-writer library.
// ---------------------------------------------------------------------------
// Maps the vibe3d `Mesh` onto lwo2-writer's `Lwo2Object` and serializes it with
// `writeLwo2File`. The library emits a faithful LWO2 IFF container
// (LAYR/TAGS/PNTS/BBOX/POLS FACE+PTCH/PTAG/SURF), so the output round-trips
// through our own `importLWO` reader (source/lwo.d) and through other
// .lwo-aware DCC tools.
//
// Coordinates are written verbatim (no handedness flip) — same as the previous
// hand-rolled exporter, so our own importLWO round-trips exactly.
//
// Two entry points:
//   * exportLwo(ref const Mesh, path)          — single mesh, one LAYR 0.
//   * exportLwoDocument(ref const Document, p)  — one LAYR per Document layer,
//     each layer's per-item xform BAKED into its points, hidden layers exported
//     with the LAYR hidden flag set, ONE global surface table shared by all
//     layers. A single-VISIBLE-layer document with identity xform produces the
//     EXACT bytes the flat single-mesh path produces (back-compat — see below).

/// Serialize `mesh` to an LWO2 file at `path` (single layer, LAYR 0).
void exportLwo(ref const Mesh mesh, string path)
{
    Lwo2Object obj;

    // Points: Vec3 → float[3], verbatim.
    obj.points.reserve(mesh.vertices.length);
    foreach (v; mesh.vertices)
        obj.points ~= [v.x, v.y, v.z];

    // One polygon per face. `mesh.faces[fi]` is a uint[] of point indices;
    // surface index comes from faceMaterial (default 0 when unassigned or
    // out of range); the PTCH/FACE kind comes from the per-face subpatch flag.
    obj.polygons = buildPolygons(mesh);

    // Surfaces: copy the per-mesh material registry. When empty, leave
    // `obj.surfaces` empty — the writer then omits TAGS/PTAG/SURF and produces
    // a pure PNTS+POLS file, matching the old "no surfaces" behavior.
    obj.surfaces.reserve(mesh.surfaces.length);
    foreach (ref s; mesh.surfaces)
        obj.surfaces ~= toLwoSurface(s);

    // --- UV: flat per-corner "uv" map -> two-tier VMAP base + VMAD overrides ---
    buildUvMaps(mesh, obj.vmaps, obj.vmads);

    writeLwo2File(path, obj);
}

/// Serialize `doc` to a multi-layer LWO2 file at `path`.
///
/// One `Lwo2Layer` per `doc.layers` entry (visible AND hidden — the user's
/// decision is to export hidden layers, flagged off via `Lwo2Layer.hidden`).
/// Each layer's `xform.composedMatrix()` is BAKED into its points (LWO carries
/// no per-layer node matrix, so the bake is the faithful representation); an
/// identity xform (the default) leaves points verbatim. The surface table is
/// GLOBAL — surface names are deduped across ALL layers (first-seen order,
/// matching `flattenDocument`'s policy) and each layer's per-face material index
/// is remapped into that shared table. PTAG inside each layer references the
/// global surface index.
///
/// Back-compat: a single-VISIBLE-layer document whose layer has an identity
/// xform routes through the N=1 case of this same builder. The identity bake
/// leaves points verbatim, the global dedup over one layer equals the per-mesh
/// registry, and the per-layer polygon/UV emission is byte-for-byte what the
/// flat path emits. The lib guarantees `buildLwo2(flatObj) ==
/// buildLwo2(equivalent-single-layers0-obj)`, so the file is byte-identical.
void exportLwoDocument(ref const Document doc, string path)
{
    Lwo2Object obj;

    // --- ONE global surface table: dedup by name across ALL layers, first-seen
    //     order (same policy as flattenDocument/flattenToMesh). `nameToIndex`
    //     maps a surface name to its slot in the merged table; per-layer remap
    //     tables rewrite each layer's faceMaterial into global indices. ---
    Lwo2Surface[]  mergedSurfaces;
    size_t[string] nameToIndex;

    Lwo2Layer[] layers;
    layers.reserve(doc.layers.length);

    foreach (const(Layer) l; doc.layers) {
        const ref Mesh src = l.mesh;

        Lwo2Layer lay;
        lay.name   = l.name;
        lay.hidden = !l.visible;          // hidden layers are exported, flagged off

        // Per-layer surface remap into the global table (value copy of the
        // const Surface, like flattenDocument).
        uint[] remap;
        remap.length = src.surfaces.length;
        foreach (si, ref s; src.surfaces) {
            if (auto idx = s.name in nameToIndex) {
                remap[si] = cast(uint) *idx;
            } else {
                const newIdx = cast(uint) mergedSurfaces.length;
                mergedSurfaces ~= toLwoSurface(s);
                nameToIndex[s.name] = newIdx;
                remap[si] = newIdx;
            }
        }

        // BAKE the per-item xform into this layer's points (column-major affine,
        // w=1). A default ItemXform composes to identity, so points are verbatim.
        const float[16] M = l.xform.composedMatrix();
        lay.points.reserve(src.vertices.length);
        foreach (v; src.vertices) {
            const p = transformPoint(M, Vec3(v.x, v.y, v.z));
            lay.points ~= [p.x, p.y, p.z];
        }

        // One polygon per face, layer-local indices, surface remapped global.
        lay.polygons = buildPolygons(src, remap);

        // UV: the same two-tier VMAP+VMAD reconstruction, per layer.
        buildUvMaps(src, lay.vmaps, lay.vmads);

        layers ~= lay;
    }

    obj.surfaces = mergedSurfaces;
    obj.layers   = layers;               // non-empty ⇒ writer emits per-layer LAYR n

    writeLwo2File(path, obj);
}

// ---------------------------------------------------------------------------
// Shared builders (single-mesh and per-layer paths share these).
// ---------------------------------------------------------------------------

/// One `Lwo2Polygon` per face of `mesh`, in face order. Surface index = the
/// per-face material remapped through `surfaceRemap` (identity when null/empty
/// — i.e. surface index used verbatim, the single-mesh case). Subpatch flag
/// from the mesh's per-face subpatch state.
private Lwo2Polygon[] buildPolygons(ref const Mesh mesh, const(uint)[] surfaceRemap = null)
{
    Lwo2Polygon[] polys;
    polys.reserve(mesh.faces.length);
    foreach (fi; 0 .. mesh.faces.length) {
        Lwo2Polygon poly;
        poly.indices  = mesh.faces[fi].dup;
        const uint mat = (fi < mesh.faceMaterial.length) ? mesh.faceMaterial[fi] : 0u;
        poly.surface  = (surfaceRemap.length && mat < surfaceRemap.length)
                        ? surfaceRemap[mat] : mat;
        poly.subpatch = mesh.isFaceSubpatch(fi);
        polys ~= poly;
    }
    return polys;
}

/// Map a vibe3d `Surface` onto an `Lwo2Surface` (value copy of fields).
private Lwo2Surface toLwoSurface(ref const Surface s)
{
    Lwo2Surface ls;
    ls.name       = s.name;
    ls.baseColor  = [s.baseColor.x, s.baseColor.y, s.baseColor.z];
    ls.diffuse    = s.diffuseAmount;
    ls.specular   = s.specularAmount;
    ls.glossiness = s.glossiness;
    ls.opacity    = s.opacity;
    return ls;
}

// ---------------------------------------------------------------------------
// UV: flat per-corner -> two-tier (VMAP continuous base + VMAD overrides)
// ---------------------------------------------------------------------------
// vibe3d's in-memory UV is a FLAT per-corner PolyVertex map ("uv"); the LWO file
// is two-tier: a continuous VMAP gives each POINT one base (u,v), and a
// discontinuous VMAD overrides individual CORNERS where they differ from that
// base (the seam case). Reconstruct that here:
//
//   * VMAP base: for each point, the UV of its FIRST incident corner (in face,
//     then corner order). Points with no corner (unreferenced) get no entry.
//   * VMAD override: every corner whose UV != its point's base, keyed
//     (point, face). The VMAD `polys[]` are in the polygon list's index space
//     (== mesh face index here, since we emit one Lwo2Polygon per face in face
//     order, both single-mesh and per-layer), and each VMAD references a SINGLE
//     poly kind. So overrides are split by mesh.isFaceSubpatch into UP TO TWO
//     VMAD entries: one whose polys[] are all FACE (non-subpatch), one all PTCH.
//
// No "uv" map (or it is not the expected PolyVertex/dim-2 shape) ⇒ `vmaps` /
// `vmads` stay untouched and the writer emits a UV-less layer (unchanged output).
//
// The map type/name written is "TXUV" / "uv" — matching what the importer keys
// on (it consumes only TXUV maps and seeds the `"uv"` PolyVertex map from them).
//
// Fills the caller's `vmaps`/`vmads` (the flat object's, or a layer's) so the
// single-mesh and per-layer paths share ONE implementation.
private void buildUvMaps(ref const Mesh mesh,
                         ref Lwo2VertexMap[]  vmaps,
                         ref Lwo2VertexMapD[] vmads)
{
    const(MeshMap)* uvMap = mesh.meshMap(kUvMapName);
    if (uvMap is null
        || uvMap.domain != MapDomain.PolyVertex
        || uvMap.dim != 2)
        return;                       // no usable UV ⇒ leave vmaps/vmads as-is

    const float[] uv = uvMap.data;

    // Pass 1: per-point base = the UV of its first incident corner. `hasBase`
    // marks which points were actually referenced by a corner.
    float[2][] base;
    bool[]     hasBase;
    base.length    = mesh.vertices.length;
    hasBase.length = mesh.vertices.length;
    foreach (uint fi; 0 .. cast(uint) mesh.faces.length) {
        const face = mesh.faces[fi];
        foreach (uint c; 0 .. cast(uint) face.length) {
            const uint point = face[c];
            if (point >= hasBase.length) continue;   // defensive
            if (hasBase[point]) continue;            // first incident corner wins
            const size_t loop = mesh.faceCornerLoop(fi, c);
            if (loop == size_t.max || loop * 2 + 2 > uv.length) continue;
            base[point]    = [uv[loop * 2], uv[loop * 2 + 1]];
            hasBase[point] = true;
        }
    }

    // Emit the continuous VMAP base (one entry per referenced point).
    Lwo2VertexMap vmap;
    vmap.type      = "TXUV";
    vmap.name      = "uv";
    vmap.dimension = 2;
    foreach (uint pt; 0 .. cast(uint) mesh.vertices.length) {
        if (!hasBase[pt]) continue;
        vmap.points ~= pt;
        vmap.values ~= base[pt][0];
        vmap.values ~= base[pt][1];
    }
    if (vmap.points.length == 0)
        return;                       // no referenced points ⇒ nothing to emit

    vmaps ~= vmap;

    // Pass 2: per-corner overrides where the corner UV differs from its point's
    // base, split by face kind (FACE vs PTCH) so each VMAD references one kind —
    // the lib's single-kind constraint. polys[] are mesh face indices, which are
    // polygon-list indices (one Lwo2Polygon per face, face order).
    Lwo2VertexMapD faceVmad, ptchVmad;
    faceVmad.type = ptchVmad.type = "TXUV";
    faceVmad.name = ptchVmad.name = "uv";
    faceVmad.dimension = ptchVmad.dimension = 2;

    enum float EPS = 1e-6f;
    foreach (uint fi; 0 .. cast(uint) mesh.faces.length) {
        const face = mesh.faces[fi];
        const bool sub = mesh.isFaceSubpatch(fi);
        foreach (uint c; 0 .. cast(uint) face.length) {
            const uint point = face[c];
            if (point >= hasBase.length || !hasBase[point]) continue;
            const size_t loop = mesh.faceCornerLoop(fi, c);
            if (loop == size_t.max || loop * 2 + 2 > uv.length) continue;
            const float cu = uv[loop * 2];
            const float cv = uv[loop * 2 + 1];
            if (fabsf(cu - base[point][0]) <= EPS
                && fabsf(cv - base[point][1]) <= EPS)
                continue;             // corner agrees with base ⇒ no override
            auto vmad = sub ? &ptchVmad : &faceVmad;
            vmad.points ~= point;
            vmad.polys  ~= fi;
            vmad.values ~= cu;
            vmad.values ~= cv;
        }
    }

    if (faceVmad.points.length) vmads ~= faceVmad;
    if (ptchVmad.points.length) vmads ~= ptchVmad;
}

private float fabsf(float x) { return x < 0 ? -x : x; }
