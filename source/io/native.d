module io.native;

import std.file      : exists, read, write;
import std.json      : JSONValue, JSONType, parseJSON, JSONException;
import std.conv      : to;
import std.format    : format;

import mesh;
import math;
import document : Document, Layer;
import seltype  : SelMode;
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
// v3 schema (current, the ONLY shape read or written — selection-types Stage 3).
// It wraps one or more layers around the shared mesh sub-object. Two changes
// from the retired v2 shape: the per-layer `selected` flag now persists the
// item-selection SET (a layer's background state derives — see below), and the
// document's edit target is named by `primaryLayer` (replacing `activeLayer`):
//   {
//     "formatVersion": 3,
//     "primaryLayer": 0,
//     "layers": [
//       { "name": "Layer 1", "visible": true, "selected": true,
//         "mesh": { /* the mesh sub-object below */ } },
//       ...
//     ]
//   }
//
// There is NO `background` key — `background(l) == l.visible && !l.selected`
// derives at runtime (Stage 2b), so the file persists `selected` alone. There
// is NO `activeLayer` key — `primaryLayer` indexes the primary (edit-target)
// layer, which the reader forces selected + visible.
//
// The shared "mesh" sub-object (unchanged across every schema version):
//   {
//     "vertices":     [[x,y,z], ...],
//     "faces":        [[i,j,k,...], ...],          // n-gon, vertex indices
//     "faceSubpatch": [bool, ...],                 // optional; default false
//     "faceMaterial": [uint, ...],                 // optional; default 0
//     "surfaces":     [{ "name", "baseColor":[r,g,b],
//                        "diffuse", "specular", "glossiness", "opacity" }, ...]
//   }
//
// CLEAN BREAK (Stage 3 — no external clients, per the project directive): the
// reader accepts EXACTLY `formatVersion == kV3dFormatVersion`. The legacy v1
// (top-level `mesh`) and v2 (`activeLayer` + per-layer `background`) shapes are
// no longer parsed — they are rejected cleanly at the version gate, leaving the
// caller's document untouched. The reader stays tolerant WITHIN v3: unknown
// fields are ignored and missing optional fields default sensibly, so the
// format can keep growing (editor state, Shader Tree) without another break.

/// The schema version the writer emits and the ONLY version the reader accepts.
/// Bumped to 3 when item-selection persistence (`selected` + `primaryLayer`)
/// landed; v1/v2 files are now rejected (deliberate break — no external clients).
enum int kV3dFormatVersion = 3;

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Serialize one `Mesh` to the shared `.v3d` "mesh" sub-object (vertices /
/// faces / subpatch / surfaces / faceMaterial). Identical bytes in v1 and v2,
/// so the same codec serves the legacy single-mesh shape and each v2 layer.
JSONValue meshToJson(ref const Mesh mesh)
{
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

    return m;
}

/// Serialize a single `mesh` to a `.v3d` document at `path`. Wraps the mesh in
/// a one-layer v3 document ("Layer 1", primary, selected) so single-mesh
/// callers (interchange flatten paths, ad-hoc saves) still produce a valid v3
/// file with exactly one mesh codec.
void writeV3d(ref const Mesh mesh, string path)
{
    auto doc = Document.bootstrap(cast(Mesh) mesh);
    writeV3d(doc, path);
}

/// Serialize a whole `Document` (every layer + which layer is primary) to a
/// `.v3d` document at `path` under `formatVersion: 3`. Each layer persists its
/// `selected` flag (the item-selection SET); `primaryLayer` names the edit
/// target. There is NO `background` key (it derives from `visible && !selected`)
/// and NO `activeLayer` key (`primaryLayer` replaces it). Each layer's `mesh`
/// sub-object goes through the shared `meshToJson` codec.
void writeV3d(ref const Document document, string path)
{
    JSONValue doc;
    doc["formatVersion"] = JSONValue(kV3dFormatVersion);
    doc["primaryLayer"]  = JSONValue(cast(long) document.activeIndex);

    JSONValue[] layers;
    layers.reserve(document.layers.length);
    foreach (ref const layer; document.layers) {
        JSONValue lj;
        lj["name"]     = JSONValue(layer.name);
        lj["visible"]  = JSONValue(layer.visible);
        // Stage 3: persist the item-selection SET directly. `background` is
        // NOT written — it derives (visible && !selected) on load.
        lj["selected"] = JSONValue(layer.selected);
        lj["mesh"]     = meshToJson(layer.mesh);
        layers ~= lj;
    }
    doc["layers"] = JSONValue(layers);

    // toPrettyString keeps the document human-readable + diff-able, matching
    // the format's design goal (source of truth, reviewable in git).
    write(path, doc.toPrettyString());
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Parse a `.v3d` document at `path` and rebuild a whole `Document`. Accepts
/// ONLY `formatVersion == kV3dFormatVersion` (v3) — the legacy v1/v2 shapes are
/// rejected at the version gate (Stage 3 clean break). A v3 file carries a
/// `layers` array (each entry persisting its `selected` flag) plus a
/// `primaryLayer` index naming the edit target; the reader re-asserts the
/// selection-set invariants via the Document mutators (`setActive` /
/// `selectItem` / `setPrimary`), forcing the primary selected + visible if the
/// file is inconsistent. Returns false (logging via the io subsystem, like
/// importLWO) on a missing file, malformed JSON, a `formatVersion` other than
/// v3, structurally wrong content, an empty `layers` array, or an out-of-range
/// vertex index — and leaves the caller's `document` UNTOUCHED in every reject
/// case (all layers are parsed into a temporary before the single atomic swap
/// below).
bool readV3d(string path, ref Document document)
{
    v3dInfo(format("readV3d: path=%s", path));

    if (!exists(path)) {
        v3dWarn("file does not exist");
        return false;
    }

    // Structural durability backstop: any unguarded typed std.json access
    // inside the parse body throws JSONException. The explicit per-field
    // rejects below give better messages; this outer catch ensures a
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

        // Version gate (Stage 3 clean break). The reader accepts EXACTLY v3 —
        // a newer file we can't parse, OR a legacy v1/v2 file, is rejected here
        // (the document is untouched). A missing `formatVersion` (the implicit
        // v1 shape) is likewise rejected. Unknown fields WITHIN v3 are ignored.
        int ver = 0;   // 0 = "no formatVersion key" → not v3 → reject
        if (auto vp = "formatVersion" in doc) {
            if (vp.type == JSONType.integer)
                ver = cast(int) vp.integer;
            else {
                v3dWarn("reject: formatVersion is not an integer");
                return false;
            }
        }
        if (ver != kV3dFormatVersion) {
            v3dWarn(format("reject: unsupported formatVersion %d "
                            ~ "(this build reads only v%d)", ver, kV3dFormatVersion));
            return false;
        }

        // Build the parsed layers into a temporary; only swap into `document`
        // once every layer parses cleanly (atomic — see the doc comment). Each
        // layer's `selected` flag is parsed into the temporary `selected[]`
        // alongside; the SET invariants are re-asserted via the Document
        // mutators AFTER the swap.
        Layer[] parsed;
        bool[]  selected;

        // --- v3: a `layers` array is required (no top-level-mesh fallback). ---
        auto lp = "layers" in doc;
        if (lp is null || lp.type != JSONType.array) {
            v3dWarn("reject: missing or non-array \"layers\"");
            return false;
        }
        if (lp.array.length == 0) {
            v3dWarn("reject: empty \"layers\" array");
            return false;
        }
        foreach (li, lj; lp.array) {
            if (lj.type != JSONType.object) {
                v3dWarn(format("reject: layer %d is not an object", li));
                return false;
            }
            auto mp = "mesh" in lj;
            if (mp is null || mp.type != JSONType.object) {
                v3dWarn(format("reject: layer %d missing or non-object \"mesh\"", li));
                return false;
            }
            auto layer = new Layer;
            if (!meshFromJson(*mp, layer.mesh))
                return false;
            // Name + flags (all optional; sensible defaults preserved).
            layer.name = format("Layer %d", li + 1);
            if (auto np = "name" in lj)
                if (np.type == JSONType.string && np.str.length > 0)
                    layer.name = np.str;
            layer.visible = true;
            if (auto vbp = "visible" in lj)
                layer.visible = (vbp.type == JSONType.true_);
            // Stage 3: persist the item-selection SET. Default deselected; the
            // mutator pass below re-asserts the ≥1-selected + primary invariants.
            bool sel = false;
            if (auto sp = "selected" in lj)
                sel = (sp.type == JSONType.true_);
            parsed   ~= layer;
            selected ~= sel;
        }

        // primaryLayer: optional; default 0; clamp into [0, layers-1]. The
        // primary is forced selected + visible below (handles an inconsistent
        // file that named a deselected/hidden layer as primary).
        size_t primaryIndex = 0;
        if (auto pp = "primaryLayer" in doc) {
            long a = 0;
            if (pp.type == JSONType.integer)        a = pp.integer;
            else if (pp.type == JSONType.uinteger)  a = cast(long) pp.uinteger;
            if (a < 0)                          a = 0;
            if (a >= cast(long) parsed.length)  a = cast(long) parsed.length - 1;
            primaryIndex = cast(size_t) a;
        }

        // --- atomic swap: every layer parsed; commit into the document ---
        document.layers  = parsed;
        document.primary = parsed[primaryIndex];

        // Re-assert the selection-set invariants via the Stage-0/2a mutators
        // (never by writing raw fields). Start from a clean baseline: the
        // primary is the edit target AND the single member of the set
        // (setActive enforces exactly-one-selected + primary selected+visible).
        document.setActive(primaryIndex);
        // Force the primary visible if the file marked it hidden (an
        // inconsistent file can't leave the edit target invisible).
        if (!document.primary.visible)
            document.primary.visible = true;
        // Re-add every other layer the file marked selected (multi-select set);
        // setPrimary at the end restores the file's primary as the edit target
        // without dropping the rest of the set.
        foreach (i, layer; parsed) {
            if (i == primaryIndex) continue;
            if (selected[i])
                document.selectItem(layer, SelMode.Add);
        }
        document.setPrimary(document.layers[primaryIndex]);

        v3dInfo(format("document ready: %d layer(s), primary=%d",
                        document.layers.length, document.activeIndex));
        return true;
    } catch (JSONException e) {
        // Backstop for any typed std.json access not guarded above. The
        // document is mutated only at the final swap (after all rejects), so a
        // throw before then leaves the caller's document intact.
        v3dWarn(format("reject: malformed JSON structure: %s", e.msg));
        return false;
    }
}

/// Single-mesh convenience overload: parse `path` and copy the ACTIVE layer's
/// mesh into `mesh`. Kept for callers that want a flat mesh (the document is
/// the source of truth for the layered load path). Leaves `mesh` untouched on
/// any reject (the parse builds a temporary Document first).
bool readV3d(string path, ref Mesh mesh)
{
    Document tmp;
    if (!readV3d(path, tmp))
        return false;
    mesh = tmp.activeMeshRef();
    return true;
}

// ---------------------------------------------------------------------------
// Mesh sub-object codec (shared by every layer; unchanged across schema versions)
// ---------------------------------------------------------------------------

/// Rebuild `mesh` from a parsed `.v3d` "mesh" sub-object `m`. Returns false
/// (logging the reason) on structurally wrong content or an out-of-range
/// vertex index; `mesh` is mutated only at the commit step (after every
/// reject), so on a false return the caller's mesh is left intact. Shared by
/// every v3 layer (the mesh shape is identical across schema versions).
private bool meshFromJson(JSONValue m, ref Mesh mesh)
{
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
