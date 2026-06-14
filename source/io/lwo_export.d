module io.lwo_export;

import lwo2;   // lwo2-writer (core config): Lwo2Object / Lwo2Polygon / Lwo2Surface
               //                            Lwo2VertexMap / Lwo2VertexMapD / writeLwo2File

import mesh;

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

/// Serialize `mesh` to an LWO2 file at `path`.
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
    obj.polygons.reserve(mesh.faces.length);
    foreach (fi; 0 .. mesh.faces.length) {
        Lwo2Polygon poly;
        poly.indices  = mesh.faces[fi].dup;
        poly.surface  = (fi < mesh.faceMaterial.length) ? mesh.faceMaterial[fi] : 0u;
        poly.subpatch = mesh.isFaceSubpatch(fi);
        obj.polygons ~= poly;
    }

    // Surfaces: copy the per-mesh material registry. When empty, leave
    // `obj.surfaces` empty — the writer then omits TAGS/PTAG/SURF and produces
    // a pure PNTS+POLS file, matching the old "no surfaces" behavior.
    obj.surfaces.reserve(mesh.surfaces.length);
    foreach (ref s; mesh.surfaces) {
        Lwo2Surface ls;
        ls.name       = s.name;
        ls.baseColor  = [s.baseColor.x, s.baseColor.y, s.baseColor.z];
        ls.diffuse    = s.diffuseAmount;
        ls.specular   = s.specularAmount;
        ls.glossiness = s.glossiness;
        ls.opacity    = s.opacity;
        obj.surfaces ~= ls;
    }

    // --- UV: flat per-corner "uv" map -> two-tier VMAP base + VMAD overrides ---
    buildUvMaps(mesh, obj);

    writeLwo2File(path, obj);
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
//     (point, face). The lib stores VMAD `polys[]` in obj.polygons[] index space
//     (== mesh face index here, since exportLwo emits one Lwo2Polygon per face in
//     face order), and asserts each VMAD references a SINGLE poly kind. So the
//     overrides are split by mesh.isFaceSubpatch into UP TO TWO VMAD entries: one
//     whose polys[] are all FACE (non-subpatch), one all PTCH (subpatch).
//
// No "uv" map (or it is not the expected PolyVertex/dim-2 shape) ⇒ obj.vmaps /
// obj.vmads stay empty and the writer emits a UV-less file (unchanged output).
//
// The map type/name written is "TXUV" / "uv" — matching what the importer keys on
// (it consumes only TXUV maps and seeds the `"uv"` PolyVertex map from them).
private void buildUvMaps(ref const Mesh mesh, ref Lwo2Object obj)
{
    const(MeshMap)* uvMap = mesh.meshMap(kUvMapName);
    if (uvMap is null
        || uvMap.domain != MapDomain.PolyVertex
        || uvMap.dim != 2)
        return;                       // no usable UV ⇒ leave vmaps/vmads empty

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

    obj.vmaps ~= vmap;

    // Pass 2: per-corner overrides where the corner UV differs from its point's
    // base, split by face kind (FACE vs PTCH) so each VMAD references one kind —
    // the lib's single-kind constraint. polys[] are mesh face indices, which are
    // obj.polygons[] indices (one Lwo2Polygon per face, face order).
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

    if (faceVmad.points.length) obj.vmads ~= faceVmad;
    if (ptchVmad.points.length) obj.vmads ~= ptchVmad;
}

private float fabsf(float x) { return x < 0 ? -x : x; }
