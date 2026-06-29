module io.native;

import std.file      : exists, read, write;
import std.json      : JSONValue, JSONType, parseJSON, JSONException;
import std.conv      : to;
import std.format    : format;

import mesh;
import math;
import document : Document, Layer, ItemXform;
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
// v5 schema (current, the ONLY shape read or written). It wraps one or more
// layers around the shared mesh sub-object. The layer envelope is unchanged
// from v4 (selection-types Stage 3): the per-layer `selected` flag persists the
// item-selection SET (a layer's background state derives — see below), and the
// document's edit target is named by `primaryLayer` (replacing the old
// `activeLayer`). v4 added an optional per-corner `uvMaps` block to the shared
// mesh sub-object (UV-maps Stage 3 — see below). v5 adds an OPTIONAL per-layer
// `xform` block (the item transform/pivot — per-item channels Phase 1); only
// the version int otherwise changes in the envelope:
//   {
//     "formatVersion": 5,
//     "primaryLayer": 0,
//     "layers": [
//       { "name": "Layer 1", "visible": true, "selected": true,
//         "xform": { "pos":[x,y,z], "rot":[x,y,z],
//                    "scl":[x,y,z], "pivot":[x,y,z] },  // optional
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
// `xform` (v5 addition, per-item channels Phase 1) carries the layer's item
// transform as four fixed `Vec3` sub-arrays (`pos`/`rot`/`scl`/`pivot`) — the
// authored channels, NOT a derived matrix. `rot` is euler degrees. The block is
// OMITTED ENTIRELY when the transform is all-default (pos=0, rot=0, scl=1,
// pivot=0), matching the optional-field convention so default-transform docs
// stay byte-clean. A MISSING block ⇒ identity transform — this is the
// within-v5 optional-field contract (forward-additive), NOT back-compat. The
// reader is TOLERANT: a missing or malformed sub-array leaves that component at
// its identity default and keeps loading (the file still opens), matching the
// `uvMaps` tolerant-within-version stance. The grouped shape is hand-written
// from the four `Layer.xform` `Vec3` fields directly (the param provider exposes
// flat scalar params; this codec does NOT iterate `params()` generically).
//
// The shared "mesh" sub-object:
//   {
//     "vertices":     [[x,y,z], ...],
//     "faces":        [[i,j,k,...], ...],          // n-gon, vertex indices
//     "faceSubpatch": [bool, ...],                 // optional; default false
//     "faceMaterial": [uint, ...],                 // optional; default 0
//     "surfaces":     [{ "name", "baseColor":[r,g,b],
//                        "diffuse", "specular", "glossiness", "opacity" }, ...],
//     "uvMaps":       [{ "name", "dim", "data":[u0,v0, u1,v1, ...] }, ...]
//                                                  // optional (v4+); per-corner
//   }
//
// `uvMaps` (v4 addition, UV-maps Stage 3) carries the PolyVertex (per-corner)
// mesh maps — v1 of the feature has just the "uv" map (dim 2). `data` is the
// flat float array in faces-as-written CORNER order: corner order == `faces`
// order == CSR loop order (D6), so the (face, corner) → value correspondence is
// implicit and no per-corner index is stored. `data.length` must equal
// `Σ face arities * dim` for the faces as written (post degenerate-drop). The
// reader is TOLERANT: a wrong-length or wrong-dim entry is ignored with a
// warning (the file still loads, just without that map), matching the codec's
// existing tolerant-within-version stance for the other optional arrays. The
// key is omitted entirely when no PolyVertex map exists.
//
// CLEAN BREAK (no external clients, per the project directive): the reader
// accepts EXACTLY `formatVersion == kV3dFormatVersion`. Every earlier shape —
// v1 (top-level `mesh`), v2 (`activeLayer` + per-layer `background`), v3
// (no `uvMaps`), and v4 (no per-layer `xform`) — is no longer parsed; they are
// rejected cleanly at the version gate, leaving the caller's document
// untouched. There is NO migration code. The reader stays tolerant WITHIN the
// current version: unknown fields are ignored and missing optional fields
// default sensibly, so the format can keep growing (editor state, Shader Tree)
// without another break.

/// The schema version the writer emits and the ONLY version the reader accepts.
/// Was 3 when item-selection persistence (`selected` + `primaryLayer`) landed;
/// 4 when the per-corner `uvMaps` block was added (UV-maps Stage 3); bumped to 5
/// when the optional per-layer `xform` block was added (per-item channels Phase
/// 1); bumped to 6 when the optional per-mesh `weightMaps` block was added
/// (per-vertex named weight maps, dim=1 Point domain). v5 and earlier files are
/// now rejected (deliberate clean break — no external clients, no migration).
enum int kV3dFormatVersion = 6;

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Serialize one `Mesh` to the shared `.v3d` "mesh" sub-object (vertices /
/// faces / subpatch / surfaces / faceMaterial / per-corner uvMaps). The same
/// codec serves every layer's mesh sub-object.
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

    // PolyVertex (per-corner) maps — v4 addition. Each registered PolyVertex
    // map is emitted as one `uvMaps` entry { name, dim, data }; `data` is the
    // flat float array in faces-as-written corner order (CSR loop order, D6).
    // The writer below emits `faces` and this block from the SAME mesh, so the
    // corner correspondence is implicit — no per-corner index in the JSON. v1
    // of the feature only ever has the "uv" map, but we write whatever
    // PolyVertex maps exist (forward-compatible for "uv2", …). Following the
    // codec's optional-array convention (faceSubpatch/faceMaterial are always
    // present), the key is omitted entirely when no PolyVertex map exists.
    JSONValue[] uvMaps;
    foreach (ref map; mesh.meshMaps) {
        if (map.domain != MapDomain.PolyVertex) continue;
        JSONValue uj;
        uj["name"] = JSONValue(map.name);
        uj["dim"]  = JSONValue(cast(long) map.dim);
        JSONValue[] data;
        data.reserve(map.data.length);
        foreach (f; map.data)
            data ~= JSONValue(f);
        uj["data"] = JSONValue(data);
        uvMaps ~= uj;
    }
    if (uvMaps.length > 0)
        m["uvMaps"] = JSONValue(uvMaps);

    // Point (per-vertex) dim-1 weight maps — v6 addition. Each registered
    // Point dim-1 map is emitted as { "name", "data":[w0,w1,...] }; `dim` is
    // implicit (always 1). Omitted entirely when no weight map exists.
    JSONValue[] wMaps;
    foreach (ref map; mesh.meshMaps) {
        if (map.domain != MapDomain.Point || map.dim != 1) continue;
        JSONValue wj;
        wj["name"] = JSONValue(map.name);
        JSONValue[] wdata;
        wdata.reserve(map.data.length);
        foreach (f; map.data)
            wdata ~= JSONValue(f);
        wj["data"] = JSONValue(wdata);
        wMaps ~= wj;
    }
    if (wMaps.length > 0)
        m["weightMaps"] = JSONValue(wMaps);

    return m;
}

/// Serialize a single `mesh` to a `.v3d` document at `path`. Wraps the mesh in
/// a one-layer document ("Layer 1", primary, selected) so single-mesh
/// callers (interchange flatten paths, ad-hoc saves) still produce a valid
/// file with exactly one mesh codec.
void writeV3d(ref const Mesh mesh, string path)
{
    auto doc = Document.bootstrap(cast(Mesh) mesh);
    writeV3d(doc, path);
}

/// Serialize a layer's item transform to the optional grouped `xform` block:
///   { "pos":[x,y,z], "rot":[x,y,z], "scl":[x,y,z], "pivot":[x,y,z] }
/// Hand-written from the four `Vec3` fields directly (the param provider exposes
/// flat scalar params; this codec is deliberately NOT a generic `params()` loop
/// — the grouped shape is the persisted form). Returns `false` (leaving `out`
/// untouched) when the transform is all-default (pos=0, rot=0, scl=1, pivot=0)
/// so the writer omits the key entirely, keeping default-transform docs
/// byte-clean.
private bool xformToJson(ref const ItemXform x, out JSONValue xj)
{
    // Default test: bit-exact against the identity authored channels. The
    // round-trip is float-text deterministic, so exact equality is correct here
    // (a layer that was never transformed compares equal and is omitted).
    if (x.pos   == Vec3(0, 0, 0) &&
        x.rot   == Vec3(0, 0, 0) &&
        x.scl   == Vec3(1, 1, 1) &&
        x.pivot == Vec3(0, 0, 0))
        return false;

    static JSONValue triple(ref const Vec3 v) {
        return JSONValue([JSONValue(v.x), JSONValue(v.y), JSONValue(v.z)]);
    }
    xj = JSONValue.init;
    xj["pos"]   = triple(x.pos);
    xj["rot"]   = triple(x.rot);
    xj["scl"]   = triple(x.scl);
    xj["pivot"] = triple(x.pivot);
    return true;
}

/// Serialize a whole `Document` (every layer + which layer is primary) to a
/// `.v3d` document at `path` under `formatVersion: 6`. Each layer persists its
/// `selected` flag (the item-selection SET); `primaryLayer` names the edit
/// target. There is NO `background` key (it derives from `visible && !selected`)
/// and NO `activeLayer` key (`primaryLayer` replaces it). Each layer also
/// persists its item transform as an OPTIONAL grouped `xform` block (omitted
/// when all-default — see `xformToJson`). Each layer's `mesh` sub-object goes
/// through the shared `meshToJson` codec.
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
        // v5: optional per-layer item transform. Hand-written from the four
        // `Vec3` fields (NOT a generic `params()` loop); omitted when default.
        JSONValue xj;
        if (xformToJson(layer.xform, xj))
            lj["xform"] = xj;
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
/// ONLY `formatVersion == kV3dFormatVersion` (v6) — every earlier shape
/// (v1/v2/v3/v4/v5) is rejected at the version gate (clean break, no migration).
/// A v6 file carries a `layers` array (each entry persisting its `selected` flag,
/// plus an optional `xform` item-transform block and an optional `weightMaps`
/// block per mesh) plus a `primaryLayer` index naming the edit target; the
/// reader re-asserts the selection-set invariants via the Document mutators
/// (`setActive` / `selectItem` / `setPrimary`), forcing the primary selected +
/// visible if the file is inconsistent. Returns false (logging via the io
/// subsystem, like importLWO) on a missing file, malformed JSON, a
/// `formatVersion` other than v6, structurally wrong content, an empty `layers`
/// array, or an out-of-range vertex index — and leaves the caller's `document`
/// UNTOUCHED in every reject case (all layers are parsed into a temporary before
/// the single atomic swap below).
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

        // Version gate (clean break). The reader accepts EXACTLY v6 — a newer
        // file we can't parse, OR a legacy v1/v2/v3/v4/v5 file, is rejected here
        // (the document is untouched). A missing `formatVersion` (the implicit v1
        // shape) is likewise rejected. Unknown fields WITHIN v6 are ignored.
        int ver = 0;   // 0 = "no formatVersion key" → not v4 → reject
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

        // --- a `layers` array is required (no top-level-mesh fallback). ---
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
            // v5: optional per-layer item transform. A missing block ⇒ identity
            // (the layer's `xform` stays at its default). Parsed tolerantly:
            // a malformed sub-array leaves that component at its identity
            // default and keeps loading (see readXform).
            if (auto xp = "xform" in lj)
                readXform(*xp, li, layer.xform);
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
/// every layer (the mesh shape is identical across layers).
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

    // --- optional: uvMaps (v4 per-corner PolyVertex maps) ---
    // Parse the well-formed entries into a staging list now; the actual map
    // values can only be APPLIED once `loops` exists (after `buildLoops`
    // below), since the PolyVertex domain is loop-keyed. Each staged entry's
    // `data` is in faces-as-written corner order == CSR loop order (D6), so the
    // length check `data.length == loops.length * dim` validates alignment and
    // the apply is a 1:1 slice copy (no per-corner index). Tolerant: a
    // wrong-dim / wrong-length / malformed entry is skipped WITH a warning so
    // the file still loads (just without that map) — never crash, never
    // misalign.
    struct StagedUv { string name; ubyte dim; float[] data; }
    StagedUv[] stagedUv;
    if (auto uvp = "uvMaps" in m) {
        if (uvp.type == JSONType.array) {
            foreach (ui, uj; uvp.array) {
                if (uj.type != JSONType.object) {
                    v3dWarn(format("ignoring uvMaps[%d]: not an object", ui));
                    continue;
                }
                // name (required, non-empty).
                string nm;
                if (auto np = "name" in uj)
                    if (np.type == JSONType.string) nm = np.str;
                if (nm.length == 0) {
                    v3dWarn(format("ignoring uvMaps[%d]: missing/empty name", ui));
                    continue;
                }
                // dim (required, >= 1).
                long dimL = 0;
                if (auto dp = "dim" in uj) {
                    if (dp.type == JSONType.integer)       dimL = dp.integer;
                    else if (dp.type == JSONType.uinteger) dimL = cast(long) dp.uinteger;
                }
                if (dimL < 1 || dimL > 255) {
                    v3dWarn(format("ignoring uvMaps[%s]: invalid dim %d", nm, dimL));
                    continue;
                }
                // data (required, flat float array).
                auto dap = "data" in uj;
                if (dap is null || dap.type != JSONType.array) {
                    v3dWarn(format("ignoring uvMaps[%s]: missing/non-array data", nm));
                    continue;
                }
                float[] data;
                data.reserve(dap.array.length);
                foreach (fj; dap.array)
                    data ~= jsonFloat(fj);
                stagedUv ~= StagedUv(nm, cast(ubyte) dimL, data);
            }
        } else {
            v3dWarn("ignoring non-array \"uvMaps\"");
        }
    }

    // --- optional: weightMaps (v6 per-vertex Point dim-1 maps) ---
    // Parse the well-formed entries into a staging list; applied after the
    // mesh is committed (vertices exist). Tolerant: wrong-length / malformed
    // entries are skipped with a warning, geometry still loads.
    struct StagedWm { string name; float[] data; }
    StagedWm[] stagedWm;
    if (auto wmp = "weightMaps" in m) {
        if (wmp.type == JSONType.array) {
            foreach (wi, wj; wmp.array) {
                if (wj.type != JSONType.object) {
                    v3dWarn(format("ignoring weightMaps[%d]: not an object", wi));
                    continue;
                }
                string nm;
                if (auto np = "name" in wj)
                    if (np.type == JSONType.string) nm = np.str;
                if (nm.length == 0) {
                    v3dWarn(format("ignoring weightMaps[%d]: missing/empty name", wi));
                    continue;
                }
                auto dap = "data" in wj;
                if (dap is null || dap.type != JSONType.array) {
                    v3dWarn(format("ignoring weightMaps[%s]: missing/non-array data", nm));
                    continue;
                }
                float[] data;
                data.reserve(dap.array.length);
                foreach (fj; dap.array)
                    data ~= jsonFloat(fj);
                stagedWm ~= StagedWm(nm, data);
            }
        } else {
            v3dWarn("ignoring non-array \"weightMaps\"");
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

    // Apply the staged PolyVertex (per-corner) maps now that `loops` exists.
    // `data` is in CSR loop order (D6), 1:1 with `mesh.loops`, so the alignment
    // check is `data.length == loops.length * dim` and the fill is a direct
    // slice copy — no per-corner re-keying. A wrong-length entry is skipped WITH
    // a warning (tolerant: the rest of the file is already committed). The
    // welded loop count rebuilt above (post degenerate-drop) is the authority a
    // misaligned hand-written map is measured against.
    int uvMapCount = 0;
    foreach (ref su; stagedUv) {
        const size_t want = mesh.loops.length * su.dim;
        if (su.data.length != want) {
            v3dWarn(format("ignoring uvMaps[%s]: data length %d != "
                            ~ "%d loops * %d dim", su.name, su.data.length,
                            mesh.loops.length, su.dim));
            continue;
        }
        auto map = mesh.addMeshMap(su.name, su.dim, MapDomain.PolyVertex);
        if (map is null) {
            // name clash with an already-staged map, or an empty-loop mesh.
            v3dWarn(format("ignoring uvMaps[%s]: could not register map", su.name));
            continue;
        }
        map.data[] = su.data[];   // corner order == loop order, 1:1
        ++uvMapCount;
    }

    // Apply staged Point dim-1 weight maps (v6). Each map must have exactly
    // `vertices.length` float entries. Mismatched lengths are skipped with a
    // warning; the rest of the mesh is already committed so the load continues.
    int wMapCount = 0;
    foreach (ref sw; stagedWm) {
        if (sw.data.length != mesh.vertices.length) {
            v3dWarn(format("ignoring weightMaps[%s]: data length %d != "
                           ~ "%d vertices", sw.name, sw.data.length,
                           mesh.vertices.length));
            continue;
        }
        auto map = mesh.addWeightMap(sw.name);
        if (map is null) {
            v3dWarn(format("ignoring weightMaps[%s]: could not register map",
                           sw.name));
            continue;
        }
        map.data[] = sw.data[];
        ++wMapCount;
    }

    v3dInfo(format("mesh ready: %d verts, %d edges, %d faces, "
                    ~ "%d marked subpatch, %d surfaces, %d uv map(s), "
                    ~ "%d weight map(s)",
                    mesh.vertices.length, mesh.edges.length,
                    mesh.faces.length, subpatchCount, mesh.surfaces.length,
                    uvMapCount, wMapCount));
    return true;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Parse a v5 per-layer `xform` block into `x`, TOLERANTLY (per the `uvMaps`
/// idiom: per-element validate / `v3dWarn` / keep going — never throw). Each of
/// the four fixed sub-arrays (`pos`/`rot`/`scl`/`pivot`) is independent: a
/// missing or malformed (non-array, < 3 entries, non-object root) sub-array
/// leaves that component at its identity default (`x` arrives default-
/// constructed from the caller), and the rest of the block still loads. So a
/// degenerate block degrades gracefully to identity-where-broken rather than
/// failing the load. `li` is the layer index, for diagnostics.
void readXform(const JSONValue xv, size_t li, ref ItemXform x)
{
    if (xv.type != JSONType.object) {
        v3dWarn(format("ignoring layer %d xform: not an object", li));
        return;
    }
    // Pull one [x,y,z] sub-array into `dst`, leaving it untouched (identity
    // default) on any malformed entry — warn + skip, never throw.
    void readTriple(string key, ref Vec3 dst) {
        auto p = key in xv;
        if (p is null) return;   // missing ⇒ keep identity default (no warning)
        if (p.type != JSONType.array || p.array.length < 3) {
            v3dWarn(format("ignoring layer %d xform.%s: not an [x,y,z] triple",
                            li, key));
            return;
        }
        dst = Vec3(jsonFloat(p.array[0]),
                   jsonFloat(p.array[1]),
                   jsonFloat(p.array[2]));
    }
    readTriple("pos",   x.pos);
    readTriple("rot",   x.rot);
    readTriple("scl",   x.scl);
    readTriple("pivot", x.pivot);
}

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
