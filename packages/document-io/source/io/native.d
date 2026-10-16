module io.native;

import std.file      : exists, read, write;
import std.json      : JSONValue, JSONType, parseJSON, JSONException;
import std.conv      : to;
import std.format    : format;
import std.algorithm : sort;

import vibe3d.mesh.core.mesh;
static import mesh_ = vibe3d.mesh.core.mesh;   // disambiguates mesh.kindInfo(MapKind) from document.kindInfo(LayerKind)
import math;
import vibe3d.util.spatial.spatial : ModelSpace;
import vibe3d.documents.model.document : Document, Layer, ItemXform, sanitizeItemXform,
                  MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG,
                  ItemKind, ImageData, ImagePlaneData,
                  kindInfo, kindFromToken, tokenOf;
import layer_params : LayerPropsProvider;
import vibe3d.editing.params.params   : Param, paramToJson, injectParamsTolerant;
import io.image_path : storePathFor, resolveStoredPath, refreshImageMeta;
import vibe3d.editing.contracts.seltype  : SelMode;
import vibe3d.util.log.log : logWarn, logInfo;
import vibe3d.mesh.core.mesh_selsets : selSetNamesVertex, selSetNamesEdge, selSetNamesPolygon,
    selSetMembersVertex, selSetMembersEdge, selSetMembersPolygon,
    selSetEditVertex, selSetEditEdge, selSetEditPolygon, SetEditMode,
    validateSetName;

// Diagnostics for the native reader funnel through the "io" log subsystem.
// The "V3D" label stays in the message body so the .v3d origin is still
// visible in the `[io] V3D: …` echo. Levels: structural rejects and tolerant
// "ignoring …" notices are warnings; the path/ready status lines are info.
private void v3dWarn(string msg) nothrow { try logWarn("io", "V3D: " ~ msg); catch (Exception) {} }
private void v3dInfo(string msg) nothrow { try logInfo("io", "V3D: " ~ msg); catch (Exception) {} }

// ---------------------------------------------------------------------------
// WHY THE REJECT REASON IS KEPT AND NOT MERELY LOGGED (review B1).
//
// `log.d` has exactly one sink — a stderr echo. There is no log panel and no
// toast, and the only non-test `addLogListener` in the tree is a test's own.
// So a reader that says WHY it refused and then only logs it has told nobody:
// a user who opens a pre-v8 document from the File menu would watch the editor
// do nothing at all, which is precisely the "hunting a corruption that isn't
// there" the version-gate wording exists to prevent.
//
// The reason therefore has to survive the call and reach a caller that can put
// it in front of someone. `FileLoad` picks it up here and answers it from
// `Command.refusalReason()`, which `app.d`'s dispatch funnel turns into the
// HTTP error text AND (through `runCommand`) a modal notice.
//
// THREAD-LOCAL, deliberately: a plain module variable in D is TLS, and every
// read of it happens on the same thread and the same call stack that produced
// it (`FileLoad.apply` → `readV3d` → back in `FileLoad.apply`). There is
// nothing shared here, so there is nothing to lock and no cross-thread
// interleaving to reason about.
private string g_v3dRejectReason;

/// WHY the last `readV3d` on THIS thread returned false, as one user-readable
/// sentence — the same text the log carries, minus the `reject: ` tag. Empty
/// after a load that succeeded (`readV3d` clears it on entry).
///
/// Read it immediately after a `false` return: the next `readV3d` overwrites
/// it.
string lastV3dRejectReason() { return g_v3dRejectReason; }

// Refuse the load: remember the reason for the caller AND log it. Every
// `return false` in `readV3d` (and in the mesh codec it calls) goes through
// here, so "the reader refused without saying why" is not a reachable state.
// The `reject: ` tag is added for the LOG only — it is grep bait, not a
// sentence a user should be shown.
private void v3dReject(string msg) nothrow { g_v3dRejectReason = msg; v3dWarn("reject: " ~ msg); }

// ---------------------------------------------------------------------------
// Native .v3d document format (JSON)
// ---------------------------------------------------------------------------
// `.v3d` is vibe3d's own document format — the source of truth. Unlike the
// LWO bridge in io/lwo_import.d + io/lwo_export.d (a lossy interchange
// format) it round-trips the full
// editor model: vertices, n-gon faces, per-face subpatch flags, the surface
// registry and per-face material indices.
//
// ===========================================================================
// v8 schema — task 0616 Ph6. THE CHAIN'S SINGLE VERSION STEP.
// ===========================================================================
//
// Owner decision (doc/tasks/work/0616-image-clip-list.md, 2026-08-08): ONE
// version bump for the whole chain of tasks, not one per task. v8 is therefore
// designed for EVERY item kind at once — mesh, empty, image, and the
// reference-image item a later task adds — even though the last one's code
// does not exist yet.
//
// **THE CHECK THAT THIS WAS DONE RIGHT, stated here because this is where the
// next reader will look: after that later task lands, `kV3dFormatVersion` must
// STILL BE 8.** It adds channels to its item's param provider and they
// serialise with no codec change, because `channels` below is generic. If
// anyone finds themselves bumping the version to store an item's channels,
// something has gone wrong with THIS design, not with theirs.
//
//   {
//     "formatVersion": 8,
//     "primaryLayer": 0,          // index into layers[] — the MESH EDIT TARGET
//     "focusedItem":  2,          // index into layers[] — the item-selection FOCUS
//     "layers": [
//       { "type":     "mesh",     // wire token (tokenOf / kindFromToken)
//         "selected": true,       // the item-selection SET
//         "parent":   0,          // index into layers[]; omitted when none
//         "links":    [ { "slot": "maskImage", "target": 3 } ],
//         "channels": { "name": "Layer 1", "visible": true,
//                       "pos.x": 0, ... "pivot.z": 0 },
//         "mesh":     { /* the mesh sub-object below */ }   // iff hasMesh
//       },
//       { "type": "image", "selected": false,
//         "channels": { "name": "logo", "visible": true,
//                       "colorspace": "(default)", "useAlpha": true },
//         "image":    { "filename": "../assets/logo.png" }  // iff hasImage
//       }
//     ]
//   }
//
// SEVEN DECISIONS, each with the alternative it beat.
//
// 1. `channels` IS THE ITEM'S WHOLE AUTHORED PARAM SET, written in full and
//    read back generically through `paramToJson` / `injectParamsInto`. There
//    is NO key list anywhere in this codec. `name`, `visible` and the twelve
//    transform components are IN there — they are already params
//    (`layer_params.d`), and keeping them as top-level keys as well would be
//    two sources of truth for the same value. v5's grouped `xform` block and
//    its hand-written four-`Vec3` codec are GONE for the same reason.
//    Cost, paid deliberately: every `.v3d` fixture in the test suite had to be
//    rewritten. Benefit: a future item kind's channels serialise with zero
//    lines of codec, which is the property the owner's one-bump rule needs.
//
// 2. A `readonly_` param is NOT authored through the generic path in EITHER
//    direction — the writer skips it and the reader strips it before
//    injecting. `injectParamsInto` is a generic typed-pointer writer that does
//    not consult the flag itself, so a read-only channel left in the block
//    would be written straight through on load, behind whatever command owns
//    it. `LayerAttr` already refuses a readonly write for exactly this reason;
//    this is the same rule at the file boundary.
//    CONSEQUENCE, and the reason `"image"` exists as its own block: an image
//    item's `filename` IS `.readonly()` (it may only be authored by
//    `image.replace`, which owns the resolve + refresh), so it cannot ride
//    `channels` — yet it is the single most important thing about the item.
//    A readonly param that is ALSO persistent state needs a block of its own.
//    That is the price of the flag, and `"image"` is it.
//
// 3. THE WRITER WRITES EVERY ITEM, UNFILTERED. v7 skipped non-mesh layers and
//    renumbered `primaryLayer` against the filtered sequence; v8 does not, and
//    `writeV3d` therefore always returns `true`. **This is a PRECONDITION, not
//    a preference** — see decision 4.
//
// 4. `parent` AND `links` ARE STORED AS INDICES INTO `layers[]`, resolved back
//    to objects after the whole file is parsed. That is a wire ENCODING of the
//    identity those references already use (the `Layer` OBJECT — see
//    `document.d`'s link header), not a second identity scheme, and it is
//    injective ONLY BECAUSE decision 3 holds: if the writer ever filters the
//    item list again, index ↔ object stops being a bijection and every stored
//    reference past the hole silently names its NEIGHBOUR. At that point a
//    per-item stable id becomes necessary. Until then it is not.
//    **A DANGLING LINK CANNOT SURVIVE THE WIRE.** A target that is no longer a
//    document member has no index, so the slot is dropped and the link reads
//    `Unset` — not `Dangling` — after a round trip. This is an honest property
//    of the index encoding and it is deliberately NOT papered over with a
//    sentinel index or a tombstone entry (either would be the second identity
//    scheme decision 4 depends on not existing). It does partially retract one
//    of the three reasons the link design gives for keeping dangling links:
//    "deleted carries strictly more information than never-set" is true in
//    memory and false across a save.
//
// 5. `focusedItem` PERSISTS, and a `primaryLayer` naming an item that cannot be
//    the edit target is CORRECTED, not obeyed and not rejected: the reader
//    re-homes to the first `canBePrimary` item and leaves focus where the file
//    put it. A file with NO `canBePrimary` item at all IS rejected — the
//    `Document` invariants have no representable answer for it. v7 could not
//    hit this because its reader only ever produced mesh-kind layers; the
//    `"type"` token is what makes it reachable, so v8 is where it is closed.
//
// 6. CHANNEL INJECTION HAPPENS BEFORE THE ATOMIC SWAP, and the outer catch is
//    `Exception`, not `JSONException`. `injectParamsInto` THROWS a plain
//    `Exception` on an unknown enum tag, a non-string for a String param and a
//    malformed Vec3. Without both halves, a bad channel value would either
//    escape `readV3d` entirely or leave the caller's document half-committed —
//    the codec's stated "a reject leaves your document untouched" guarantee
//    holds only if nothing can throw after `document.layers = parsed`.
//
// 7. INJECT, THEN RUN THE MUTATOR PASS — the ORDER is load-bearing. `visible`
//    is deliberately not writable through `layer.attr`, because hiding the
//    primary has to promote a replacement; a generic `channels` injection
//    bypasses that hook by construction. It is safe here ONLY because the
//    post-parse mutator pass re-asserts the invariants and force-shows a
//    hidden primary afterwards. Stated as a rule so it is not mistaken for an
//    accident of where the code was pasted.
//
// There is NO `background` key — `background(l) == l.visible && !l.selected`
// derives at runtime, so the file persists `selected` alone. There is NO
// `activeLayer` key — `primaryLayer` indexes the primary (edit-target) layer,
// which the reader forces selected + visible.
//
// `image` (v8) carries the image item's payload: `filename`, in the STORED
// form — relative to the document when the file sits beside it or in its
// parent, absolute otherwise (`io/image_path.d` owns the rule and both
// directions of it). The codec never has to know that a channel is a path,
// because the path is not a channel.
//
// The shared "mesh" sub-object:
//   {
//     "vertices":     [[x,y,z], ...],
//     "faces":        [[i,j,k,...], ...],          // n-gon, vertex indices
//     "wireEdges":    [[a,b], ...],                // optional (task 3910);
//                                                    // explicitly authored pairs
//     "faceSubpatch": [bool, ...],                 // optional; default false
//     "faceMaterial": [uint, ...],                 // optional; default 0
//     "surfaces":     [{ "name", "baseColor":[r,g,b],
//                        "diffuse", "specular", "glossiness", "opacity" }, ...],
//     "uvMaps":       [{ "name", "dim", "data":[u0,v0, u1,v1, ...] }, ...]
//                                                  // optional (v4+); per-corner
//     "weightMaps":   [{ "name", "data":[w0,w1,...] }, ...]
//                                                  // optional (v6+); per-vertex
//     "edgeMaps":     [{ "kind", "name", "data":[s0,s1,...] }, ...]
//                                                  // optional (task 1062); per-edge
//     "vertexMorphs": [{ "kind", "name",
//                        "verts":[i,...], "values":[x,y,z, ...] }, ...]
//                                                  // optional (task 1069); per-vertex,
//                                                  // dim 3, SPARSE
//   }
//
// `wireEdges` serializes authorship, not a recomputed set of currently
// face-less pairs. That keeps ordinary face-built/imported meshes at zero
// entries and preserves an authored pair even when a face also covers it.
// Pretty-printed cost measured for task 3910: about 153 bytes for the first
// entry and 104 bytes per additional four-digit pair; an arc pays that cost
// for its actual wire content, while a cube/grid pays no key at all.
//
// `vertexMorphs` (task 1069 addition, kV3dFormatVersion NOT bumped — the same
// within-version tolerance `edgeMaps` and `selectionSets` rode) carries
// `MapDomain.Point` dim-3 MORPH maps. Two things about its shape are
// load-bearing rather than stylistic:
//
//   * It is SPARSE. `verts` lists exactly the vertices that HAVE an entry and
//     `values` carries three floats each (`values.length == verts.length * 3`).
//     In memory the map is dense with a parallel presence channel; a dense
//     wire form would collapse "no entry" into "entry == 0", which for the
//     ABSOLUTE kind is the difference between "stay at the base" and
//     "teleport to the origin".
//   * `kind` ("relative" | "absolute") is REQUIRED, because it cannot be
//     inferred. Both kinds are Point/dim-3 and neither reserves a name, so
//     neither of this codec's two identification mechanisms — the reserved
//     name and the declared shape — can tell them apart. An entry with an
//     unrecognised kind is skipped with a warning rather than guessed at.
//
// The reader range-checks every listed index against `vertices.length` and
// skips an out-of-range one with a warning, keeping the rest of the map: a
// `.v3d` is untrusted input and these indices address a dense array directly.
// The key is omitted entirely when the mesh has no morph map.
//
// Note the hazard this block closes: `weightMaps` above skips any Point map
// with `dim != 1`, so before `vertexMorphs` existed a dim-3 Point map was
// silently not saved at all.
//
// `edgeMaps` (task 1062 addition, kV3dFormatVersion NOT bumped — see the
// "8 IS MEANT TO STAY 8" note below) carries `MapDomain.Edge` dim-1 maps.
// Today's one producer is the reserved subdivision crease-weight channel
// (`kind: "creaseWeight"`, name `"crease"`); the block is written/read
// generically the same way `weightMaps` is, so a future user-authored edge
// map round-trips alongside it. `data.length` must equal `edges.length`
// (edge index space is settled by `buildLoops`/`rebuildEdges` before this
// applies — see edge_weight_plan.md §0 П4 for why that index is stable
// across a save/reload with no intervening topology edit). Values round-trip
// VERBATIM, including out-of-range ones — this codec does not clamp; the
// clamp lives solely in subpatch_osd.creaseSharpnessFromWeight. Omitted
// entirely when no Edge map exists.
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
// accepts EXACTLY `formatVersion == kV3dFormatVersion`. Every earlier shape is
// no longer parsed; they are rejected cleanly at the version gate, leaving the
// caller's document untouched. There is NO migration code. The v7 → v8 break
// is the widest one so far (`name` / `visible` / `xform` all moved into
// `channels`), and it was taken knowingly: the owner accepted that every file
// saved until now stops opening, in exchange for one read path instead of two.
//
// THE REJECTION MESSAGE IS PART OF THE CONTRACT. It must name the FILE's
// version and the EDITOR's, and say the file is not damaged. "Could not open"
// reads as corruption and sends the user hunting a problem that does not
// exist — the file is fine, it is simply a different revision of a format
// that does not convert.
//
// The reader stays tolerant WITHIN the current version: unknown fields are
// ignored and missing optional fields default sensibly, so the format can keep
// growing (editor state, Shader Tree) without another break.

/// The schema version the writer emits and the ONLY version the reader accepts.
/// Was 3 when item-selection persistence (`selected` + `primaryLayer`) landed;
/// 4 when the per-corner `uvMaps` block was added (UV-maps Stage 3); bumped to 5
/// when the optional per-layer `xform` block was added (per-item channels Phase
/// 1); bumped to 6 when the optional per-mesh `weightMaps` block was added
/// (per-vertex named weight maps, dim=1 Point domain); bumped to 7 when the
/// optional per-face `facePart` array was added (per-face numeric part id);
/// bumped to 8 by task 0616 Ph6 — the item `"type"` token, the generic
/// `channels` block (which absorbed `name` / `visible` / `xform`), the
/// `"image"` payload, `parent`, `links` and `focusedItem`.
///
/// **8 IS MEANT TO STAY 8** across the rest of this chain — see the v8 schema
/// note above. A later task filling in an item kind's channels must not need a
/// bump; if it does, this design failed.
/// v7 and earlier files are now rejected (deliberate clean break — no migration).
///
/// Confirmed still true at task 1062 (the `edgeMaps` block) and task 1060
/// (the `selectionSets` block, this comment's own addition): both landed as
/// ADDITIVE OPTIONAL keys under the within-version tolerance rule stated
/// above — a v8 reader ignores them when absent, a v8 writer omits them when
/// empty — exactly the growth "8 stays 8" was written to cover. Neither task
/// bumped the constant.
enum int kV3dFormatVersion = 8;

// ---------------------------------------------------------------------------
// The Surface sub-codec, as a descriptor table (task 0720, audit №4 D8).
//
// D8's framing was "33 keys described twice". Measured, the mesh codec has 16
// distinct key literals and every one of them appears exactly twice, once in
// `meshToJson` and once in `meshFromJson` — and the two sides agree today.
// For the mesh-level keys that duplication is cosmetic: the only way it can go
// wrong is a rename on one side, and a rename on one side breaks the .v3d
// round-trip, which `tests/test_native_v3d.d` asserts on every run. Making
// them share a constant would remove no risk that a test does not already
// hold, so they are left alone.
//
// The SURFACE sub-object is a different case, and it is the one worth a table.
// Its JSON names are the short editor names and its struct fields are the
// verbose ones (`diffuse` → `diffuseAmount`), so the mapping is real and lived
// in a comment. More to the point, NOTHING relates the set of keys to the set
// of fields: add a field to `Surface` and the codec silently does not carry
// it, the round-trip test still passes (both sides default it), and the loss
// only shows up as a user's material coming back wrong.
//
// That is not hypothetical. `Surface.compiledFromTreeId` exists today and the
// codec has never carried it. It is not a live bug — nothing in the tree ever
// writes that field, so there is nothing to lose yet — but it is exactly the
// shape of the defect, sitting in the code with every test green.
//
// The table below is therefore checked against `Surface.tupleof`: every field
// must appear exactly once, and a field the format deliberately does not carry
// must say so with an empty JSON name rather than by being absent. Adding a
// field to `Surface` now fails the build until someone decides which it is.
// ---------------------------------------------------------------------------
private struct SurfaceField {
    string json;    // key in the .v3d surface object; "" = deliberately not carried
    string field;   // member of `Surface`
}

private enum SurfaceField[] kSurfaceFields = [
    SurfaceField("name",       "name"),
    SurfaceField("baseColor",  "baseColor"),
    SurfaceField("diffuse",    "diffuseAmount"),
    SurfaceField("specular",   "specularAmount"),
    SurfaceField("glossiness", "glossiness"),
    SurfaceField("opacity",    "opacity"),
    // Smoothing (additive optional keys; an absent key reads `Surface.init`).
    // The angle is in DEGREES, as the struct stores it.
    SurfaceField("smoothing",      "smoothing"),
    SurfaceField("smoothingAngle", "smoothingAngleDeg"),
    // Sidedness (additive optional key, a JSON boolean; absent → false).
    SurfaceField("twoSided",    "twoSided"),
    // Not carried by the format — decided, not deferred (task 0762).
    // `compiledFromTreeId` is a forward-compat hook for the shader tree (see
    // mesh.d): it is only meaningful paired with the ShaderTree graph it
    // points into, and `.v3d` does not store that graph. A bare id with no
    // graph behind it would be a dangling reference the next reader could
    // not resolve, so persisting the id ALONE would not preserve anything —
    // it would just move the loss from "field is empty" to "field points at
    // nothing". `grep compiledFromTreeId` finds exactly its declaration: no
    // code writes it today, so nothing is lost by this in practice either.
    // The obligation for whoever adds the writer: land the ShaderTree graph
    // codec and this field's key in the SAME change, and bump
    // kV3dFormatVersion with it — see the reproduction unittest below.
    SurfaceField("",           "compiledFromTreeId"),
];

private string surfaceCodecProblem() {
    foreach (i, a; kSurfaceFields) {
        bool onSurface = false;
        static foreach (m; __traits(allMembers, Surface))
            if (m == a.field) onSurface = true;
        if (!onSurface)
            return "kSurfaceFields names " ~ a.field ~ ", which Surface does not have";
        foreach (b; kSurfaceFields[i + 1 .. $]) {
            if (a.field == b.field)
                return "kSurfaceFields lists " ~ a.field ~ " twice";
            if (a.json.length && a.json == b.json)
                return "kSurfaceFields maps two fields onto the key " ~ a.json;
        }
    }
    static foreach (i, _; Surface.tupleof) {{
        enum n = __traits(identifier, Surface.tupleof[i]);
        bool covered = false;
        foreach (k; kSurfaceFields) if (k.field == n) covered = true;
        if (!covered)
            return "Surface." ~ n ~ " has no row in kSurfaceFields — give it a"
                 ~ " key, or an empty key to say the format does not carry it";
    }}
    return null;
}

static assert(surfaceCodecProblem() is null, surfaceCodecProblem());

// Task 6930: morph indices stay in their signed wire domain until both bounds
// are proved; only then may the reader narrow one to the platform index width.
private bool morphVertexIndexInBounds(long vertexIndex, size_t vertexCount)
        pure nothrow @safe
{
    return vertexIndex >= 0 && vertexIndex < cast(long) vertexCount;
}

unittest
{
    assert(morphVertexIndexInBounds(1, 2), "the last valid morph index is accepted");
    assert(!morphVertexIndexInBounds(-1, 2), "a negative morph index is rejected");
    assert(!morphVertexIndexInBounds(2, 2), "the vertex-count boundary is rejected");
    assert(!morphVertexIndexInBounds((1L << 32) + 1, 2),
        "a 64-bit wire index must be rejected before platform-width narrowing");
}

// Task 0762 — reproduce the loss the decision above is about, so it stays a
// measured fact rather than a claim in a comment. A populated
// `compiledFromTreeId` does NOT survive a `meshToJson`/`meshFromJson`
// round-trip: `kSurfaceFields` gives it an empty JSON key, so the writer
// skips it and the reader leaves the field at `Surface.init`. If a future
// change starts writing this field without also giving it a key here, this
// is the test that turns that silent loss into a red assertion instead of a
// material coming back wrong after a save/load cycle.
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    Mesh m = makeCube();
    Surface s;
    s.compiledFromTreeId = "tree-42";
    m.surfaces ~= s;

    Mesh back;
    assert(meshFromJson(meshToJson(m), back));
    assert(back.surfaces.length == 1);
    assert(back.surfaces[0].compiledFromTreeId == "",
           "compiledFromTreeId round-tripped — kSurfaceFields and this test "
           ~ "must be updated together (task 0762)");
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Serialize one `Mesh` to the shared `.v3d` "mesh" sub-object (vertices /
/// faces / subpatch / surfaces / faceMaterial / per-corner uvMaps). The same
/// codec serves every layer's mesh sub-object.
/// Pre-flight for `meshToJson`: the index and component name of the first
/// vertex component that is not a finite number, or `-1` in `vi` when the
/// mesh is clean.
///
/// WHY IT EXISTS (task 1550). `JSONValue(float.infinity).toString()` THROWS
/// ("Cannot encode Infinity"), so the `.v3d` writer already failed loudly on a
/// corrupt mesh rather than writing a file that is not JSON — which is the
/// right half of the behaviour and is why this task does not change it. What
/// it did not do is say WHICH vertex, and a std.json exception surfacing from
/// a save is not a message anyone can act on. This names the vertex before a
/// single byte is written.
///
/// The two halves of 1550 pull in opposite directions ON PURPOSE: `/api/model`
/// is a DIAGNOSTIC read that must stay readable when the mesh is broken, so it
/// prints `null` and reports a count; `.v3d` is the document of record, where
/// a silent hole would be a lie about what the user saved, so it refuses.
void firstNonFiniteVertex(ref const Mesh mesh, out long vi, out string comp)
{
    import std.math : isFinite;
    vi = -1;
    foreach (i, v; mesh.vertices) {
        if (!isFinite(v.x)) { vi = cast(long) i; comp = "x"; return; }
        if (!isFinite(v.y)) { vi = cast(long) i; comp = "y"; return; }
        if (!isFinite(v.z)) { vi = cast(long) i; comp = "z"; return; }
    }
}

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

    // Authored edges are sparse state: omit the key for ordinary face-built
    // meshes. Sort the AA keys so save -> load -> save is byte-stable and does
    // not inherit associative-array or live-edge iteration order.
    if (mesh.wireEdgeKeys.length != 0) {
        JSONValue[] wires;
        auto keys = mesh.wireEdgeKeys.keys;
        sort(keys);
        wires.reserve(keys.length);
        foreach (key; keys)
            wires ~= JSONValue([JSONValue(cast(long)(key >> 32)),
                                JSONValue(cast(long)(key & 0xFFFF_FFFFUL))]);
        m["wireEdges"] = JSONValue(wires);
    }

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

    // Surface registry. Both directions are generated from `kSurfaceFields`,
    // which is where the short-editor-name ↔ verbose-struct-field mapping
    // lives and which is checked against `Surface.tupleof` at compile time.
    JSONValue[] surfaces;
    surfaces.reserve(mesh.surfaces.length);
    foreach (ref s; mesh.surfaces) {
        JSONValue sj;
        static foreach (k; kSurfaceFields) {{
            static if (k.json.length) {
                alias F = typeof(__traits(getMember, Surface, k.field));
                static if (is(F == string) || is(F == float) || is(F == bool))
                    sj[k.json] = JSONValue(__traits(getMember, s, k.field));
                else static if (is(F == Vec3)) {
                    const c = __traits(getMember, s, k.field);
                    sj[k.json] = JSONValue([
                        JSONValue(c.x), JSONValue(c.y), JSONValue(c.z)]);
                } else
                    static assert(false, "no .v3d surface codec for "
                                       ~ F.stringof ~ " (" ~ k.field ~ ")");
            }
        }}
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

    // Edge (dim-1) maps — task 1062 addition. Today the only producer is the
    // reserved subdivision crease-weight channel (source/mesh.d,
    // MapKind.creaseWeight, name kCreaseWeightMapName == "crease"), but the
    // block is written generically off `MapDomain.Edge` the same way
    // `weightMaps` is written generically off `MapDomain.Point` — a future
    // user-authored edge map would ride the same wire shape. `data` is the
    // FULL dense array in canonical face-then-authored-pair order, zero or
    // not — this codec
    // never prunes a zero entry (checked 2026-08-17: the reference's crease
    // map type has no zero default, so "never touched" and "explicitly 0"
    // are distinct THERE; ours is a dense MeshMap like every other one, so
    // preserving every entry verbatim — never collapsing a zero away — is
    // what keeps the round trip from losing anything that wasn't already
    // collapsed in memory; see the long comment on Mesh.edgeCreaseWeight).
    // `kind` carries the reserved map's identity so a future user-authored
    // edge map (dim/domain matching but a different name) round-trips
    // alongside it without ambiguity. Omitted entirely when no Edge map
    // exists, matching uvMaps/weightMaps' optional-array convention.
    JSONValue[] eMaps;
    const edgeOrder = mesh.canonicalEdgeOrder();
    bool identityEdgeOrder = edgeOrder.length == mesh.edges.length;
    if (identityEdgeOrder)
        foreach (i, ei; edgeOrder)
            if (ei != i) { identityEdgeOrder = false; break; }
    foreach (ref map; mesh.meshMaps) {
        if (map.domain != MapDomain.Edge || map.dim != 1) continue;
        JSONValue ej;
        ej["kind"] = JSONValue(map.name == kCreaseWeightMapName
                                 ? "creaseWeight" : "");
        ej["name"] = JSONValue(map.name);
        JSONValue[] edata;
        edata.reserve(edgeOrder.length);
        if (identityEdgeOrder && map.data.length == edgeOrder.length) {
            foreach (f; map.data) edata ~= JSONValue(f);
        } else {
            foreach (ei; edgeOrder)
                edata ~= JSONValue(ei < map.data.length ? map.data[ei] : 0.0f);
        }
        ej["data"] = JSONValue(edata);
        eMaps ~= ej;
    }
    if (eMaps.length > 0)
        m["edgeMaps"] = JSONValue(eMaps);

    // Point (per-vertex) dim-3 MORPH maps — task 1069, an ADDITIVE key inside
    // format version 8 (the same within-version tolerance `edgeMaps` and
    // `selectionSets` rode; see the "8 IS MEANT TO STAY 8" note above).
    //
    // The key is `vertexMorphs`, NOT the name a reader reaches for by analogy
    // with uvMaps/weightMaps/edgeMaps — that natural name is a banned symbol
    // (neutrality dictionary), which was checked BEFORE this block was written
    // rather than after (task 1062's lesson).
    //
    // SPARSE ON THE WIRE. In memory a morph map is dense like every other
    // MeshMap, with a parallel presence channel; here only the PRESENT entries
    // are emitted, as two parallel arrays. That is not a size optimisation —
    // it is the only way the file can carry the distinction the presence
    // channel exists for. A dense emission would make "this vertex has no
    // entry" indistinguishable from "this vertex's entry is zero", which for
    // the ABSOLUTE kind is the difference between "stay at the base" and
    // "teleport to the origin".
    //
    // `kind` is written because it CANNOT be inferred: both morph kinds are
    // Point/dim-3 and neither reserves a name, so name and shape — the only
    // two mechanisms this codec has — cannot tell them apart.
    JSONValue[] vMorphs;
    foreach (ref map; mesh.meshMaps) {
        if (!isMorphKind(map.kind)) continue;
        JSONValue mj;
        mj["kind"] = JSONValue(map.kind == MapKind.morphRelative
                                 ? "relative" : "absolute");
        mj["name"] = JSONValue(map.name);
        JSONValue[] mvVerts, mvValues;
        const size_t n = map.data.length / 3;
        foreach (i; 0 .. n) {
            if (!map.isPresent(i)) continue;
            mvVerts  ~= JSONValue(cast(long) i);
            mvValues ~= JSONValue(map.data[i * 3]);
            mvValues ~= JSONValue(map.data[i * 3 + 1]);
            mvValues ~= JSONValue(map.data[i * 3 + 2]);
        }
        mj["verts"]  = JSONValue(mvVerts);
        mj["values"] = JSONValue(mvValues);
        vMorphs ~= mj;
    }
    if (vMorphs.length > 0)
        m["vertexMorphs"] = JSONValue(vMorphs);

    // Selection sets (task 1060 addition, kV3dFormatVersion NOT bumped — the
    // SAME within-version-tolerance rule `edgeMaps` above rode; see the "8 IS
    // MEANT TO STAY 8" note above). One optional key per domain, each an
    // array of `{name, members}`; the whole `selectionSets` object is
    // omitted when all three domains are empty, matching every other
    // optional-array convention in this codec.
    //
    // Edge members are VERTEX-INDEX PAIRS (`[a,b]`), never an edge index —
    // this is the load-bearing half of the storage decision
    // (mesh_selsets.d's doc comment / doc/selection_sets_plan.md §Q1.3/§Q2):
    // an edge index is invalidated by every topology edit and by any change in
    // canonical face/authored-pair order, while a vertex pair degrades
    // gracefully (the entry vanishes with its vertex rather than silently
    // reattaching to an unrelated edge).
    JSONValue[] ssVertexArr, ssEdgeArr, ssPolygonArr;
    foreach (nm; selSetNamesVertex(mesh)) {
        JSONValue sj;
        sj["name"] = JSONValue(nm);
        JSONValue[] mem;
        foreach (vi; selSetMembersVertex(mesh, nm)) mem ~= JSONValue(cast(long) vi);
        sj["members"] = JSONValue(mem);
        ssVertexArr ~= sj;
    }
    foreach (nm; selSetNamesEdge(mesh)) {
        JSONValue sj;
        sj["name"] = JSONValue(nm);
        JSONValue[] mem;
        foreach (pr; selSetMembersEdge(mesh, nm))
            mem ~= JSONValue([JSONValue(cast(long) pr[0]), JSONValue(cast(long) pr[1])]);
        sj["members"] = JSONValue(mem);
        ssEdgeArr ~= sj;
    }
    foreach (nm; selSetNamesPolygon(mesh)) {
        JSONValue sj;
        sj["name"] = JSONValue(nm);
        JSONValue[] mem;
        foreach (fi; selSetMembersPolygon(mesh, nm)) mem ~= JSONValue(cast(long) fi);
        sj["members"] = JSONValue(mem);
        ssPolygonArr ~= sj;
    }
    if (ssVertexArr.length > 0 || ssEdgeArr.length > 0 || ssPolygonArr.length > 0) {
        JSONValue ssj;
        ssj["vertex"]  = JSONValue(ssVertexArr);
        ssj["edge"]    = JSONValue(ssEdgeArr);
        ssj["polygon"] = JSONValue(ssPolygonArr);
        m["selectionSets"] = ssj;
    }

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

/// Serialize one item's AUTHORED channel set — the whole of
/// `LayerPropsProvider.params()` minus the `readonly_` ones (decision 2).
///
/// There is deliberately no key list here: whatever the provider exposes for
/// that kind is what the file carries, which is what lets a future kind's
/// channels ride this codec unchanged (decision 1).
///
/// The const-cast is contained and read-only. The provider binds `Param`
/// pointers to the layer's fields, which needs a MUTABLE `Layer`; every use
/// below is `paramToJson`, which only reads through them. Dropping `const`
/// from `writeV3d`'s signature instead would give up a guarantee its callers
/// deserve — saving a document does not change it.
private JSONValue channelsToJson(const(Layer) layer)
{
    auto prov = new LayerPropsProvider(cast(Layer) layer);
    JSONValue cj = JSONValue(cast(JSONValue[string]) null);
    foreach (ref p; prov.params()) {
        if (p.readonly_) continue;
        cj[p.name] = channelToJson(p, layer);
    }
    return cj;
}

/// One channel's JSON value, GUARANTEED to be a value this codec's own reader
/// will accept (review S2).
///
/// THE HOLE THIS CLOSES. `paramToJson` is a general-purpose value formatter,
/// and for the two enum kinds it is deliberately lenient in a way that a FILE
/// FORMAT cannot afford:
///
///   * `Kind.Enum` writes `*p.sptr` verbatim, with no check that the live
///     string is one of the param's declared tags;
///   * `Kind.IntEnum` has an explicit documented fallback — an unmatched live
///     value is written as a RAW INTEGER.
///
/// `injectParamsTolerant` — the reader's only channel writer — THROWS on both,
/// and that throw is caught by `readV3d`'s outer backstop, which rejects the
/// WHOLE DOCUMENT. Its tolerance (task 3150) covers the NUMERIC gate only and
/// deliberately stops short of the two enum kinds, for the reason the next
/// paragraph gives: dropping an unreadable NUMBER costs one channel, while
/// dropping an undeclared TAG would silently rewrite a foreign document. So a value that never went through a validating write path (a
/// direct field assignment, a D enum member with no table entry) would produce
/// a file that saves without complaint and then cannot be opened. Task 0616
/// Ph6's own N5 fixture (1) is precisely such a file, hand-written; nothing
/// makes one today, but the first `IntEnum` item channel would.
///
/// WHY THE WRITE SIDE AND NOT A TOLERANT READER. The reader's reject is a
/// deliberate, tested contract (N5): a channel value this build does not
/// understand must not be silently turned into one that it does — that is how
/// a foreign or hand-edited document gets quietly rewritten. Loosening it
/// would delete the only guard on the way in, to compensate for a defect on
/// the way out. And `paramToJson` itself is NOT the place either: its leniency
/// is load-bearing for `tool.attr ?` queries, which must report the live value
/// as it is rather than a laundered one. The invariant being enforced —
/// "everything this codec writes, this codec reads" — belongs to the codec.
///
/// The substitute is the param's DECLARED DEFAULT, which is by construction a
/// value the reader accepts, and the substitution is logged with both values
/// so the loss is visible rather than silent.
private JSONValue channelToJson(ref const Param p, const(Layer) layer)
{
    // Both arms answer the same question the reader asks — "is this tag one of
    // the declared ones" — and both fall back through the DECLARED DEFAULT to
    // the FIRST declared entry, because a default that is itself undeclared
    // would reproduce the bug one level down. A param with no declared values
    // at all has nothing acceptable to write and is left to `paramToJson`.
    if (p.kind == Param.Kind.Enum && p.enumValues.length > 0) {
        bool has(string tag) {
            foreach (ref e; p.enumValues) if (e[0] == tag) return true;
            return false;
        }
        if (!has(*p.sptr)) {
            immutable tag = has(p.default_.s) ? p.default_.s : p.enumValues[0][0];
            v3dWarn(format("item \"%s\": channel \"%s\" holds \"%s\", which is "
                ~ "not one of its declared values; writing \"%s\" instead — "
                ~ "the file has to stay readable, and this reader rejects a "
                ~ "whole document over one unknown channel tag",
                layer.name, p.name, *p.sptr, tag));
            return JSONValue(tag);
        }
    } else if (p.kind == Param.Kind.IntEnum && p.intEnumValues.length > 0) {
        bool has(int v) {
            foreach (ref e; p.intEnumValues) if (e.value == v) return true;
            return false;
        }
        if (!has(*p.iePtr)) {
            // Written by TAG, never as a raw integer: the raw-int form is
            // exactly the shape the reader refuses when it matches no entry,
            // so re-emitting a number would only move the problem.
            string tag = p.intEnumValues[0].wireTag;
            foreach (ref e; p.intEnumValues)
                if (e.value == p.default_.i) { tag = e.wireTag; break; }
            v3dWarn(format("item \"%s\": channel \"%s\" holds the undeclared "
                ~ "value %d; writing \"%s\" instead — a raw integer matching "
                ~ "no entry is rejected on load, and it takes the whole "
                ~ "document with it",
                layer.name, p.name, *p.iePtr, tag));
            return JSONValue(tag);
        }
    }
    return paramToJson(p);
}

/// Serialize an image item's payload block: the filename in its STORED form,
/// derived against the document being written (`io/image_path.d`).
///
/// A payload that was never constructed writes an empty filename rather than
/// nothing at all, so the block's shape does not depend on how the item was
/// created — the reader treats "" as "names no file" and marks it missing.
private JSONValue imageToJson(const(ImageData) img, string docPath)
{
    JSONValue ij;
    ij["filename"] = JSONValue(
        img is null ? "" : storePathFor(img.storedPath, docPath));
    return ij;
}

/// Serialize a whole `Document` — EVERY item, unfiltered — to a `.v3d`
/// document at `path` under `formatVersion: 8`.
///
/// Per item: its kind `"type"` token, its `selected` flag (the item-selection
/// SET), its `parent` and `links` as indices into `layers[]`, its whole
/// authored `channels` set, and its payload block (`mesh` when `hasMesh`,
/// `image` when `hasImage`). `primaryLayer` names the mesh edit target and
/// `focusedItem` the item-selection focus. There is NO `background` key (it
/// derives from `visible && !selected`) and NO `activeLayer` key.
///
/// **UNFILTERED IS A PRECONDITION, NOT A STYLE CHOICE.** `parent` and `links`
/// encode their target as its INDEX in the array written here, so the mapping
/// index ↔ object must be total and injective. v7 skipped the layers it could
/// not represent and renumbered `primaryLayer` around them; if that ever comes
/// back, every stored reference past a hole silently names its neighbour, and
/// a per-item stable id becomes necessary before it does.
///
/// Returns `false`, WITHOUT WRITING ANYTHING, if the emitted array would not
/// be a position-for-position image of `document.layers` — see the enforced
/// check in the loop below. Its caller (`commands/file/save.d`'s `FileSave`)
/// gates the dirty-flag rebaseline on the result, so a refused write leaves
/// the document dirty rather than pretending it was saved.
///
/// The check is an `if`, NOT an `assert`: every shipped binary is built
/// `--build=release` (the two AppImage scripts, the macOS bundle script and
/// both CI release jobs), and `-release` strips plain asserts entirely. An
/// assert here would have been dev-only enforcement of the one precondition
/// whose violation silently re-points every stored reference.
bool writeV3d(ref const Document document, string path)
{
    JSONValue doc;
    doc["formatVersion"] = JSONValue(kV3dFormatVersion);

    JSONValue[] layers;
    layers.reserve(document.layers.length);
    foreach (li, layer; document.layers) {
        // THE PRECONDITION, CHECKED WHERE IT IS ESTABLISHED. Every reference
        // in this file (`parent`, `links`, `primaryLayer`, `focusedItem`) is
        // encoded as `document.indexOf(target)` — an index into
        // `document.layers` — while the reader resolves it against the array
        // written HERE. Those two are the same numbering only while this loop
        // emits item `li` at array position `li`. A comparison of the two
        // LENGTHS at the end would accept a write that dropped one item and
        // duplicated another; this compares the position of the item about to
        // be appended against its own document index, which is what the
        // encoding actually depends on.
        if (layers.length != li) {
            v3dWarn(format("refusing to write %s: item %d would land at "
                ~ "position %d in the file. `parent`/`links`/`primaryLayer` "
                ~ "are indices into this array, so a write that skips or "
                ~ "reorders an item re-points every reference past the hole "
                ~ "at its neighbour. Nothing was written.",
                path, li, layers.length));
            return false;
        }

        JSONValue lj;
        lj["type"]     = JSONValue(tokenOf(layer.kind));
        lj["selected"] = JSONValue(layer.selected);

        // --- parent: an index, omitted when unset ---------------------------
        if (layer.parent !is null) {
            const pi = document.indexOf(layer.parent);
            if (pi < document.layers.length)
                lj["parent"] = JSONValue(cast(long) pi);
            else
                v3dWarn(format("layer %d (\"%s\"): parent is not an item of "
                    ~ "this document — the link cannot be encoded and is "
                    ~ "dropped", li, layer.name));
        }

        // --- links: an ARRAY, in `linkSlots()`'s canonical order -------------
        // An array rather than a JSON object because a `JSONValue` object is a
        // D associative array: its key order is a hash order, so the same
        // document would not produce the same bytes twice and the canonical
        // (name-sorted) order the link list maintains would be thrown away at
        // the last step. `.v3d` is meant to be diffable in git.
        //
        // A DANGLING target has no index and is therefore DROPPED — after a
        // round trip that link reads `Unset`, not `Dangling`. Deliberate; see
        // decision 4. No sentinel, no tombstone.
        JSONValue[] slots;
        foreach (ref s; layer.linkSlots()) {
            const ti = document.indexOf(s.link.targetUnchecked());
            if (ti >= document.layers.length) {
                v3dWarn(format("layer %d (\"%s\"): link slot \"%s\" points at "
                    ~ "an item that is no longer in this document; the slot is "
                    ~ "dropped (a dangling link cannot be encoded as an index)",
                    li, layer.name, s.name));
                continue;
            }
            JSONValue e;
            e["slot"]   = JSONValue(s.name);
            e["target"] = JSONValue(cast(long) ti);
            slots ~= e;
        }
        if (slots.length > 0) lj["links"] = JSONValue(slots);

        // --- channels: the whole authored param set, no key list ------------
        lj["channels"] = channelsToJson(layer);

        // --- payload blocks, one per payload capability ---------------------
        // Pre-flight (task 1550): name the offending vertex BEFORE std.json
        // throws its own "Cannot encode Infinity" from somewhere inside the
        // encoder, where nothing identifies the mesh, the layer or the index.
        //
        // IT THROWS, and that is the point of the phase. The old failure was
        // already HONEST — std.json refused, `writeV3d` propagated, the
        // command bridge turned the exception into `{"status":"error"}` and
        // no file appeared. Only the message was useless. Returning `false`
        // here instead would have downgraded that to a silent `{"status":
        // "ok"}` with the file merely absent (`FileSave` threads the return
        // value into the dirty flag, not into its own result), i.e. it would
        // have traded a bad message for a lost failure. Measured, not
        // assumed: source/http_server.d's command bridge is the `catch
        // (Exception e) { resp.error = e.msg; }` that makes this visible.
        if (layer.hasMesh) {
            long nfVert; string nfComp;
            firstNonFiniteVertex(layer.meshRef(), nfVert, nfComp);
            if (nfVert >= 0)
                throw new Exception(format("refusing to write %s: item %d "
                    ~ "(\"%s\") vertex %d component %s is not finite, and a "
                    ~ "non-finite number has no JSON encoding. Nothing was "
                    ~ "written.", path, li, layer.name, nfVert, nfComp));
        }
        if (layer.hasMesh)  lj["mesh"]  = meshToJson(layer.meshRef());
        if (layer.hasImage) lj["image"] = imageToJson(layer.imageOrNull(), path);

        layers ~= lj;
    }
    // The tail half of the same precondition: the per-item check above cannot
    // see an item dropped AFTER the last emitted one (a `break`, or a loop
    // that stopped one short), because there is no later iteration to catch
    // the position drift.
    if (layers.length != document.layers.length) {
        v3dWarn(format("refusing to write %s: the document holds %d item(s) "
            ~ "but only %d reached the file, so every stored index is now a "
            ~ "reference to a different item. Nothing was written.",
            path, document.layers.length, layers.length));
        return false;
    }

    // TASK 0654 — `primaryLayer: -1` means "the item selection is empty".
    //
    // The key's domain widens; the schema version does NOT bump (v8 "is meant
    // to stay 8" — see the version constant). This is a value inside an
    // existing key, and the reader's own contract is to stay tolerant within a
    // version. Every layer's `selected` is already written per-item, so the
    // empty set is representable without -1; -1 is what distinguishes it from
    // "selection lost" — a reader seeing all-false `selected` with
    // `primaryLayer: 0` cannot tell an emptied document from a malformed one,
    // and would repair the second by selecting layer 0, i.e. by silently
    // undoing the first.
    doc["primaryLayer"] = JSONValue(document.hasEditTarget()
        ? cast(long) document.activeIndex : -1L);
    // `focusedItem` is a document invariant (always a member), but a Document
    // caught mid-assembly by a direct field write may not satisfy it yet, and
    // writing `layers.length` as an index would be a reject on the way back in.
    const fi = document.indexOf(document.focusedItem);
    if (fi < document.layers.length)
        doc["focusedItem"] = JSONValue(cast(long) fi);
    doc["layers"] = JSONValue(layers);

    // toPrettyString keeps the document human-readable + diff-able, matching
    // the format's design goal (source of truth, reviewable in git).
    write(path, doc.toPrettyString());
    return true;
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Parse a `.v3d` document at `path` and rebuild a whole `Document`. Accepts
/// ONLY `formatVersion == kV3dFormatVersion` (v8) — every earlier shape is
/// rejected at the version gate (clean break, no migration), with a message
/// that names both versions and says the file is not damaged.
///
/// A v8 file carries a `layers` array (each entry: a `"type"` token, its
/// `selected` flag, optional `parent` / `links` indices, its authored
/// `channels`, and a payload block per capability) plus `primaryLayer` and
/// `focusedItem` indices. The reader re-asserts the selection-set invariants
/// via the Document mutators (`setActive` / `selectItem` / `setPrimary`),
/// forcing the primary selected + visible if the file is inconsistent, and
/// re-homing the primary when the file names an item that cannot be one.
///
/// Returns false (logging via the io subsystem, like importLWO) on a missing
/// file, malformed JSON, an unsupported `formatVersion`, an unknown item type
/// token, structurally wrong content, an empty `layers` array, a document with
/// no possible edit target, an out-of-range vertex index, or a channel value
/// the param codec refuses — and leaves the caller's `document` UNTOUCHED in
/// every reject case (everything is parsed and injected into a temporary
/// before the single atomic swap below).
bool readV3d(string path, ref Document document)
{
    v3dInfo(format("readV3d: path=%s", path));

    // Clear FIRST: `lastV3dRejectReason()` describes THIS call, and a stale
    // sentence left by a previous load would be read as this one's.
    g_v3dRejectReason = "";

    if (!exists(path)) {
        v3dReject(format("there is no file at %s", path));
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
            v3dReject(format("malformed JSON: %s", e.msg));
            return false;
        }

        if (doc.type != JSONType.object) {
            v3dReject("top-level value is not a JSON object");
            return false;
        }

        // Version gate (clean break). The reader accepts EXACTLY v8; anything
        // else is rejected here and the caller's document is untouched.
        //
        // THE WORDING IS PART OF THE CONTRACT (task 0616 Ph6, owner). Each
        // branch names the FILE's version AND this build's, and says the file
        // is not damaged. A bare "could not open" would send the user looking
        // for corruption that is not there — the commonest reason to land
        // here is simply a document written before the v8 break, and there is
        // no migration by design.
        int ver = 0;   // 0 = "no formatVersion key" → not v8 → reject
        if (auto vp = "formatVersion" in doc) {
            if (vp.type == JSONType.integer)
                ver = cast(int) vp.integer;
            else {
                v3dReject("\"formatVersion\" is present but is not an "
                    ~ "integer, so this file cannot be identified as a .v3d "
                    ~ "document of any version");
                return false;
            }
        }
        if (ver != kV3dFormatVersion) {
            if (ver == 0)
                v3dReject(format("no \"formatVersion\" key — this file "
                    ~ "does not identify itself as a .v3d document. This build "
                    ~ "reads .v3d format version %d.", kV3dFormatVersion));
            else if (ver < kV3dFormatVersion)
                v3dReject(format("this document is .v3d format version "
                    ~ "%d, written by an EARLIER build of the editor; this "
                    ~ "build reads version %d only and does not convert older "
                    ~ "documents (deliberate clean break, no migration). The "
                    ~ "file is not damaged.", ver, kV3dFormatVersion));
            else
                v3dReject(format("this document is .v3d format version "
                    ~ "%d, written by a NEWER build of the editor; this build "
                    ~ "reads version %d only. The file is not damaged — open "
                    ~ "it with a build that reads version %d.",
                    ver, kV3dFormatVersion, ver));
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
            v3dReject("missing or non-array \"layers\"");
            return false;
        }
        if (lp.array.length == 0) {
            v3dReject("empty \"layers\" array");
            return false;
        }
        foreach (li, lj; lp.array) {
            if (lj.type != JSONType.object) {
                v3dReject(format("layer %d is not an object", li));
                return false;
            }

            // --- the item KIND ----------------------------------------------
            // Optional, defaulting to "mesh" (the kind every pre-v8 document
            // held and `Layer.kind`'s own default), but an UNKNOWN token is a
            // REJECT: silently turning a kind we do not understand into a mesh
            // would produce an item whose payload block we then fail to find,
            // or — worse — one we misread as geometry. `kindFromToken` is the
            // validated chokepoint and leaves `kind` untouched when it says no.
            ItemKind kind = ItemKind.Mesh;
            if (auto tp = "type" in lj) {
                if (tp.type != JSONType.string || !kindFromToken(tp.str, kind)) {
                    v3dReject(format("layer %d has an unknown item type "
                        ~ "%s — this build does not know what that is, and "
                        ~ "guessing would silently change the document",
                        li, tp.toString()));
                    return false;
                }
            }

            auto layer = new Layer;
            layer.kind = kind;

            // --- payload blocks, BEFORE channels ----------------------------
            // The channel injection binds param pointers into the payload
            // (an image item's `colorspace` / `useAlpha` live on `ImageData`),
            // so the payload has to exist first or the provider falls back to
            // the base bundle and those channels are silently dropped.
            //
            // TWO JOBS, ONE `if` — the trap task 0612 Stage 9 walked into.
            // This block reads a payload BLOCK off the wire and it CONSTRUCTS
            // the object the channel injection binds into. A kind that needs
            // only the second job still needs an arm here, and the plan that
            // asked "does the plane need a payload block in the file?"
            // answered the first question correctly (no) and skipped the
            // second. Measured before the fix: the writer emitted all ten of
            // the image plane's channels, the reader restored the envelope and
            // every transform component, and every channel came back at its
            // DEFAULT because `imagePlaneOrNull()` was null. If you add a
            // payload-bearing kind, the question is not "what does it write",
            // it is "what does the injection need to already exist".
            if (kindInfo(kind).hasMesh) {
                auto mp = "mesh" in lj;
                if (mp is null || mp.type != JSONType.object) {
                    v3dReject(format("layer %d is a \"%s\" item and must "
                        ~ "carry a \"mesh\" object", li, tokenOf(kind)));
                    return false;
                }
                if (!meshFromJson(*mp, layer.meshRef()))
                    return false;
            }
            if (kindInfo(kind).hasImage) {
                auto img = new ImageData();
                layer.imageRef() = img;
                string stored;
                if (auto ip = "image" in lj) {
                    if (ip.type == JSONType.object) {
                        if (auto fp = "filename" in *ip)
                            if (fp.type == JSONType.string) stored = fp.str;
                    } else {
                        v3dWarn(format("ignoring layer %d \"image\": not an object", li));
                    }
                }
                // Resolve the STORED form against THIS document's location —
                // which is what makes a document that moved to another folder
                // still find the images that travelled with it.
                img.storedPath = resolveStoredPath(stored, path);
                // §Q4: a file that is not there is NOT a malformed document.
                // The item keeps its path and reports itself missing; the load
                // continues. `refreshImageMeta` already logged the reason and
                // has left `missing` true.
                if (img.storedPath.length > 0 && !refreshImageMeta(img))
                    v3dWarn(format("layer %d: image \"%s\" could not be read; "
                        ~ "the item keeps its path and is marked missing",
                        li, img.storedPath));
            }
            // The image plane has NO payload block in the format — its ten
            // channels ride the generic `channels` object, which is why the
            // v8 schema needed no version step for this kind and
            // `kV3dFormatVersion` is still 8. What it does need is the
            // payload OBJECT, constructed here so the injection a few lines
            // down has somewhere to bind. Default-constructed and then
            // overwritten by the file's channels: a channel the file omits
            // keeps `ImagePlaneData`'s own default, which is the same rule
            // every other channel already follows.
            if (kindInfo(kind).hasImagePlane)
                layer.imagePlaneRef() = new ImagePlaneData();

            // --- channels ---------------------------------------------------
            // Defaults FIRST, so a channel the file omits keeps a sensible
            // value rather than whatever the injector did not write.
            layer.name = format("Layer %d", li + 1);
            if (auto cp = "channels" in lj) {
                if (cp.type == JSONType.object) {
                    // Strip `readonly_` before injecting (decision 2):
                    // `injectParamsInto` is a generic typed-pointer writer with
                    // no policy of its own, so a read-only channel left in the
                    // list would be authored here behind the command that owns
                    // it. This is the same refusal `layer.attr` already makes.
                    auto prov = new LayerPropsProvider(layer);
                    Param[] writable;
                    foreach (ref p; prov.params())
                        if (!p.readonly_) writable ~= p;
                    // MAY THROW (unknown enum tag, wrong JSON type for a String
                    // or Vec3). Caught by the outer `catch (Exception)` — and
                    // this runs BEFORE the atomic swap, which is what makes a
                    // bad channel value a clean reject instead of a
                    // half-committed document (decision 6).
                    //
                    // The TOLERANT form (task 3150), because decision 6 was
                    // about the document's SHAPE and this is a route into it
                    // for one scalar. A numeric channel with no legal number
                    // to land on — `"pos.x":"nope"`, a NaN, `1e39` (finite
                    // JSON, infinite float) — is DROPPED and named, and the
                    // component keeps the identity written a few lines above.
                    // The strict `injectParamsInto` throws there instead, and
                    // that refusal is right at the wire edge and wrong here:
                    // it loses a whole document over one corrupt scalar.
                    // Dropping is also strictly better than the `0.0` this
                    // route substituted before task 3021 — that 0 is a
                    // SINGULAR `scl`, which the band repair below then had to
                    // rescue. See params.d's InjectPolicy header.
                    foreach (badName; injectParamsTolerant(writable, *cp))
                        v3dWarn(format("layer %d channel \"%s\": value is not "
                            ~ "a number this channel can hold; the channel "
                            ~ "keeps its default", li, badName));
                } else {
                    v3dWarn(format("ignoring layer %d \"channels\": not an object", li));
                }
            }
            // R7 (task 0614): the generic injector applies only the DECLARED
            // `.min`/`.max`, which caps the scale magnitude from above but
            // cannot express the exclusion band around zero and cannot reject a
            // NaN (every comparison against NaN is false). `.v3d` is the
            // native format and therefore the likeliest carrier of a poisoned
            // value, so the band is enforced here exactly as the two command
            // write paths enforce it. `ItemXform.init` is the "prior" because a
            // fresh load has none.
            if (kindInfo(kind).hasXform) {
                ItemXform noPrior;
                if (sanitizeItemXform(layer.xform, noPrior))
                    v3dWarn(format("layer %d xform carried out-of-range values; "
                        ~ "clamped scale to [%g, %g] (sign preserved) and "
                        ~ "replaced any non-finite component with its identity",
                        li, MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG));
            }

            // Persist the item-selection SET. Default deselected; the mutator
            // pass below re-asserts the ≥1-selected + primary invariants.
            bool sel = false;
            if (auto sp = "selected" in lj)
                sel = (sp.type == JSONType.true_);

            parsed   ~= layer;
            selected ~= sel;
        }

        // --- second pass: resolve `parent` and `links` -----------------------
        // Deliberately after EVERY layer exists: an index may name an item that
        // appears later in the file, and that is the ordinary case (a consumer
        // written before the image it points at). Both are validated against
        // the parsed length and reported tolerantly — a bad reference is a
        // dropped reference, not a rejected document, matching the `uvMaps`
        // stance for the same reason (the rest of the file is still good).
        foreach (li, lj; lp.array) {
            if (auto pp = "parent" in lj) {
                if (pp.type == JSONType.integer || pp.type == JSONType.uinteger) {
                    const long a = (pp.type == JSONType.uinteger)
                        ? cast(long) pp.uinteger : pp.integer;
                    if (a < 0 || a >= cast(long) parsed.length)
                        v3dWarn(format("ignoring layer %d \"parent\": index %d "
                            ~ "is outside [0, %d)", li, a, parsed.length));
                    else if (cast(size_t) a == li)
                        v3dWarn(format("ignoring layer %d \"parent\": an item "
                            ~ "cannot be its own parent", li));
                    else
                        parsed[li].parent = parsed[cast(size_t) a];
                } else if (pp.type != JSONType.null_) {
                    v3dWarn(format("ignoring layer %d \"parent\": not an index", li));
                }
            }
            if (auto kp = "links" in lj) {
                if (kp.type != JSONType.array) {
                    v3dWarn(format("ignoring layer %d \"links\": not an array", li));
                } else foreach (ei, e; kp.array) {
                    if (e.type != JSONType.object) {
                        v3dWarn(format("ignoring layer %d links[%d]: not an object", li, ei));
                        continue;
                    }
                    string slot;
                    if (auto sp2 = "slot" in e)
                        if (sp2.type == JSONType.string) slot = sp2.str;
                    if (slot.length == 0) {
                        v3dWarn(format("ignoring layer %d links[%d]: missing/empty slot name", li, ei));
                        continue;
                    }
                    long t = -1;
                    if (auto tp2 = "target" in e) {
                        if (tp2.type == JSONType.integer)       t = tp2.integer;
                        else if (tp2.type == JSONType.uinteger) t = cast(long) tp2.uinteger;
                    }
                    if (t < 0 || t >= cast(long) parsed.length) {
                        v3dWarn(format("ignoring layer %d link \"%s\": target %d "
                            ~ "is outside [0, %d)", li, slot, t, parsed.length));
                        continue;
                    }
                    parsed[li].setLink(slot, parsed[cast(size_t) t]);
                }
            }
        }

        // --- primaryLayer: -1 → EMPTY selection; else clamped + kind-corrected
        //
        // TASK 0654: a NEGATIVE `primaryLayer` is not a malformed index any
        // more, it is the empty item selection. It used to be clamped to 0,
        // which is exactly the substitution this task exists to remove — and
        // the clamp is kept for a too-LARGE index, which really is a caller
        // naming a layer badly.
        size_t primaryIndex = 0;
        bool   emptySelection = false;
        if (auto pp = "primaryLayer" in doc) {
            long a = 0;
            if (pp.type == JSONType.integer)        a = pp.integer;
            else if (pp.type == JSONType.uinteger)  a = cast(long) pp.uinteger;
            if (a < 0)                          emptySelection = true;
            if (a >= cast(long) parsed.length)  a = cast(long) parsed.length - 1;
            if (!emptySelection) primaryIndex = cast(size_t) a;
        }
        // Decision 5. v7's reader could only ever produce mesh-kind layers, so
        // the raw write of `document.primary` that used to live below was
        // harmless by construction; the `"type"` token is exactly what ends
        // that, so v8 is where the exposure is closed. A malformed index is a
        // REPAIRABLE inconsistency (re-home to the first item that can be the
        // edit target) — but a document with NO such item is not repairable at
        // all: `Document`'s invariants have no representable answer, and every
        // consumer of `layers` would then be reasoning about a document the
        // type system says cannot exist. Reject that one; the caller's
        // document is untouched (nothing has been swapped yet).
        // Task 0654: skipped when the file declares an EMPTY selection — there
        // is no primary to kind-check, and the "no `canBePrimary` item at all"
        // rejection below still has to run, because that document is
        // unrepresentable regardless of what is selected in it.
        if (emptySelection) {
            bool any = false;
            foreach (l; parsed) if (kindInfo(l.kind).canBePrimary) { any = true; break; }
            if (!any) {
                v3dReject("no item in this document can be the mesh edit "
                    ~ "target — a document must contain at least one item that "
                    ~ "`canBePrimary`, and this one contains none");
                return false;
            }
        } else if (!kindInfo(parsed[primaryIndex].kind).canBePrimary) {
            size_t rehome = parsed.length;
            foreach (i, l; parsed)
                if (kindInfo(l.kind).canBePrimary) { rehome = i; break; }
            if (rehome == parsed.length) {
                v3dReject("no item in this document can be the mesh edit "
                    ~ "target — a document must contain at least one item that "
                    ~ "`canBePrimary`, and this one contains none");
                return false;
            }
            v3dWarn(format("\"primaryLayer\" %d names a \"%s\" item, which "
                ~ "cannot be the mesh edit target; re-homing the primary to "
                ~ "layer %d and leaving the focus where the file put it",
                primaryIndex, tokenOf(parsed[primaryIndex].kind), rehome));
            primaryIndex = rehome;
        }

        // --- focusedItem: optional; defaults to the primary ------------------
        size_t focusIndex = primaryIndex;
        if (auto fp = "focusedItem" in doc) {
            long a = -1;
            if (fp.type == JSONType.integer)        a = fp.integer;
            else if (fp.type == JSONType.uinteger)  a = cast(long) fp.uinteger;
            if (a < 0 || a >= cast(long) parsed.length)
                v3dWarn(format("ignoring \"focusedItem\" %d: outside [0, %d)",
                    a, parsed.length));
            else
                focusIndex = cast(size_t) a;
        }

        // --- atomic swap: everything parsed and injected; commit ------------
        // Nothing above this line touched `document`, so every `return false`
        // so far left the caller's document byte-identical. Nothing below can
        // throw.
        document.layers = parsed;
        document.noteLayerListChanged();
        // Task 0671: the item-selection state names the PREVIOUS document's
        // items (this is the app's live `Document`, handed by `ref`), so drop
        // it wholesale before rebuilding from the file. `clearItemSelection`
        // would be the wrong call here — it MOVES items into history rather
        // than forgetting them, which is exactly what must not survive a load.
        document.resetSelectionState();

        // Re-assert the selection-set invariants via the mutators, never by
        // writing raw fields. `setActive` alone is enough to install the
        // primary now that `primaryIndex` is guaranteed `canBePrimary` above —
        // the raw `document.primary = parsed[primaryIndex]` that used to sit
        // here (and that `document.d` flagged as the last remaining L3
        // violation) is gone with it.
        // TASK 0654 — `primaryLayer: -1` restores the EMPTY selection, and it
        // does so by running the mutator, not by leaving the fields at their
        // parsed defaults: `document` is the app's LIVE document (`FileLoad`
        // hands it by `ref`), so `primary`/`focusedItem` still point at the
        // PREVIOUS document's layers and would be stale, not empty.
        //
        // TASK 0668 — the per-layer `selected` bits ARE re-applied here, and
        // this is a correction, not an addition. 0654 skipped them on the
        // stated ground that "`primaryLayer: -1` and a selected layer cannot
        // both be true" — a consequence of its biconditional, which 0668
        // split. `primaryLayer: -1` now means only "no MESH EDIT TARGET", and
        // the ordinary document that produces it is a reference plane (or a
        // clip) selected alone. Skipping the bits would round-trip that
        // document to an empty selection: the panel the user had open would
        // come back showing nothing, with no error anywhere to explain it.
        //
        // Only `!canBePrimary` items are re-selected. A file that says -1
        // while marking a MESH selected is self-contradictory — obeying the
        // `selected` bit would install the very primary the file said does
        // not exist — so that bit is reported and dropped, the same way an
        // out-of-model `focusedItem` is below.
        if (emptySelection) {
            document.clearItemSelection();
            foreach (i, layer; parsed) {
                if (!selected[i]) continue;
                if (kindInfo(layer.kind).canBePrimary) {
                    v3dWarn(format("ignoring \"selected\" on layer %d: the file "
                        ~ "declares no edit target (\"primaryLayer\": -1) but "
                        ~ "marks a \"%s\" item selected, which would create "
                        ~ "one", i, tokenOf(layer.kind)));
                    continue;
                }
                document.selectItem(layer, SelMode.Add);
            }
            // Focus LAST, for the same reason the primary path states below:
            // the `Add` loop leaves the focus on whichever item came last in
            // file order, and the file's own `focusedItem` is the specific
            // answer. Only honoured for an item the loop actually selected.
            if (focusIndex < parsed.length && selected[focusIndex]
                && !kindInfo(parsed[focusIndex].kind).canBePrimary)
                document.selectItem(parsed[focusIndex], SelMode.Add);
            v3dInfo(format("document ready: %d item(s), no edit target, "
                        ~ "%d item(s) selected",
                            document.layers.length,
                            document.selectedItemCount));
            return true;
        }

        // TASK 0671 — the file's edit target may be LATCHED, i.e. named by
        // `primaryLayer` while its own `"selected"` is false. That is now an
        // ordinary saved state (drop the item selection, or select a reference
        // plane, and save), and it is the state the old shape here could not
        // read back: `setActive(primaryIndex)` SELECTS the item it installs,
        // so the document would come back with a selection the user never
        // left behind.
        //
        // Restore the SET first, in file order, then decide the target from
        // what the file said about it — selected ⇒ re-seat at the head of the
        // current queue; not selected ⇒ re-seat at the head of its kind's
        // history bucket. Both are the same statement ("this item is first in
        // the walk") made in whichever of the two lists the file put it in.
        document.clearItemSelection();
        foreach (i, layer; parsed)
            if (selected[i]) document.selectItem(layer, SelMode.Add);
        if (selected[primaryIndex])
            document.setPrimary(document.layers[primaryIndex]);
        else
            document.latchEditTarget(document.layers[primaryIndex]);
        // ~~Force the primary visible if the file marked it hidden (an
        // inconsistent file can't leave the edit target invisible).~~ RETIRED
        // (task 0671): a hidden edit target is not an inconsistency, it is a
        // measured state — hiding the target does not hand it on (`tests/
        // fixtures/edit_target_legality.json`, cell
        // `hidden_mesh_keeps_the_target`). Forcing `visible` here made the
        // round trip lose the user's hide.

        // Focus LAST: the `Add` loop above left the focus on whichever selected
        // item came last in file order, so a file that named a different focus
        // re-states it here — through the mutator, which also satisfies the
        // `focusedItem.selected` invariant.
        //
        // TASK 0671 — the "not representable" arm is gone. It refused a focus
        // on a `canBePrimary` item that was not the primary, on the (then true)
        // ground that every mutator focusing such an item also made it the
        // target. `add` no longer promotes: select mesh A, ctrl-add mesh B, and
        // the focus is B while the target is A. That is now the ordinary
        // multi-mesh selection, and dropping it on load would have moved the
        // user's focus without saying so. The one case still refused is a focus
        // on an item the file did not mark selected, which the invariant
        // forbids outright.
        if (focusIndex < parsed.length && focusIndex != primaryIndex) {
            auto f = parsed[focusIndex];
            if (selected[focusIndex])
                document.selectItem(f, SelMode.Add);
            else
                v3dWarn(format("ignoring \"focusedItem\" %d: the file does not "
                    ~ "mark that item selected, and the focus is the current "
                    ~ "selection's own pointer", focusIndex));
        }

        v3dInfo(format("document ready: %d item(s), primary=%d, focus=%d",
                        document.layers.length, document.activeIndex,
                        document.indexOf(document.focusedItem)));
        return true;
    } catch (Exception e) {
        // Backstop for any typed std.json access not guarded above AND for the
        // param codec, which throws a plain `Exception` on a channel value it
        // refuses (decision 6). `JSONException` alone would let that one escape
        // `readV3d` entirely and past `FileLoad`, which only checks the `bool`.
        //
        // The guarantee this preserves: `document` is mutated only at the swap
        // above, after every reject, so a throw before then leaves the caller's
        // document intact.
        v3dReject(e.msg);
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
    // Task 0654: a file saved with an empty item selection has no ACTIVE layer
    // for this overload to flatten. Refuse — the alternative is to hand back
    // layer 0 under the name "the active layer", which is a different mesh than
    // the one asked for and indistinguishable from success at the call site.
    // `mesh` is left untouched, matching this overload's stated contract.
    if (!tmp.hasEditTarget()) {
        v3dWarn(format("%s was saved with no item selected, so it has no "
            ~ "active layer to read a single mesh from", path));
        return false;
    }
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
        v3dReject("missing or non-array \"vertices\"");
        return false;
    }
    Vec3[] verts;
    verts.reserve(vp.array.length);
    foreach (i, vj; vp.array) {
        if (vj.type != JSONType.array || vj.array.length < 3) {
            v3dReject(format("vertex %d is not an [x,y,z] triple", i));
            return false;
        }
        verts ~= Vec3(jsonFloat(vj.array[0]),
                      jsonFloat(vj.array[1]),
                      jsonFloat(vj.array[2]));
    }

    // --- faces (required) ---
    auto fp = "faces" in m;
    if (fp is null || fp.type != JSONType.array) {
        v3dReject("missing or non-array \"faces\"");
        return false;
    }
    uint[][] polys;
    polys.reserve(fp.array.length);
    foreach (i, fj; fp.array) {
        if (fj.type != JSONType.array) {
            v3dReject(format("face %d is not an array", i));
            return false;
        }
        uint[] face;
        face.reserve(fj.array.length);
        foreach (ij; fj.array) {
            if (ij.type != JSONType.integer && ij.type != JSONType.uinteger) {
                v3dReject(format("face %d has a non-integer index", i));
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
        // Silently drop faces below the smallest ring the editor can BUILD,
        // rather than reject the whole file (the policy importLWO uses).
        //
        // The floor is TWO, not three, and that is load-bearing since task
        // 1200: `mesh.makePolygon` now builds a two-point polygon, because the
        // reference does (ledger row 7). At `>= 3` this reader silently ate it
        // on the way back in — and not only it: `faceSubpatch`, `faceMaterial`,
        // `facePart` and the Hide bits are applied BY POSITION against `polys`
        // below, so every face after the dropped one inherited its neighbour's
        // attributes, and the corner count shifted enough to fail every UV
        // map's length check and drop those too. A document whose only face was
        // the two-point one failed to load at all ("no polygons"). Silent
        // corruption of a document the editor itself had just written.
        //
        // Reached independently from a SECOND route and measured there too
        // (task 1210): `vert.join keep:1` leaves two-point polygons behind, and
        // an 8-face fan came back from save->load with 6. Two probes converging
        // on one line is why this is a real defect and not an artefact of either
        // new shape.
        if (face.length >= 2)
            polys ~= face;
    }

    // NO POLYGON REQUIREMENT (task 1210). A points-only mesh is a state the
    // editor can now REACH: `vert.join` over every vertex of a plate leaves
    // one free vertex and no faces, matching the reference. The writer emitted
    // that document happily and this reader refused to read it back — the
    // document saved, and opening it failed with "no polygons".
    //
    // NO VERTEX REQUIREMENT EITHER (task 1890). What stood here was 1210's own
    // leftover — "the vertex requirement above stays: a mesh with neither
    // vertices nor polygons is still nothing at all" — and that sentence is
    // FALSE about this editor. An EMPTY MESH ITEM is not nothing; it is what
    // the Add Item ▸ Mesh button makes, it is a first-class row in the Items
    // list, and both this list and the reference give it its own appearance
    // (`ItemGlyph.Empty`, a greyed name) precisely because a created-but-empty
    // layer is an ordinary thing to have.
    //
    // So this was the SAME defect as 1210 one clause further along, and it bit
    // harder: the reject is raised per LAYER but fails the WHOLE file, so one
    // empty layer made the entire document unopenable. Reported from a
    // backdrop-only scene — two image planes and an empty mesh to model into —
    // but the image planes are incidental: `layer.add` then save then load is
    // the whole reproduction, measured before this line was touched.
    //
    // The STRUCTURAL guards are untouched and still do the real work: a
    // "vertices" key that is missing or is not an array still rejects above,
    // as does a malformed triple. This clause only ever judged an
    // already-well-formed EMPTY array, which is a document the writer emits.

    // Out-of-range vertex index check before committing anything.
    const uint nv = cast(uint) verts.length;
    foreach (fi, face; polys)
        foreach (idx; face)
            if (idx >= nv) {
                v3dReject(format("face %d references vertex %d "
                                ~ "(only %d verts)", fi, idx, nv));
                return false;
            }

    // --- optional: authored wire edges (task 3910) ---
    // Tolerant like the other additive arrays: malformed or out-of-range
    // entries are ignored individually. Sort before insertion so the freshly
    // loaded live edge order is exactly Mesh.canonicalEdgeOrder(): face walk,
    // then authored pairs by ascending edgeKey.
    uint[2][] wireEdges;
    if (auto wp = "wireEdges" in m) {
        if (wp.type == JSONType.array) {
            wireEdges.reserve(wp.array.length);
            foreach (wi, pairJ; wp.array) {
                if (pairJ.type != JSONType.array || pairJ.array.length != 2) {
                    v3dWarn(format("ignoring wireEdges[%d]: expected [a,b]", wi));
                    continue;
                }
                long[2] raw;
                bool valid = true;
                foreach (k; 0 .. 2) {
                    const x = pairJ.array[k];
                    if (x.type == JSONType.integer) raw[k] = x.integer;
                    else if (x.type == JSONType.uinteger) raw[k] = cast(long)x.uinteger;
                    else valid = false;
                }
                if (!valid || raw[0] < 0 || raw[1] < 0 ||
                    raw[0] >= nv || raw[1] >= nv || raw[0] == raw[1]) {
                    v3dWarn(format("ignoring wireEdges[%d]: invalid endpoint pair", wi));
                    continue;
                }
                wireEdges ~= [cast(uint)raw[0], cast(uint)raw[1]];
            }
            sort!((a, b) => edgeKey(a[0], a[1]) < edgeKey(b[0], b[1]))(wireEdges);
        } else {
            v3dWarn("ignoring non-array \"wireEdges\"");
        }
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
                // Generated from the same table as the writer — see
                // kSurfaceFields. Per-type tolerance is unchanged: a string
                // key of the wrong type is ignored, a colour needs three
                // components, a scalar goes through jsonFloat (which already
                // tolerates every numeric spelling).
                static foreach (k; kSurfaceFields) {{
                    static if (k.json.length) {
                        alias F = typeof(__traits(getMember, Surface, k.field));
                        if (auto kp = k.json in sj) {
                            static if (is(F == string)) {
                                if (kp.type == JSONType.string)
                                    __traits(getMember, s, k.field) = kp.str;
                            } else static if (is(F == Vec3)) {
                                if (kp.type == JSONType.array
                                    && kp.array.length >= 3)
                                    __traits(getMember, s, k.field) =
                                        Vec3(jsonFloat(kp.array[0]),
                                             jsonFloat(kp.array[1]),
                                             jsonFloat(kp.array[2]));
                            } else static if (is(F == float)) {
                                __traits(getMember, s, k.field) = jsonFloat(*kp);
                            } else static if (is(F == bool)) {
                                // JSON booleans only; any other type keeps the default.
                                if (kp.type == JSONType.true_)
                                    __traits(getMember, s, k.field) = true;
                                else if (kp.type == JSONType.false_)
                                    __traits(getMember, s, k.field) = false;
                            } else
                                static assert(false, "no .v3d surface codec for "
                                                   ~ F.stringof);
                        }
                    }
                }}
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

    // --- optional: edgeMaps (v8-within-version addition, task 1062) ---
    // Parse into a staging list now; applied after `buildLoops` below since
    // the Edge domain is edge-index-keyed (mesh.edges only exists once
    // topology is built — mirrors the uvMaps/weightMaps staging discipline).
    // `kind` IS read (task 1062 review, NIT 7 — an earlier revision of this
    // comment claimed it was read while the parser never actually extracted
    // it from the JSON object at all): an unrecognized kind is still loaded
    // as a plain named Edge map (forward-compatible, same tolerant stance as
    // every other optional array here), but a kind that explicitly claims
    // to be the RESERVED `"creaseWeight"` kind under a non-reserved name is
    // rejected below (`kCreaseWeightMapName` is what a reader — subpatch_osd.d's
    // creaseWeightMap() — actually keys on, so a mismatched claim would
    // silently register a decoy the crease consumer never sees).
    struct StagedEm { string name; string kind; float[] data; }
    StagedEm[] stagedEm;
    if (auto emp = "edgeMaps" in m) {
        if (emp.type == JSONType.array) {
            foreach (ei, ej; emp.array) {
                if (ej.type != JSONType.object) {
                    v3dWarn(format("ignoring edgeMaps[%d]: not an object", ei));
                    continue;
                }
                string nm;
                if (auto np = "name" in ej)
                    if (np.type == JSONType.string) nm = np.str;
                if (nm.length == 0) {
                    v3dWarn(format("ignoring edgeMaps[%d]: missing/empty name", ei));
                    continue;
                }
                string kind;
                if (auto kp = "kind" in ej)
                    if (kp.type == JSONType.string) kind = kp.str;
                if (kind == "creaseWeight" && nm != kCreaseWeightMapName) {
                    v3dWarn(format("ignoring edgeMaps[%s]: kind \"creaseWeight\" "
                                  ~ "claimed under a non-reserved name "
                                  ~ "(expected \"%s\")", nm, kCreaseWeightMapName));
                    continue;
                }
                auto dap = "data" in ej;
                if (dap is null || dap.type != JSONType.array) {
                    v3dWarn(format("ignoring edgeMaps[%s]: missing/non-array data", nm));
                    continue;
                }
                float[] data;
                data.reserve(dap.array.length);
                foreach (fj; dap.array)
                    data ~= jsonFloat(fj);
                stagedEm ~= StagedEm(nm, kind, data);
            }
        } else {
            v3dWarn("ignoring non-array \"edgeMaps\"");
        }
    }

    // --- optional: vertexMorphs (task 1069 addition, within-version) ---
    // Point-domain dim-3 morph maps, SPARSE on the wire: parallel `verts` /
    // `values` arrays, `values.length == verts.length * 3`. Staged here and
    // applied after the mesh is committed, the same discipline every other
    // optional map array follows.
    //
    // UNTRUSTED INPUT. A `.v3d` can be hand-edited or produced by something
    // else, and every decoded index goes straight into a dense array. So:
    // every index is range-checked against `vertices.length` at APPLY time
    // (the count is not known yet here), an out-of-range one is skipped with
    // a warning and the rest of the map still loads, and nothing here ever
    // throws — the same tolerant stance §Q3 sets for the whole codec.
    struct StagedVm { string name; string kind; long[] verts; float[] values; }
    StagedVm[] stagedVm;
    if (auto vmp = "vertexMorphs" in m) {
        if (vmp.type == JSONType.array) {
            foreach (vi, vj; vmp.array) {
                if (vj.type != JSONType.object) {
                    v3dWarn(format("ignoring vertexMorphs[%d]: not an object", vi));
                    continue;
                }
                string nm;
                if (auto np = "name" in vj)
                    if (np.type == JSONType.string) nm = np.str;
                if (nm.length == 0) {
                    v3dWarn(format("ignoring vertexMorphs[%d]: missing/empty name", vi));
                    continue;
                }
                string kind;
                if (auto kp = "kind" in vj)
                    if (kp.type == JSONType.string) kind = kp.str;
                // Unlike `edgeMaps`, an unknown kind is NOT loaded as a plain
                // map: the kind is the only thing that says what the stored
                // numbers MEAN, so guessing would silently mis-place every
                // vertex the map touches.
                if (kind != "relative" && kind != "absolute") {
                    v3dWarn(format("ignoring vertexMorphs[%s]: unknown kind \"%s\" "
                                  ~ "(expected \"relative\" or \"absolute\")", nm, kind));
                    continue;
                }
                auto mvp = "verts"  in vj;
                auto sp  = "values" in vj;
                if (mvp is null || mvp.type != JSONType.array
                 || sp is null || sp.type != JSONType.array) {
                    v3dWarn(format("ignoring vertexMorphs[%s]: missing/non-array "
                                  ~ "verts or values", nm));
                    continue;
                }
                if (sp.array.length != mvp.array.length * 3) {
                    v3dWarn(format("ignoring vertexMorphs[%s]: values length %d != "
                                  ~ "%d verts * 3", nm, sp.array.length,
                                  mvp.array.length));
                    continue;
                }
                long[] mvVerts;
                mvVerts.reserve(mvp.array.length);
                bool malformed = false;
                foreach (ij; mvp.array) {
                    if (ij.type != JSONType.integer && ij.type != JSONType.uinteger) {
                        malformed = true;
                        break;
                    }
                    mvVerts ~= (ij.type == JSONType.integer)
                             ? ij.integer : cast(long) ij.uinteger;
                }
                if (malformed) {
                    v3dWarn(format("ignoring vertexMorphs[%s]: non-integer vertex index", nm));
                    continue;
                }
                float[] values;
                values.reserve(sp.array.length);
                foreach (fj; sp.array)
                    values ~= jsonFloat(fj);
                stagedVm ~= StagedVm(nm, kind, mvVerts, values);
            }
        } else {
            v3dWarn("ignoring non-array \"vertexMorphs\"");
        }
    }

    // --- optional: selectionSets (task 1060 addition, within-version) ---
    // Parse into staging lists now; applied after `buildLoops`/`rebuildEdges`
    // below, same discipline as `uvMaps`/`weightMaps`/`edgeMaps` — the EDGE
    // domain in particular needs `edgeIndex(a,b)` to resolve, which needs
    // `edges`/`edgeIndexMap` built. Tolerant per entry: a malformed member,
    // an invalid name, an out-of-range index, an unresolvable edge pair, or
    // an over-cap set count is a per-entry SKIP with a warning — never a
    // hard reject of the whole file (§Q3's standing policy).
    struct StagedSetVertex  { string name; long[]    members; }
    struct StagedSetPolygon { string name; long[]    members; }
    struct StagedSetEdge    { string name; long[2][] members; }
    StagedSetVertex[]  stagedSetVertex;
    StagedSetPolygon[] stagedSetPolygon;
    StagedSetEdge[]    stagedSetEdge;
    if (auto ssp = "selectionSets" in m) {
        if (ssp.type == JSONType.object) {
            if (auto svp = "vertex" in *ssp) {
                if (svp.type == JSONType.array) {
                    foreach (vi, vj; svp.array) {
                        if (vj.type != JSONType.object) {
                            v3dWarn(format("ignoring selectionSets.vertex[%d]: not an object", vi));
                            continue;
                        }
                        string nm;
                        if (auto np = "name" in vj) if (np.type == JSONType.string) nm = np.str;
                        if (nm.length == 0) {
                            v3dWarn(format("ignoring selectionSets.vertex[%d]: missing/empty name", vi));
                            continue;
                        }
                        auto mp = "members" in vj;
                        if (mp is null || mp.type != JSONType.array) {
                            v3dWarn(format("ignoring selectionSets.vertex[%s]: missing/non-array members", nm));
                            continue;
                        }
                        long[] mem;
                        foreach (ej; mp.array) {
                            if (ej.type == JSONType.integer)       mem ~= ej.integer;
                            else if (ej.type == JSONType.uinteger) mem ~= cast(long) ej.uinteger;
                        }
                        stagedSetVertex ~= StagedSetVertex(nm, mem);
                    }
                } else {
                    v3dWarn("ignoring non-array \"selectionSets.vertex\"");
                }
            }
            if (auto spp = "polygon" in *ssp) {
                if (spp.type == JSONType.array) {
                    foreach (pi, pj; spp.array) {
                        if (pj.type != JSONType.object) {
                            v3dWarn(format("ignoring selectionSets.polygon[%d]: not an object", pi));
                            continue;
                        }
                        string nm;
                        if (auto np = "name" in pj) if (np.type == JSONType.string) nm = np.str;
                        if (nm.length == 0) {
                            v3dWarn(format("ignoring selectionSets.polygon[%d]: missing/empty name", pi));
                            continue;
                        }
                        auto mp = "members" in pj;
                        if (mp is null || mp.type != JSONType.array) {
                            v3dWarn(format("ignoring selectionSets.polygon[%s]: missing/non-array members", nm));
                            continue;
                        }
                        long[] mem;
                        foreach (ej; mp.array) {
                            if (ej.type == JSONType.integer)       mem ~= ej.integer;
                            else if (ej.type == JSONType.uinteger) mem ~= cast(long) ej.uinteger;
                        }
                        stagedSetPolygon ~= StagedSetPolygon(nm, mem);
                    }
                } else {
                    v3dWarn("ignoring non-array \"selectionSets.polygon\"");
                }
            }
            if (auto sep = "edge" in *ssp) {
                if (sep.type == JSONType.array) {
                    foreach (ei, ej2; sep.array) {
                        if (ej2.type != JSONType.object) {
                            v3dWarn(format("ignoring selectionSets.edge[%d]: not an object", ei));
                            continue;
                        }
                        string nm;
                        if (auto np = "name" in ej2) if (np.type == JSONType.string) nm = np.str;
                        if (nm.length == 0) {
                            v3dWarn(format("ignoring selectionSets.edge[%d]: missing/empty name", ei));
                            continue;
                        }
                        auto mp = "members" in ej2;
                        if (mp is null || mp.type != JSONType.array) {
                            v3dWarn(format("ignoring selectionSets.edge[%s]: missing/non-array members", nm));
                            continue;
                        }
                        long[2][] mem;
                        foreach (pairJ; mp.array) {
                            if (pairJ.type != JSONType.array || pairJ.array.length != 2) continue;
                            long a, b;
                            auto aj = pairJ.array[0], bj = pairJ.array[1];
                            if (aj.type == JSONType.integer) a = aj.integer;
                            else if (aj.type == JSONType.uinteger) a = cast(long) aj.uinteger;
                            else continue;
                            if (bj.type == JSONType.integer) b = bj.integer;
                            else if (bj.type == JSONType.uinteger) b = cast(long) bj.uinteger;
                            else continue;
                            mem ~= [a, b];
                        }
                        stagedSetEdge ~= StagedSetEdge(nm, mem);
                    }
                } else {
                    v3dWarn("ignoring non-array \"selectionSets.edge\"");
                }
            }
        } else {
            v3dWarn("ignoring non-object \"selectionSets\"");
        }
    }

    // --- commit: rebuild the mesh on a fresh struct (mirrors importLWO) ---
    mesh = Mesh.init;
    mesh.vertices = verts;
    uint[ulong] edgeLookup;
    foreach (face; polys)
        mesh.addFaceFast(edgeLookup, face);
    foreach (ref wire; wireEdges)
        mesh.addWireEdgeFast(edgeLookup, wire[0], wire[1]);
    mesh.buildLoops();

    // Apply per-face subpatch flags (parallel to faces).
    //
    // The bound is hoisted, and that is not cosmetic: `mesh.isSubpatch` is a
    // materialized view — it allocates a fresh `bool[]` over every face on
    // each call — so asking it for `.length` once per FACE made this loop
    // quadratic in the face count.
    //
    // The bound read here is `faceMarks.length`, because that is the length the
    // view reports. `resizeSubpatch()` on the line above sets it to
    // `faces.length`, which makes the two equal today — but the read has to name
    // the array the view is built over, not the one that happens to match it.
    mesh.resizeSubpatch();
    const size_t nFaceMarks = mesh.faceMarks.length;
    int subpatchCount = 0;
    foreach (fi, flag; faceSubpatch) {
        if (fi >= nFaceMarks) break;
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
        // Task 1069: classify when the shape matches the uv kind's own
        // declaration. A uv block with a different dim is still loaded (the
        // codec has always been tolerant here) but stays `unclassified`
        // rather than claiming a kind whose declared shape it does not have.
        auto map = mesh.addMeshMap(su.name, su.dim, MapDomain.PolyVertex,
                                   su.dim == mesh_.kindInfo(MapKind.uv).dim
                                     ? MapKind.uv : MapKind.unclassified);
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

    // Apply staged Edge dim-1 maps (task 1062). Each map must have exactly
    // `edges.length` float entries — `edges` is settled by `buildLoops`
    // above in canonical order (face traversal, then sorted authored pairs),
    // so this check is what makes "the Nth entry belongs to the Nth edge"
    // true after a reload. `addMeshMap` registers a plain
    // Edge/dim-1 map regardless of `kind` — the reserved NAME is what a
    // reader (subpatch_osd.d's creaseWeightMap()) actually keys on, not the
    // `kind` string. An unknown/absent `kind` never blocks the load (still
    // registered as a plain named Edge map); the one `kind` value that DOES
    // block a load is `"creaseWeight"` claimed under a non-reserved name —
    // rejected above, in the staging loop, before this one ever sees it.
    int eMapCount = 0;
    foreach (ref se; stagedEm) {
        if (se.data.length != mesh.edges.length) {
            v3dWarn(format("ignoring edgeMaps[%s]: data length %d != "
                           ~ "%d edges", se.name, se.data.length,
                           mesh.edges.length));
            continue;
        }
        // Task 1069: stamp the kind so `kind` is not a field only morphs
        // populate. Only the one recognised value classifies; anything else
        // (absent, empty, a future string) stays `unclassified`, which is the
        // honest reading and is exactly what the negative kind filters are
        // written to tolerate.
        auto map = mesh.addMeshMap(se.name, 1, MapDomain.Edge,
                                   se.kind == "creaseWeight"
                                     ? MapKind.creaseWeight
                                     : MapKind.unclassified);
        if (map is null) {
            v3dWarn(format("ignoring edgeMaps[%s]: could not register map",
                           se.name));
            continue;
        }
        map.data[] = se.data[];
        ++eMapCount;
    }

    // Apply staged Point dim-3 morph maps (task 1069). Sparse on the wire:
    // each listed vertex index gets an entry (value AND presence); every
    // vertex NOT listed is left absent, which is the whole point of the block.
    //
    // Every index is range-checked HERE, against the committed vertex count —
    // a `.v3d` is untrusted input and these indices address a dense array
    // directly. An out-of-range index is skipped with a warning and the map
    // keeps loading; nothing throws and nothing is written out of bounds.
    int vmCount = 0;
    foreach (ref sv; stagedVm) {
        const MapKind kind = (sv.kind == "relative")
                           ? MapKind.morphRelative : MapKind.morphAbsolute;
        auto map = mesh.addMeshMapOfKind(kind, sv.name);
        if (map is null) {
            v3dWarn(format("ignoring vertexMorphs[%s]: could not register map",
                           sv.name));
            continue;
        }
        size_t skipped = 0;
        foreach (k, vidx; sv.verts) {
            if (!morphVertexIndexInBounds(vidx, mesh.vertices.length)) {
                ++skipped;
                continue;
            }
            // Count a REFUSED write too, not just an out-of-range index.
            // `MeshMap.setEntry` range-checks on its own, so this loop cannot
            // write out of bounds even with the guard above removed — which
            // means the guard above buys the DIAGNOSTIC, not the safety. A
            // refusal that produced no warning would be silent data loss.
            if (!map.setEntry(cast(size_t) vidx,
                              Vec3(sv.values[k * 3], sv.values[k * 3 + 1],
                                   sv.values[k * 3 + 2])))
                ++skipped;
        }
        if (skipped > 0)
            v3dWarn(format("vertexMorphs[%s]: skipped %d entr%s with an "
                          ~ "out-of-range vertex index (mesh has %d vertices)",
                          sv.name, skipped, skipped == 1 ? "y" : "ies",
                          mesh.vertices.length));
        ++vmCount;
    }

    // Apply staged selection sets (task 1060). `edges`/`edgeIndexMap` are
    // settled by `buildLoops()` above (same reason `edgeMaps` waits this
    // long), so the EDGE domain can resolve `[a,b]` pairs to a live edge
    // right here. `SetEditMode.replace` on a fresh (just-`ensureSlot`ed)
    // name is exactly "set membership to this list" — the same idiom
    // `weightMaps`'s `map.data[] = sw.data[]` uses for its own domain.
    int ssVertexCount = 0, ssEdgeCount = 0, ssPolygonCount = 0;
    foreach (ref sv; stagedSetVertex) {
        auto err = validateSetName(sv.name);
        if (err !is null) {
            v3dWarn(format("ignoring selectionSets.vertex[%s]: %s", sv.name, err));
            continue;
        }
        bool[] want = new bool[](mesh.vertices.length);
        bool ok = true;
        foreach (v; sv.members) {
            if (v < 0 || v >= cast(long) mesh.vertices.length) { ok = false; break; }
            want[cast(size_t) v] = true;
        }
        if (!ok) {
            v3dWarn(format("ignoring selectionSets.vertex[%s]: member index out of range",
                           sv.name));
            continue;
        }
        try {
            selSetEditVertex(mesh, sv.name, SetEditMode.replace, want);
            ++ssVertexCount;
        } catch (Exception e) {
            v3dWarn(format("ignoring selectionSets.vertex[%s]: %s", sv.name, e.msg));
        }
    }
    foreach (ref sp; stagedSetPolygon) {
        auto err = validateSetName(sp.name);
        if (err !is null) {
            v3dWarn(format("ignoring selectionSets.polygon[%s]: %s", sp.name, err));
            continue;
        }
        bool[] want = new bool[](mesh.faces.length);
        bool ok = true;
        foreach (f; sp.members) {
            if (f < 0 || f >= cast(long) mesh.faces.length) { ok = false; break; }
            want[cast(size_t) f] = true;
        }
        if (!ok) {
            v3dWarn(format("ignoring selectionSets.polygon[%s]: member index out of range",
                           sp.name));
            continue;
        }
        try {
            selSetEditPolygon(mesh, sp.name, SetEditMode.replace, want);
            ++ssPolygonCount;
        } catch (Exception e) {
            v3dWarn(format("ignoring selectionSets.polygon[%s]: %s", sp.name, e.msg));
        }
    }
    foreach (ref se; stagedSetEdge) {
        auto err = validateSetName(se.name);
        if (err !is null) {
            v3dWarn(format("ignoring selectionSets.edge[%s]: %s", se.name, err));
            continue;
        }
        // Per-PAIR graceful degrade (not per-entry reject, unlike vertex/
        // polygon above): a pair that no longer resolves to a live edge —
        // for example because one of its two vertices vanished —
        // is exactly the failure mode pair-keying exists to degrade
        // gracefully from. Dropping just that member, not the whole named
        // set, is the same conservative arm `selSetRekeyEdges` takes at
        // every in-session re-key site.
        bool[] want = new bool[](mesh.edges.length);
        foreach (pr; se.members) {
            if (pr[0] < 0 || pr[1] < 0) continue;
            const ei = mesh.edgeIndex(cast(uint) pr[0], cast(uint) pr[1]);
            if (ei == ~0u) continue;
            want[ei] = true;
        }
        try {
            selSetEditEdge(mesh, se.name, SetEditMode.replace, want);
            ++ssEdgeCount;
        } catch (Exception e) {
            v3dWarn(format("ignoring selectionSets.edge[%s]: %s", se.name, e.msg));
        }
    }

    v3dInfo(format("mesh ready: %d verts, %d edges, %d faces, "
                    ~ "%d marked subpatch, %d surfaces, %d uv map(s), "
                    ~ "%d weight map(s), %d edge map(s), %d selection set(s)",
                    mesh.vertices.length, mesh.edges.length,
                    mesh.faces.length, subpatchCount, mesh.surfaces.length,
                    uvMapCount, wMapCount, eMapCount,
                    ssVertexCount + ssEdgeCount + ssPolygonCount));
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
    import vibe3d.mesh.core.mesh       : makeCube;

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

    // Precondition: the degenerate numbers really are on disk. v8 carries the
    // transform as FLAT channel keys, not as a grouped `xform` block.
    {
        auto raw = parseJSON(readText(path));
        auto ch  = raw["layers"].array[0]["channels"];
        assert(jsonFloat(ch["scl.x"]) == 0.0f,
            "precondition: the file must literally carry scl.x == 0 — if the "
          ~ "WRITER has grown a band, this case is now loading a clean file "
          ~ "and pins nothing about the reader");
        assert(jsonFloat(ch["scl.y"]) < 0.0f
            && fabs(jsonFloat(ch["scl.y"])) < MIN_ITEM_SCALE_MAG,
            "precondition: scl.y is on disk as a negative under-floor value");
        assert(jsonFloat(ch["scl.z"]) > MAX_ITEM_SCALE_MAG,
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
// N9 — `edgeMaps[*].kind` IS ACTUALLY READ (task 1062 review, NIT 7).
//
// An earlier revision of the staging-loop comment claimed "`kind` is read"
// while the parser never extracted the field from the JSON object at all —
// a comment describing code that did not exist. This pins the one place
// `kind` now has a real effect: a `"creaseWeight"`-kind entry claimed under
// a name OTHER than the reserved `kCreaseWeightMapName` ("crease") is
// rejected, because `subpatch_osd.d`'s `creaseWeightMap()` keys on the NAME,
// not `kind` — a mismatched claim would otherwise silently register a decoy
// map the crease consumer never reads, while a human skimming the file sees
// `"kind":"creaseWeight"` and assumes it is live.
//
// Mutation: delete the `kind == "creaseWeight" && nm != kCreaseWeightMapName`
// guard in the staging loop → the bogus-named entry registers under its own
// (wrong) name and both assertions below redden (verified 2026-08-17).
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    Mesh m = makeCube();
    immutable uint ei = m.edgeIndex(0, 1);
    assert(ei != ~0u);
    assert(m.setCreaseWeight(ei, 0.4f));

    auto j = meshToJson(m);
    assert("edgeMaps" in j, "fixture precondition: the crease map was written");
    assert(j["edgeMaps"].array.length == 1);
    assert(j["edgeMaps"].array[0]["kind"].str == "creaseWeight");
    assert(j["edgeMaps"].array[0]["name"].str == kCreaseWeightMapName);

    // Spoof the name while keeping the reserved kind claim.
    j["edgeMaps"].array[0]["name"] = JSONValue("bogus");

    Mesh back;
    assert(meshFromJson(j, back),
        "a rejected entry must not fail the WHOLE load, only itself");
    assert(back.meshMap("bogus") is null,
        "a \"creaseWeight\"-kind entry under a non-reserved name must be "
      ~ "REJECTED, not silently registered under its own (wrong) name");
    assert(back.creaseWeightMap() is null,
        "…and since the only edgeMaps entry was rejected, no crease map "
      ~ "exists under the reserved name either");
}
