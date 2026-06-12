module io.lwo_export;

import lwo2;   // lwo2-writer (core config): Lwo2Object / Lwo2Polygon / Lwo2Surface / writeLwo2File

import mesh;

// ---------------------------------------------------------------------------
// LWO2 export via the lwo2-writer library.
// ---------------------------------------------------------------------------
// Maps the vibe3d `Mesh` onto lwo2-writer's `Lwo2Object` and serializes it with
// `writeLwo2File`. The library emits a faithful LWO2 IFF container
// (LAYR/TAGS/PNTS/BBOX/POLS FACE+PTCH/PTAG/SURF), so the output round-trips
// through our own `importLWO` reader (source/lwo.d) and through MODO/LightWave.
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

    writeLwo2File(path, obj);
}
