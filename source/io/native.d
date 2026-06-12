module io.native;

import std.file      : exists, read, write;
import std.json      : JSONValue, JSONType, parseJSON, JSONException;
import std.conv      : to;
import std.format    : format;

import mesh;
import math;
import log : logWarn, logInfo;

// Diagnostics for the native reader funnel through the "io" log subsystem.
// The "V3D" label stays in the message body so the .v3d origin is still
// visible in the `[io] V3D: …` echo. Levels: structural rejects and tolerant
// "ignoring …" notices are warnings; the path/ready status lines are info.
private void v3dWarn(string msg) nothrow { try logWarn("io", "V3D: " ~ msg); catch (Exception) {} }
private void v3dInfo(string msg) nothrow { try logInfo("io", "V3D: " ~ msg); catch (Exception) {} }

// ---------------------------------------------------------------------------
// Native .v3d document format (JSON)
// ---------------------------------------------------------------------------
// `.v3d` is vibe3d's own document format — the source of truth. Unlike the
// LWO bridge in lwo.d (a lossy interchange format) it round-trips the full
// editor model: vertices, n-gon faces, per-face subpatch flags, the surface
// registry and per-face material indices.
//
// v1 schema (see doc/asset_io_plan.md):
//   {
//     "formatVersion": 1,
//     "mesh": {
//       "vertices":     [[x,y,z], ...],
//       "faces":        [[i,j,k,...], ...],          // n-gon, vertex indices
//       "faceSubpatch": [bool, ...],                 // optional; default false
//       "faceMaterial": [uint, ...],                 // optional; default 0
//       "surfaces":     [{ "name", "baseColor":[r,g,b],
//                          "diffuse", "specular", "glossiness", "opacity" }, ...]
//     }
//   }
//
// The reader is deliberately tolerant: unknown fields are ignored, missing
// optional fields default sensibly, and an unrecognised `formatVersion` is
// rejected with a clear message. This is a hard requirement — the format
// must grow (editor state, layers, Shader Tree) without breaking old files.

/// The schema version the writer emits and the highest the reader accepts.
enum int kV3dFormatVersion = 1;

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Serialize `mesh` to a `.v3d` JSON document at `path`. Emits the full state
/// the Mesh currently holds (vertices / faces / subpatch / surfaces /
/// faceMaterial) under `formatVersion: kV3dFormatVersion`.
void writeV3d(ref const Mesh mesh, string path)
{
    JSONValue doc;
    doc["formatVersion"] = JSONValue(kV3dFormatVersion);

    JSONValue m;

    // Vertices — one [x,y,z] triple per vertex.
    JSONValue[] verts;
    verts.reserve(mesh.vertices.length);
    foreach (v; mesh.vertices)
        verts ~= JSONValue([JSONValue(v.x), JSONValue(v.y), JSONValue(v.z)]);
    m["vertices"] = JSONValue(verts);

    // Faces — n-gon vertex-index lists.
    JSONValue[] faces;
    faces.reserve(mesh.faces.length);
    foreach (face; mesh.faces) {
        JSONValue[] idx;
        idx.reserve(face.length);
        foreach (i; face)
            idx ~= JSONValue(cast(long) i);
        faces ~= JSONValue(idx);
    }
    m["faces"] = JSONValue(faces);

    // Per-face subpatch flags (parallel to faces). Defensively read through
    // isFaceSubpatch so a short isSubpatch array still yields one entry/face.
    JSONValue[] subpatch;
    subpatch.reserve(mesh.faces.length);
    foreach (fi, _; mesh.faces)
        subpatch ~= JSONValue(mesh.isFaceSubpatch(fi));
    m["faceSubpatch"] = JSONValue(subpatch);

    // Per-face material index into `surfaces` (defaults to 0 when unset).
    JSONValue[] faceMat;
    faceMat.reserve(mesh.faces.length);
    foreach (fi, _; mesh.faces) {
        const uint mat = (fi < mesh.faceMaterial.length)
            ? mesh.faceMaterial[fi] : 0u;
        faceMat ~= JSONValue(cast(long) mat);
    }
    m["faceMaterial"] = JSONValue(faceMat);

    // Surface registry. JSON keys are the short editor names; they map onto
    // the Surface struct's verbose field names (diffuse → diffuseAmount, …).
    JSONValue[] surfaces;
    surfaces.reserve(mesh.surfaces.length);
    foreach (ref s; mesh.surfaces) {
        JSONValue sj;
        sj["name"]       = JSONValue(s.name);
        sj["baseColor"]  = JSONValue([
            JSONValue(s.baseColor.x),
            JSONValue(s.baseColor.y),
            JSONValue(s.baseColor.z)]);
        sj["diffuse"]    = JSONValue(s.diffuseAmount);
        sj["specular"]   = JSONValue(s.specularAmount);
        sj["glossiness"] = JSONValue(s.glossiness);
        sj["opacity"]    = JSONValue(s.opacity);
        surfaces ~= sj;
    }
    m["surfaces"] = JSONValue(surfaces);

    doc["mesh"] = m;

    // toPrettyString keeps the document human-readable + diff-able, matching
    // the format's design goal (source of truth, reviewable in git).
    write(path, doc.toPrettyString());
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Parse a `.v3d` document at `path` and rebuild `mesh` from scratch. Returns
/// false (logging to stderr, like importLWO) on a missing file, malformed
/// JSON, an unknown `formatVersion`, structurally wrong content, or an
/// out-of-range vertex index. On success `mesh` holds the reconstructed scene.
bool readV3d(string path, ref Mesh mesh)
{
    v3dInfo(format("readV3d: path=%s", path));

    if (!exists(path)) {
        v3dWarn("file does not exist");
        return false;
    }

    // Structural durability backstop: any unguarded typed std.json access
    // inside the parse-and-rebuild body (e.g. reading .integer on a value
    // std.json actually stored as uinteger) throws JSONException. The explicit
    // per-field rejects below give better messages; this outer catch ensures a
    // hand-crafted .v3d degrades to a clean `false` reject instead of crashing
    // the load. Non-JSON logic errors are not swallowed.
    try {
        JSONValue doc;
        try {
            doc = parseJSON(cast(string) read(path));
        } catch (JSONException e) {
            v3dWarn(format("reject: malformed JSON: %s", e.msg));
            return false;
        }

        if (doc.type != JSONType.object) {
            v3dWarn("reject: top-level value is not a JSON object");
            return false;
        }

        // Version dispatch. v1 is the only schema today; a higher number means a
        // file written by a newer vibe3d than we can parse — reject clearly
        // rather than guess. Unknown fields elsewhere are ignored (tolerant).
        int ver = 1;
        if (auto vp = "formatVersion" in doc) {
            if (vp.type == JSONType.integer)
                ver = cast(int) vp.integer;
            else {
                v3dWarn("reject: formatVersion is not an integer");
                return false;
            }
        } else {
            v3dInfo(format("no formatVersion; assuming v%d", ver));
        }
        if (ver > kV3dFormatVersion || ver < 1) {
            v3dWarn(format("reject: unsupported formatVersion %d "
                            ~ "(this build reads 1..%d)", ver, kV3dFormatVersion));
            return false;
        }

        auto mp = "mesh" in doc;
        if (mp is null || mp.type != JSONType.object) {
            v3dWarn("reject: missing or non-object \"mesh\"");
            return false;
        }
        JSONValue m = *mp;

        // --- vertices (required) ---
        auto vp = "vertices" in m;
        if (vp is null || vp.type != JSONType.array) {
            v3dWarn("reject: missing or non-array \"vertices\"");
            return false;
        }
        Vec3[] verts;
        verts.reserve(vp.array.length);
        foreach (i, vj; vp.array) {
            if (vj.type != JSONType.array || vj.array.length < 3) {
                v3dWarn(format("reject: vertex %d is not an [x,y,z] triple", i));
                return false;
            }
            verts ~= Vec3(jsonFloat(vj.array[0]),
                          jsonFloat(vj.array[1]),
                          jsonFloat(vj.array[2]));
        }

        // --- faces (required) ---
        auto fp = "faces" in m;
        if (fp is null || fp.type != JSONType.array) {
            v3dWarn("reject: missing or non-array \"faces\"");
            return false;
        }
        uint[][] polys;
        polys.reserve(fp.array.length);
        foreach (i, fj; fp.array) {
            if (fj.type != JSONType.array) {
                v3dWarn(format("reject: face %d is not an array", i));
                return false;
            }
            uint[] face;
            face.reserve(fj.array.length);
            foreach (ij; fj.array) {
                if (ij.type != JSONType.integer && ij.type != JSONType.uinteger) {
                    v3dWarn(format("reject: face %d has a non-integer index", i));
                    return false;
                }
                // std.json parses integer literals >= 2^63 as uinteger; reading
                // .integer on those THROWS. Pick the matching accessor. A huge
                // uinteger (or a negative integer) wraps to a large uint that the
                // out-of-range vertex-index check below rejects cleanly.
                const long raw = (ij.type == JSONType.uinteger)
                    ? cast(long) ij.uinteger : ij.integer;
                face ~= cast(uint) raw;
            }
            // Mirror importLWO: silently drop degenerate (< 3-vert) faces rather
            // than reject the whole file.
            if (face.length >= 3)
                polys ~= face;
        }

        if (verts.length == 0) {
            v3dWarn("reject: no vertices");
            return false;
        }
        if (polys.length == 0) {
            v3dWarn("reject: no polygons");
            return false;
        }

        // Out-of-range vertex index check before committing anything.
        const uint nv = cast(uint) verts.length;
        foreach (fi, face; polys)
            foreach (idx; face)
                if (idx >= nv) {
                    v3dWarn(format("reject: face %d references vertex %d "
                                    ~ "(only %d verts)", fi, idx, nv));
                    return false;
                }

        // --- optional: faceSubpatch ---
        // Read into a flat bool[] parallel to `polys` (after degenerate drop the
        // index alignment is best-effort, identical to importLWO's PTCH handling).
        bool[] faceSubpatch;
        if (auto sp = "faceSubpatch" in m) {
            if (sp.type == JSONType.array) {
                faceSubpatch.reserve(sp.array.length);
                foreach (bj; sp.array)
                    faceSubpatch ~= (bj.type == JSONType.true_);
            } else {
                v3dWarn("ignoring non-array \"faceSubpatch\"");
            }
        }

        // --- optional: faceMaterial ---
        uint[] faceMaterial;
        if (auto mmp2 = "faceMaterial" in m) {
            if (mmp2.type == JSONType.array) {
                faceMaterial.reserve(mmp2.array.length);
                foreach (mj; mmp2.array) {
                    if (mj.type == JSONType.uinteger)
                        faceMaterial ~= cast(uint) mj.uinteger;
                    else if (mj.type == JSONType.integer)
                        faceMaterial ~= cast(uint) mj.integer;
                    else
                        faceMaterial ~= 0u;
                }
            } else {
                v3dWarn("ignoring non-array \"faceMaterial\"");
            }
        }

        // --- optional: surfaces ---
        Surface[] surfaces;
        if (auto surfp = "surfaces" in m) {
            if (surfp.type == JSONType.array) {
                surfaces.reserve(surfp.array.length);
                foreach (sj; surfp.array) {
                    if (sj.type != JSONType.object) continue;  // tolerant: skip junk
                    Surface s;                                  // struct defaults
                    if (auto np = "name" in sj)
                        if (np.type == JSONType.string) s.name = np.str;
                    if (auto cp = "baseColor" in sj)
                        if (cp.type == JSONType.array && cp.array.length >= 3)
                            s.baseColor = Vec3(jsonFloat(cp.array[0]),
                                               jsonFloat(cp.array[1]),
                                               jsonFloat(cp.array[2]));
                    if (auto dp = "diffuse" in sj)    s.diffuseAmount  = jsonFloat(*dp);
                    if (auto pp = "specular" in sj)   s.specularAmount = jsonFloat(*pp);
                    if (auto gp = "glossiness" in sj) s.glossiness     = jsonFloat(*gp);
                    if (auto op = "opacity" in sj)    s.opacity        = jsonFloat(*op);
                    surfaces ~= s;
                }
            } else {
                v3dWarn("ignoring non-array \"surfaces\"");
            }
        }

        // --- commit: rebuild the mesh on a fresh struct (mirrors importLWO) ---
        mesh = Mesh.init;
        mesh.vertices = verts;
        uint[ulong] edgeLookup;
        foreach (face; polys)
            mesh.addFaceFast(edgeLookup, face);
        mesh.buildLoops();

        // Apply per-face subpatch flags (parallel to faces).
        mesh.resizeSubpatch();
        int subpatchCount = 0;
        foreach (fi, flag; faceSubpatch) {
            if (fi >= mesh.isSubpatch.length) break;
            mesh.setFaceSubpatch(fi, flag);
            if (flag) ++subpatchCount;
        }

        // Surfaces + per-face material. Grow faceMaterial to one entry per face
        // (entries beyond what the file listed default to 0).
        mesh.surfaces = surfaces;
        mesh.faceMaterial.length = mesh.faces.length;
        foreach (fi; 0 .. mesh.faces.length)
            mesh.faceMaterial[fi] = (fi < faceMaterial.length) ? faceMaterial[fi] : 0u;

        v3dInfo(format("mesh ready: %d verts, %d edges, %d faces, "
                        ~ "%d marked subpatch, %d surfaces",
                        mesh.vertices.length, mesh.edges.length,
                        mesh.faces.length, subpatchCount, mesh.surfaces.length));
        return true;
    } catch (JSONException e) {
        // Backstop for any typed std.json access not guarded above. mesh is
        // only mutated at the commit step (after all rejects), so on a throw
        // before commit the caller's mesh is left intact.
        v3dWarn(format("reject: malformed JSON structure: %s", e.msg));
        return false;
    }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Read a JSON number as a float, accepting integer, unsigned and floating
/// encodings (std.json stores 1.0 as JSONType.float but 1 as integer).
float jsonFloat(const JSONValue v)
{
    switch (v.type) {
        case JSONType.float_:    return cast(float) v.floating;
        case JSONType.integer:   return cast(float) v.integer;
        case JSONType.uinteger:  return cast(float) v.uinteger;
        default:                 return 0.0f;
    }
}
