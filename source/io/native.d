module io.native;

import std.file      : exists, read, write;
import std.json      : JSONValue, JSONType, parseJSON, JSONException;
import std.conv      : to;
import std.format    : format;

import mesh;
import math;
import document : Document, Layer, ItemXform, sanitizeItemXform,
                  MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG;
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
/// (per-vertex named weight maps, dim=1 Point domain); bumped to 7 when the
/// optional per-face `facePart` array was added (per-face numeric part id).
/// v6 and earlier files are now rejected (deliberate clean break — no migration).
enum int kV3dFormatVersion = 7;

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

    // Per-face part id (defaults to 0 when unset). Optional: omit when all 0.
    bool anyNonZeroPart = false;
    foreach (fi, _; mesh.faces)
        if (fi < mesh.facePart.length && mesh.facePart[fi] != 0u)
            { anyNonZeroPart = true; break; }
    if (anyNonZeroPart) {
        JSONValue[] facePrt;
        facePrt.reserve(mesh.faces.length);
        foreach (fi, _; mesh.faces) {
            const uint prt = (fi < mesh.facePart.length) ? mesh.facePart[fi] : 0u;
            facePrt ~= JSONValue(cast(long) prt);
        }
        m["facePart"] = JSONValue(facePrt);
    }

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
/// `.v3d` document at `path` under `formatVersion: 7`. Each layer persists its
/// `selected` flag (the item-selection SET); `primaryLayer` names the edit
/// target. There is NO `background` key (it derives from `visible && !selected`)
/// and NO `activeLayer` key (`primaryLayer` replaces it). Each layer also
/// persists its item transform as an OPTIONAL grouped `xform` block (omitted
/// when all-default — see `xformToJson`). Each layer's `mesh` sub-object goes
/// through the shared `meshToJson` codec.
///
/// Returns `true` when every layer in `document.layers` was written, `false`
/// when at least one non-mesh layer was SKIPPED (task 0615 Stage 6/7 review
/// round 2, should-fix 4). The file is still written successfully in the
/// `false` case — with whatever layers v7 CAN represent — but the on-disk
/// document no longer matches the in-memory one. A caller that tracks a
/// dirty/clean flag (`commands/file/save.d`'s `FileSave`) must not treat a
/// `false` return as "saved clean".
bool writeV3d(ref const Document document, string path)
{
    JSONValue doc;
    doc["formatVersion"] = JSONValue(kV3dFormatVersion);

    // Task 0615 (Stage 7 finding): v7 has no representation for a non-mesh
    // item — Stage 8/v8 (which would add a `"type"` token) is deferred to
    // task 0616 by owner decision (doc/nonmesh_item_types_plan.md). A
    // non-mesh layer only exists via this task's Stage 6/7 test-injection
    // path in this slice (no UI/command surface can create one), but the
    // WRITER must not crash if the live document holds one anyway —
    // `layer.meshRef()`'s `debug` assert would fire, exactly the crash
    // Stage 7's live mixed-document sweep hit. Skip the layer entirely
    // rather than write a `"mesh"`-less entry: the READER's own guard
    // (below, "mesh required") rejects the WHOLE file over one such entry,
    // which is worse than simply omitting the layer. `primaryLayer` is
    // written relative to THIS SAME filtered sequence, not the original
    // layer indices — otherwise a non-mesh layer positioned before the
    // primary would silently shift which layer loads back as primary.
    size_t primaryIdxOut = 0;
    bool skippedAny = false;
    JSONValue[] layers;
    layers.reserve(document.layers.length);
    foreach (ref const layer; document.layers) {
        if (!layer.hasMesh) {
            v3dWarn("skipping non-mesh layer \"" ~ layer.name
                ~ "\" — v7 cannot represent it (see task 0616)");
            skippedAny = true;
            continue;
        }
        if (layer is document.primary) primaryIdxOut = layers.length;
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
        lj["mesh"]     = meshToJson(layer.meshRef());
        layers ~= lj;
    }
    doc["primaryLayer"] = JSONValue(cast(long) primaryIdxOut);
    doc["layers"] = JSONValue(layers);

    // toPrettyString keeps the document human-readable + diff-able, matching
    // the format's design goal (source of truth, reviewable in git).
    write(path, doc.toPrettyString());
    return !skippedAny;
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Parse a `.v3d` document at `path` and rebuild a whole `Document`. Accepts
/// ONLY `formatVersion == kV3dFormatVersion` (v7) — every earlier shape
/// (v1/v2/v3/v4/v5/v6) is rejected at the version gate (clean break, no migration).
/// A v7 file carries a `layers` array (each entry persisting its `selected` flag,
/// plus an optional `xform` item-transform block and an optional `weightMaps`
/// block per mesh) plus a `primaryLayer` index naming the edit target; the
/// reader re-asserts the selection-set invariants via the Document mutators
/// (`setActive` / `selectItem` / `setPrimary`), forcing the primary selected +
/// visible if the file is inconsistent. Returns false (logging via the io
/// subsystem, like importLWO) on a missing file, malformed JSON, a
/// `formatVersion` other than v7, structurally wrong content, an empty `layers`
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

        // Version gate (clean break). The reader accepts EXACTLY v7 — a newer
        // file we can't parse, OR a legacy v1/v2/v3/v4/v5/v6 file, is rejected here
        // (the document is untouched). A missing `formatVersion` (the implicit v1
        // shape) is likewise rejected. Unknown fields WITHIN v7 are ignored.
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
            // v7 has no "type" key (Stage 8/v8 is out of scope for this task —
            // cancelled, see task 0616); every layer this reader builds is
            // mesh-kind (`Layer.kind` defaults to `ItemKind.Mesh`).
            if (!meshFromJson(*mp, layer.meshRef()))
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
        // (setActive enforces primary selected+visible; task 0615 NIT,
        // review round 2 — it no longer enforces exactly-one-selected in
        // general: naming a non-mesh `primaryIndex` here leaves the selected
        // set at exactly TWO, {that layer, the still-selected mesh primary}
        // — see document.d's exclusiveSelect/§L2. `parsed[primaryIndex]`
        // is still resolved to a mesh-kind layer by construction as of this
        // stage, so that case does not fire here yet; it is the exposure
        // L3/Stage 8 must close).
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

    // --- optional: facePart ---
    uint[] facePart;
    if (auto fpp = "facePart" in m) {
        if (fpp.type == JSONType.array) {
            facePart.reserve(fpp.array.length);
            foreach (pj; fpp.array) {
                if (pj.type == JSONType.uinteger)
                    facePart ~= cast(uint) pj.uinteger;
                else if (pj.type == JSONType.integer)
                    facePart ~= cast(uint) pj.integer;
                else
                    facePart ~= 0u;
            }
        } else {
            v3dWarn("ignoring non-array \"facePart\"");
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

    // Surfaces + per-face material + per-face part. Grow arrays to one entry per
    // face (entries beyond what the file listed default to 0).
    mesh.surfaces = surfaces;
    mesh.faceMaterial.length = mesh.faces.length;
    foreach (fi; 0 .. mesh.faces.length)
        mesh.faceMaterial[fi] = (fi < faceMaterial.length) ? faceMaterial[fi] : 0u;
    mesh.facePart.length = mesh.faces.length;
    foreach (fi; 0 .. mesh.faces.length)
        mesh.facePart[fi] = (fi < facePart.length) ? facePart[fi] : 0u;

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
///
/// The parsed block is then put through `document.sanitizeItemXform` (task 0614
/// Phase 5 review, B3). Tolerating a MALFORMED sub-array is not the same as
/// tolerating a well-formed but ILLEGAL value: `"scl":[0,1,1]` parses perfectly
/// and loads a singular `ItemXform`, exactly the state the R7 guard exists to
/// make impossible. `.v3d` is the NATIVE format, so it is the likeliest carrier
/// of such a value — a file written by an older build, hand-edited, or produced
/// by a tool that never saw the band. `ItemXform.init` is passed as the "prior"
/// value because a fresh load has none: a non-finite component therefore falls
/// back to its channel identity rather than to some other layer's number.
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

    // Enforce the R7 value policy on the loaded block. Warn when it fires: a
    // silent repair of a file the user wrote is a value change they should be
    // told about, and a stream of these is how a bad exporter gets found.
    ItemXform noPrior;                       // == ItemXform.init (identity)
    if (sanitizeItemXform(x, noPrior))
        v3dWarn(format("layer %d xform carried out-of-range values; clamped "
                     ~ "scale to [%g, %g] (sign preserved) and replaced any "
                     ~ "non-finite component with its identity",
                       li, MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG));
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

// ---------------------------------------------------------------------------
// Task 0615 Stage 7 (finding): `writeV3d(ref const Document, string)` used to
// call `layer.meshRef()` unconditionally for EVERY layer — v7 has no
// `"type"` concept at all, so nothing gated that call. Once a non-mesh layer
// became constructible (Stages 1-6), that was a live crash: `meshRef()`'s
// `debug` assert fires on a non-mesh layer, and the Stage 7 mixed-document
// sweep hit it via a plain File > Save. The fix skips non-mesh layers (with
// a warning) and recomputes `primaryLayer` relative to the FILTERED
// sequence actually written, not the original layer indices — this
// in-module test pins both halves: no crash, and a non-mesh layer sitting
// BEFORE the primary in `document.layers` must not shift which layer loads
// back as primary.
// ---------------------------------------------------------------------------
unittest {
    import std.file   : tempDir, remove, exists;
    import std.path   : buildPath;
    import std.format : format;
    import std.random : uniform;
    import mesh        : makeCube;
    import document     : ItemKind;

    auto path = buildPath(tempDir(),
        format("vibe3d_native_ut_%d.v3d", uniform(0, int.max)));
    scope(exit) if (exists(path)) remove(path);

    // [Empty(non-mesh), MeshA(primary), MeshB] — the primary sits BEFORE
    // another mesh layer, not at the end of `document.layers` (task 0615
    // Stage 6/7 review round 2, should-fix 3). With the primary LAST (the
    // original fixture here), the READER's out-of-range clamp
    // (`primaryIndex` clamped into `[0, parsed.length-1]`, above) happens to
    // land on the right layer even under the UNFIXED writer — which wrote
    // the raw, pre-filter `document.activeIndex` (2) — because clamping 2
    // into the filtered 2-entry range also yields 1. That fixture could not
    // tell the fixed writer from the buggy one. Here the buggy write (raw
    // index 1, already in-range for a 2-entry output — no clamp kicks in)
    // loads MeshB; the fixed write (index 0, relative to the FILTERED
    // output) loads MeshA. RED before the fix, GREEN after.
    auto doc = Document.bootstrap(makeCube());     // "Layer 1" == MeshA
    auto meshA = doc.layers[0];
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB"; meshB.meshRef() = makeCube();
    doc.layers = [empty, meshA, meshB];
    doc.setActive(1);                              // MeshA stays primary (index 1)
    assert(doc.primary is meshA);

    // Writing must not crash (the `debug` assert this used to trip). It must
    // also report the skip via its return value (should-fix 4) — a caller
    // that gates a dirty/clean flag on this return must see `false` here.
    assert(!writeV3d(doc, path),
        "writeV3d must report false: the Empty layer was skipped");

    // Round-trip: the reader only ever produces mesh-kind layers (v7 has no
    // `"type"`), so the loaded document has exactly the two MESH layers, in
    // their relative order, and the primary is correctly MeshA — NOT
    // shifted onto MeshB by the dropped Empty layer.
    Document loaded;
    assert(readV3d(path, loaded), "round-trip load must succeed");
    assert(loaded.layers.length == 2,
        "the non-mesh layer is dropped; only the 2 mesh layers survive");
    assert(loaded.layers[0].name == "Layer 1", "MeshA kept its bootstrap name");
    assert(loaded.layers[1].name == "MeshB");
    assert(loaded.primary is loaded.layers[0],
        "primaryLayer must be written relative to the FILTERED sequence — "
        ~ "MeshA is output index 0, not its original index 1 (the unfixed "
        ~ "writer would have emitted the raw index 1 and loaded MeshB instead)");
    assert(loaded.primary.hasMesh);
}

// ---------------------------------------------------------------------------
// Task 0614 Phase 5 review, B3: the `.v3d` reader is a WRITE PATH into
// `ItemXform.scl` and must enforce the R7 band like every other one.
//
// `"scl":[0,1,1]` is not malformed — it parses perfectly and used to load a
// SINGULAR `ItemXform`, precisely the state the guard exists to prevent. And
// `.v3d` is the NATIVE format, so it is the likeliest carrier of a poisoned
// value: a file from a build that predates the guard, a hand edit, an exporter
// that never saw the band. Enforcing the band on the two command paths and the
// gesture kernel but not here makes the invalid state rare instead of
// impossible.
//
// THE PRECONDITION THAT KEEPS THIS TEST HONEST: it asserts the on-disk JSON
// really carries the degenerate numbers before loading them. The fixture gets
// them onto disk through `writeV3d` (the writer has no band of its own, by
// design — it persists what the document holds), so if a band is ever added to
// the WRITER this case would silently start testing a clean file and prove
// nothing about the reader. The precondition fails loudly instead.
//
// The rig is displaced and rotated off every axis so "the reader restored the
// value" and "the reader reset the channel to its identity" read different
// numbers — at pos=0/rot=0 they read the same and the case would pass either
// way.
// ---------------------------------------------------------------------------
unittest {
    import std.file   : tempDir, remove, exists, readText;
    import std.path   : buildPath;
    import std.format : format;
    import std.random : uniform;
    import std.math   : isFinite, fabs;
    import mesh       : makeCube;

    auto path = buildPath(tempDir(),
        format("vibe3d_native_scl_ut_%d.v3d", uniform(0, int.max)));
    scope(exit) if (exists(path)) remove(path);

    auto doc = Document.bootstrap(makeCube());
    auto l   = doc.layers[0];
    l.xform.pos   = Vec3(1.3f, 0.7f, -0.9f);
    l.xform.rot   = Vec3(20f, 35f, -50f);
    l.xform.pivot = Vec3(0.25f, -0.4f, 0.6f);
    // x: dead zero (singular). y: NEGATIVE and under the floor — a mirror must
    // survive the repair as a mirror. z: finite but absurd — the ceiling.
    l.xform.scl   = Vec3(0.0f, -1e-9f, 1e30f);

    assert(writeV3d(doc, path), "fixture write must succeed");

    // Precondition: the degenerate numbers really are on disk.
    {
        auto raw = parseJSON(readText(path));
        auto s   = raw["layers"].array[0]["xform"]["scl"].array;
        assert(jsonFloat(s[0]) == 0.0f,
            "precondition: the file must literally carry scl.x == 0 — if the "
          ~ "WRITER has grown a band, this case is now loading a clean file "
          ~ "and pins nothing about the reader");
        assert(jsonFloat(s[1]) < 0.0f && fabs(jsonFloat(s[1])) < MIN_ITEM_SCALE_MAG,
            "precondition: scl.y is on disk as a negative under-floor value");
        assert(jsonFloat(s[2]) > MAX_ITEM_SCALE_MAG,
            "precondition: scl.z is on disk as an over-ceiling value");
    }

    Document loaded;
    assert(readV3d(path, loaded), "load must succeed — a repair is not a reject");
    auto x = loaded.layers[0].xform;

    assert(x.scl.x == MIN_ITEM_SCALE_MAG,
        "a zero scale in a .v3d must load as the POSITIVE floor, not as 0 — "
      ~ "0 loads a singular ItemXform whose composedMatrix() cannot be "
      ~ "inverted, poisoning the action centre, the axis basis, every snap "
      ~ "frame and the next export. Got " ~ x.scl.x.to!string);
    assert(x.scl.y == -MIN_ITEM_SCALE_MAG,
        "a negative under-floor scale must load as the NEGATIVE floor: the "
      ~ "band caps the MAGNITUDE and a mirror is a legal item transform, so a "
      ~ "repair that clamps to +floor silently un-mirrors the item. Got "
      ~ x.scl.y.to!string);
    assert(x.scl.z == MAX_ITEM_SCALE_MAG,
        "an over-ceiling scale must load capped: finite on disk, but it "
      ~ "overflows to infinity at the first matrix product. Got "
      ~ x.scl.z.to!string);

    // The repair is per-component and must not normalise the rest of the rig
    // on its way past. (Exact equality: the JSON round-trip is float-text
    // deterministic — this is the same basis xformToJson's default test uses.)
    assert(x.pos   == Vec3(1.3f, 0.7f, -0.9f),   "pos survives the repair");
    assert(x.rot   == Vec3(20f, 35f, -50f),      "rot survives the repair");
    assert(x.pivot == Vec3(0.25f, -0.4f, 0.6f),  "pivot survives the repair");

    // The property the band is actually for.
    auto m = x.composedMatrix();
    foreach (v; m) assert(isFinite(v), "the repaired xform composes finitely");
    immutable float det = m[0] * (m[5]*m[10] - m[6]*m[9])
                        - m[4] * (m[1]*m[10] - m[2]*m[9])
                        + m[8] * (m[1]*m[6]  - m[2]*m[5]);
    assert(det != 0.0f && isFinite(det),
        "and to an INVERTIBLE one — the whole point of the floor");
    assert(x.modelSpace().invertible,
        "the picking-facing ModelSpace agrees: a loaded document can never "
      ~ "present a non-invertible item transform");
}

// ---------------------------------------------------------------------------
// Task 0614 Phase 7 — the `.v3d` item-transform round-trip, enumerated PER
// FIELD and PER ITEM KIND rather than sampled.
//
// What already exists and what this adds. `test_layer_xform_io.d` drives
// LOAD -> SAVE (a hand-written file re-emitted, compared at 1e-6); the band
// case above drives SAVE -> LOAD but only to prove the REPAIR. Neither one
// answers the question a user actually has: I dialled a transform in, I
// saved, I re-opened — is what I get back the same item? That needs
// SAVE -> LOAD compared BIT-EXACTLY on all twelve channels, and it needs the
// answer for the things that are NOT channels: a non-mesh item, and the
// parent link.
//
// THE FIXTURE IS THE TEST. A serialiser bug is only visible if the numbers
// separate the wrong implementations from the right one, so the fixture is
// chosen against a named list of them and the separation is ASSERTED, not
// asserted-by-comment:
//   * every one of the twelve numbers differs from its channel identity
//     (0/0/1/0)  -> a dropped field reads a different number;
//   * the twelve are pairwise distinct in magnitude  -> a swapped pair
//     (pos<->pivot, x<->z, rot<->scl) reads a different number;
//   * `rot` has no zero and no multiple of 90        -> a permuted euler
//     triple composes to a different matrix (asserted below), which a
//     90-degree or single-axis rotation would NOT;
//   * `scl` is non-uniform and one component is NEGATIVE -> a serialiser
//     that writes a magnitude, or a single uniform factor, reads different
//     numbers;
//   * `pivot` is non-zero AND the pose is rotated+scaled -> dropping the
//     pivot changes the composed matrix (asserted below), which at
//     rot=0/scl=1 it would NOT (T(p)·I·T(-p) == I for any p).
// Bit-exactness is a legitimate bar, not an aspiration: `float` widens to
// `double` in `JSONValue`, std.json prints a double with enough digits to
// re-read it exactly, and the narrowing back to `float` is then exact.
//
// The two NON-channel answers this pins are LOSSES, and they are asserted as
// losses on purpose: the day either one is fixed, this test goes red and
// names the USAGE.md paragraph that has to change with it.
// ---------------------------------------------------------------------------
unittest {
    import std.file   : tempDir, remove, exists;
    import std.path   : buildPath;
    import std.format : format;
    import std.random : uniform;
    import std.math   : fabs, fmod;
    import mesh       : makeCube;
    import document   : ItemKind;

    auto path = buildPath(tempDir(),
        format("vibe3d_native_xform_rt_%d.v3d", uniform(0, int.max)));
    scope(exit) if (exists(path)) remove(path);

    // --- the fixture --------------------------------------------------------
    ItemXform src;
    src.pos   = Vec3( 1.3f,  -0.7f,   2.9f);
    src.rot   = Vec3(17.3f, -43.7f,  61.1f);   // no 0, no multiple of 90
    src.scl   = Vec3( 2.5f,   0.4f,  -1.75f);  // non-uniform, one mirror
    src.pivot = Vec3(-0.35f,  0.85f,  1.15f);

    // --- and the PROOF that the fixture discriminates -----------------------
    {
        immutable float[12] c = [src.pos.x, src.pos.y, src.pos.z,
                                 src.rot.x, src.rot.y, src.rot.z,
                                 src.scl.x, src.scl.y, src.scl.z,
                                 src.pivot.x, src.pivot.y, src.pivot.z];
        immutable float[12] identity = [0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0];
        foreach (i; 0 .. 12)
            assert(c[i] != identity[i],
                "fixture: channel " ~ i.to!string ~ " must differ from its "
              ~ "identity or a serialiser that DROPS it still passes");
        foreach (i; 0 .. 12)
            foreach (j; i + 1 .. 12)
                assert(fabs(c[i]) != fabs(c[j]),
                    "fixture: channels " ~ i.to!string ~ "/" ~ j.to!string
                  ~ " share a magnitude — a serialiser that swaps them "
                  ~ "still passes");
        foreach (v; [src.rot.x, src.rot.y, src.rot.z])
            assert(fmod(fabs(v), 90.0f) != 0.0f,
                "fixture: a multiple of 90 degrees makes the euler ORDER "
              ~ "unobservable in the composed matrix");

        // Euler order is observable AT THIS TRIPLE: reversing it composes to a
        // different rotation. (It would not for a single-axis rotation.)
        auto rA = matrixFromEulerZYX(src.rot);
        auto rB = matrixFromEulerZYX(Vec3(src.rot.z, src.rot.y, src.rot.x));
        bool orderMatters = false;
        foreach (i; 0 .. 16) if (fabs(rA[i] - rB[i]) > 1e-4f) orderMatters = true;
        assert(orderMatters,
            "fixture: this rot triple must be order-sensitive, else a codec "
          ~ "that reverses the components is invisible");

        // The pivot is load-bearing AT THIS POSE: zeroing it moves the item.
        ItemXform noPivot = src;
        noPivot.pivot = Vec3(0, 0, 0);
        auto mA = src.composedMatrix(), mB = noPivot.composedMatrix();
        bool pivotMatters = false;
        foreach (i; 0 .. 16) if (fabs(mA[i] - mB[i]) > 1e-4f) pivotMatters = true;
        assert(pivotMatters,
            "fixture: dropping the pivot must change the composed matrix, "
          ~ "else the pivot assertions below are decoration");
    }

    // --- the document: a mesh item, a NON-MESH item, and a PARENTED item ----
    auto doc  = Document.bootstrap(makeCube());
    auto A    = doc.layers[0];
    A.name    = "A";
    A.xform   = src;

    auto E    = new Layer;
    E.name    = "E";
    E.kind    = ItemKind.Empty;
    E.xform.pos = Vec3(9.5f, -8.5f, 7.5f);   // a transform-only item, dialled in

    auto C    = new Layer;
    C.name    = "C";
    C.meshRef() = makeCube();
    C.parent  = A;

    doc.layers = [A, E, C];
    doc.setActive(0);
    assert(doc.primary is A,           "setup: A is the primary");
    assert(C.parent is A,              "setup: C really is parented to A — "
        ~ "without this the parent-drop assertion below is vacuous");
    assert(E.kind == ItemKind.Empty,   "setup: E really is a non-mesh item");

    // v7 cannot represent a non-mesh item, so the write is INCOMPLETE by
    // contract (this is the same `false` the FileSave dirty-flag gate reads).
    assert(!writeV3d(doc, path),
        "a document holding a non-mesh item cannot be written completely");

    Document loaded;
    assert(readV3d(path, loaded), "round-trip load must succeed");

    // === WHAT SURVIVES: all twelve channels, BIT-EXACT ======================
    auto got = loaded.layers[0].xform;
    assert(got.pos.x   == src.pos.x   && got.pos.y   == src.pos.y
        && got.pos.z   == src.pos.z,   "pos must round-trip bit-exact, got "
        ~ got.pos.x.to!string ~ "," ~ got.pos.y.to!string ~ "," ~ got.pos.z.to!string);
    assert(got.rot.x   == src.rot.x   && got.rot.y   == src.rot.y
        && got.rot.z   == src.rot.z,   "rot must round-trip bit-exact (DEGREES, "
        ~ "ZYX order), got " ~ got.rot.x.to!string ~ "," ~ got.rot.y.to!string
        ~ "," ~ got.rot.z.to!string);
    assert(got.scl.x   == src.scl.x   && got.scl.y   == src.scl.y
        && got.scl.z   == src.scl.z,   "scl must round-trip bit-exact INCLUDING "
        ~ "the negative (mirror) component, got " ~ got.scl.x.to!string ~ ","
        ~ got.scl.y.to!string ~ "," ~ got.scl.z.to!string);
    assert(got.pivot.x == src.pivot.x && got.pivot.y == src.pivot.y
        && got.pivot.z == src.pivot.z, "pivot must round-trip bit-exact, got "
        ~ got.pivot.x.to!string ~ "," ~ got.pivot.y.to!string ~ ","
        ~ got.pivot.z.to!string);

    // The observable that follows from the four: the item lands in the same
    // place. Implied by the channel equalities TODAY (the composed matrix is a
    // pure function of them) — kept because it is the property a user cares
    // about, and it survives a future codec that persists a matrix instead.
    assert(loaded.layers[0].xform.composedMatrix() == src.composedMatrix(),
        "the composed world matrix must be identical after a round-trip");

    // === WHAT DOES NOT SURVIVE #1: a non-mesh item, and its transform =======
    assert(loaded.layers.length == 2,
        "v7 has no representation for a non-mesh item: the Empty item is "
      ~ "DROPPED, not written as an empty mesh — got "
      ~ loaded.layers.length.to!string ~ " layers");
    foreach (l; loaded.layers) {
        assert(l.kind == ItemKind.Mesh,
            "every layer a v7 file can produce is mesh-kind");
        assert(l.name != "E",
            "the Empty item must not come back under any kind — its item "
          ~ "transform (9.5,-8.5,7.5) went with it. If this ever fails, the "
          ~ "format grew a type token and USAGE.md's `.v3d` note must change");
    }

    // === WHAT DOES NOT SURVIVE #2: the item PARENT link =====================
    assert(loaded.layers[1].name == "C", "sanity: layer 1 is the parented item");
    assert(loaded.layers[1].parent is null,
        "v7 persists no parent key, so the link is dropped silently on save. "
      ~ "This assertion documents a LOSS: if it fails, parenting became "
      ~ "persistent and USAGE.md's `.v3d` note must change with it. Got parent="
      ~ loaded.layers[1].parent.name);

    // === Deliberately NOT asserted here: the item-selection FOCUS ===========
    // v7 persists no focus key, so focus is re-derived on load (`readV3d`
    // ends with `setPrimary`, whose `focusedItem = l` homes it on the
    // primary). That is a traced fact, not a testable loss: `Document`
    // maintains `focusedItem is primary` for an ALL-MESH document, and an
    // all-mesh document is the only thing a v7 file can hold — the two
    // answers "restored from the file" and "re-derived onto the primary"
    // coincide, so any assertion here would pass against either. Focus can
    // only diverge from the primary while a NON-MESH item is focused, and
    // that item does not survive the save at all (above).
}
